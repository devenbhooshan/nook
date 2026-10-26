import NookCore
import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var highlighted = 0
    @State private var commands: [PaletteCommand] = []
    @State private var ranking = PaletteRanking.load()
    @FocusState private var focused: Bool
    /// When it opened. A pointer resting where the list appears reports a hover right away; that isn't a choice,
    /// and following it would make Return pick whatever row happened to be under the pointer.
    @State private var openedAt = Date()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: store.paletteMode == .tags ? "tag" : "command")
                        .foregroundStyle(.secondary)
                    TextField(store.paletteMode == .tags ? "Tag this conversation…" : "Type a command…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit(run)
                        .onKeyPress(.downArrow) { step(1); return .handled }
                        .onKeyPress(.upArrow) { step(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(.horizontal, 18)
                .frame(height: 52)

                Divider().opacity(0.6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if results.isEmpty {
                                Text("No matching commands")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                if index == 0 || results[index - 1].section != command.section {
                                    Text(command.section)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, index == 0 ? 4 : 10)
                                        .padding(.bottom, 3)
                                }
                                row(command, isHighlighted: index == highlighted)
                                    .id(index)
                                    .clickable()
                                    .onHover { if $0, Date().timeIntervalSince(openedAt) > 0.4 { highlighted = index } }
                                    .onTapGesture {
                                        highlighted = index
                                        run()
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
                }
            }
            .frame(width: 580)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
            .padding(.top, 90)
        }
        .onAppear {
            openedAt = Date()
            commands = store.paletteCommands()
            focused = true
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private var results: [PaletteCommand] {
        let byTitle = Dictionary(commands.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        return ranking.rank(commands.map(\.title), query: query).compactMap { byTitle[$0] }
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: command.systemImage)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? Theme.accent : .secondary)
            Text(command.title)
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer()
            if let shortcut = command.shortcut {
                KeyCap(shortcut)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Theme.accent.opacity(0.13) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func step(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    private func run() {
        guard results.indices.contains(highlighted) else { return }
        let command = results[highlighted]
        ranking.record(query: query, title: command.title)
        ranking.save()
        close()
        command.action()
    }

    private func close() {
        store.showPalette = false
        store.paletteMode = .everything
    }
}

struct ShortcutHelpView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { store.showHelp = false }

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Keyboard shortcuts").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("Press any key to close").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 20) {
                    GridRow {
                        column(ShortcutInterpreter.reference[0])
                        column(ShortcutInterpreter.reference[1])
                    }
                    GridRow {
                        column(ShortcutInterpreter.reference[2])
                        column(ShortcutInterpreter.reference[3])
                    }
                    GridRow {
                        column(ShortcutInterpreter.reference[4])
                    }
                }
            }
            .padding(26)
            .frame(width: 620)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
        }
    }

    private func column(_ section: ShortcutInterpreter.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(section.entries) { entry in
                HStack {
                    Text(entry.title).font(.system(size: 13))
                    Spacer(minLength: 16)
                    HStack(spacing: 3) {
                        ForEach(entry.keys.split(separator: " ").map(String.init).filter { $0 != "/" || entry.keys == "/" }, id: \.self) { key in
                            KeyCap(key.uppercased())
                        }
                    }
                }
            }
        }
        .frame(width: 270)
    }
}
