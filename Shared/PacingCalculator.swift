import Foundation

enum PacingZone: String {
    case chill
    case onTrack
    case hot
}

struct PacingResult {
    let delta: Double
    let expectedUsage: Double
    let actualUsage: Double
    let zone: PacingZone
    let message: String
    let resetDate: Date?
}

enum PacingCalculator {
    private static let chillMessages = [
        "pacing.chill.1", "pacing.chill.2", "pacing.chill.3",
    ]
    private static let onTrackMessages = [
        "pacing.ontrack.1", "pacing.ontrack.2", "pacing.ontrack.3",
    ]
    private static let hotMessages = [
        "pacing.hot.1", "pacing.hot.2", "pacing.hot.3",
    ]

    /// Returns how far through a period we are, as a percentage (0–100).
    /// `resetsAt` is the end of the period; `duration` is its total length.
    static func elapsedPct(resetsAt: Date, duration: TimeInterval, now: Date = Date()) -> Double {
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start) / duration
        return min(max(elapsed, 0), 1) * 100
    }

    static func calculate(from usage: UsageResponse, now: Date = Date()) -> PacingResult? {
        guard let bucket = usage.fiveHour,
              let resetsAt = bucket.resetsAtDate
        else { return nil }

        let expectedUsage = elapsedPct(resetsAt: resetsAt, duration: 5 * 3600, now: now)
        let delta = bucket.utilization - expectedUsage

        let zone: PacingZone
        let messages: [String]
        if delta < -10 {
            zone = .chill
            messages = chillMessages
        } else if delta > 10 {
            zone = .hot
            messages = hotMessages
        } else {
            zone = .onTrack
            messages = onTrackMessages
        }

        let messageKey = messages.randomElement() ?? messages[0]
        let message = String(localized: String.LocalizationValue(messageKey))

        return PacingResult(
            delta: delta,
            expectedUsage: expectedUsage,
            actualUsage: bucket.utilization,
            zone: zone,
            message: message,
            resetDate: resetsAt
        )
    }
}
