import AppKit
import Combine
import SwiftUI

struct ScoreRowFrames: PreferenceKey {
    static var defaultValue: [Double: CGRect] = [:]
    static func reduce(value: inout [Double: CGRect], nextValue: () -> [Double: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Stay still inside a phrase; move once when the active phrase changes.
struct XWScoreFollowBridge: NSViewRepresentable {
    var clock: PlaybackClock
    var offset: Double
    var rows: [ScoreRow]
    var frames: [Double: CGRect]
    var follow: Bool
    var reduceMotion: Bool
    var onManualScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        context.coordinator.anchor = view
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        let c = context.coordinator
        let resumed = follow && !c.follow
        c.offset = offset; c.rows = rows; c.frames = frames
        c.follow = follow; c.reduceMotion = reduceMotion; c.onManualScroll = onManualScroll
        if c.clock !== clock {
            c.clock = clock
            c.subscription = clock.$time.sink { [weak c] in c?.receive($0) }
        }
        c.attach()
        c.receive(clock.time, force: resumed)
    }
    static func dismantleNSView(_ nsView: Anchor, coordinator: Coordinator) { coordinator.stop() }

    final class Anchor: NSView {
        var moved: (() -> Void)?
        override var isFlipped: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moved?() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); moved?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        weak var anchor: Anchor?
        weak var scroll: NSScrollView?
        weak var clock: PlaybackClock?
        var subscription: AnyCancellable?
        var rows: [ScoreRow] = []
        var frames: [Double: CGRect] = [:]
        var offset = 0.0
        var follow = true
        var reduceMotion = false
        var onManualScroll: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var animation: Timer?
        private var startY = 0.0, goalY = 0.0, started = 0.0
        private var lastRow: Double?
        private var lastFrame: CGRect?
        private var lastViewportSize: CGSize?
        private var positioned = false
        private var writing = false

        deinit { stop() }
        func stop() {
            animation?.invalidate(); animation = nil
            subscription?.cancel(); subscription = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
        }
        func attach() {
            guard let view = anchor, view.window != nil, let found = view.enclosingScrollView else { return }
            guard scroll !== found else { return }
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            scroll = found; positioned = false
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: found, queue: .main) { [weak self] _ in
                    guard let self, self.follow, !self.writing else { return }
                    self.follow = false; self.animation?.invalidate(); self.animation = nil
                    DispatchQueue.main.async { [weak self] in self?.onManualScroll?() }
                })
            }
            found.contentView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                     object: found.contentView, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let clock = self.clock else { return }
                    self.receive(clock.time)
                }
            })
            // The clock may already be paused before AppKit attaches this view to its window.
            // Replay that position once the scroll view exists; do not wait for another audio tick.
            if let clock { receive(clock.time) }
        }
        private var currentY: Double {
            guard let scroll, let document = scroll.documentView else { return 0 }
            return document.isFlipped ? scroll.contentView.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.maxY
        }
        private func write(_ y: Double) {
            guard let scroll, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let upper = max(0, document.bounds.height - clip.bounds.height)
            let clamped = min(upper, max(0, y))
            let origin = document.isFlipped ? clamped : document.bounds.maxY - clip.bounds.height - clamped
            writing = true
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin))
            scroll.reflectScrolledClipView(clip)
            writing = false
        }
        func receive(_ value: Double, force: Bool = false) {
            let t = value + offset
            guard follow else { animation?.invalidate(); animation = nil; return }
            guard let anchor, anchor.window != nil,
                  let scroll, let document = scroll.documentView,
                  let row = rows.first(where: { t >= $0.start && t < $0.end }) ?? (t >= (rows.last?.end ?? .infinity) ? rows.last : nil),
                  let frame = frames[row.id], frame.height > 0 else { return }
            let viewport = scroll.contentView.bounds.size
            let changed = lastRow != row.id || lastFrame != frame || lastViewportSize != viewport
            guard force || changed || !positioned else { return }
            let point = anchor.convert(NSPoint(x: 0, y: frame.minY), to: document)
            let y = document.isFlipped ? point.y : document.bounds.maxY - point.y
            let height = viewport.height
            let bottomPoint = anchor.convert(NSPoint(x: 0, y: frame.maxY), to: document)
            let bottom = document.isFlipped ? bottomPoint.y : document.bounds.maxY - bottomPoint.y
            // A normal phrase starts at a steady reading position; a tall phrase keeps its lyric visible.
            let target = min(max(0, document.bounds.height - scroll.contentView.bounds.height),
                             max(0, y - 14, bottom - height + 14))
            lastRow = row.id; lastFrame = frame; lastViewportSize = viewport
            goalY = target
            if !positioned || reduceMotion || abs(target - currentY) > scroll.contentView.bounds.height * 1.5 {
                animation?.invalidate(); animation = nil
                write(target); positioned = true
            } else if abs(target - currentY) > 0.5 {
                animation?.invalidate()
                startY = currentY; started = ProcessInfo.processInfo.systemUptime
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
                animation = timer; RunLoop.main.add(timer, forMode: .common)
            }
        }
        private func step() {
            guard follow else { animation?.invalidate(); animation = nil; return }
            let p = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.28)
            let eased = p * p * (3 - 2 * p)
            write(startY + (goalY - startY) * eased)
            if p >= 1 { animation?.invalidate(); animation = nil }
        }
    }
}
