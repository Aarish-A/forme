import SwiftUI

/// Every token and component the design system offers, on one screen.
///
/// This is not a shipping screen — it exists so that on brand day the whole
/// system can be judged in a few seconds instead of by clicking through the
/// app. Use the previews below, and the canvas variant toggles for Increase
/// Contrast and Reduce Motion, which are read-only environment values and so
/// can't be set from code.
struct DesignSystemGallery: View {
    /// Kept next to the gallery rather than on `Theme.Colors`, so the production
    /// token file stays free of display-only lists. Adding a token means adding
    /// a line here — the gallery being incomplete is the reminder.
    private let colours: [(String, Color)] = [
        ("accent", Theme.Colors.accent),
        ("surface", Theme.Colors.surface),
        ("surfaceSecondary", Theme.Colors.surfaceSecondary),
        ("outline", Theme.Colors.outline),
        ("textPrimary", Theme.Colors.textPrimary),
        ("textSecondary", Theme.Colors.textSecondary)
    ]

    private let spacings: [(String, CGFloat)] = [
        ("xs", Theme.Spacing.xs),
        ("sm", Theme.Spacing.sm),
        ("md", Theme.Spacing.md),
        ("lg", Theme.Spacing.lg),
        ("xl", Theme.Spacing.xl),
        ("xxl", Theme.Spacing.xxl)
    ]

    private let radii: [(String, CGFloat)] = [
        ("sm", Theme.Radius.sm),
        ("md", Theme.Radius.md),
        ("card", Theme.Radius.card)
    ]

    @State private var isNudged = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                section("Type") {
                    ForEach(Theme.TextRole.allCases, id: \.self) { role in
                        Text(role.rawValue)
                            .formeText(role)
                    }
                }

                section("Colour") {
                    ForEach(colours, id: \.0) { name, colour in
                        HStack(spacing: Theme.Spacing.md) {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(colour)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .strokeBorder(Theme.Colors.outline)
                                )
                            Text(name).formeText(.body)
                        }
                    }
                }

                section("Status") {
                    ForEach(SemanticStatus.allCases, id: \.self) { status in
                        StatusLabel(status, "The quick brown fox.")
                    }
                }

                section("Spacing") {
                    ForEach(spacings, id: \.0) { name, value in
                        HStack(spacing: Theme.Spacing.md) {
                            Rectangle()
                                .fill(Theme.Colors.accent)
                                .frame(width: value, height: 16)
                            Text("\(name) · \(Int(value))").formeText(.caption)
                        }
                    }
                }

                section("Radius") {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(radii, id: \.0) { name, value in
                            VStack(spacing: Theme.Spacing.xs) {
                                RoundedRectangle(cornerRadius: value)
                                    .fill(Theme.Colors.surfaceSecondary)
                                    .frame(width: 64, height: 64)
                                Text(name).formeText(.caption)
                            }
                        }
                    }
                }

                section("Card") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Linen shirt").formeText(.bodyEmphasis)
                        Text("Worn twice this month").formeText(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .formeCard()
                }

                section("Buttons") {
                    Button("Primary") {}.buttonStyle(.formePrimary)
                    Button("Primary, disabled") {}.buttonStyle(.formePrimary).disabled(true)
                    Button("Secondary") {}.buttonStyle(.formeSecondary)
                    Button("Secondary, disabled") {}.buttonStyle(.formeSecondary).disabled(true)
                }

                section("Motion") {
                    Button("Nudge") { isNudged.toggle() }
                        .buttonStyle(.formeSecondary)
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.accent)
                        .frame(width: 44, height: 44)
                        .offset(x: isNudged ? 120 : 0)
                        .animation(Theme.Motion.settle, value: isNudged)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .formeScreenPadding()
            .padding(.vertical, Theme.Spacing.xl)
        }
        .background(Theme.Colors.surface)
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .formeText(.sectionTitle)
            content()
        }
    }
}

#Preview("Light") {
    DesignSystemGallery()
}

#Preview("Dark") {
    DesignSystemGallery()
        .preferredColorScheme(.dark)
}

#Preview("Accessibility XL") {
    DesignSystemGallery()
        .dynamicTypeSize(.accessibility3)
}
