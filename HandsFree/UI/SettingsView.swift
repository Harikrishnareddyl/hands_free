import SwiftUI
import AppKit
import KeyboardShortcuts

// MARK: - Categories

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case hotkeys
    case voiceInput
    case askAI
    case voiceOutput
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .hotkeys:      return "Hotkeys"
        case .voiceInput:   return "Voice Input"
        case .askAI:        return "Ask AI"
        case .voiceOutput:  return "Voice & Sounds"
        case .about:        return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:      return "gearshape.fill"
        case .hotkeys:      return "command"
        case .voiceInput:   return "waveform"
        case .askAI:        return "sparkles"
        case .voiceOutput:  return "speaker.wave.2.fill"
        case .about:        return "info.circle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .general:      return "API keys and app behavior."
        case .hotkeys:      return "Pick the shortcuts that trigger dictation and Ask AI."
        case .voiceInput:   return "Wake word, transcription model, and how clips are captured."
        case .askAI:        return "Model, system prompt, and how the answer card behaves."
        case .voiceOutput:  return "Spoken replies, cloud voices, and audio cues."
        case .about:        return "Version, links, and acknowledgments."
        }
    }
}

// MARK: - Root view

struct SettingsView: View {
    @State private var selection: SettingsCategory = .general
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
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 520, ideal: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .background(
            // Clicks on empty areas resign first responder so focused
            // text fields lose their caret. Same affordance the old
            // single-pane Form had.
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

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            sidebarHeader
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.bottom, DS.space8)

