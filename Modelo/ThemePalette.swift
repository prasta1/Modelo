import SwiftUI

/// A complete, resolved set of color tokens for one theme (§3.5). `Theme.active`
/// points at one of these; the static `Theme.*` accessors read through it, so the
/// ~600 existing `Theme.textHi`-style call sites stay unchanged. Swapping the active
/// palette + a root `.id(themeID)` rebuild repaints the whole app.
struct ThemePalette {
    let scheme: ColorScheme

    // Legacy `Theme.Palette.*` surfaces + text
    let bg, panel, panelHigh: Color
    let ink, inkDim, inkFaint: Color
    let signal, live, idle, offline, alert, vision, think: Color
    let stroke, strokeStrong: Color

    // Native-Refined `Theme.*` surfaces
    let windowBG, sidebarBG, popoverBG, consoleBG: Color
    // Native-Refined text hierarchy
    let textHi, textMid, textLo, textDim, textFaint, textBright, textSoft, textMute: Color
    // Accent + status
    let amber, amberName, green, blue, purple: Color
    // Hairlines / fills
    let line, fill, fillHi: Color
    // Accent tints
    let amberFill, amberFillLo, amberBorder, greenGlow: Color
    // Send-button gradient endpoints + backdrop glow
    let gradStart, gradEnd, glow: Color
}

extension ThemePalette {
    /// Derives a full palette from a compact base set (Catppuccin-style surface ramp
    /// + a handful of semantic colors). Overlay hairlines flip white/black with the
    /// scheme so they read correctly on light surfaces.
    static func build(
        scheme: ColorScheme,
        crust: UInt32, mantle: UInt32, base: UInt32, surface0: UInt32,
        text: UInt32, subtext1: UInt32, subtext0: UInt32, overlay1: UInt32, overlay0: UInt32,
        accent: UInt32, accentName: UInt32, accentDeep: UInt32,
        green: UInt32, idle: UInt32, offline: UInt32, alert: UInt32,
        blue: UInt32, purple: UInt32, vision: UInt32, think: UInt32
    ) -> ThemePalette {
        let dark = scheme == .dark
        let fg: Color = dark ? .white : .black
        let accentC = Color(hex: accent)
        let greenC = Color(hex: green)
        // Resolved surfaces / text — named so the big init below stays type-checkable.
        let cBg = Color(hex: mantle), cPanel = Color(hex: base), cPanelHigh = Color(hex: surface0)
        let cConsole = Color(hex: crust)
        let cText = Color(hex: text), cSub1 = Color(hex: subtext1), cSub0 = Color(hex: subtext0)
        let cOv1 = Color(hex: overlay1), cOv0 = Color(hex: overlay0)
        let cStroke = fg.opacity(dark ? 0.08 : 0.10), cStrokeS = fg.opacity(dark ? 0.14 : 0.16)
        let cLine = fg.opacity(dark ? 0.06 : 0.10)
        let cFill = fg.opacity(dark ? 0.03 : 0.05), cFillHi = fg.opacity(dark ? 0.06 : 0.09)
        let cGlow = dark ? fg.opacity(0.04) : fg.opacity(0.0)
        return ThemePalette(
            scheme: scheme,
            bg: cBg, panel: cPanel, panelHigh: cPanelHigh,
            ink: cText, inkDim: cSub0, inkFaint: cOv0,
            signal: accentC, live: greenC, idle: Color(hex: idle), offline: Color(hex: offline),
            alert: Color(hex: alert), vision: Color(hex: vision), think: Color(hex: think),
            stroke: cStroke, strokeStrong: cStrokeS,
            windowBG: cPanel, sidebarBG: cBg, popoverBG: cPanelHigh, consoleBG: cConsole,
            textHi: cText, textMid: cSub1, textLo: cSub0,
            textDim: cOv1, textFaint: cOv0, textBright: cText, textSoft: cSub1, textMute: cOv1,
            amber: accentC, amberName: Color(hex: accentName), green: greenC,
            blue: Color(hex: blue), purple: Color(hex: purple),
            line: cLine, fill: cFill, fillHi: cFillHi,
            amberFill: accentC.opacity(0.16), amberFillLo: accentC.opacity(0.11),
            amberBorder: accentC.opacity(0.30), greenGlow: greenC.opacity(0.14),
            gradStart: accentC, gradEnd: Color(hex: accentDeep),
            glow: cGlow
        )
    }

    /// The shipping default — Modelo's existing dark "instrument" look, preserved
    /// token-for-token so enabling theming changes nothing until the user opts in.
    static let dark = ThemePalette(
        scheme: .dark,
        bg: Color(hex: 0x0B0C0F), panel: Color(hex: 0x141519), panelHigh: Color(hex: 0x1C1E25),
        ink: Color(hex: 0xECEDF0), inkDim: Color(hex: 0x9A9DA6), inkFaint: Color(hex: 0x5E626B),
        signal: Color(hex: 0xFFB23D), live: Color(hex: 0x46DE83), idle: Color(hex: 0xE8B84B),
        offline: Color(hex: 0x565A63), alert: Color(hex: 0xFF6A45),
        vision: Color(hex: 0x5AC8FA), think: Color(hex: 0xB98CFF),
        stroke: Color.white.opacity(0.07), strokeStrong: Color.white.opacity(0.13),
        windowBG: Color(hex: 0x15151A), sidebarBG: Color(hex: 0x101014),
        popoverBG: Color(hex: 0x1B1B22), consoleBG: Color(hex: 0x0D0D11),
        textHi: Color(hex: 0xEDECEF), textMid: Color(hex: 0xD5D2DC), textLo: Color(hex: 0x9A96A4),
        textDim: Color(hex: 0x615D68), textFaint: Color(hex: 0x56535D), textBright: Color(hex: 0xE7E5EC),
        textSoft: Color(hex: 0xC9C5D0), textMute: Color(hex: 0x8A8692),
        amber: Color(hex: 0xE0A04B), amberName: Color(hex: 0xE8B86A), green: Color(hex: 0x5BBF8A),
        blue: Color(hex: 0x7C93C9), purple: Color(hex: 0xAC9FD6),
        line: Color.white.opacity(0.06), fill: Color.white.opacity(0.025), fillHi: Color.white.opacity(0.055),
        amberFill: Color(hex: 0xE0A04B, alpha: 0.14), amberFillLo: Color(hex: 0xE0A04B, alpha: 0.10),
        amberBorder: Color(hex: 0xE0A04B, alpha: 0.22), greenGlow: Color(hex: 0x5BBF8A, alpha: 0.12),
        gradStart: Color(hex: 0xE7AC57), gradEnd: Color(hex: 0xBD7A2C), glow: Color.white.opacity(0.045)
    )

