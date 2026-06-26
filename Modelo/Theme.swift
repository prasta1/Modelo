import SwiftUI

/// Centralized design tokens for Modelo's "instrument" look — a dark,
/// telemetry-forward control surface for local inference. Colors, fonts, and the
/// shared chrome views all live here so the whole app stays consistent and a
/// palette tweak happens in exactly one place.
enum Theme {

    // MARK: Palette
    // Near-black panels lifted by a single warm "signal" accent. Status hues
    // (live / idle / offline) are deliberately kept distinct from the brand so a
    // green dot never reads as a tappable amber control.
    /// The active palette (§3.5). Swapped when the user changes the theme; all the
    /// token accessors below read through it. Set this *before* the root `.id(themeID)`
    /// subtree rebuilds so views pick up the new colors. Defaults to the dark look.
    static var active: ThemePalette = .dark

    /// Apply the stored theme to `active` (called at launch and on each scene build).
    @discardableResult
    static func applyStored(_ raw: String) -> ThemePalette {
        active = ThemeID.current(raw).palette
        return active
    }

    enum Palette {
        static var bg: Color          { active.bg }
        static var panel: Color       { active.panel }
        static var panelHigh: Color   { active.panelHigh }
        static var ink: Color         { active.ink }
        static var inkDim: Color      { active.inkDim }
        static var inkFaint: Color    { active.inkFaint }

        static var signal: Color      { active.signal }
        static var live: Color        { active.live }
        static var idle: Color        { active.idle }
        static var offline: Color     { active.offline }
        static var alert: Color       { active.alert }

        static var vision: Color      { active.vision }
        static var think: Color       { active.think }

        static var stroke: Color       { active.stroke }
        static var strokeStrong: Color { active.strokeStrong }
    }

    // MARK: Type
    // Per design preference the whole UI uses SF Pro (the system font) for one
    // consistent typeface. These helpers are kept — call sites still read
    // `label`/`metric`/`mono` — but now return SF Pro. Tabular alignment, where it
    // matters (metrics, counts), is handled with `.monospacedDigit()` at the call site.
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold)
    }
    static func metric(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .medium)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Monospaced — the deliberate exception for genuinely code/console text
    /// (tool-call arguments, shell commands). The rest of the UI is SF Pro.
    static func code(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Shared HH:mm formatter for message timestamps (built once, reused).
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Color from hex literal

extension Color {
    /// Build an sRGB color from a `0xRRGGBB` literal — keeps the palette readable.
    /// `alpha` defaults to opaque; the Native Refined tokens pass it for tinted fills.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Reusable surface

extension View {
    /// Wrap content in the recurring rounded, hairline-stroked panel unit.
    func panel(_ fill: Color = Theme.Palette.panel,
               radius: CGFloat = 10,
               stroke: Color = Theme.Palette.stroke) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }
}

/// App-wide backdrop: a near-black base lifted by a faint top glow so large dark
/// surfaces don't read as a flat void.
struct InstrumentBackground: View {
    var body: some View {
        Theme.Palette.bg
            .overlay(alignment: .top) {
                LinearGradient(colors: [Theme.active.glow, .clear],
                               startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
    }
}

// MARK: - Shared chrome views

/// A small uppercase, letter-spaced monospaced caption — the "eyebrow" label that
/// sits above sections and beside metrics. The signature texture of the look.
struct Eyebrow: View {
    let text: String
    var color: Color
    var size: CGFloat

    init(_ text: String, color: Color = Theme.Palette.inkFaint, size: CGFloat = 10) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(size))
            .tracking(1.5)
            .foregroundStyle(color)
    }
}

/// A hairline-bordered capability tag (vision / tools / reasoning), monospaced.
struct Chip: View {
    let text: String
    var tint: Color = Theme.Palette.inkDim

    var body: some View {
        Text(text.uppercased())
            .lineLimit(1)
            .font(Theme.label(9))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
            .fixedSize()
    }
}

/// Capability chips for a model. Shared by the picker trigger and the chat header
/// so the two presentations never drift apart.
struct CapabilityChips: View {
    let model: LMStudioModel

    var body: some View {
        HStack(spacing: 4) {
            if model.isFree           { Chip(text: "free",   tint: Theme.Palette.live) }
            if model.supportsVision   { Chip(text: "vision", tint: Theme.Palette.vision) }
            if model.supportsToolUse  { Chip(text: "tools",  tint: Theme.Palette.signal) }
            if model.supportsThinking { Chip(text: "reason", tint: Theme.Palette.think) }
        }
    }
}

/// A themed on/off control shaped like a capability chip: an outlined capsule at
/// rest that fills with the brand amber when engaged. Lets header toggles (e.g.
/// Tools) read as part of the instrument surface instead of borrowing the default
/// macOS accent button. Apply with `.toggleStyle(ChipToggleStyle())`.
struct ChipToggleStyle: ToggleStyle {
    var tint: Color = Theme.Palette.signal

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ChipToggleLabel(on: configuration.isOn, tint: tint) { configuration.label }
        }
        .buttonStyle(.plain)
    }
}

