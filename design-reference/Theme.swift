import SwiftUI

// MARK: - Design tokens
//
// Every inline hex/alpha literal from the HTML mock collapses into `Theme`.
// See `SwiftUI Handoff.md` §1. Geist → SF Pro (system), Geist Mono → SF Mono.

enum Theme {

    // Surfaces
    static let windowBG  = Color(hex: 0x15151A)   // main content panels
    static let sidebarBG = Color(hex: 0x101014)   // sidebar
    static let popoverBG = Color(hex: 0x1B1B22)   // menu-bar + picker popovers
    static let consoleBG = Color(hex: 0x0D0D11)   // console / code surfaces

    // Text
    static let textHi    = Color(hex: 0xEDECEF)
    static let textMid   = Color(hex: 0xD5D2DC)
    static let textLo    = Color(hex: 0x9A96A4)
    static let textDim   = Color(hex: 0x615D68)
    static let textFaint = Color(hex: 0x56535D)

    // A few in-between greys the mock uses verbatim.
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

    // Amber tints reused for chips / active rows.
    static let amberFill   = Color(hex: 0xE0A04B, alpha: 0.14)
    static let amberFillLo = Color(hex: 0xE0A04B, alpha: 0.10)
    static let amberBorder = Color(hex: 0xE0A04B, alpha: 0.22)
    static let greenGlow   = Color(hex: 0x5BBF8A, alpha: 0.12)

    // Send-button gradient (#e7ac57 → #bd7a2c).
    static let sendGradient = LinearGradient(
        colors: [Color(hex: 0xE7AC57), Color(hex: 0xBD7A2C)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // Corner radii (handoff §1).
    enum Radius {
        static let card: CGFloat    = 12
        static let control: CGFloat = 8
        static let field: CGFloat   = 9
        static let popover: CGFloat = 15
        static let bubble: CGFloat  = 14
        static let bubbleTight: CGFloat = 5   // tightened corner on user bubbles
    }
}

extension Color {
    /// `Color(hex: 0x15151A)` — mirrors the inline hex literals in the mock.
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension Font {
    /// SF Mono. Used for model IDs, metrics, timestamps, log lines, and the
    /// letter-spaced uppercase eyebrows.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Brand mark
//
// The lemon 🍋‍🟩 is the brand glyph. Ship a real asset (`Image("ModeloMark")`)
// and a monochrome template variant for the menu bar; the emoji here is the
// mock stand-in.

struct ModeloMark: View {
    var size: CGFloat = 19
    var body: some View {
        Text("🍋‍🟩")
            .font(.system(size: size))
            // Swap for: Image("ModeloMark").resizable().frame(width: size, height: size)
    }
}

// MARK: - Shared controls

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

/// Eyebrow label: mono, uppercase, letter-spaced, dim — used throughout.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.textDim
    var size: CGFloat = 10
    var tracking: CGFloat = 1.6
    var body: some View {
        Text(text)
            .font(.mono(size))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}
