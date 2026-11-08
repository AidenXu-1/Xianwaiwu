import Foundation

func xwTime(_ seconds: Double, precise: Bool = false) -> String {
    guard seconds.isFinite else { return "0:00" }
    let value = max(0, seconds)
    if precise {
        let tenths = Int((value * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
    let whole = Int(value.rounded(.down))
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

func xwRange(_ range: ClosedRange<Double>, duration: Double? = nil) -> String {
    if let duration, abs(range.lowerBound) < 0.000001, abs(range.upperBound - duration) < 0.000001 { return "整首" }
    return "\(xwTime(range.lowerBound, precise: true))–\(xwTime(range.upperBound, precise: true))"
}
