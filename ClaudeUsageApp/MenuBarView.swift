import SwiftUI
import AppKit
import WidgetKit

// MARK: - Metric ID

enum MetricID: String, CaseIterable {
    case fiveHour = "fiveHour"
    case sevenDay = "sevenDay"
    case sonnet = "sonnet"
    case pacing = "pacing"

    var label: String {
        switch self {
        case .fiveHour: return String(localized: "metric.session")
        case .sevenDay: return String(localized: "metric.weekly")
        case .sonnet: return String(localized: "metric.sonnet")
        case .pacing: return String(localized: "pacing.label")
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .sonnet: return "S"
        case .pacing: return "P"
        }
    }
}

enum PacingDisplayMode: String {
    case dot
    case dotDelta
}

// MARK: - ViewModel

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var fiveHourPct: Int = 0
    @Published var sevenDayPct: Int = 0
    @Published var sonnetPct: Int? = nil
    @Published var fiveHourReset: String = ""
    @Published var sevenDayReset: String = ""
    @Published var sevenDayElapsedPct: Double? = nil
    @Published var extraUsage: ExtraUsage? = nil
    @Published var pacingDelta: Int = 0
    @Published var pacingZone: PacingZone = .onTrack
    @Published var pacingResult: PacingResult?
    @Published var lastUpdate: Date?
    @Published var isLoading = false
    @Published var hasError = false
    @Published var hasConfig = false
    @Published var pinnedMetrics: Set<MetricID> {
        didSet { savePinnedMetrics() }
    }

    private var timer: Timer?
    private var displaySettingsObserver: Any?

    init() {
        // Load pinned metrics from UserDefaults (default: 5h + 7d)
        if let saved = UserDefaults.standard.stringArray(forKey: "pinnedMetrics") {
            pinnedMetrics = Set(saved.compactMap { MetricID(rawValue: $0) })
        } else {
            pinnedMetrics = [.fiveHour, .sevenDay]
        }
        hasConfig = ClaudeAPIClient.shared.isConfigured
        loadCached()
        startRefreshTimer()
        UsageNotificationManager.requestPermission()
        // Force WidgetKit to discover all widgets including PacingWidget
        WidgetKit.WidgetCenter.shared.reloadAllTimelines()
        Task { await refresh() }

        // Observe display settings changes from SettingsView
        displaySettingsObserver = NotificationCenter.default.addObserver(
            forName: .displaySettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.reloadDisplaySettings()
            }
        }
    }

    func reloadDisplaySettings() {
        if let saved = UserDefaults.standard.stringArray(forKey: "pinnedMetrics") {
            let newMetrics = Set(saved.compactMap { MetricID(rawValue: $0) })
            if newMetrics != pinnedMetrics {
                pinnedMetrics = newMetrics
            }
        }
        // Force re-render for pacingDisplayMode changes
        objectWillChange.send()
    }

    func toggleMetric(_ metric: MetricID) {
        if pinnedMetrics.contains(metric) {
            // Don't allow removing the last one
            if pinnedMetrics.count > 1 {
                pinnedMetrics.remove(metric)
            }
        } else {
            pinnedMetrics.insert(metric)
        }
    }

    private func savePinnedMetrics() {
        UserDefaults.standard.set(pinnedMetrics.map(\.rawValue), forKey: "pinnedMetrics")
    }

    func pct(for metric: MetricID) -> Int {
        switch metric {
        case .fiveHour: return fiveHourPct
        case .sevenDay: return sevenDayPct
        case .sonnet: return sonnetPct ?? 0
        case .pacing: return pacingDelta
        }
    }

    var pacingDisplayMode: PacingDisplayMode {
        PacingDisplayMode(rawValue: UserDefaults.standard.string(forKey: "pacingDisplayMode") ?? "dotDelta") ?? .dotDelta
    }

    var menuBarImage: NSImage {
        guard hasConfig, !hasError else {
            return renderText("--")
        }
        return renderPinnedMetrics()
    }

    func refresh() async {
        guard ClaudeAPIClient.shared.isConfigured else {
            hasConfig = false
            return
        }
        hasConfig = true
        isLoading = true
        defer { isLoading = false }
        do {
            let usage = try await ClaudeAPIClient.shared.fetchUsage()
            update(from: usage)
            hasError = false
            lastUpdate = Date()
            UsageNotificationManager.checkThresholds(
                fiveHour: fiveHourPct,
                sevenDay: sevenDayPct,
                sonnet: sonnetPct,
                extraUsage: extraUsage
            )
        } catch {
            hasError = true
        }
    }

    func reloadConfig() {
        hasConfig = ClaudeAPIClient.shared.isConfigured
        Task { await refresh() }
    }

    // MARK: - Private

    private func loadCached() {
        if let cached = ClaudeAPIClient.shared.loadCachedUsage() {
            update(from: cached.usage)
            lastUpdate = cached.fetchDate
        }
    }

    private func update(from usage: UsageResponse) {
        fiveHourPct = Int(usage.fiveHour?.utilization ?? 0)
        sevenDayPct = Int(usage.sevenDay?.utilization ?? 0)
        sonnetPct = usage.sevenDaySonnet.map { Int($0.utilization) }

        if let reset = usage.fiveHour?.resetsAtDate {
            let diff = reset.timeIntervalSinceNow
            if diff > 0 {
                let h = Int(diff) / 3600
                let m = (Int(diff) % 3600) / 60
                fiveHourReset = h > 0 ? "\(h)h \(m)min" : "\(m)min"
            } else {
                fiveHourReset = String(localized: "relative.now")
            }
        } else {
            fiveHourReset = ""
        }

        if let resetsAt = usage.sevenDay?.resetsAtDate {
            sevenDayElapsedPct = PacingCalculator.elapsedPct(resetsAt: resetsAt, duration: 7 * 24 * 3600)
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE h:mm a"
            sevenDayReset = formatter.string(from: resetsAt)
        } else {
            sevenDayElapsedPct = nil
            sevenDayReset = ""
        }

        extraUsage = usage.extraUsage?.isEnabled == true ? usage.extraUsage : nil

        if let pacing = PacingCalculator.calculate(from: usage) {
            pacingDelta = Int(pacing.delta)
            pacingZone = pacing.zone
            pacingResult = pacing
        }
    }

    private func startRefreshTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    // MARK: - Menu Bar Image Rendering

    private func renderPinnedMetrics() -> NSImage {
        let height: CGFloat = 22
        let ordered: [MetricID] = [.fiveHour, .sevenDay, .sonnet, .pacing].filter { pinnedMetrics.contains($0) }

        // Build attributed string with placeholder colors to measure width.
        let str = buildMetricsString(ordered: ordered, labelColor: .labelColor)
        let width = ceil(str.size().width) + 2

        // Use drawing handler so colors are re-resolved on every render
        // (handles light/dark menu bar switching correctly).
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { [self] _ in
            let s = self.buildMetricsString(ordered: ordered, labelColor: .labelColor)
            s.draw(at: NSPoint(x: 1, y: (height - s.size().height) / 2))
            return true
        }
        img.isTemplate = false
        return img
    }

    private func buildMetricsString(ordered: [MetricID], labelColor: NSColor) -> NSMutableAttributedString {
        let str = NSMutableAttributedString()
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: labelColor,
        ]
        for (i, metric) in ordered.enumerated() {
            if i > 0 {
                str.append(NSAttributedString(string: "  ", attributes: sepAttrs))
            }
            if metric == .pacing {
                let dotAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: nsColorForZone(pacingZone),
                ]
                str.append(NSAttributedString(string: "\u{25CF}", attributes: dotAttrs))
                if pacingDisplayMode == .dotDelta {
                    let sign = pacingDelta >= 0 ? "+" : ""
                    str.append(NSAttributedString(string: " \(sign)\(pacingDelta)%", attributes: textAttrs))
                }
            } else {
                let value = pct(for: metric)
                let dotAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: nsColorForPct(value),
                ]
                str.append(NSAttributedString(string: "\u{25CF} ", attributes: dotAttrs))
                str.append(NSAttributedString(string: "\(value)%", attributes: textAttrs))
            }
        }
        return str
    }

    private func renderText(_ text: String) -> NSImage {
        let height: CGFloat = 22
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let width = ceil(str.size().width) + 2
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            str.draw(at: NSPoint(x: 1, y: (height - str.size().height) / 2))
            return true
        }
        img.isTemplate = false
        return img
    }

    private func nsColorForPct(_ pct: Int) -> NSColor {
        if pct < 60 { return NSColor(red: 0.13, green: 0.77, blue: 0.29, alpha: 1) } // green
        if pct < 85 { return NSColor(red: 0.98, green: 0.60, blue: 0.09, alpha: 1) } // orange
        return NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1) // red
    }

    private func nsColorForZone(_ zone: PacingZone) -> NSColor {
        switch zone {
        case .chill: return NSColor(red: 0.13, green: 0.77, blue: 0.29, alpha: 1)
        case .onTrack: return NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
        case .hot: return NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        }
    }
}

