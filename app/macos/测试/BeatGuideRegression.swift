import AVFoundation
import Foundation

@main enum BeatGuideRegression {
    static var count = 0
    struct Failure: Error { var message: String }
    static func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw Failure(message: name) }
        count += 1; print("PASS \(count) \(name)")
    }
    static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    static func render(_ renderer: inout BeatGuideRenderer, buffers: Int = 20) -> [Float] {
        var output: [Float] = []
        for _ in 0..<buffers {
            guard let buffer = renderer.nextBuffer() else { break }
            output += samples(buffer)
        }
        return output
    }
    static func onsets(_ values: [Float]) -> [Int] {
        var result: [Int] = [], quiet = 100000
        for (i, x) in values.enumerated() {
            if abs(x) > 0.00001 {
                if quiet > 100 { result.append(i) }
                quiet = 0
            } else { quiet += 1 }
        }
        return result
    }
    static func main() {
        do { try run() } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        for rate in [44100.0, 48000.0] {
            var renderer = BeatGuideRenderer(sampleRate: rate, beats: [0.1, 0.3, 0.8], start: 0, range: 0...1.2, looping: false)
            let values = render(&renderer)
            let events = onsets(values)
            try check(values.count == Int((rate * 1.2).rounded()), "\(Int(rate))Hz 输出范围精确且停止后不延长")
            try check(events.count == 3 && zip(events, [0.1, 0.3, 0.8]).allSatisfy { abs(Double($0) / rate - $1) < 0.0001 },
                      "\(Int(rate))Hz 非均匀真实鼓点在 0.1 毫秒内落到指定样本")
            try check(values.allSatisfy(\.isFinite) && (values.map { abs($0) }.max() ?? 1) < 0.5,
                      "打击声非空且峰值留有余量")
        }
        var stream = BeatGuideRenderer(sampleRate: 48000, beats: [0.49, 0.8], start: 0, range: 0...1, looping: false)
        var whole = stream
        let joined = render(&stream)
        let single = samples(whole.nextBuffer(frames: 48000)!)
        try check(joined == single, "跨半秒缓冲区的打击声尾音连续")
        var loop = BeatGuideRenderer(sampleRate: 48000, beats: [0.25, 0.5, 0.75], start: 0.21, range: 0.21...0.77, looping: true)
        let looped = render(&loop, buffers: 6)
        let events = onsets(looped)
        let expected = (0..<5).flatMap { lap in [0.04, 0.29, 0.54].map { $0 + Double(lap) * 0.56 } }
        try check(events.count >= expected.count && zip(events.prefix(expected.count), expected).allSatisfy { abs(Double($0) / 48000 - $1) < 0.0001 },
                  "不齐拍的 A/B 范围按原节拍相位循环，无每圈累积漂移")
        var tiny = BeatGuideRenderer(sampleRate: 48000, beats: [0.3], start: 0.29, range: 0.29...0.31, looping: true)
        try check(tiny.nextBuffer()!.frameLength == 24000, "短循环仍预备半秒音频，避免依赖逐拍界面回调")
        var silent = BeatGuideRenderer(sampleRate: 48000, beats: [], start: 0, range: 0...1, looping: false)
        try check(render(&silent).allSatisfy { $0 == 0 }, "没有节拍不产生虚构节奏")
        var one = BeatGuideRenderer(sampleRate: 48000, beats: [0.25], start: 0, range: 0...1.2, looping: false)
        try check(onsets(render(&one)).count == 1, "单个节拍不扩展成固定四拍循环")

        // Pass the generated PCM through the real offline audio engine as well.
        let engine = AVAudioEngine(), guide = PracticeBeatGuide()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        guide.prepare(sampleRate: 48000, engine: engine, mixer: engine.mainMixerNode)
        let node = guide.node
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        var proof = BeatGuideRenderer(sampleRate: 48000, beats: [0.1, 0.3, 0.8], start: 0, range: 0...1.2, looping: false)
        node.scheduleBuffer(proof.nextBuffer(frames: 57600)!, completionHandler: nil); node.play()
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var actual: [Float] = []
        while actual.count < 57600 {
            let status = try engine.renderOffline(AVAudioFrameCount(min(4096, 57600 - actual.count)), to: buffer)
            guard status == .success else { throw Failure(message: "离线渲染未成功：\(status)") }
            actual += samples(buffer)
        }
        node.stop(); engine.stop()
        try check(onsets(actual).count == 3 && (actual.map { abs($0) }.max() ?? 0) > 0.05, "系统音频引擎实际输出三个可用打击声")
        let peak = actual.map { abs($0) }.max() ?? 0
        let previousPeak = (proof.pulse.map { abs($0) }.max() ?? 0) * 0.2
        try check(previousPeak > 0 && (1.4...1.6).contains(peak / previousPeak), "实际默认鼓点通道比原音量提高约一半幅度")
        try check(peak < 0.2, "调高后的独立鼓点峰值保留混音余量")
        print("Default percussion peak \(peak), previous reference \(previousPeak)")
        print("Completed \(count) percussion checks")
    }
}
