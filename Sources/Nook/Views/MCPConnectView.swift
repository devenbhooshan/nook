import AppKit
import NookCore
import SwiftUI

enum MCPServerLocation {
    /// `nook-mcp` sits next to the app's own executable, both in Nook.app and in `swift run` builds.
    static var path: String {
        let executable = Bundle.main.executableURL ?? Bundle.main.bundleURL
        return executable.deletingLastPathComponent().appendingPathComponent("nook-mcp").path
    }
}

/// Pick an MCP client and copy the exact setup for it. Used in onboarding and Settings → Integrations.
struct MCPConnectView: View {
    @State private var client: MCPClient = .claudeCode

    private var snippet: String { client.snippet(serverPath: MCPServerLocation.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Client", selection: $client) {
                ForEach(MCPClient.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(client.instructions)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            CommandBox(text: snippet)
                .id(client)
        }
    }
}

/// Monospaced text with a Copy button, for commands and config snippets.
struct CommandBox: View {
    let text: String
    @State private var copiedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                withAnimation(.snappy(duration: 0.15)) { copiedAt = Date() }
            } label: {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: text) { copiedAt = nil }
    }

    private var isCopied: Bool {
        copiedAt.map { Date().timeIntervalSince($0) < 3 } ?? false
    }
}
