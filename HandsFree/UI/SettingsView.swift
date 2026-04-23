import SwiftUI
import AppKit
import KeyboardShortcuts

struct SettingsView: View {
    @State private var apiKeyPresent: Bool = Secrets.groqAPIKey() != nil
    @State private var deepgramKeyPresent: Bool = Secrets.deepgramAPIKey() != nil
    @State private var showSetupSheet: Bool = false
    @State private var showDeepgramSetupSheet: Bool = false
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    @State private var audioCueMode: AudioCueMode = Preferences.audioCueMode
    @State private var wakeExecutionProvider: Preferences.WakeWordExecutionProvider = Preferences.wakeWordExecutionProvider
    @AppStorage("transcriptionModel")       private var transcriptionModel = GroqClient.Model.whisperTurbo
    @AppStorage("transcriptionVocabulary")  private var vocabulary = ""
    @AppStorage("language")                 private var language = ""
    @AppStorage("minDurationSeconds")       private var minDuration = 1.0
    @AppStorage("maxDurationSeconds")       private var maxDuration = 180.0
    @AppStorage("askAIModel")               private var askAIModel = GroqClient.LLMModel.llama33_70b
    @AppStorage("askAISystemPrompt")        private var askAISystemPrompt = Preferences.defaultAskAISystemPrompt
    @AppStorage("answerAutoHideEnabled")    private var answerAutoHideEnabled = true
    @AppStorage("answerAutoHideSeconds")    private var answerAutoHideSeconds = 30.0
    @AppStorage("speakAnswersEnabled")      private var speakAnswersEnabled = true
    @AppStorage("cloudTTSEnabled")          private var cloudTTSEnabled = false
    @AppStorage("deepgramVoice")            private var deepgramVoice = "aura-2-thalia-en"
    @AppStorage("wakeWordEnabled")          private var wakeWordEnabled = false
    @AppStorage("wakeWordThreshold")        private var wakeWordThreshold = 0.5
    @AppStorage("wakeWordAction")           private var wakeWordAction = Preferences.WakeWordAction.dictate.rawValue

