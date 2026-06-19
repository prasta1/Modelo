import SwiftUI

/// Streaming console panel under the Status cards (handoff §6). Color-coded
/// mono log rows on `Theme.consoleBG` with a level filter.
struct ConsoleInspector: View {
    @Environment(AppStore.self) private var store

    private var lines: [LogLine] {
        switch store.consoleFilter {
        case "Info":     return store.consoleLines.filter { $0.level == .info || $0.level == .ping }
        case "Warnings": return store.consoleLines.filter { $0.level == .warn }
        default:         return store.consoleLines
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Console").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textHi)
                Text("Mac Studio M3 Ultra").font(.mono(10.5)).foregroundStyle(Theme.textDim)
                Spacer()
                SegmentedPills(options: ["All", "Info", "Warnings"], selection: $store.consoleFilter)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(line.time).foregroundStyle(Color(hex: 0x4E4B55))
                            Text(line.level.rawValue)
                                .foregroundStyle(line.level.color)
                                .tracking(0.6)
                                .frame(width: 42, alignment: .leading)
                            Text(line.message).foregroundStyle(Theme.textLo)
                            Spacer(minLength: 0)
                        }
                        .font(.mono(11))
                        .padding(.vertical, 3.5)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .background(Theme.consoleBG, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.line))
    }
}
