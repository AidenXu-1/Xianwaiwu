import AVFoundation
import Foundation

/// A small streaming percussion lane in source frames, mixed through the same rate processor as music.
struct BeatGuideRenderer {
    let format: AVAudioFormat
    let beatFrames: [Int64]
    let pulse: [Float]
    let lower: Int64
    let upper: Int64
    let looping: Bool
    private(set) var cursor: Int64

    init(sampleRate: Double, beats: [Double], start: Double, range: ClosedRange<Double>, looping: Bool) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        beatFrames = Array(Set(beats.filter { $0.isFinite && $0 >= 0 }.map { Int64(($0 * sampleRate).rounded()) })).sorted()
        lower = Int64((range.lowerBound * sampleRate).rounded())
        upper = Int64((range.upperBound * sampleRate).rounded())
        cursor = max(lower, min(upper, Int64((start * sampleRate).rounded())))
        self.looping = looping
        // Deterministic, short wooden tap. No sample files, model, meter, or invented downbeats.
        let count = Int(sampleRate * 0.035)
        var noise: UInt32 = 731
        pulse = (0..<count).map { i in
            noise = 1664525 &* noise &+ 1013904223
            let t = Double(i) / sampleRate
            let n = Double(noise & 0xffff) / 32768 - 1
            let attack = min(1, t / 0.0015)
            return Float(attack * (0.34 * sin(2 * .pi * 1250 * t) * exp(-150 * t) + 0.12 * n * exp(-250 * t)))
        }
    }
    private func previousBeat(_ frame: Int64) -> Int {
        var low = 0, high = beatFrames.count
        while low < high {
            let mid = (low + high) / 2
            if beatFrames[mid] <= frame { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
    mutating func nextBuffer(frames requested: Int? = nil) -> AVAudioPCMBuffer? {
        guard upper > lower, looping || cursor < upper else { return nil }
        let wanted = requested ?? Int(format.sampleRate * 0.5)
        let count = looping ? wanted : min(wanted, Int(upper - cursor))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        var index = previousBeat(cursor)
        for i in 0..<count {
            if cursor >= upper { cursor = lower; index = previousBeat(cursor) }
            while index + 1 < beatFrames.count && beatFrames[index + 1] <= cursor { index += 1 }
            let age = index >= 0 ? cursor - beatFrames[index] : Int64.max
            data[i] = age >= 0 && age < Int64(pulse.count) ? pulse[Int(age)] : 0
            cursor += 1
        }
        return buffer
    }
}

final class PracticeBeatGuide {
    let node = AVAudioPlayerNode()
    private(set) var format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var renderer: BeatGuideRenderer?
    private var generation = 0
    private var origin = 0.0
    private var range: ClosedRange<Double> = 0...0
    private var looping = false
    private(set) var renderedBuffers = 0
    private(set) var scheduledBuffers = 0
    private(set) var nonzeroScheduledFrames = 0

    func prepare(sampleRate: Double, engine: AVAudioEngine, mixer: AVAudioMixerNode) {
        stop()
        if !engine.attachedNodes.contains(node) { engine.attach(node) }
        if format.sampleRate != sampleRate || node.numberOfOutputs == 0 {
            engine.disconnectNodeOutput(node)
        }
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(node, to: mixer, format: format)
        node.volume = 0.3
    }
    func start(beats: [Double], from position: Double, range: ClosedRange<Double>, looping: Bool, at anchor: AVAudioTime) {
        stop()
        guard !beats.isEmpty, range.upperBound > range.lowerBound else { return }
        self.range = range; self.looping = looping
        renderer = BeatGuideRenderer(sampleRate: format.sampleRate, beats: beats, start: position, range: range, looping: looping)
        origin = Double(renderer!.cursor) / format.sampleRate
        renderedBuffers = 0; scheduledBuffers = 0; nonzeroScheduledFrames = 0
        let token = generation
        for _ in 0..<3 { schedule(token) }
        if scheduledBuffers > 0 { node.play(at: anchor) }
    }
    func stop() {
        generation += 1
        if node.isPlaying || renderer != nil { node.stop() }
        renderer = nil
    }
    private func schedule(_ token: Int) {
        guard generation == token, let buffer = renderer?.nextBuffer() else { return }
        scheduledBuffers += 1
        if let values = buffer.floatChannelData?[0] {
            nonzeroScheduledFrames += (0..<Int(buffer.frameLength)).reduce(0) { $0 + (abs(values[$1]) > 0.00001 ? 1 : 0) }
        }
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataRendered) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.renderedBuffers += 1
                self.schedule(token)
            }
        }
    }
    func position(at hostTime: UInt64, speed: Double) -> Double? {
        guard node.isPlaying, let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render), time.sampleRate > 0 else { return nil }
        let adjustment = hostTime >= render.hostTime ? AVAudioTime.seconds(forHostTime: hostTime - render.hostTime) : -AVAudioTime.seconds(forHostTime: render.hostTime - hostTime)
        var value = origin + Double(time.sampleTime) / time.sampleRate + adjustment * speed
        if looping {
            let lower = (range.lowerBound * format.sampleRate).rounded() / format.sampleRate
            let upper = (range.upperBound * format.sampleRate).rounded() / format.sampleRate
            if value >= upper { value = lower + (value - upper).truncatingRemainder(dividingBy: upper - lower) }
        }
        return min(range.upperBound, value)
    }
}