    var body: some View {
        Form {
            apiKeySection
            hotkeySection
            wakeWordSection
            transcriptionSection
            askAISection
            cloudTTSSection
            soundsSection
            generalSection
            aboutSection
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
        .sheet(isPresented: $showDeepgramSetupSheet) {
            DeepgramKeySetupSheet(isPresented: $showDeepgramSetupSheet) { recheck() }
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
        Section("Hotkeys") {
            LabeledContent("Dictate") {
                KeyboardShortcuts.Recorder(for: .dictate)
            }
            LabeledContent("Ask AI") {
                KeyboardShortcuts.Recorder(for: .askAI)
            }
            Text("Fn (🌐) always triggers dictation, regardless of this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Wake word

    private var wakeWordSection: some View {
        Section("Wake word") {
            Toggle(isOn: Binding(
                get: { wakeWordEnabled },
                set: { newValue in
                    wakeWordEnabled = newValue
                    Preferences.wakeWordEnabled = newValue
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Say \u{201C}\(WakeWordEngine.wakePhrase)\u{201D} to start a session")
                    Text("Always listens on-device. Audio only leaves your Mac after the phrase fires.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if wakeWordEnabled {
                Picker("When it fires", selection: $wakeWordAction) {
                    ForEach(Preferences.WakeWordAction.allCases) { action in
                        Text(action.label).tag(action.rawValue)
                    }
                }
                Text(wakeWordAction == Preferences.WakeWordAction.askAI.rawValue
                     ? "Answers stream into the floating card and are read aloud by the built-in voice."
                     : "Transcribed text is pasted (or copied) into whatever app is focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("After the cue, start speaking. Hands-Free auto-submits once you pause for about a second — or click the pill to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(String(format: "%.2f", wakeWordThreshold))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $wakeWordThreshold, in: 0.10...0.95, step: 0.05)
                    Text("Lower = fires more easily (better in noisy rooms). Higher = fewer false triggers. Default 0.50 works for most voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Compute backend", selection: $wakeExecutionProvider) {
                    ForEach(Preferences.WakeWordExecutionProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .onChange(of: wakeExecutionProvider) { _, newValue in
                    Preferences.wakeWordExecutionProvider = newValue
                }
                Text("ONNX Runtime execution provider. Switch if CoreML pegs a core — pure ORT CPU can be lower-power for small models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Ask AI

    private var askAISection: some View {
        Section("Ask AI") {
            Picker("Model", selection: $askAIModel) {
                ForEach(GroqClient.LLMModel.all, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("System prompt")
                    Spacer()
                    Button("Reset") {
                        askAISystemPrompt = Preferences.defaultAskAISystemPrompt
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                TextEditor(text: $askAISystemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 90, maxHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )
            }

            Text("Speak a question, release to get a streamed answer in a floating card.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $speakAnswersEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read answers aloud")
                    Text("Uses the built-in macOS voice. Turn off to hide the speaker button entirely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Auto-hide answer card", isOn: $answerAutoHideEnabled)
            if answerAutoHideEnabled {
                LabeledContent("Hide after") {
                    HStack(spacing: 4) {
                        TextField("", value: $answerAutoHideSeconds,
                                  format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("s")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Resets whenever you click, drag, scroll, or type in the card. Turn off to keep it on screen until you close it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cloud TTS

    private var cloudTTSSection: some View {
        Section("Cloud TTS (optional)") {
            HStack(spacing: 8) {
                Image(systemName: deepgramKeyPresent
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(deepgramKeyPresent ? Color.green : Color.orange)
                Text(deepgramKeyPresent ? "Deepgram key configured" : "No Deepgram key")
                Spacer()
                Button(deepgramKeyPresent ? "Setup guide…" : "Set up key…") {
                    showDeepgramSetupSheet = true
                }
            }

            Toggle(isOn: Binding(
                get: { cloudTTSEnabled && deepgramKeyPresent },
                set: { newValue in cloudTTSEnabled = newValue }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use cloud voice for answers")
                    Text("When on, answers stream through Deepgram's Aura voices. When off (or key missing), the built-in macOS voice is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!deepgramKeyPresent)

            if cloudTTSEnabled && deepgramKeyPresent {
                Picker("Voice", selection: $deepgramVoice) {
                    ForEach(DeepgramTTSPlayer.Voice.allCases) { v in
                        Text(v.label).tag(v.rawValue)
                    }
                }
            }
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

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Max clip") {
                    HStack(spacing: 4) {
                        TextField("", value: $maxDuration, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("s")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Hard cap on every recording — hold-to-talk, hands-free, Ask AI, and wake word. A countdown appears in the pill and ticks for the final 5 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Vocabulary hints")
                    Spacer()
                    if !vocabulary.isEmpty {
                        Button("Clear") { vocabulary = "" }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
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

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hands-Free")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Version \(UpdateChecker.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("GitHub ↗",
                     destination: URL(string: "https://github.com/Harikrishnareddyl/hands-free")!)
                    .font(.caption)
            }
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
            .onChange(of: audioCueMode) { _, newValue in
                Preferences.audioCueMode = newValue
                if newValue == .off { SoundEffects.stopHum() }
            }
        }
    }

    private func recheck() {
        apiKeyPresent = Secrets.groqAPIKey() != nil
        deepgramKeyPresent = Secrets.deepgramAPIKey() != nil
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

// MARK: - Deepgram setup sheet

private struct DeepgramKeySetupSheet: View {
    @Binding var isPresented: Bool
    var onDismiss: () -> Void

    private let commands = """
    mkdir -p ~/Library/Application\\ Support/HandsFree
    chmod 700 ~/Library/Application\\ Support/HandsFree
    printf '%s' 'YOUR_DEEPGRAM_KEY' > ~/Library/Application\\ Support/HandsFree/deepgram-key
    chmod 600 ~/Library/Application\\ Support/HandsFree/deepgram-key
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deepgram TTS setup")
                    .font(.title2.weight(.semibold))
                Spacer()
                Link("Get a key ↗",
                     destination: URL(string: "https://console.deepgram.com/signup")!)
                    .font(.subheadline)
            }

            Text("Optional. Powers low-latency spoken answers. Hands-Free reads the key from a plain text file — no Keychain, no password prompts. Leave unconfigured to use the built-in macOS voice instead.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Run in Terminal (replace `YOUR_DEEPGRAM_KEY`):")
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
                Text("• Set `DEEPGRAM_API_KEY` as an environment variable in your shell profile.")
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
