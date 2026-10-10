import NookCore
import SwiftUI

/// First-run setup: connect mail, choose how tagging runs, then (optionally) connect an AI assistant over MCP.
struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(step: store.onboardingStep)
                .padding(.top, 44)
            Spacer(minLength: 16)
            Group {
                switch store.onboardingStep {
                case .connectAccount:
                    ConnectAccountStep()
                case .setUpTagging:
                    SetUpTaggingStep()
                case .connectAssistant, .done:
                    ConnectAssistantStep()
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct StepIndicator: View {
    let step: OnboardingStep

    private let items: [(step: OnboardingStep, title: String, note: String?)] = [
        (.connectAccount, "Connect mail", nil),
        (.setUpTagging, "Tagging", nil),
        (.connectAssistant, "AI assistant", "optional"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 28, height: 1.5)
                }
                label(number: index + 1, title: item.title, note: item.note, state: state(of: item.step))
            }
        }
    }

    private enum State { case done, current, upcoming }

    private func state(of item: OnboardingStep) -> State {
        if item.rawValue < step.rawValue { return .done }
        return item == step ? .current : .upcoming
    }

    private func label(number: Int, title: String, note: String?, state: State) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(state == .upcoming ? Color.primary.opacity(0.08) : Theme.accent)
                    .frame(width: 20, height: 20)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state == .current ? .white : .secondary)
                }
            }
            Text(title)
                .font(.system(size: 12.5, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .upcoming ? .secondary : .primary)
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Step 1

private struct ConnectAccountStep: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                NookMark(size: 64)
                Text("Nook")
                    .font(.system(size: 34, weight: .semibold))
                Text("Private, local-first mail for your Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                Principle(systemImage: "internaldrive", title: "Stored on this Mac", detail: "Your mail lives in a local database, not on a server.")
                Principle(systemImage: "eye.slash", title: "No tracking", detail: "Remote images and scripts are blocked by default.")
                Principle(systemImage: "sparkles", title: "On-device AI", detail: "Tags come from a model running on your Mac.")
            }
            .frame(maxWidth: 640)

            VStack(alignment: .leading, spacing: 14) {
                GoogleClientForm()
                HStack {
                    if !store.hasGoogleClient {
                        // Say why the button can't be pressed yet, rather than leaving it mysteriously grey.
                        Text("Paste your client ID and secret to continue.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.addAccount()
                    } label: {
                        HStack(spacing: 8) {
                            if store.isSigningIn { ProgressView().controlSize(.small) }
                            Text(store.isSigningIn ? "Waiting for Google…" : "Connect Gmail")
                        }
                        .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.isSigningIn || !store.hasGoogleClient)
                }
            }
            .padding(20)
            .frame(width: 520)
            .onboardingCard()
        }
    }
}

// MARK: - Tagging