/// Label chrome for `ChipToggleStyle`, split into its own view so it can own the
/// hover state — a `ToggleStyle` itself can't hold `@State`.
private struct ChipToggleLabel<Label: View>: View {
    let on: Bool
    let tint: Color
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        label()
            .font(Theme.label(9))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(on ? tint : Theme.Palette.inkDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                on ? tint.opacity(0.15) : (hovering ? Theme.Palette.panelHigh : Color.clear),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(on ? tint.opacity(0.5) : Theme.Palette.stroke, lineWidth: 1)
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

/// A monospaced "·"-separated spec readout: arch · params · quant · context · size.
/// Omits whatever the API didn't report, so `/v1/models` fallbacks degrade cleanly.
struct SpecStrip: View {
    let model: LMStudioModel
    var showArch: Bool = true

    private var parts: [String] {
        var p: [String] = []
        if showArch, let a = model.displayArch { p.append(a.uppercased()) }
        if let s = model.parameterSize   { p.append(s) }
        if let q = model.quantization    { p.append(q) }
        if let c = model.maxContextLength { p.append("\(c >= 1000 ? "\(c / 1000)K" : "\(c)") ctx") }
        if let f = model.displaySizeFormatted { p.append(f) }
        return p
    }

    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(Theme.metric(11))
            .foregroundStyle(Theme.Palette.inkDim)
            .lineLimit(1)
    }
}

/// A glowing reachability LED. "Unknown" breathes so it's told apart from the brand
/// amber by motion, not just hue.
struct StatusLED: View {
    let status: ServerStatus
    var size: CGFloat = 7
    /// Whether the "unknown" state breathes. Turn OFF next to content that reflows
    /// (e.g. a header with a live count): a `repeatForever` animation can otherwise
    /// leak into the surrounding layout and animate the dot's position.
    var breathe: Bool = true
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch status {
        case .online:  Theme.Palette.live
        case .offline: Theme.Palette.offline
        case .unknown: Theme.Palette.idle
        }
    }

    /// Only breathe for an unknown server, when asked, and never under Reduce Motion.
    private var isBreathing: Bool { breathe && !reduceMotion && status == .unknown }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(status == .offline ? 0 : 0.9),
                    radius: status == .offline ? 0 : 5)
            .opacity(isBreathing && pulsing ? 0.3 : 1)
            .animation(isBreathing
                       ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                       : .default,
                       value: pulsing)
            // Track the breathing state so the loop stops the moment a server
            // resolves (online/offline), rather than lingering from onAppear.
            .onChange(of: isBreathing, initial: true) { pulsing = isBreathing }
    }
}

/// A blinking block cursor shown while an assistant turn is still empty (pre-first
/// token), so a pending reply looks alive instead of like a dead "…".
struct BlinkingCursor: View {
    @State private var on = true