            Section {
                ForEach(SettingsCategory.allCases) { category in
                    Label {
                        Text(category.title)
                            .font(.system(size: 13, weight: .medium))
                    } icon: {
                        Image(systemName: category.icon)
                            .foregroundStyle(selection == category ? DS.brand : .secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(category)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var sidebarHeader: some View {
        HStack(spacing: DS.space10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.brand.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Hands-Free")
                    .font(.system(size: 13, weight: .semibold))
                Text("v\(UpdateChecker.currentVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.space4)
        .padding(.top, DS.space8)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.space20) {
                pageHeader

                Group {
                    switch selection {
                    case .general:      generalPage
                    case .hotkeys:      hotkeysPage
                    case .voiceInput:   voiceInputPage
                    case .askAI:        askAIPage
                    case .voiceOutput:  voiceOutputPage
                    case .about:        aboutPage
                    }
                }
            }
            .padding(.horizontal, DS.space24)
            .padding(.top, DS.space24)
            .padding(.bottom, DS.space32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var pageHeader: some View {
        PageHeader(title: selection.title, subtitle: selection.subtitle)
    }

    // MARK: - General page

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: DS.space20) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "API key", subtitle: "Groq powers transcription and Ask AI. Key lives as a plain file under Application Support.")
                SettingsCard {
                    SettingsRow("Groq API key", subtitle: apiKeyPresent ? "Configured. Hands-Free reads the key on every request." : "Not yet set — Hands-Free can't transcribe until you add one.") {
                        HStack(spacing: DS.space6) {
                            StatusDot(kind: apiKeyPresent ? .ok : .warn)
                            Text(apiKeyPresent ? "Configured" : "Not set")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button(apiKeyPresent ? "Setup guide…" : "Set up key…") {
                                showSetupSheet = true
                            }
                            .controlSize(.small)
                        }
                    }
                    if apiKeyPresent {
                        RowSeparator()
                        SettingsRow("Key path", subtitle: "Where Hands-Free reads your key from on disk.") {
                            Text(APIKeyStore.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 260, alignment: .trailing)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Behavior")
                SettingsCard {
                    SettingsRow("Launch at login", subtitle: "Open Hands-Free automatically when you sign in.") {
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin },
                            set: { newValue in
                                launchAtLogin = newValue
                                LaunchAtLogin.set(newValue)
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }
        }
    }

    // MARK: - Hotkeys page

    private var hotkeysPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(
                title: "Shortcuts",
                subtitle: "Click a row to record a new shortcut. Press the existing combo while it's empty to clear."
            )
            SettingsCard {
                SettingsRow("Dictate", subtitle: "Hold to talk. Release to paste a transcription into the focused app.") {
                    KeyboardShortcuts.Recorder(for: .dictate)
                }
                RowSeparator()
                SettingsRow("Ask AI", subtitle: "Hold to ask a question. Release to stream an answer in the floating card.") {
                    KeyboardShortcuts.Recorder(for: .askAI)
                }
            }
            .padding(.bottom, DS.space12)

            HStack(spacing: DS.space8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(DS.brand)
                    .font(.system(size: 12))
                Text("Fn (🌐) always triggers dictation, regardless of this setting. Tap-tap latches a hands-free session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Voice input page

    private var voiceInputPage: some View {
        VStack(alignment: .leading, spacing: DS.space20) {

            // Wake word
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(
                    title: "Wake word",
                    subtitle: "Always listens on-device. Audio only leaves your Mac after the phrase fires."
                )
                SettingsCard {
                    SettingsRow(
                        "Say \u{201C}\(WakeWordEngine.wakePhrase)\u{201D} to start a session",
                        subtitle: "Tiny on-device model triggers the recorder when it hears your phrase."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { wakeWordEnabled },
                            set: { newValue in
                                wakeWordEnabled = newValue
                                Preferences.wakeWordEnabled = newValue
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    if wakeWordEnabled {
                        RowSeparator()
                        SettingsRow("When it fires", subtitle: wakeFiresSubtitle) {
                            Picker("", selection: $wakeWordAction) {
                                ForEach(Preferences.WakeWordAction.allCases) { action in
                                    Text(action.label).tag(action.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                        RowSeparator()
                        SettingsStackRow(
                            "Sensitivity",
                            subtitle: "Lower = fires more easily (better in noisy rooms). Higher = fewer false triggers. Default 0.50 works for most voices.",
                            trailingAccessory: AnyView(
                                Text(String(format: "%.2f", wakeWordThreshold))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            )
                        ) {
                            Slider(value: $wakeWordThreshold, in: 0.10...0.95, step: 0.05)
                                .tint(DS.brand)
                        }
                        RowSeparator()
                        SettingsRow(
                            "Compute backend",
                            subtitle: "ONNX Runtime execution provider. Switch if CoreML pegs a core."
                        ) {
                            Picker("", selection: $wakeExecutionProvider) {
                                ForEach(Preferences.WakeWordExecutionProvider.allCases) { provider in
                                    Text(provider.label).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                            .onChange(of: wakeExecutionProvider) { _, newValue in
                                Preferences.wakeWordExecutionProvider = newValue
                            }
                        }
                    }
                }
            }

            // Transcription
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(
                    title: "Transcription",
                    subtitle: "Whisper model and how clips are captured."
                )
                SettingsCard {
                    SettingsRow("Model", subtitle: "Turbo is faster; Large is the most accurate.") {
                        Picker("", selection: $transcriptionModel) {
                            Text("Whisper v3 Turbo").tag(GroqClient.Model.whisperTurbo)
                            Text("Whisper v3").tag(GroqClient.Model.whisperLarge)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    RowSeparator()
                    SettingsRow("Language", subtitle: "Two-letter ISO code, or leave blank to auto-detect.") {
                        TextField("auto", text: $language)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    RowSeparator()
                    SettingsRow("Min clip", subtitle: "Recordings shorter than this are dropped without an API call.") {
                        HStack(spacing: 4) {
                            TextField("", value: $minDuration, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("s").foregroundStyle(.secondary)
                        }
                    }
                    RowSeparator()
                    SettingsRow(
                        "Max clip",
                        subtitle: "Hard cap on every recording. The pill counts down for the final 5 seconds."
                    ) {
                        HStack(spacing: 4) {
                            TextField("", value: $maxDuration, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("s").foregroundStyle(.secondary)
                        }
                    }
                    RowSeparator()
                    SettingsStackRow(
                        "Vocabulary hints",
                        subtitle: "Names, acronyms, and technical terms Whisper should expect.",
                        trailingAccessory: vocabulary.isEmpty
                            ? nil
                            : AnyView(
                                Button("Clear") { vocabulary = "" }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            )
                    ) {
                        TextField(
                            "Names, acronyms, technical terms…",
                            text: $vocabulary,
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private var wakeFiresSubtitle: String {
        wakeWordAction == Preferences.WakeWordAction.askAI.rawValue
            ? "Answers stream into the floating card and are read aloud."
            : "Transcribed text is pasted into whatever app is focused."
    }

    // MARK: - Ask AI page

    private var askAIPage: some View {
        VStack(alignment: .leading, spacing: DS.space20) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(
                    title: "Model",
                    subtitle: "Speak a question, release to get a streamed answer in a floating card."
                )
                SettingsCard {
                    SettingsRow("LLM", subtitle: "Larger = smarter, slower. Smaller = quicker, sometimes shallower.") {
                        Picker("", selection: $askAIModel) {
                            ForEach(GroqClient.LLMModel.all, id: \.id) { m in
                                Text(m.label).tag(m.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    RowSeparator()
                    SettingsStackRow(
                        "System prompt",
                        subtitle: "Tone, format, length — what Hands-Free tells the model to do before every question.",
                        trailingAccessory: AnyView(
                            Button("Reset") {
                                askAISystemPrompt = Preferences.defaultAskAISystemPrompt
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        )
                    ) {
                        TextEditor(text: $askAISystemPrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 100, maxHeight: 200)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                                    .fill(Color.secondary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: DS.hairline)
                            )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Answer card", subtitle: "How long answers stay on screen.")
                SettingsCard {
                    SettingsRow("Auto-hide", subtitle: "Resets whenever you click, drag, scroll, or type in the card.") {
                        Toggle("", isOn: $answerAutoHideEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if answerAutoHideEnabled {
                        RowSeparator()
                        SettingsRow("Hide after", subtitle: "Seconds of inactivity before the card dismisses itself.") {
                            HStack(spacing: 4) {
                                TextField("", value: $answerAutoHideSeconds,
                                          format: .number.precision(.fractionLength(0)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                Text("s").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Voice & sounds page

    private var voiceOutputPage: some View {
        VStack(alignment: .leading, spacing: DS.space20) {

            // Spoken answers
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(
                    title: "Spoken answers",
                    subtitle: "Have Ask AI's reply read out loud as it streams."
                )
                SettingsCard {
                    SettingsRow(
                        "Read answers aloud",
                        subtitle: "Uses the built-in macOS voice. Turn off to hide the speaker button entirely."
                    ) {
                        Toggle("", isOn: $speakAnswersEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }

            // Cloud TTS
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(
                    title: "Cloud voice (optional)",
                    subtitle: "Stream answers through Deepgram's Aura voices instead of the built-in macOS one."
                )
                SettingsCard {
                    SettingsRow(
                        "Deepgram key",
                        subtitle: deepgramKeyPresent
                            ? "Configured. Cloud voice can be toggled below."
                            : "Add a Deepgram key to enable cloud voice."
                    ) {
                        HStack(spacing: DS.space6) {
                            StatusDot(kind: deepgramKeyPresent ? .ok : .warn)
                            Text(deepgramKeyPresent ? "Configured" : "Not set")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button(deepgramKeyPresent ? "Setup guide…" : "Set up key…") {
                                showDeepgramSetupSheet = true
                            }
                            .controlSize(.small)
                        }
                    }
                    RowSeparator()
                    SettingsRow(
                        "Use cloud voice",
                        subtitle: "When off (or key missing), Hands-Free uses the built-in macOS voice."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { cloudTTSEnabled && deepgramKeyPresent },
                            set: { newValue in cloudTTSEnabled = newValue }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!deepgramKeyPresent)
                    }
                    if cloudTTSEnabled && deepgramKeyPresent {
                        RowSeparator()
                        SettingsRow("Voice", subtitle: "Pick the Aura-2 model used for streaming TTS.") {
                            Picker("", selection: $deepgramVoice) {
                                ForEach(DeepgramTTSPlayer.Voice.allCases) { v in
                                    Text(v.label).tag(v.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }
                }
            }

            // Audio cues
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(
                    title: "Sounds",
                    subtitle: "Chimes when a session starts, ends, or hits the duration cap."
                )
                SettingsCard {
                    SettingsRow("Audio cues", subtitle: "Off, chimes only, or full set including transcribe hum.") {
                        Picker("", selection: $audioCueMode) {
                            ForEach(AudioCueMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .onChange(of: audioCueMode) { _, newValue in
                            Preferences.audioCueMode = newValue
                            if newValue == .off { SoundEffects.stopHum() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - About page

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: DS.space20) {
            SettingsCard {
                HStack(alignment: .center, spacing: DS.space16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DS.brand.gradient)
                            .frame(width: 56, height: 56)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hands-Free")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Version \(UpdateChecker.currentVersion)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Link(destination: URL(string: "https://github.com/Harikrishnareddyl/hands-free")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("GitHub")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(DS.space16)
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "What's running", subtitle: "Hand to support if something looks off.")
                SettingsCard {
                    aboutRow("Transcription", value: Preferences.transcriptionModel)
                    RowSeparator()
                    aboutRow("Ask AI model", value: Preferences.askAIModel)
                    RowSeparator()
                    aboutRow("Min clip", value: String(format: "%.1f s", Preferences.minDurationSeconds))
                    RowSeparator()
                    aboutRow("Max clip", value: String(format: "%.0f s", Preferences.maxDurationSeconds))
                }
            }
        }
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        SettingsRow(label) {
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    private func recheck() {
        apiKeyPresent = Secrets.groqAPIKey() != nil
        deepgramKeyPresent = Secrets.deepgramAPIKey() != nil
    }
}

// MARK: - Setup sheet (Groq)

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
        VStack(alignment: .leading, spacing: DS.space16) {
            HStack(alignment: .firstTextBaseline) {
                Text("API key setup")
                    .font(.title2.weight(.semibold))
                Spacer()
                Link(destination: URL(string: "https://console.groq.com/keys")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Get a key")
                    }
                    .font(.subheadline)
                }
            }

            Text("Hands-Free reads your Groq key from a plain text file — no Keychain, no password prompts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.space6) {
                Text("Run in Terminal (replace `gsk_YOUR_KEY_HERE`):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(commands)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .dsCodeBlock()
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
        .padding(DS.space20)
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
        VStack(alignment: .leading, spacing: DS.space16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deepgram TTS setup")
                    .font(.title2.weight(.semibold))
                Spacer()
                Link(destination: URL(string: "https://console.deepgram.com/signup")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Get a key")
                    }
                    .font(.subheadline)
                }
            }

            Text("Optional. Powers low-latency spoken answers. Hands-Free reads the key from a plain text file — no Keychain, no password prompts. Leave unconfigured to use the built-in macOS voice instead.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.space6) {
                Text("Run in Terminal (replace `YOUR_DEEPGRAM_KEY`):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(commands)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .dsCodeBlock()
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
        .padding(DS.space20)
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

/// Transparent NSView placed behind the form. Any mouse-down that reaches it
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
        let v = super.hitTest(point)
        return v === self ? self : v
    }
}
