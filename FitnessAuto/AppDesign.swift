import SwiftUI

/// Native surfaces and semantic colors; no motion on incoming Bluetooth samples.
enum AppDesign {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.84, blue: 0.73, alpha: 1)
            : UIColor(red: 0.04, green: 0.40, blue: 0.32, alpha: 1)
    })
    static let destructive = Color(red: 0.76, green: 0.12, blue: 0.16)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct AppListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppDesign.background)
            .tint(AppDesign.accent)
            .environment(\.defaultMinListRowHeight, 48)
    }
}
extension View {
    func appListStyle() -> some View { modifier(AppListStyle()) }
}

struct AppSectionTitle: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.bottom, 4)
    }
}

struct ConnectionBadge: View {
    let title: String
    let connected: Bool
    var connecting = false
    var body: some View {
        HStack(spacing: 8) {
            if connecting { ProgressView().controlSize(.mini) }
            else { Circle().fill(connected ? AppDesign.accent : Color.secondary).frame(width: 7, height: 7) }
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppDesign.accent.opacity(connected ? 0.10 : 0.04), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 38
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                if !typeSize.isAccessibilitySize { Image(systemName: icon).accessibilityHidden(true) }
                Text(title).lineLimit(1).minimumScaleFactor(0.5)
            }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 5) { number; unitLabel }
                VStack(alignment: .leading, spacing: 2) { number; unitLabel }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppDesign.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private var number: some View {
        Text(value).font(.system(size: numberSize, weight: .semibold, design: .rounded))
            .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
    }
    private var unitLabel: some View { Text(unit).font(.caption).foregroundStyle(.secondary) }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppDesign.accent
    var keepsTintWhenDisabled = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(enabled || keepsTintWhenDisabled ? Color.white : Color.secondary)
            .background(enabled ? tint : keepsTintWhenDisabled ? tint.opacity(0.65) : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PlanSummaryRow: View {
    let plan: WorkoutPlan
    let icon: String
    var showsChevron = true
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(AppDesign.accent)
                .frame(width: 44, height: 44)
                .background(AppDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(plan.title).font(.headline).foregroundStyle(.primary)
                Text((plan.duration % 60 == 0 ? "\(plan.duration / 60) 分钟" : "\(plan.duration / 60) 分 \(plan.duration % 60) 秒") + " · \(plan.steps.count) 个阶段")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 6)
    }
}

struct DashboardShortcut: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(AppDesign.accent)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