    var body: some View {
        Text("▍")
            .font(.system(size: 15))
            .foregroundStyle(Theme.Palette.signal)
            .opacity(on ? 1 : 0.12)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}

// MARK: - Native Refined design tokens (Claude Design handoff)
//
// Flat token set from the redesign (`design-reference/Theme.swift`), merged
// alongside `Theme.Palette` for the screen-by-screen restyle. Each view adopts
// these as it is reworked; `Palette` stays until every screen has migrated, then
// it can be retired.
extension Theme {
    // All tokens read through the active palette (§3.5); see `ThemePalette`.
    // Surfaces
    static var windowBG: Color  { active.windowBG }   // main content panels
    static var sidebarBG: Color { active.sidebarBG }  // sidebar
    static var popoverBG: Color { active.popoverBG }  // menu-bar + picker popovers
    static var consoleBG: Color { active.consoleBG }  // console / code surfaces

    // Text
    static var textHi: Color     { active.textHi }
    static var textMid: Color    { active.textMid }
    static var textLo: Color     { active.textLo }
    static var textDim: Color    { active.textDim }
    static var textFaint: Color  { active.textFaint }
    static var textBright: Color { active.textBright }  // sidebar names / wordmark
    static var textSoft: Color   { active.textSoft }    // conversation titles
    static var textMute: Color   { active.textMute }    // inactive nav / chevrons

    // Accent + status
    static var amber: Color     { active.amber }      // brand accent
    static var amberName: Color { active.amberName }  // selected model name in picker
    static var green: Color     { active.green }      // live / loaded
    static var blue: Color      { active.blue }       // POST log lines
    static var purple: Color    { active.purple }     // MCP log lines

    // Hairlines / fills (foreground tint at low alpha)
    static var line: Color   { active.line }
    static var fill: Color   { active.fill }
    static var fillHi: Color { active.fillHi }

    // Accent tints reused for chips / active rows
    static var amberFill: Color   { active.amberFill }
    static var amberFillLo: Color { active.amberFillLo }
    static var amberBorder: Color { active.amberBorder }
    static var greenGlow: Color   { active.greenGlow }

    // Send-button gradient (accent → deep accent).
    static var sendGradient: LinearGradient {
        LinearGradient(colors: [active.gradStart, active.gradEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    enum Radius {
        static let card: CGFloat    = 12
        static let control: CGFloat = 8
        static let field: CGFloat   = 9
        static let popover: CGFloat = 15
        static let bubble: CGFloat  = 14
        static let bubbleTight: CGFloat = 5
    }
}

extension Font {
    /// Matches the redesign's `.mono(11)` call sites. Returns SF Pro (the system
    /// font) so the whole UI shares one typeface; the name is kept for the call sites.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Native Refined shared controls

/// The lemon 🍋‍🟩 brand glyph (mock stand-in; swap for a bundled `Image` asset).
struct ModeloMark: View {
    var size: CGFloat = 19
    var body: some View {
        Text("🍋‍🟩").font(.system(size: size))
    }
}

/// 36×21 pill toggle: amber when on, white-12% when off (settings + endpoints).
struct PillToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? Theme.amber : Color.white.opacity(0.12))
            .frame(width: 36, height: 21)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? .white : Color(hex: 0xCFCDD6))
                    .frame(width: 17, height: 17)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() } }
    }
}

/// Single-select filter pill for family/provider strips. Active state highlights amber,
/// matching `ChipToggleStyle`. Use in horizontally-scrolling pill rows.
struct FilterPill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.label(9))
                .lineLimit(1)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(isActive ? Theme.amber : Theme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isActive ? Theme.amberFill : (hovering ? Theme.fillHi : Color.clear),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? Theme.amberBorder : Theme.line,
                        lineWidth: 1
                    )
                )
                .animation(.easeOut(duration: 0.12), value: isActive)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Compact pill segmented control (console filter, report range).
struct SegmentedPills: View {
    let options: [String]
    @Binding var selection: String
    var boxed: Bool = false      // report range sits inside a bordered box

    var body: some View {
        HStack(spacing: boxed ? 0 : 7) {
            ForEach(options, id: \.self) { opt in
                let active = opt == selection
                Text(opt)
                    .font(.system(size: boxed ? 12 : 11))
                    .foregroundStyle(active ? Theme.textHi : Theme.textMute)
                    .padding(.horizontal, boxed ? 12 : 10)
                    .frame(height: 24)
                    .background(active ? Theme.fillHi : .clear,
                               in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt }
            }
        }
        .padding(boxed ? 3 : 0)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.line))
            }
        }
    }
}