    /// A clean light theme (not Catppuccin) for users who want a true light mode.
    static let light = build(
        scheme: .light,
        crust: 0xECECEF, mantle: 0xF2F2F5, base: 0xFFFFFF, surface0: 0xE6E6EB,
        text: 0x1A1A1F, subtext1: 0x3A3A44, subtext0: 0x5C5C68, overlay1: 0x86868F, overlay0: 0xA2A2AC,
        accent: 0xC8801E, accentName: 0xA8650F, accentDeep: 0x9A6212,
        green: 0x2E9E63, idle: 0xC99A2E, offline: 0xA8A8B2, alert: 0xD1503A,
        blue: 0x3E5FA8, purple: 0x7A5AB8, vision: 0x1E8FB8, think: 0x8050C0
    )

    // Catppuccin — https://catppuccin.com/palette
    static let latte = build(
        scheme: .light,
        crust: 0xDCE0E8, mantle: 0xE6E9EF, base: 0xEFF1F5, surface0: 0xCCD0DA,
        text: 0x4C4F69, subtext1: 0x5C5F77, subtext0: 0x6C6F85, overlay1: 0x8C8FA1, overlay0: 0x9CA0B0,
        accent: 0xFE640B, accentName: 0xDF8E1D, accentDeep: 0xC24F08,
        green: 0x40A02B, idle: 0xDF8E1D, offline: 0x9CA0B0, alert: 0xD20F39,
        blue: 0x1E66F5, purple: 0x8839EF, vision: 0x209FB5, think: 0x7287FD
    )

    static let frappe = build(
        scheme: .dark,
        crust: 0x232634, mantle: 0x292C3C, base: 0x303446, surface0: 0x414559,
        text: 0xC6D0F5, subtext1: 0xB5BFE2, subtext0: 0xA5ADCE, overlay1: 0x838BA7, overlay0: 0x737994,
        accent: 0xEF9F76, accentName: 0xE5C890, accentDeep: 0xD97F4F,
        green: 0xA6D189, idle: 0xE5C890, offline: 0x737994, alert: 0xE78284,
        blue: 0x8CAAEE, purple: 0xCA9EE6, vision: 0x85C1DC, think: 0xBABBF1
    )

    static let macchiato = build(
        scheme: .dark,
        crust: 0x181926, mantle: 0x1E2030, base: 0x24273A, surface0: 0x363A4F,
        text: 0xCAD3F5, subtext1: 0xB8C0E0, subtext0: 0xA5ADCB, overlay1: 0x8087A2, overlay0: 0x6E738D,
        accent: 0xF5A97F, accentName: 0xEED49F, accentDeep: 0xE08658,
        green: 0xA6DA95, idle: 0xEED49F, offline: 0x6E738D, alert: 0xED8796,
        blue: 0x8AADF4, purple: 0xC6A0F6, vision: 0x7DC4E4, think: 0xB7BDF8
    )

    static let mocha = build(
        scheme: .dark,
        crust: 0x11111B, mantle: 0x181825, base: 0x1E1E2E, surface0: 0x313244,
        text: 0xCDD6F4, subtext1: 0xBAC2DE, subtext0: 0xA6ADC8, overlay1: 0x7F849C, overlay0: 0x6C7086,
        accent: 0xFAB387, accentName: 0xF9E2AF, accentDeep: 0xE8915C,
        green: 0xA6E3A1, idle: 0xF9E2AF, offline: 0x6C7086, alert: 0xF38BA8,
        blue: 0x89B4FA, purple: 0xCBA6F7, vision: 0x74C7EC, think: 0xB4BEFE
    )
}

/// The user-selectable themes (§3.5). Raw values persist in `@AppStorage("themeID")`.
enum ThemeID: String, CaseIterable, Identifiable {
    case dark, light, latte, frappe, macchiato, mocha

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark:      return "Dark"
        case .light:     return "Light"
        case .latte:     return "Catppuccin Latte"
        case .frappe:    return "Catppuccin Frappé"
        case .macchiato: return "Catppuccin Macchiato"
        case .mocha:     return "Catppuccin Mocha"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .dark:      return .dark
        case .light:     return .light
        case .latte:     return .latte
        case .frappe:    return .frappe
        case .macchiato: return .macchiato
        case .mocha:     return .mocha
        }
    }

    /// Resolve from the stored raw value, falling back to dark.
    static func current(_ raw: String) -> ThemeID { ThemeID(rawValue: raw) ?? .dark }
}
