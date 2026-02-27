import UserNotifications
import Foundation

enum UsageNotificationManager {
    private static let center = UNUserNotificationCenter.current()

    static func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func checkThresholds(fiveHour: Int, sevenDay: Int, sonnet: Int?, extraUsage: ExtraUsage? = nil) {
        check(metric: "fiveHour", label: String(localized: "metric.session"), pct: fiveHour, thresholds: [90, 100])
        check(metric: "sevenDay", label: String(localized: "metric.weekly"), pct: sevenDay, thresholds: [95, 100])
        if let sonnet {
            check(metric: "sonnet", label: String(localized: "metric.sonnet"), pct: sonnet, thresholds: [60, 85])
        }
        checkExtraUsage(extraUsage)
    }

    // MARK: - Per-metric threshold check

    private static func check(metric: String, label: String, pct: Int, thresholds: [Int]) {
        let sortedThresholds = thresholds.sorted()
        let crossedCount = sortedThresholds.filter { pct >= $0 }.count

        let key = "lastThresholdCount_\(metric)"
        let previousCount = UserDefaults.standard.integer(forKey: key)

        guard crossedCount != previousCount else { return }
        UserDefaults.standard.set(crossedCount, forKey: key)

        if crossedCount > previousCount {
            // Crossed one or more thresholds upward — notify for the highest newly crossed
            let newlyExceeded = sortedThresholds[crossedCount - 1]
            notifyThreshold(metric: metric, label: label, pct: pct, threshold: newlyExceeded, isMax: crossedCount == sortedThresholds.count)
        } else if crossedCount == 0 && previousCount > 0 {
            // Dropped below all thresholds
            notifyRecovery(metric: metric, label: label, pct: pct)
        }
    }

    private static func checkExtraUsage(_ extra: ExtraUsage?) {
        let isActive = extra?.isEnabled == true && (extra?.utilization ?? 0) > 0
        let key = "lastExtraUsageActive"
        let wasActive = UserDefaults.standard.bool(forKey: key)

        guard isActive != wasActive else { return }
        UserDefaults.standard.set(isActive, forKey: key)

        if isActive {
            notifyExtraUsageStarted(extra!)
        }
    }

    // MARK: - Notification builders

    private static func notifyThreshold(metric: String, label: String, pct: Int, threshold: Int, isMax: Bool) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        if isMax {
            content.title = "🔴 \(label) — \(pct)%"
            content.body = String(localized: "notif.red.body")
        } else {
            content.title = "⚠️ \(label) — \(pct)%"
            content.body = String(format: String(localized: "notif.threshold.body"), threshold)
        }

        send(id: "threshold_\(metric)_\(threshold)", content: content)
    }

    private static func notifyRecovery(metric: String, label: String, pct: Int) {
        let content = UNMutableNotificationContent()
        content.title = "🟢 \(label) — \(pct)%"
        content.body = String(localized: "notif.green.body")
        content.sound = .default

        send(id: "recovery_\(metric)", content: content)
    }

    private static func notifyExtraUsageStarted(_ extra: ExtraUsage) {
        let usedDollars = extra.usedCredits / 100
        let limitDollars = extra.monthlyLimit / 100
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notif.extra.title")
        content.body = String(format: String(localized: "notif.extra.body"), usedDollars, limitDollars)
        content.sound = .default

        send(id: "extra_usage_started", content: content)
    }

    private static func send(id: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // Immediate
        )
        center.add(request)
    }
}
