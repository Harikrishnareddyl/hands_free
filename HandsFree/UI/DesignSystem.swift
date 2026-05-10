import SwiftUI

// MARK: - Design tokens

/// Centralized visual language for HandsFree's settings, onboarding, and
/// history surfaces. Inspired by AriaType's design system: near-black
/// primary on warm-white surfaces, generous rounding (8–20pt), tight
/// heading tracking, and translucent low-contrast borders.
enum DS {

    // MARK: Brand

    /// Brand mark color — the same electric violet that already lived
    /// inline in OnboardingView. Used sparingly: app icon mark, hero
    /// accents, the "click me" hint chips. Never as a constant accent
    /// background — the layout itself is monochrome-neutral.
    static let brand = Color(red: 0.42, green: 0.20, blue: 0.95)
    static let brandSoft = Color(red: 0.42, green: 0.20, blue: 0.95).opacity(0.10)

    // MARK: Status

    static let success = Color(red: 0.13, green: 0.77, blue: 0.37)   // ~#22C55E
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.04)   // ~#F59E0B
    static let danger  = Color(red: 0.94, green: 0.27, blue: 0.27)   // ~#EF4444

    // MARK: Surfaces

    /// Faint border used on cards and dividers. Stays barely visible in
    /// both light and dark mode — the geometry should carry the read.
    static let cardStrokeOpacity: Double = 0.07
    static let rowStrokeOpacity: Double = 0.05

    // MARK: Spacing — 4pt grid

    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space6: CGFloat = 6
    static let space8: CGFloat = 8
    static let space10: CGFloat = 10
    static let space12: CGFloat = 12
    static let space14: CGFloat = 14
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    // MARK: Radii — generous rounding throughout

    /// Buttons, pills, badges.
    static let radiusPill: CGFloat = 999
    /// Inputs, small cards, compact rows.
    static let radiusSmall: CGFloat = 8
    /// Settings cards, code blocks.
    static let radiusMedium: CGFloat = 12
    /// Hero cards, modal sheets, large surfaces.
    static let radiusLarge: CGFloat = 20

    // MARK: Strokes

    static let hairline: CGFloat = 0.5
}

// MARK: - Page header

/// Big page title + supporting line. Sits at the top of every detail
/// pane in Settings/Onboarding so each surface introduces itself.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Section title

/// Small title + optional subtitle that introduces a `SettingsCard`.
struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DS.space8)
    }
}

// MARK: - Settings card

/// Grouped panel used to cluster related settings. Big radius + soft
/// translucent border + neutral fill. Matches AriaType's `card` token.
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusMedium, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusMedium, style: .continuous)
                .strokeBorder(Color.primary.opacity(DS.cardStrokeOpacity), lineWidth: DS.hairline)
        )
    }
}

// MARK: - Settings row (label + trailing control)

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.space12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.space8)
            trailing
        }
        .padding(.horizontal, DS.space14)
        .padding(.vertical, DS.space10)
    }
}

// MARK: - Stacked row (label + full-width control)

struct SettingsStackRow<Inner: View>: View {
    let title: String
    var subtitle: String? = nil
    let trailingAccessory: AnyView?
    let inner: Inner

    init(
        _ title: String,
        subtitle: String? = nil,
        trailingAccessory: AnyView? = nil,
        @ViewBuilder content: () -> Inner
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingAccessory = trailingAccessory
        self.inner = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if let trailingAccessory {
                    trailingAccessory
                }
            }
            inner
        }
        .padding(.horizontal, DS.space14)
        .padding(.vertical, DS.space10)
    }
}

// MARK: - Row separator

struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(DS.rowStrokeOpacity))
            .frame(height: DS.hairline)
            .padding(.leading, DS.space14)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    enum Tone { case brand, warning, info, success, neutral }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, DS.space6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule(style: .continuous))
    }

    private var background: Color {
        switch tone {
        case .brand:   return DS.brandSoft
        case .warning: return DS.warning.opacity(0.15)
        case .info:    return Color.blue.opacity(0.12)
        case .success: return DS.success.opacity(0.18)
        case .neutral: return Color.secondary.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch tone {
        case .brand:   return DS.brand
        case .warning: return DS.warning
        case .info:    return .blue
        case .success: return DS.success
        case .neutral: return .secondary
        }
    }
}

// MARK: - Status dot

struct StatusDot: View {
    enum Kind { case ok, warn, error, neutral }

    let kind: Kind

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch kind {
        case .ok:      return DS.success
        case .warn:    return DS.warning
        case .error:   return DS.danger
        case .neutral: return Color.secondary
        }
    }
}

// MARK: - Brand mark

/// Small rounded square with the app glyph inside, used in sidebars and
/// "about" sections. Picks the gradient from the existing brand color so
/// it carries identity without splashing purple across the whole UI.
struct BrandMark: View {
    var size: CGFloat = 32
    var corner: CGFloat = 8
    var iconSize: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(DS.brand.gradient)
            Image(systemName: "mic.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - View modifiers

extension View {
    /// Inner card background with soft fill. Used for read-only command
    /// snippets and other code-like blocks.
    func dsCodeBlock() -> some View {
        self
            .padding(DS.space12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .strokeBorder(Color.primary.opacity(DS.cardStrokeOpacity), lineWidth: DS.hairline)
            )
    }
}
