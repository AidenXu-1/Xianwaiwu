import AppKit
import SwiftUI

enum XWTheme {
    static let background = color(0x151513)
    static let bar = color(0x191917)
    static let panel = color(0x1d1d1a)
    static let raised = color(0x23231f)
    static let line = color(0x34342e)
    static let text = color(0xf2f0e9)
    static let muted = color(0xa09e94)
    static let dim = color(0x797b73)
    static let accent = color(0xe8aa72)
    static let accentBright = color(0xf3c391)
    static let accentInk = color(0x2b1b10)
    static let green = color(0xa8c6a0)
    static let danger = color(0xc96f60)

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }

    static func trackColor(_ id: String) -> Color {
        switch id {
        case "vocals", "lead": color(0xe8aa72)
        case "harmony": color(0xb5a2ca)
        case "instrumental", "backing": color(0x9db7b2)
        case "drums": color(0xbaa0c5)
        case "bass": color(0xc6b578)
        case "guitar": color(0x8fbfa2)
        case "piano": color(0x92abc7)
        case "other": color(0xaaa69b)
        default: color(0xc6c8bd)
        }
    }

    static func trackSymbol(_ id: String) -> String {
        switch id {
        case "vocals", "lead": "mic"
        case "harmony": "person.2.wave.2"
        case "drums": "circle.grid.2x2"
        case "bass": "waveform.path"
        case "guitar": "guitars"
        case "piano": "pianokeys"
        case "other": "square.stack.3d.up"
        default: "music.note"
        }
    }

    static func trackDetail(_ id: String) -> String {
        switch id {
        case "vocals": "主唱与和声"
        case "instrumental": "乐器与编曲"
        case "lead": "歌曲主唱"
        case "harmony": "歌曲和声"
        case "backing": "和声与乐器"
        case "drums": "鼓与打击乐"
        case "bass": "低音乐器"
        case "guitar": "木吉他与电吉他"
        case "piano": "钢琴声部"
        case "other": "其余声音"
        default: "完整混合"
        }
    }
}

struct XWMode: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let count: Int

    static let all = [
        XWMode(id: "pair", title: "人声与伴奏", detail: "人声、纯伴奏各一条", symbol: "mic", count: 2),
        XWMode(id: "lead3", title: "主唱、和声、伴奏", detail: "主唱、和声、纯伴奏各一条", symbol: "music.note", count: 3),
        XWMode(id: "music6", title: "音乐六轨", detail: "人声、鼓、贝斯、吉他、钢琴、其他", symbol: "square.stack.3d.up", count: 6)
    ]

    static func resolve(_ id: String) -> XWMode {
        let normalized = ["lead", "backing"].contains(id) ? "leadback" : id
        if normalized == "leadback" {
            return XWMode(id: "leadback", title: "主唱与和声伴奏（旧版）", detail: "主唱一条，和声与乐器一条", symbol: "music.note", count: 2)
        }
        return all.first { $0.id == normalized } ?? all[0]
    }
}

private final class XWHover: ObservableObject {
    let id = UUID()
    @Published var active = false
}

enum XWKeyboardFocus {
    private static var buttons = Set<UUID>()
    static var hasButton: Bool { !buttons.isEmpty }
    static func update(_ id: UUID, focused: Bool) {
        if focused { buttons.insert(id) } else { buttons.remove(id) }
    }
}

struct XWSurfaceInteraction: ViewModifier {
    let pressed: Bool
    let radius: CGFloat
    @StateObject private var hover = XWHover()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius).fill(enabled && hover.active ? .white.opacity(0.025) : .clear).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(focused ? XWTheme.accent : .clear, lineWidth: 2).allowsHitTesting(false))
            .brightness(pressed ? 0.025 : 0)
            .scaleEffect(pressed && !reduceMotion ? 0.986 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.10), value: hover.active)
            .onHover { hover.active = $0 }
            .onChange(of: focused) { _, value in XWKeyboardFocus.update(hover.id, focused: value) }
            .onDisappear { XWKeyboardFocus.update(hover.id, focused: false) }
    }
}

enum XWButtonKind { case primary, secondary, quiet, selected, danger, play }

struct XWButtonStyle: ButtonStyle {
    var kind: XWButtonKind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, pressed: configuration.isPressed, kind: kind, compact: compact)
    }

    private struct Face<Content: View>: View {
        let label: Content
        let pressed: Bool
        let kind: XWButtonKind
        let compact: Bool
        @StateObject private var hover = XWHover()
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var foreground: Color {
            switch kind {
            case .primary, .danger: XWTheme.accentInk
            case .play: XWTheme.raised
            case .selected: XWTheme.accent
            case .quiet: hover.active ? XWTheme.text : XWTheme.muted
            default: XWTheme.text
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: hover.active ? XWTheme.accentBright : XWTheme.accent
            case .danger: hover.active ? XWTheme.color(0xdb8373) : XWTheme.danger
            case .play: hover.active ? .white : XWTheme.text
            case .selected: XWTheme.accent.opacity(0.11)
            case .quiet: hover.active ? .white.opacity(0.045) : .clear
            default: hover.active ? XWTheme.color(0x2e2e29) : XWTheme.color(0x262622)
            }
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: kind == .play ? 30 : compact ? 6 : 10)
            label
                .font(.system(size: compact ? 11 : 13, weight: kind == .quiet ? .medium : .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .play ? 0 : compact ? 8 : 15)
                .frame(minHeight: compact ? 28 : kind == .play ? 42 : 40)
                .background(fill, in: shape)
                .overlay(shape.fill(pressed ? .black.opacity(0.12) : .clear).allowsHitTesting(false))
                .overlay(shape.strokeBorder(focused && enabled ? XWTheme.accent :
                    kind == .selected ? XWTheme.accent.opacity(0.45) :
                    kind == .secondary ? XWTheme.color(0x3b3b34) : .clear,
                    lineWidth: focused ? 2 : 1).allowsHitTesting(false))
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.38)
                .scaleEffect(pressed && !reduceMotion ? 0.975 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hover.active)
                .onHover { hover.active = $0 }
                .onChange(of: focused) { _, value in XWKeyboardFocus.update(hover.id, focused: value) }
                .onDisappear { XWKeyboardFocus.update(hover.id, focused: false) }
        }
    }
}

struct XWBrandMark: View {
    var size: CGFloat = 31
    private static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSImage(contentsOf: Project.root.appendingPathComponent("design/assets/弦外屋 Logo/弦外屋 · 木吉他精细版.png"))
    }()

    var body: some View {
        Group {
            if let image = Self.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "guitars").resizable().scaledToFit().padding(5).foregroundStyle(XWTheme.accent) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
    }
}

struct XWTrackBadge: View {
    let id: String
    var size: CGFloat = 31

    var body: some View {
        Image(systemName: XWTheme.trackSymbol(id))
            .font(.system(size: size * 0.47))
            .foregroundStyle(XWTheme.trackColor(id))
            .frame(width: size, height: size)
            .background(XWTheme.trackColor(id).opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
