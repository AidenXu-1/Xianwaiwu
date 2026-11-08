import AppKit
import Combine
import CoreText
import SwiftUI

/// The waveform stays still while its cursor subscribes directly to the playback clock.
struct XWWaveform: NSViewRepresentable {
    let peaks: [Float]
    let dataBounds: ClosedRange<Double>
    let displayBounds: ClosedRange<Double>
    let clock: PlaybackClock
    let clockOffset: Double
    var selection: ClosedRange<Double>?
    var editing = false
    var color = XWTheme.trackColor("original")
    var audible = true
    var label = "播放位置"
    var identifier = "xw.waveform"
    let seek: (Double) -> Void
    var updateRange: ((Double, Double) -> Void)?
    var beginRange: (() -> Void)?
    var hoverGuide: XWWaveformGuide?

    func makeNSView(context: Context) -> XWWaveformCanvas {
        let view = XWWaveformCanvas()
        view.connect(clock)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: XWWaveformCanvas, context: Context) {
        let waveChanged = view.peaks != peaks || view.dataBounds != dataBounds || view.displayBounds != displayBounds ||
            view.audible != audible || view.waveColor != NSColor(color)
        let changed = waveChanged || view.selection != selection || view.editing != editing
        view.peaks = peaks
        view.dataBounds = dataBounds
        view.displayBounds = displayBounds
        view.selection = selection
        view.editing = editing
        view.clockOffset = clockOffset
        view.audible = audible
        view.waveColor = NSColor(color)
        view.seek = seek
        view.updateRange = updateRange
        view.beginRange = beginRange
        hoverGuide?.reference = view
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(editing ? "拖动框选，拖两端调整。按 Escape 取消，在选段栏完成或恢复整首。" : beginRange != nil ? "点击定位，拖动选择处理范围，拖选区两端调整。左右方向键定位，Shift 精调。" : "点击定位，左右方向键微调，按住 Shift 每次移动十分之一秒。")
        if waveChanged { view.invalidateWaveformImage() }
        if changed {
            view.needsDisplay = true
            view.window?.invalidateCursorRects(for: view)
        }
        view.updateCursor()
    }
}

/// Shares the actual waveform geometry without publishing mouse movement through SwiftUI.
final class XWWaveformGuide {
    weak var reference: XWWaveformCanvas?
}

struct XWWaveformGuideOverlay: NSViewRepresentable {
    let guide: XWWaveformGuide
    func makeNSView(context: Context) -> XWWaveformGuideView { XWWaveformGuideView(guide: guide) }
    func updateNSView(_ view: XWWaveformGuideView, context: Context) { view.refreshPointer() }
}

/// A transparent tracking surface: clicks, scrolling and selection drags reach the waveform below.
final class XWWaveformGuideView: NSView {
    let guide: XWWaveformGuide
    private let line = CAShapeLayer()
    private let bubble = CALayer()
    private let caption = CATextLayer()
    private var tracking: NSTrackingArea?
    private var dragMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private(set) var hoverTime: Double?
    private(set) var hoverX: CGFloat?
    private(set) var hoverText = ""
    override var isFlipped: Bool { true }

