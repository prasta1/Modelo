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
    enum Palette {
        static let bg          = Color(hex: 0x0B0C0F) // window base
        static let panel       = Color(hex: 0x141519) // raised surface (sidebar, composer)
        static let panelHigh   = Color(hex: 0x1C1E25) // hover / selected / tracks
        static let ink         = Color(hex: 0xECEDF0) // primary text
        static let inkDim       = Color(hex: 0x9A9DA6) // secondary text
        static let inkFaint    = Color(hex: 0x5E626B) // tertiary / metadata

        static let signal      = Color(hex: 0xFFB23D) // brand accent (amber)
        static let live        = Color(hex: 0x46DE83) // online
        static let idle        = Color(hex: 0xE8B84B) // unknown (pulses)
        static let offline     = Color(hex: 0x565A63) // offline
        static let alert       = Color(hex: 0xFF6A45) // errors / over-budget

        // Capability tints
        static let vision      = Color(hex: 0x5AC8FA)
        static let think       = Color(hex: 0xB98CFF)

        static let stroke       = Color.white.opacity(0.07)
        static let strokeStrong = Color.white.opacity(0.13)
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
                LinearGradient(colors: [Color.white.opacity(0.045), .clear],
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
            .font(Theme.label(9))
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
    }
}

/// Capability chips for a model. Shared by the picker trigger and the chat header
/// so the two presentations never drift apart.
struct CapabilityChips: View {
    let model: LMStudioModel

    var body: some View {
        HStack(spacing: 4) {
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
        if let f = model.fileSizeFormatted { p.append(f) }
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
    // Surfaces
    static let windowBG  = Color(hex: 0x15151A)   // main content panels
    static let sidebarBG = Color(hex: 0x101014)   // sidebar
    static let popoverBG = Color(hex: 0x1B1B22)   // menu-bar + picker popovers
    static let consoleBG = Color(hex: 0x0D0D11)   // console / code surfaces

    // Text
    static let textHi     = Color(hex: 0xEDECEF)
    static let textMid    = Color(hex: 0xD5D2DC)
    static let textLo     = Color(hex: 0x9A96A4)
    static let textDim    = Color(hex: 0x615D68)
    static let textFaint  = Color(hex: 0x56535D)
    static let textBright = Color(hex: 0xE7E5EC)   // sidebar names / wordmark
    static let textSoft   = Color(hex: 0xC9C5D0)   // conversation titles
    static let textMute   = Color(hex: 0x8A8692)   // inactive nav / chevrons

    // Accent + status
    static let amber     = Color(hex: 0xE0A04B)    // brand accent
    static let amberName = Color(hex: 0xE8B86A)    // selected model name in picker
    static let green     = Color(hex: 0x5BBF8A)    // live / loaded
    static let blue      = Color(hex: 0x7C93C9)    // POST log lines
    static let purple    = Color(hex: 0xAC9FD6)    // MCP log lines

    // Hairlines / fills (white at low alpha)
    static let line   = Color.white.opacity(0.06)
    static let fill   = Color.white.opacity(0.025)
    static let fillHi = Color.white.opacity(0.055)

    // Amber tints reused for chips / active rows
    static let amberFill   = Color(hex: 0xE0A04B, alpha: 0.14)
    static let amberFillLo = Color(hex: 0xE0A04B, alpha: 0.10)
    static let amberBorder = Color(hex: 0xE0A04B, alpha: 0.22)
    static let greenGlow   = Color(hex: 0x5BBF8A, alpha: 0.12)

    // Send-button gradient (#e7ac57 → #bd7a2c).
    static let sendGradient = LinearGradient(
        colors: [Color(hex: 0xE7AC57), Color(hex: 0xBD7A2C)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

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
