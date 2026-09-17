import SwiftUI

/// A single labelled usage row: "5h" / "7d" label, a segmented progress bar,
/// the percentage, and the reset date — laid out to match the reference UI.
struct UsageRow: View {
    let label: String
    let window: UsageWindow
    let locale: Locale

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 13.25, weight: .regular))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: 42, alignment: .leading)

            SegmentedUsageBar(
                fraction: window.remainingFraction,
                fillColor: window.remainingQuotaLevel.color
            )
            .frame(width: 108, height: 7)

            Text(window.remainingPercentText)
                .font(.system(size: 13.25, weight: .regular))
                .foregroundStyle(window.remainingQuotaLevel.valueColor)
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()

            Text(resetText)
                .font(.system(size: 13.25, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(window.remainingPercentText), \(resetText)")
    }

    /// Format dates in the reference menu's day-first style while retaining a
    /// natural Chinese month/day representation.
    private var resetText: String {
        guard let date = window.resetsAt else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = locale
        if locale.language.languageCode?.identifier == "zh" {
            formatter.setLocalizedDateFormatFromTemplate("Md")
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }
}

/// Compact block-based meter that keeps exact partial-segment progress.
///
/// - `fraction`: Remaining quota in the normalized 0...1 range, or `nil` when
///   the provider value is unavailable.
/// - `fillColor`: Semantic quota color selected by the caller.
///
/// Unknown and unfilled segments retain a neutral track. Partial leading and
/// trailing blocks prevent small nonzero values from being visually rounded to
/// either zero or a complete segment.
private struct SegmentedUsageBar: View {
    let fraction: Double?
    let fillColor: Color

    private let segmentCount = 14

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { index in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.20))

                        if segmentFill(at: index) > 0 {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(fillColor)
                                .frame(
                                    width: geometry.size.width * segmentFill(at: index)
                                )
                        }
                    }
                }
            }
        }
    }

    /// Return the exact 0...1 fill amount for one segment.
    ///
    /// - Parameter index: Zero-based segment position from the leading edge.
    /// - Returns: A clamped fraction for that segment. Unknown values return zero.
    private func segmentFill(at index: Int) -> Double {
        guard let fraction else { return 0 }
        let scaledFraction = min(1, max(0, fraction)) * Double(segmentCount)
        return min(1, max(0, scaledFraction - Double(index)))
    }
}

extension RemainingQuotaLevel {
    /// Color used for filled progress segments at this quota level.
    fileprivate var color: Color {
        switch self {
        case .unavailable:
            return Color.white.opacity(0.36)
        case .critical:
            return Color(red: 1.00, green: 0.31, blue: 0.34)
        case .warning:
            return Color(red: 0.98, green: 0.73, blue: 0.22)
        case .healthy:
            return Color(red: 0.30, green: 0.82, blue: 0.45)
        }
    }

    /// Keep unknown percentages neutral while matching known text to the meter.
    fileprivate var valueColor: Color {
        switch self {
        case .unavailable: return Color.white.opacity(0.72)
        case .critical, .warning, .healthy: return color
        }
    }
}
