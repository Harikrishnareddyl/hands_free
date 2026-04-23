import SwiftUI
import AppKit
import KeyboardShortcuts

struct SettingsView: View {
    @State private var apiKeyPresent: Bool = Secrets.groqAPIKey() != nil
    @State private var showSetupSheet: Bool = false
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    @State private var audioCueMode: AudioCueMode = Preferences.audioCueMode
    @AppStorage("transcriptionModel")       private var transcriptionModel = GroqClient.Model.whisperTurbo
    @AppStorage("transcriptionVocabulary")  private var vocabulary = ""
    @AppStorage("language")                 private var language = ""
    @AppStorage("minDurationSeconds")       private var minDuration = 2.0

    var body: some View {
        Form {
            apiKeySection
            hotkeySection
            transcriptionSection
            soundsSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            // Clicks on empty areas of the form resign first responder so
            // the focused text field loses its caret.
            ClickToUnfocusView()
        )
        .sheet(isPresented: $showSetupSheet) {
            APIKeySetupSheet(isPresented: $showSetupSheet) { recheck() }
        }
        .onAppear { recheck() }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section("API key") {
            HStack(spacing: 8) {
                Image(systemName: apiKeyPresent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(apiKeyPresent ? Color.green : Color.orange)
                Text(apiKeyPresent ? "Configured" : "Not set")
                Spacer()
                Button(apiKeyPresent ? "Setup guide…" : "Set up key…") {
                    showSetupSheet = true
                }
            }
            if apiKeyPresent {
                Text(APIKeyStore.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        Section("Hotkey") {
            LabeledContent("Shortcut") {
                KeyboardShortcuts.Recorder(for: .dictate)
            }
            Text("Fn (🌐) always triggers dictation, regardless of this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Model", selection: $transcriptionModel) {
                Text("Whisper v3 Turbo").tag(GroqClient.Model.whisperTurbo)
                Text("Whisper v3").tag(GroqClient.Model.whisperLarge)
            }

            LabeledContent("Language") {
                TextField("auto", text: $language)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            LabeledContent("Min clip") {
                HStack(spacing: 4) {
                    TextField("", value: $minDuration, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("s")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Vocabulary hints")
                TextField("Names, acronyms, technical terms…",
                          text: $vocabulary, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLogin = newValue
                    LaunchAtLogin.set(newValue)
                    launchAtLogin = LaunchAtLogin.isEnabled  // reflect actual state
                }
            ))
        }
    }

    // MARK: - Sounds

    private var soundsSection: some View {
        Section("Sounds") {
            Picker("Audio cues", selection: $audioCueMode) {
                ForEach(AudioCueMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .onChange(of: audioCueMode) { newValue in
                Preferences.audioCueMode = newValue
                if newValue == .off { SoundEffects.stopHum() }
            }
        }
    }

    private func recheck() {
        apiKeyPresent = Secrets.groqAPIKey() != nil
    }
}

// MARK: - Setup sheet

private struct APIKeySetupSheet: View {
    @Binding var isPresented: Bool
    var onDismiss: () -> Void

    private let commands = """
    mkdir -p ~/Library/Application\\ Support/HandsFree
    chmod 700 ~/Library/Application\\ Support/HandsFree
    printf '%s' 'gsk_YOUR_KEY_HERE' > ~/Library/Application\\ Support/HandsFree/groq-key
    chmod 600 ~/Library/Application\\ Support/HandsFree/groq-key
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("API key setup")
                    .font(.title2.weight(.semibold))
                Spacer()
                Link("Get a key ↗",
                     destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.subheadline)
            }

            Text("Hands-Free reads your Groq key from a plain text file — no Keychain, no password prompts.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Run in Terminal (replace `gsk_YOUR_KEY_HERE`):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(commands)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    .textSelection(.enabled)
                HStack {
                    Button("Copy commands") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commands, forType: .string)
                    }
                    Button("Reveal folder in Finder") { revealFolder() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Alternatives")
                    .font(.caption.weight(.semibold))
                Text("• Set `GROQ_API_KEY` as an environment variable in your shell profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• A key at `~/.config/handsfree/groq-key` is auto-migrated on first read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") {
                    onDismiss()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func revealFolder() {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("HandsFree", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

// MARK: - Click-to-unfocus helper

/// Transparent NSView placed behind the Form. Any mouse-down that reaches it
/// (i.e. wasn't eaten by a control) resigns the window's first responder,
/// which removes the focus ring from whatever text field had it.
private struct ClickToUnfocusView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FocusClearingView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FocusClearingView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)
        super.mouseDown(with: event)
    }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only receive clicks that reach the background — control subviews
        // still handle their own clicks first.
        let v = super.hitTest(point)
        return v === self ? self : v
    }
}