// MARK: - Visual Effect Background

private struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.backgroundColor = .clear
                window.isOpaque = false
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Popover View

struct MenuBarPopoverView: View {
    private static let pacingHotThreshold: Double = 1

    @ObservedObject var viewModel: MenuBarViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TokenEater")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Metrics
            VStack(spacing: 10) {
                metricRow(id: .fiveHour, label: String(localized: "metric.session"), pct: viewModel.fiveHourPct, reset: viewModel.fiveHourReset, elapsedPct: viewModel.pacingResult?.expectedUsage)
                metricRow(id: .sevenDay, label: String(localized: "metric.weekly"), pct: viewModel.sevenDayPct, reset: viewModel.sevenDayReset, elapsedPct: viewModel.sevenDayElapsedPct)
                if let sonnetPct = viewModel.sonnetPct {
                    metricRow(id: .sonnet, label: String(localized: "metric.sonnet"), pct: sonnetPct, reset: nil)
                }
                if let extra = viewModel.extraUsage {
                    extraUsageRow(extra)
                }
            }
            .padding(.horizontal, 16)

            // Last update
            if let date = viewModel.lastUpdate {
                let formattedDate = date.formatted(.relative(presentation: .named))
                Text(String(format: String(localized: "menubar.updated"), formattedDate))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }

