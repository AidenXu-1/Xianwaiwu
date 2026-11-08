import Foundation
import AVFoundation
import AppKit
import SwiftUI

struct Track: Identifiable {
    let id: String
    let label: String
    let url: URL
    let peakDB: Double?
}

struct PlayerFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: Double = 0
    func synchronize(_ value: Double) { if time != value { time = value } }
}

final class PracticePlayer: ObservableObject {
    struct ListeningState {
        let time: Double
        let a, b: Double
        let loop: Bool
        let enabled, solo: Set<String>

        func constrained(to range: ClosedRange<Double>) -> ListeningState {
            let lower = max(range.lowerBound, a)
            let upper = min(range.upperBound, b)
            let usable = lower.isFinite && upper.isFinite && upper - lower >= 0.0999
            return ListeningState(time: min(range.upperBound, max(range.lowerBound, time)),
                                  a: usable ? lower : range.lowerBound,
                                  b: usable ? upper : range.upperBound,
                                  loop: usable && loop, enabled: enabled, solo: solo)
        }
    }

    let clock = PlaybackClock()
    private(set) var time: Double {
        get { clock.time }
        set {
            if clock.time != newValue { clock.time = newValue }
        }
    }
    @Published var playing = false
    @Published var volume: Float = 0.75 { didSet { applyLevels() } }
    @Published var speed: Double = 1 { didSet { changeRate() } }
    @Published var pitch: Int = 0 { didSet { stretch.pitch = Float(pitch * 100); stretch.bypass = speed == 1 && pitch == 0 } }
    @Published var beatGuideEnabled = false {
        didSet {
            guard oldValue != beatGuideEnabled else { return }
            if beatGuideEnabled && playing { startBeatGuideDuringPlayback() }
            else { beatGuide.stop() }
            applyLevels()
        }
    }
    private(set) var beatGuideTimes: [Double] = []
    let beatGuide = PracticeBeatGuide()
    @Published var a: Double = 0
    @Published var b: Double = 0
    @Published var loop = false
    @Published var enabled = Set<String>()
    @Published var solo = Set<String>()
    private(set) var limit: ClosedRange<Double> = 0...0
    private(set) var tracks = [Track]()
    private var files = [AVAudioFile]()
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let stretch = AVAudioUnitTimePitch()
    private var nodes = [AVAudioPlayerNode]()
    private var startClock: TimeInterval = 0
    private var startAt: Double = 0
    private var activeSpeed: Double = 1
    private var playbackHostTime: UInt64 = 0
    private var timer: Timer?
    private var playEnd: Double = 0
    private var loopSpan: ClosedRange<Double>?
    private var generation = 0
    private var loopEdit: DispatchWorkItem?
    private var playbackGain: Float = 1
    var previewGain: Float { playbackGain }
    private var levelGeneration = 0
    var audibleTracks: Set<String> { solo.isEmpty ? enabled : solo }
    var onFailure: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    /// Real node clocks normalized to one render host time, avoiding a render boundary between queries.
    var nodePlaybackTimes: [String: Double] {
        let snapshots = nodes.enumerated().compactMap { i, node -> (String, Double, UInt64)? in
            guard let render = node.lastRenderTime, render.isHostTimeValid,
                  let position = node.playerTime(forNodeTime: render), position.sampleRate > 0 else { return nil }
            return (tracks[i].id, Double(position.sampleTime) / position.sampleRate, render.hostTime)
        }
        guard let reference = snapshots.first?.2 else { return [:] }
        return Dictionary(uniqueKeysWithValues: snapshots.map { id, seconds, host in
            let adjustment = host <= reference ? AVAudioTime.seconds(forHostTime: reference-host) : -AVAudioTime.seconds(forHostTime: host-reference)
            return (id, seconds + adjustment)
        })
    }
    var playbackDiagnostics: String {
        let clocks = nodes.enumerated().map { i, node in
            let rendered = node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0) }.map { Double($0.sampleTime) / $0.sampleRate } ?? -1
            return "\(tracks[i].id)=\(rendered),volume=\(node.volume)"
        }.joined(separator: ";")
        return "engine=\(engine.isRunning),hostElapsed=\(ProcessInfo.processInfo.systemUptime-startClock),fresh=\(current()),cached=\(time),\(clocks)"
    }

    init() {
        engine.attach(mixer)
        engine.attach(stretch)
        engine.connect(mixer, to: stretch, format: nil)
        engine.connect(stretch, to: engine.mainMixerNode, format: nil)
        stretch.overlap = 12
        // The first release plays at the original rate/pitch; avoid unnecessary effect preroll.
        stretch.bypass = true
    }

    deinit { timer?.invalidate(); loopEdit?.cancel(); engine.stop() }

    static func safePreviewGain(for tracks: [Track]) -> Float {
        let sumPeaks = tracks.reduce(0.0) { $0 + ($1.peakDB.map { pow(10, $0 / 20) } ?? 1) }
        return Float(min(1, 0.95 / max(0.01, sumPeaks)))
    }

    func prepare(_ newTracks: [Track], range: ClosedRange<Double>? = nil, comparisonGain: Float? = nil) throws {
        let newFiles = try newTracks.map { try AVAudioFile(forReading: $0.url) }
        guard !newFiles.isEmpty,
              newFiles.allSatisfy({ $0.length > 0 && (1...2).contains($0.processingFormat.channelCount) }) else {
            throw PlayerFailure("未找到可播放的单声道或双声道音轨。")
        }
        let durations = newFiles.map { Double($0.length) / $0.processingFormat.sampleRate }
        if let first = newFiles.first, newFiles.count > 1,
           !newFiles.allSatisfy({ $0.processingFormat.sampleRate == first.processingFormat.sampleRate &&
                                  abs(Double($0.length - first.length)) <= 1 }) {
            throw PlayerFailure("这些文件的采样率或长度不同，无法保证同步。请选择同一组导出的分轨。")
        }
        stop()
        engine.stop()
        beatGuide.prepare(sampleRate: newFiles[0].processingFormat.sampleRate, engine: engine, mixer: mixer)
        for node in nodes { engine.detach(node) }
        tracks = newTracks
        files = newFiles
        nodes = files.map { file in
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: mixer, format: file.processingFormat)
            return node
        }
        let duration = durations.min() ?? 0
        let lower = min(duration, max(0, range?.lowerBound ?? 0))
        limit = lower...max(lower, min(duration, range?.upperBound ?? duration))
        time = limit.lowerBound
        a = limit.lowerBound; b = limit.upperBound; loop = false
        enabled = Set(tracks.map(\.id)); solo = []
        stretch.rate = Float(speed); stretch.pitch = Float(pitch * 100)
        stretch.bypass = speed == 1 && pitch == 0
        // A constant, conservative gain keeps other tracks at the same level when one is muted.
        playbackGain = comparisonGain.map { min(1, max(0, $0)) } ?? Self.safePreviewGain(for: tracks)
        applyLevels()
    }

    func clear() {
        stop()
        engine.stop()
        for node in nodes { engine.detach(node) }
        nodes = []; files = []; tracks = []
        limit = 0...0; time = 0; a = 0; b = 0; loop = false; enabled = []; solo = []
        configureBeatGuide([])
    }

    func useRange(_ range: ClosedRange<Double>) {
        let adjusted = listeningState().constrained(to: range)
        stop()
        limit = range
        time = range.lowerBound
        a = adjusted.a; b = adjusted.b; loop = adjusted.loop
    }

    func toggle() { playing ? stop() : begin() }

    func listeningState() -> ListeningState {
        ListeningState(time: playing ? current() : time, a: a, b: b,
                       loop: loop, enabled: enabled, solo: solo)
    }

    func restoreListening(_ state: ListeningState?, at position: Double, resume: Bool) {
        if let state = state?.constrained(to: limit) {
            let ids = Set(tracks.map(\.id))
            enabled = state.enabled.intersection(ids)
            solo = state.solo.intersection(ids)
            a = state.a; b = state.b; loop = state.loop
            applyLevels()
        }
        time = min(limit.upperBound, max(limit.lowerBound, position))
        if resume { begin() }
    }

    func stop() {
        if playing { time = current() }
        beatGuide.stop()
        generation += 1
        loopEdit?.cancel(); loopEdit = nil
        timer?.invalidate(); timer = nil
        for node in nodes { node.stop() }
        playing = false
        onStateChange?()
    }

    private func current() -> Double {
        let elapsed: Double
        if let node = nodes.first, let renderTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: renderTime), playerTime.sampleRate > 0 {
            elapsed = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        } else {
            elapsed = max(0, ProcessInfo.processInfo.systemUptime - startClock) * activeSpeed
        }
        let position = startAt + elapsed
        if let loopSpan, position >= loopSpan.upperBound {
            let duration = loopSpan.upperBound - loopSpan.lowerBound
            return loopSpan.lowerBound + (position - loopSpan.upperBound).truncatingRemainder(dividingBy: duration)
        }
        return min(playEnd, position)
    }

    func seek(_ value: Double) {
        guard value.isFinite else { return }
        let resume = playing
        stop()
        time = min(limit.upperBound, max(limit.lowerBound, value))
        if resume { begin() }
        onStateChange?()
    }

    func updateLoop(_ value: Bool) {
        let resume = playing
        stop()
        loop = value && b - a >= 0.0999
        if resume { begin() }
    }

    func clearLoop() {
        let resume = playing
        stop()
        a = limit.lowerBound; b = limit.upperBound; loop = false
        if resume { begin() }
    }

    func setA(_ value: Double) {
        guard value.isFinite else { return }
        a = max(limit.lowerBound, min(value, b - 0.1))
        queueLoopEdit()
    }

    func setB(_ value: Double) {
        guard value.isFinite else { return }
        b = min(limit.upperBound, max(value, a + 0.1))
        queueLoopEdit()
    }

    private func queueLoopEdit() {
        guard loop && playing else { return }
        loopEdit?.cancel()
        let edit = DispatchWorkItem { [weak self] in
            guard let self, self.playing, self.loop else { return }
            self.updateLoop(true)
        }
        loopEdit = edit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: edit)
    }

    private func changeRate() {
        stretch.rate = Float(speed)
        stretch.bypass = speed == 1 && pitch == 0
        activeSpeed = speed
    }

    func configureBeatGuide(_ times: [Double]) {
        guard beatGuideTimes != times else { return }
        beatGuideTimes = times
        if times.isEmpty { beatGuideEnabled = false; beatGuide.stop() }
        else if beatGuideEnabled && playing { startBeatGuideDuringPlayback() }
    }

    private func startBeatGuideDuringPlayback() {
        guard playing, beatGuideEnabled, !beatGuideTimes.isEmpty else { return }
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.045)
        var position: Double
        if let node = nodes.first, let render = node.lastRenderTime, render.isHostTimeValid,
           render.hostTime >= playbackHostTime, let stamp = node.playerTime(forNodeTime: render), stamp.sampleRate > 0 {
            let lead = host >= render.hostTime ? AVAudioTime.seconds(forHostTime: host - render.hostTime) : 0
            position = startAt + Double(stamp.sampleTime) / stamp.sampleRate + lead * speed
        } else {
            position = startAt + AVAudioTime.seconds(forHostTime: host - min(host, playbackHostTime)) * speed
        }
        if let span = loopSpan, position >= span.upperBound {
            position = span.lowerBound + (position - span.upperBound).truncatingRemainder(dividingBy: span.upperBound - span.lowerBound)
        }
        let span = loopSpan ?? limit
        beatGuide.start(beats: beatGuideTimes, from: min(span.upperBound, position), range: span,
                        looping: loopSpan != nil, at: AVAudioTime(hostTime: host))
    }

    var beatGuideAlignmentError: Double? {
        guard let node = nodes.first, let render = node.lastRenderTime,
              let stamp = node.playerTime(forNodeTime: render), stamp.sampleRate > 0,
              let guideTime = beatGuide.position(at: render.hostTime, speed: speed) else { return nil }
        var music = startAt + Double(stamp.sampleTime) / stamp.sampleRate
        if let span = loopSpan, music >= span.upperBound {
            music = span.lowerBound + (music - span.upperBound).truncatingRemainder(dividingBy: span.upperBound - span.lowerBound)
        }
        return abs(guideTime - music)
    }

    func setAll(_ state: Bool) {
        solo = []
        enabled = state ? Set(tracks.map(\.id)) : []
        applyLevels()
        onStateChange?()
    }

    func toggleTrack(_ id: String) {
        if enabled.contains(id) { enabled.remove(id) } else { enabled.insert(id) }
        applyLevels()
        onStateChange?()
    }

    func toggleSolo(_ id: String) {
        if solo.contains(id) { solo.remove(id) } else { solo.insert(id) }
        applyLevels()
        onStateChange?()
    }

    func clearSolo() {
        solo = []
        applyLevels()
        onStateChange?()
    }

    private func applyLevels() {
        let audible = audibleTracks
        levelGeneration += 1
        let token = levelGeneration
        let starts = nodes.map(\.volume)
        let targets = tracks.map { audible.contains($0.id) ? Float(1) : Float(0) }
        let startMix = mixer.outputVolume
        let targetMix = volume * playbackGain * (beatGuideEnabled ? 0.88 : 1)
        if playing {
            for step in 1...4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.004) { [weak self] in
                    guard let self, self.levelGeneration == token, self.nodes.count == targets.count else { return }
                    for i in targets.indices { self.nodes[i].volume = starts[i] + (targets[i] - starts[i]) * Float(step) / 4 }
                    self.mixer.outputVolume = startMix + (targetMix - startMix) * Float(step) / 4
                }
            }
        } else {
            for i in nodes.indices { nodes[i].volume = targets[i] }
            mixer.outputVolume = targetMix
        }
    }

    private func begin() {
        guard !nodes.isEmpty, limit.upperBound > limit.lowerBound else { return }
        let lower = loop ? a : limit.lowerBound
        let upper = loop ? b : limit.upperBound
        let selected = time < lower || time >= upper - 0.015 ? lower : time
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            generation += 1
            loopSpan = loop ? lower...upper : nil
            schedule(from: selected, to: upper, generation: generation)
            if let loopSpan {
                // Keep two complete laps ahead of the audio render callback.
                schedule(from: loopSpan.lowerBound, to: loopSpan.upperBound, generation: generation)
                schedule(from: loopSpan.lowerBound, to: loopSpan.upperBound, generation: generation)
            }
            let delay = 0.045
            let anchor = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay))
            playbackHostTime = anchor.hostTime
            if beatGuideEnabled {
                beatGuide.start(beats: beatGuideTimes, from: selected, range: lower...upper,
                                looping: loopSpan != nil, at: anchor)
            }
            for node in nodes { node.play(at: anchor) }
            startAt = selected
            startClock = ProcessInfo.processInfo.systemUptime + delay
            activeSpeed = speed
            playEnd = upper
            time = selected
            playing = true
            onStateChange?()
            let refresh = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self, self.playing else { return }
                self.time = self.current()
            }
            timer = refresh
            RunLoop.main.add(refresh, forMode: .common)
        } catch {
            stop()
            onFailure?("无法打开电脑的声音输出。请确认有可用扬声器或耳机。\n\(error.localizedDescription)")
        }
    }

    private func schedule(from lower: Double, to upper: Double, generation token: Int) {
        for (i, file) in files.enumerated() {
            let rate = file.processingFormat.sampleRate
            let first = AVAudioFramePosition((lower * rate).rounded())
            let until = min(file.length, AVAudioFramePosition((upper * rate).rounded()))
            let count = max(0, min(Int64(UInt32.max), until - first))
            guard count > 0 else { continue }
            if i == 0 {
                nodes[i].scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(count), at: nil,
                                         completionCallbackType: loopSpan == nil ? .dataPlayedBack : .dataRendered) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.playing, self.generation == token else { return }
                        if let span = self.loopSpan {
                            self.schedule(from: span.lowerBound, to: span.upperBound, generation: token)
                        } else {
                            self.stop()
                            self.time = upper
                        }
                    }
                }
            } else {
                nodes[i].scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(count), at: nil)
            }
        }
    }
}