    init(guide: XWWaveformGuide) {
        self.guide = guide
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("xw.waveform.hover-guide")
        setAccessibilityElement(false)
        line.strokeColor = NSColor(XWTheme.text).withAlphaComponent(0.7).cgColor
        line.lineWidth = 1
        line.lineDashPattern = [3, 3]
        line.isHidden = true
        bubble.backgroundColor = NSColor(XWTheme.raised).cgColor
        bubble.cornerRadius = 4
        bubble.borderWidth = 0.5
        bubble.borderColor = NSColor(XWTheme.muted).withAlphaComponent(0.5).cgColor
        bubble.isHidden = true
        caption.font = CTFontCreateWithName("Menlo" as CFString, 10, nil)
        caption.fontSize = 10
        caption.alignmentMode = .center
        caption.foregroundColor = NSColor(XWTheme.text).cgColor
        bubble.addSublayer(caption)
        layer?.addSublayer(line); layer?.addSublayer(bubble)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        hideGuide()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        caption.contentsScale = window.backingScaleFactor
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            if let self, event.window === self.window { self.track(event) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.hideGuide() }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func layout() { super.layout(); refreshPointer() }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { hideGuide() }

    func refreshPointer() {
        guard let window, window.isKeyWindow else { hideGuide(); return }
        showGuide(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    private func track(_ event: NSEvent) {
        guard window?.isKeyWindow == true else { hideGuide(); return }
        showGuide(at: convert(event.locationInWindow, from: nil))
    }
    private func showGuide(at point: NSPoint) {
        guard bounds.contains(point), visibleRect.contains(point), let reference = guide.reference,
              reference.window === window, reference.bounds.width > 12,
              reference.displayBounds.upperBound > reference.displayBounds.lowerBound else { hideGuide(); return }
        let plot = reference.convert(reference.bounds, to: self)
        let first = plot.minX + 6, last = plot.maxX - 6
        guard point.x >= first, point.x <= last else { hideGuide(); return }
        let fraction = Double((point.x - first) / (last - first))
        let value = reference.displayBounds.lowerBound + fraction * (reference.displayBounds.upperBound - reference.displayBounds.lowerBound)
        let milliseconds = Int((max(0, value) * 1000).rounded())
        hoverTime = value; hoverX = point.x
        hoverText = String(format: "%d:%02d.%03d", milliseconds / 60000, milliseconds / 1000 % 60, milliseconds % 1000)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let path = CGMutablePath(); path.move(to: CGPoint(x: point.x, y: 22)); path.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        line.path = path; line.isHidden = false
        let width: CGFloat = 78
        bubble.frame = CGRect(x: min(max(0, point.x + 8), max(0, bounds.width - width)), y: 1, width: width, height: 19)
        caption.frame = CGRect(x: 2, y: 3, width: width - 4, height: 14)
        caption.string = hoverText; bubble.isHidden = false
        CATransaction.commit()
    }
    private func hideGuide() {
        hoverTime = nil; hoverX = nil; hoverText = ""
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.isHidden = true; bubble.isHidden = true
        CATransaction.commit()
    }
}

final class XWWaveformCanvas: NSView {
    var peaks: [Float] = []
    var dataBounds: ClosedRange<Double> = 0...1
    var displayBounds: ClosedRange<Double> = 0...1
    var selection: ClosedRange<Double>?
    var editing = false
    var audible = true
    var waveColor = NSColor(XWTheme.muted)
    var clockOffset: Double = 0
    var seek: ((Double) -> Void)?
    var updateRange: ((Double, Double) -> Void)?
    var beginRange: (() -> Void)?
    private let cursor = CALayer()
    private let cursorDot = CALayer()
    private var observation: AnyCancellable?
    private var clockTime: Double = 0
    private var dragKind = ""
    private var lastHandle = "end"
    private var anchor: Double = 0
    private var dragOffset: Double = 0
    private var dragOrigin: CGFloat = 0
    private var pendingKind = "new"
    private var waveformImage: CGImage?
    private var imageScale: CGFloat = 0

    func invalidateWaveformImage() { waveformImage = nil; imageScale = 0 }
    private func cachedWaveformImage() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        if imageScale == scale { return waveformImage }
        imageScale = scale
        guard !peaks.isEmpty, let context = CGContext(data: nil, width: Int(640 * scale), height: Int(128 * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(waveColor.withAlphaComponent(audible ? 0.88 : 0.24).cgColor)
        context.setLineWidth(1.45); context.setLineCap(.round)
        let dataSpan = max(0.001, dataBounds.upperBound - dataBounds.lowerBound)
        // Fixed bins stop the waveform from changing its pattern at intermediate widths.
        let stride = max(1, Int(ceil(Double(peaks.count) / 320)))
        for index in Swift.stride(from: 0, to: peaks.count, by: stride) {
            let value = dataBounds.lowerBound + dataSpan * Double(index) / Double(max(1, peaks.count - 1))
            guard displayBounds.contains(value) else { continue }
            let position = CGFloat((value - displayBounds.lowerBound) / span) * 640
            let height = max(0.7, CGFloat(min(1, max(0, peaks[index..<min(peaks.count, index + stride)].max() ?? 0))) * 64)
            context.move(to: CGPoint(x: position, y: 64 - height)); context.addLine(to: CGPoint(x: position, y: 64 + height))
        }
        context.strokePath(); waveformImage = context.makeImage()
        return waveformImage
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        cursor.backgroundColor = NSColor(XWTheme.accentBright).cgColor
        cursorDot.backgroundColor = NSColor(XWTheme.accentBright).cgColor
        cursorDot.cornerRadius = 2.5
        layer?.addSublayer(cursor)
        layer?.addSublayer(cursorDot)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func connect(_ clock: PlaybackClock) {
        observation = clock.$time.receive(on: RunLoop.main).sink { [weak self] time in
            self?.clockTime = time
            self?.updateCursor()
        }
    }

    private var span: Double { max(0.001, displayBounds.upperBound - displayBounds.lowerBound) }
    private var drawingWidth: CGFloat { max(1, bounds.width - 12) }
    private func x(_ value: Double) -> CGFloat { 6 + CGFloat((value - displayBounds.lowerBound) / span) * drawingWidth }
    private func time(_ point: CGFloat) -> Double {
        displayBounds.lowerBound + Double(min(1, max(0, (point - 6) / drawingWidth))) * span
    }

    func updateCursor() {
        let value = clockTime + clockOffset
        let position = x(value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursor.isHidden = value < displayBounds.lowerBound - 0.01 || value > displayBounds.upperBound + 0.01 || peaks.isEmpty
        cursorDot.isHidden = cursor.isHidden
        cursor.frame = CGRect(x: position, y: 5, width: 1, height: max(0, bounds.height - 10))
        cursorDot.frame = CGRect(x: position - 2, y: 4, width: 5, height: 5)
        CATransaction.commit()
        setAccessibilityValue(xwTime(value, precise: true))
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        updateCursor()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = bounds.height / 2
        context.setStrokeColor(NSColor(XWTheme.line).withAlphaComponent(0.55).cgColor)
        context.setLineWidth(0.6)
        context.move(to: CGPoint(x: 6, y: center))
        context.addLine(to: CGPoint(x: bounds.width - 6, y: center))
        for n in 1...3 {
            let position = 6 + drawingWidth * CGFloat(n) / 4
            context.move(to: CGPoint(x: position, y: 5))
            context.addLine(to: CGPoint(x: position, y: bounds.height - 5))
        }
        context.strokePath()

        if let image = cachedWaveformImage() {
            let maxAmplitude = min(77, max(12, bounds.height * 0.36))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 6, y: center - maxAmplitude, width: drawingWidth, height: maxAmplitude * 2))
        }

        if let selection {
            let left = min(bounds.width, max(0, x(selection.lowerBound)))
            let right = min(bounds.width, max(left, x(selection.upperBound)))
            context.setFillColor(NSColor.black.withAlphaComponent(0.34).cgColor)
            context.fill(CGRect(x: 0, y: 3, width: left, height: max(0, bounds.height - 6)))
            context.fill(CGRect(x: right, y: 3, width: max(0, bounds.width - right), height: max(0, bounds.height - 6)))
            context.setFillColor(NSColor(XWTheme.accent).withAlphaComponent(0.035).cgColor)
            context.fill(CGRect(x: left, y: 3, width: right - left, height: max(0, bounds.height - 6)))
            context.setStrokeColor(NSColor(XWTheme.accent).withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: left, y: 3, width: right - left, height: max(0, bounds.height - 6)))
            if editing || beginRange != nil {
                for position in [left, right] {
                    let rect = CGRect(x: position - 4, y: center - 19, width: 8, height: 38)
                    let handle = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                    NSColor(XWTheme.accent).setFill()
                    handle.fill()
                    NSColor(XWTheme.accentInk).withAlphaComponent(0.6).setStroke()
                    let line = NSBezierPath()
                    line.move(to: CGPoint(x: position, y: center - 5))
                    line.line(to: CGPoint(x: position, y: center + 5))
                    line.stroke()
                }
            }
        }
        if window?.firstResponder === self {
            context.setStrokeColor(NSColor(XWTheme.accent).withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1.5)
            context.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        anchor = time(point.x)
        dragOrigin = point.x
        dragOffset = 0
        if editing || beginRange != nil {
            if let selection,
               min(abs(point.x - x(selection.lowerBound)), abs(point.x - x(selection.upperBound))) <= 12 {
                let startDistance = abs(point.x - x(selection.lowerBound))
                let endDistance = abs(point.x - x(selection.upperBound))
                pendingKind = startDistance == endDistance ? lastHandle : startDistance < endDistance ? "start" : "end"
                lastHandle = pendingKind
                dragOffset = x(pendingKind == "start" ? selection.lowerBound : selection.upperBound) - point.x
            } else {
                pendingKind = "new"
                lastHandle = "end"
            }
            dragKind = editing ? pendingKind : "pending"
        } else {
            dragKind = "seek"
            seek?(anchor)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dragKind == "pending" {
            guard abs(point.x - dragOrigin) >= 4 else { return }
            beginRange?()
            editing = true
            dragKind = pendingKind
            window?.invalidateCursorRects(for: self)
        }
        let value = time(point.x + dragOffset)
        switch dragKind {
        case "seek": seek?(value)
        case "start":
            if let selection { setRange(min(value, selection.upperBound - 0.2), selection.upperBound) }
        case "end":
            if let selection { setRange(selection.lowerBound, max(value, selection.lowerBound + 0.2)) }
        case "new":
            lastHandle = value < anchor ? "start" : "end"
            var lower = min(anchor, value), upper = max(anchor, value)
            if upper - lower < 0.2 {
                if value < anchor {
                    lower = max(displayBounds.lowerBound, upper - 0.2)
                    upper = min(displayBounds.upperBound, max(upper, lower + 0.2))
                } else {
                    upper = min(displayBounds.upperBound, lower + 0.2)
                    lower = max(displayBounds.lowerBound, min(lower, upper - 0.2))
                }
            }
            setRange(lower, upper)
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragKind == "pending" { seek?(anchor) }
        dragKind = ""
    }

    private func setRange(_ lower: Double, _ upper: Double) {
        guard lower.isFinite, upper.isFinite, lower >= displayBounds.lowerBound,
              upper <= displayBounds.upperBound, upper - lower >= 0.199999 else { return }
        selection = lower...upper
        updateRange?(lower, upper)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: editing ? .crosshair : .pointingHand)
        if editing || beginRange != nil, let selection {
            for value in [selection.lowerBound, selection.upperBound] {
                addCursorRect(CGRect(x: x(value) - 10, y: 0, width: 20, height: bounds.height), cursor: .resizeLeftRight)
            }
        }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        let step: Double = event.modifierFlags.contains(.shift) ? 0.1 : 1
        switch event.keyCode {
        case 123: adjust(-step)
        case 124: adjust(step)
        case 115: seek?(displayBounds.lowerBound)
        case 119: seek?(displayBounds.upperBound)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjust(1); return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjust(-1); return true
    }

    private func adjust(_ step: Double) {
        guard editing, let selected = selection else {
            seek?(min(displayBounds.upperBound, max(displayBounds.lowerBound, clockTime + clockOffset + step)))
            return
        }
        guard span >= 0.2 else { return }
        let updated: ClosedRange<Double>
        if lastHandle == "start" {
            let start = max(displayBounds.lowerBound, min(selected.upperBound - 0.2, selected.lowerBound + step))
            updated = start...selected.upperBound
        } else {
            let end = min(displayBounds.upperBound, max(selected.lowerBound + 0.2, selected.upperBound + step))
            updated = selected.lowerBound...end
        }
        selection = updated
        updateRange?(updated.lowerBound, updated.upperBound)
        needsDisplay = true
        setAccessibilityValue("\(lastHandle == "start" ? "起点" : "终点") \(xwTime(lastHandle == "start" ? updated.lowerBound : updated.upperBound, precise: true))")
    }
}