            Divider()
                .padding(.top, 12)

            // Actions
            HStack(spacing: 0) {
                actionButton(icon: "arrow.clockwise", label: String(localized: "menubar.refresh")) {
                    Task { await viewModel.refresh() }
                }
                actionButton(icon: "gear", label: String(localized: "menubar.settings")) {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                actionButton(icon: "power", label: String(localized: "menubar.quit")) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 264)
        .background(WindowAccessor())
        .background(VisualEffectView())
    }

    // MARK: - Metric Row

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func metricRow(id: MetricID, label: String, pct: Int, reset: String?, elapsedPct: Double? = nil) -> some View {
        let isPinned = viewModel.pinnedMetrics.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.toggleMetric(id)
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 9))
                        .foregroundStyle(isPinned ? colorForPct(pct) : Color(nsColor: .tertiaryLabelColor))
                        .rotationEffect(.degrees(isPinned ? 0 : 45))
                }
                .buttonStyle(.plain)
                .help(isPinned ? Text(String(localized: "menubar.hide")) : Text(String(localized: "menubar.show")))

                Text(label)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = reset, !reset.isEmpty {
                    Text(String(format: String(localized: "metric.reset"), reset))
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                Text("\(pct)%")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(colorForPct(pct))
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(height: 5)

                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(gradientForPct(pct, elapsedPct: elapsedPct))
                        .frame(width: max(0, geo.size.width * CGFloat(pct) / 100), height: 5)

                    if let elapsedPct {
                        Rectangle()
                            .fill(tickColorForDelta(Double(pct) - elapsedPct))
                            .frame(width: 2, height: 10)
                            .offset(x: geo.size.width * CGFloat(min(elapsedPct, 100)) / 100 - 1)
                    }
                }
            }
            .frame(height: 10)
        }
    }

    private func extraUsageRow(_ extra: ExtraUsage) -> some View {
        let usedDollars = extra.usedCredits / 100
        let limitDollars = extra.monthlyLimit / 100
        let pct = Int(extra.utilization)
        let elapsedPct = monthElapsedPct()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(String(localized: "metric.extra"))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "$%.2f / $%.0f", usedDollars, limitDollars))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text("\(pct)%")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(colorForPct(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(gradientForPct(pct, elapsedPct: elapsedPct))
                        .frame(width: max(0, geo.size.width * CGFloat(pct) / 100), height: 5)
                    Rectangle()
                        .fill(tickColorForDelta(Double(pct) - elapsedPct))
                        .frame(width: 2, height: 10)
                        .offset(x: geo.size.width * CGFloat(min(elapsedPct, 100)) / 100 - 1)
                }
            }
            .frame(height: 10)
        }
    }

    private func monthElapsedPct(now: Date = Date()) -> Double {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let range = cal.range(of: .day, in: .month, for: now)!
        let duration = Double(range.count) * 24 * 3600
        return min(max(now.timeIntervalSince(start) / duration, 0), 1) * 100
    }

    private func tickColorForDelta(_ delta: Double) -> Color {
        if delta > Self.pacingHotThreshold { return Color(red: 0.94, green: 0.27, blue: 0.27) }
        if delta < -Self.pacingHotThreshold { return Color(red: 0.13, green: 0.77, blue: 0.29) }
        return Color(red: 0.04, green: 0.52, blue: 1.0)
    }

    private func barColorForDelta(_ delta: Double) -> (Double, Double, Double) {
        if delta < -Self.pacingHotThreshold { return (0.13, 0.77, 0.29) }
        if delta > Self.pacingHotThreshold  { return (0.94, 0.27, 0.27) }
        // within threshold: interpolate green→blue→red
        let t = (delta + Self.pacingHotThreshold) / (2 * Self.pacingHotThreshold)
        if t < 0.5 {
            let s = t * 2
            return (0.13 + (0.04 - 0.13) * s, 0.77 + (0.52 - 0.77) * s, 0.29 + (1.0 - 0.29) * s)
        } else {
            let s = (t - 0.5) * 2
            return (0.04 + (0.94 - 0.04) * s, 0.52 + (0.27 - 0.52) * s, 1.0 + (0.27 - 1.0) * s)
        }
    }

    private func colorForPct(_ pct: Int) -> Color {
        if pct < 60 { return Color(red: 0.13, green: 0.77, blue: 0.29) }
        if pct < 85 { return Color(red: 0.98, green: 0.60, blue: 0.09) }
        return Color(red: 0.94, green: 0.27, blue: 0.27)
    }

    private func gradientForPct(_ pct: Int, elapsedPct: Double? = nil) -> LinearGradient {
        guard let elapsedPct, pct > 0 else {
            return LinearGradient(
                colors: [Color(red: 0.13, green: 0.77, blue: 0.29), Color(red: 0.29, green: 0.87, blue: 0.50)],
                startPoint: .leading, endPoint: .trailing
            )
        }

        // Sample barColorForDelta at several positions across the filled bar.
        let pctD = Double(pct)
        let positions: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
        let stops: [Gradient.Stop] = positions.map { fraction in
            let xPct = fraction * pctD
            let (r, g, b) = barColorForDelta(xPct - elapsedPct)
            return .init(color: Color(red: r, green: g, blue: b), location: fraction)
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
}