/// Pick where tagging runs. Ollama is recommended; Apple Intelligence and off are a click away.
private struct SetUpTaggingStep: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(TaggingSettings.engineKey) private var engine = TagEngine.ollama.rawValue
    @AppStorage(TaggingSettings.ollamaModelKey) private var ollamaModel = TaggingSettings.defaultOllamaModel
    @AppStorage(TaggingSettings.ollamaURLKey) private var ollamaURL = OllamaTagModel.defaultURL.absoluteString
    @State private var ollama: OllamaStatus?

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Text("Tag mail on this Mac")
                    .font(.system(size: 26, weight: .semibold))
                Text("A local model sorts new mail into tabs like Needs Reply and Newsletter.\nYour mail never leaves this Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                option(.ollama, title: "Ollama", badge: "Recommended", detail: ollamaDetail) {
                    if engine == TagEngine.ollama.rawValue, let commands = ollama?.setupCommands(model: ollamaModel) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ollama == .notRunning ? "Run this in Terminal (needs Homebrew), or get the app from ollama.com:" : "Run this in Terminal:")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            CommandBox(text: commands)
                        }
                    }
                }
                Divider().opacity(0.6)
                option(.apple, title: "Apple Intelligence", badge: nil, detail: AppleTagModel.statusDescription) {
                    if engine == TagEngine.apple.rawValue, !AppleTagModel.isAvailable {
                        Button("Open Apple Intelligence Settings") { openAppleIntelligenceSettings() }
                            .controlSize(.small)
                    }
                }
                Divider().opacity(0.6)
                option(.off, title: "Don't tag for now", badge: nil, detail: "Your inbox works without tabs. You can turn tagging on in Settings.") { EmptyView() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .frame(width: 520)
            .onboardingCard()

            VStack(spacing: 10) {
                Button {
                    store.finishTaggingSetup()
                } label: {
                    Text("Continue").frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        // Check Ollama now and every few seconds, so finishing the install in Terminal shows up here by itself.
        .task(id: ollamaModel + ollamaURL) {
            while !Task.isCancelled {
                let installed = await OllamaTagModel.installedModels(baseURL: URL(string: ollamaURL) ?? OllamaTagModel.defaultURL)
                let status = OllamaStatus.evaluate(installedModels: installed, model: ollamaModel)
                if status != ollama { withAnimation(.snappy(duration: 0.2)) { ollama = status } }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var ollamaDetail: String {
        switch ollama {
        case nil: "Checking…"
        case .ready(let model)?: "Ready with \(model). Runs any model you choose, including your own."
        case .missingModel(let model)?: "Running, but \(model) isn't downloaded yet."
        case .notRunning?: "Free and open source. Runs any model you choose, including your own."
        }
    }

    private var footnote: String {
        switch TagEngine(rawValue: engine) {
        case .ollama where ollama?.isReady != true: "You can continue now. Tagging starts once Ollama is ready."
        case .apple where !AppleTagModel.isAvailable: "You can continue now. Tagging starts once Apple Intelligence is on."
        default: "Change this anytime in Settings → Intelligence."
        }
    }

    private func option<Extra: View>(_ choice: TagEngine, title: String, badge: String?, detail: String, @ViewBuilder extra: () -> Extra) -> some View {
        let selected = engine == choice.rawValue || (choice == .ollama && engine == TagEngine.automatic.rawValue)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { engine = choice.rawValue }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title).font(.system(size: 13.5, weight: .semibold))
                            if let badge {
                                Text(badge)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                            if choice == .ollama, ollama?.isReady == true {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                            }
                        }
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    extra()
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
    }

    private func openAppleIntelligenceSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

// MARK: - Step 2

private struct ConnectAssistantStep: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(MCPSettings.enabledKey) private var mcpEnabled = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Text("Bring your AI assistant")
                    .font(.system(size: 26, weight: .semibold))
                Text("Claude and other MCP clients can search your mail and draft replies.\nThey can't send anything. Drafts wait in Nook for you.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $mcpEnabled.animation(.snappy(duration: 0.2))) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow assistants on this Mac")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("What an assistant reads goes to its model provider.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if mcpEnabled {
                    MCPConnectView()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(20)
            .frame(width: 520)
            .onboardingCard()

            VStack(spacing: 10) {
                Button {
                    store.finishOnboarding()
                } label: {
                    Text(mcpEnabled ? "Go to Inbox" : "Skip, go to Inbox").frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Quiet status: which account is connected and whether mail is still downloading.
    private var footnote: String {
        let who = store.accounts.count == 1 ? store.accounts[0].email : "\(store.accounts.count) accounts"
        return store.isSyncing ? "\(who) connected · downloading mail…" : "\(who) connected · change this anytime in Settings"
    }
}

// MARK: - Shared pieces

private struct Principle: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func onboardingCard() -> some View {
        background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The Google OAuth client fields, shared by onboarding and Settings.
struct GoogleClientForm: View {
    @EnvironmentObject private var store: AppStore
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Google OAuth client")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(showHelp ? "Hide steps" : "How do I get one?") { showHelp.toggle() }
                    .buttonStyle(.textLink)
                    .font(.system(size: 12))
            }
            Text("Nook talks to Gmail directly from your Mac, using an OAuth client you own. No Nook server ever sees your mail or tokens.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showHelp {
                VStack(alignment: .leading, spacing: 4) {
                    step(1, "In Google Cloud Console, create a project and enable the Gmail API.")
                    step(2, "Set up the OAuth consent screen (External, Testing) and add your Gmail address as a test user.")
                    step(3, "Credentials → Create credentials → OAuth client ID → Desktop app.")
                    step(4, "Paste the client ID and secret below.")
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                }
                .padding(10)
                .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            TextField("Client ID", text: $clientId, prompt: Text("1234-abc.apps.googleusercontent.com"))
                .textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $clientSecret, prompt: Text("Client secret"))
                .textFieldStyle(.roundedBorder)
        }
        .onAppear {
            let config = store.googleConfig
            clientId = config.clientId
            clientSecret = config.clientSecret
        }
        .onChange(of: clientId) { save() }
        .onChange(of: clientSecret) { save() }
    }

    private func save() {
        store.saveGoogleConfig(clientId: clientId, clientSecret: clientSecret)
        store.objectWillChange.send()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Nook's mark: a pebble with a dimple on a sea-green tile. Matches the app icon (scripts/make-icon.swift).
struct NookMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.53, green: 0.84, blue: 0.75), Color(red: 0.16, green: 0.52, blue: 0.45)],
                    startPoint: .top, endPoint: .bottom
                ))
            PebbleShape()
                .fill(LinearGradient(colors: [.white, Color(red: 0.88, green: 0.85, blue: 0.80)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.55, height: size * 0.41)
                .shadow(color: Color(red: 0.05, green: 0.24, blue: 0.2).opacity(0.45), radius: size * 0.05, y: size * 0.035)
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.62, blue: 0.54), Color(red: 0.44, green: 0.8, blue: 0.7)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(y: size * 0.01)
        }
        .frame(width: size, height: size)
    }
}

/// The same squared-off, bottom-heavy stone as the app icon.
struct PebbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 120
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let n: CGFloat = 2.35
            // SwiftUI's y axis points down, so "bottom" is positive sine here.
            let fullness = 1 + 0.05 * max(0, s)
            let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1) * rect.width / 2 / 1.05 * fullness
            let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1) * rect.height / 2 / 1.05 * fullness
            let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
