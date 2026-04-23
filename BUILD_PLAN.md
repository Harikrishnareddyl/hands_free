# Hands-Free — A Wispr Flow Alternative for macOS

A background Mac app that lets you hold a global hotkey, speak into the mic, release, and get cleaned-up text pasted into whatever input field is focused — or copied to clipboard if no field is focused. All transcriptions are saved locally so you can revisit them later.

Built on **Groq Whisper v3 Turbo** (transcription) and **Groq Llama 3.3 70B** (cleanup/formatting) — roughly **$0.04/hr of audio + pennies per cleanup call** vs Wispr Flow's $15/mo subscription.

---

## 1. What Wispr Flow actually does (research summary)

Wispr Flow is a menu-bar app on macOS (also Windows, iOS, Android). The workflow:

1. User presses a global hotkey — **`Fn`** (push-to-talk) or **`Fn + Space`** (hands-free toggle) by default. On Macs without Fn, it's `Ctrl + Opt` / `Ctrl + Opt + Space`. Mouse buttons can also be bound.
2. Mic records while the key is held (push-to-talk) or until the key is pressed again (hands-free). Audio is streamed to their cloud.
3. Multi-layer AI processing:
   - **Layer 1**: Whisper-style transcription.
   - **Layer 2**: LLM cleanup — strips filler words (`um`, `uh`, `like`), applies punctuation, handles backtracking ("meet Tuesday — wait, Wednesday" → "meet Wednesday"), adapts style to the target app (Slack vs Gmail vs VS Code).
4. Final text is **pasted** into the focused text field (they use clipboard + simulated `Cmd+V`, same approach we'll use).
5. If nothing's focused, text just lands on the clipboard.
6. Everything is stored server-side, synced across devices, and exposed as a searchable history + dictionary + voice-shortcuts feature.

Key constraints they live with (and so will we):
- Cloud round-trip latency — usually ~1s for short clips, longer for long ones.
- 20-minute max session length per dictation.
- They pay for the cleanup LLM on every invocation — this is the main cost driver, not transcription.

**Confirmation our Groq-based plan is viable**: multiple open-source clones already exist and work well — [SFlow](https://github.com/daniel-carreon/sflow) (Python + Groq Whisper), [OpenWhispr](https://github.com/OpenWhispr/openwhispr), [VoiceTypr](https://github.com/moinulmoin/voicetypr), [FreeFlow](https://github.com/zachlatta/freeflow), [Tambourine](https://github.com/kstonekuan/tambourine-voice). SFlow in particular does almost exactly what we want but in Python. We'll build native Swift for better integration, lower memory, and no Python runtime.

---

## 2. What we're building

### Core behavior (v1)

- **Always-running menu-bar app** (no Dock icon, `LSUIElement = true`).
- **Hold-to-talk hotkey**: hold `Right Option` (configurable) → records → release → transcribes → cleans up → pastes at cursor.
- **Hands-free toggle hotkey**: double-tap the same key (or a separate binding) → starts recording → tap again to stop.
- **Target detection**: uses macOS Accessibility API to detect if a text field is focused.
  - If yes → paste via clipboard + simulated `Cmd+V`.
  - If no → leave text on clipboard + show a toast notification.
- **Always save locally**: every transcription (raw + cleaned) goes into a SQLite DB with timestamp, target app, duration.
- **History window**: searchable log of past transcriptions with click-to-copy.
- **Visual feedback**: small floating pill near the cursor (or menu-bar status indicator) showing "idle / recording / transcribing / done".
- **Sound cues**: subtle start/stop chimes (toggleable).

### Out of scope for v1

- Multi-device sync (local-only DB is fine for v1).
- Voice-shortcuts / snippets expansion.
- Custom dictionary / personal vocab (Groq supports a `prompt` param we can wire up later).
- Command mode ("new line", "period", "delete that") — Wispr calls this "Command Mode"; we'll skip for v1.
- Local/offline transcription fallback (nice-to-have for v2).

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Menu-bar app (Swift, AppKit, LSUIElement)                  │
│                                                              │
│  ┌──────────────┐   hold    ┌──────────────┐                │
│  │ HotKey       │──────────>│ AudioEngine  │                │
│  │ (Carbon API) │  release  │ (AVAudio-    │                │
│  └──────────────┘─────┐     │  Engine)     │                │
│                       │     │ 16kHz mono   │                │
│                       ▼     │ PCM buffer   │                │
│              ┌──────────────────┐                           │
│              │ Recorder service │ writes WAV to /tmp        │
│              └──────────────────┘                           │
│                       │                                     │
│                       ▼                                     │
│              ┌──────────────────┐    POST /audio/           │
│              │ Groq client      │──> transcriptions         │
│              │ (URLSession)     │    whisper-large-v3-turbo │
│              └──────────────────┘                           │
│                       │ raw transcript                      │
│                       ▼                                     │
│              ┌──────────────────┐    POST /chat/completions │
│              │ Cleanup service  │──> llama-3.3-70b-versatile│
│              │ (system prompt:  │    (skippable for short   │
│              │  remove fillers, │     utterances)           │
│              │  add punct, keep │                           │
│              │  meaning)        │                           │
│              └──────────────────┘                           │
│                       │ cleaned text                        │
│                       ▼                                     │
│   ┌───────────────────────────────────────────────────┐     │
│   │ Insertion service                                 │     │
│   │  1. Check focused element via AXUIElement         │     │
│   │  2. Put text on NSPasteboard                      │     │
│   │  3. If field focused: CGEvent post Cmd+V          │     │
│   │  4. If not: keep on pasteboard, show toast        │     │
│   └───────────────────────────────────────────────────┘     │
│                       │                                     │
│                       ▼                                     │
│              ┌──────────────────┐                           │
│              │ SQLite history   │  (raw, cleaned, app,      │
│              │ (GRDB.swift)     │   ts, duration, cost)     │
│              └──────────────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

### Tech choices

| Concern | Choice | Why |
|---|---|---|
| Language | **Swift + AppKit** | Native, low memory, no runtime dep. SwiftUI for the settings/history windows only. |
| Global hotkey | [**sindresorhus/KeyboardShortcuts**](https://github.com/sindresorhus/KeyboardShortcuts) | User-customizable, works when menu-bar is open, actively maintained. Wraps Carbon under the hood. |
| Audio capture | **AVAudioEngine** with a tap on `inputNode` | Native, low-latency, 16kHz mono tap is trivial. No AVAudioSession on macOS. |
| Audio encoding | Write to `.wav` (PCM 16-bit mono 16kHz) | Groq accepts wav; we skip encoding overhead. m4a/opus later if we want smaller payloads. |
| Transcription | **Groq `whisper-large-v3-turbo`** via `/audio/transcriptions` | $0.04/hr, 216x real-time, 12% WER. Upgrade path: `whisper-large-v3` (10.3% WER, $0.11/hr) for accuracy-critical users. |
| Cleanup LLM | **Groq `llama-3.3-70b-versatile`** via `/chat/completions` | ~275 tok/s, $0.59 / $0.79 per M tokens in/out. Typical cleanup call: ~200 tokens in, ~150 out = fractions of a cent. Skip cleanup if transcript is <3 words or looks already clean (regex heuristic). |
| Text insertion | `NSPasteboard` + `CGEvent` synthesized `Cmd+V` | Universal — works in any app including web inputs. Same approach every OSS clone uses. |
| Focused-field detection | **Accessibility API** (`AXUIElementCopyAttributeValue` on `AXFocusedUIElement`) | Required permission (user grants in System Settings → Privacy → Accessibility). |
| History DB | **GRDB.swift** (SQLite) | Single-file DB under `~/Library/Application Support/HandsFree/`. Lightweight, typed. |
| Secrets | **Keychain** (via `KeychainAccess` or raw `Security.framework`) | Groq API key stored per-user. |
| Packaging | Xcode project, `.app` bundle, Developer ID signed + notarized | Required so the Accessibility/Mic permission prompts trust us. |

### Key permissions the user has to grant

1. **Microphone** (`NSMicrophoneUsageDescription` in Info.plist) — prompted first time we start `AVAudioEngine`.
2. **Accessibility** — for reading focused-element + posting synthetic Cmd+V. No Info.plist key; user must manually enable in System Settings. We'll detect and link them to the right pane.
3. **Input Monitoring** — may be needed by the hotkey library for global keyDown events; also user-toggled.

All three must succeed before the app is fully functional. First-run wizard walks through each.

---

## 4. Request/response details

### Transcription call

```
POST https://api.groq.com/openai/v1/audio/transcriptions
Authorization: Bearer $GROQ_API_KEY
Content-Type: multipart/form-data

fields:
  file: <audio.wav>
  model: whisper-large-v3-turbo
  response_format: json        # or verbose_json for word timestamps
  language: en                 # optional; omit for auto-detect
  temperature: 0
  prompt: "<optional vocab hints from user dictionary>"
```

Limits: **25 MB per file** on free tier, **100 MB** on dev tier. At 16kHz mono WAV that's ~13 minutes free / ~52 minutes dev — well under Wispr's 20-min session cap, so we match their UX. Billing rounds up to 10 seconds minimum.

### Cleanup call

```
POST https://api.groq.com/openai/v1/chat/completions
model: llama-3.3-70b-versatile
messages:
  - role: system
    content: |
      You are a transcription cleaner. Take the raw voice transcript below and:
      - Remove filler words (um, uh, like, you know) unless emphasized
      - Handle explicit corrections ("no wait", "I mean X") by applying them
      - Add natural punctuation and capitalization
      - Preserve the speaker's meaning, tone, and vocabulary exactly
      - Do NOT add new information, summarize, or rephrase
      - Do NOT wrap in quotes or add commentary
      - Output only the cleaned text
  - role: user
    content: "<raw transcript>"
temperature: 0.1
max_tokens: <~1.5x input length>
```

We include optional context hints when we have them: the target app's bundle ID (so the LLM can match Slack's terse style vs an email's formal one). Keep this system prompt tight — it's sent on every cleanup call and counts as input tokens.

### Cost sanity check

Assume 500 dictations/month × 30 seconds avg:
- Transcription: 500 × 30s = 4.2 hrs × $0.04 = **$0.17**
- Cleanup: 500 calls × ~350 tokens total = 175k tokens × blended ~$0.70/M = **$0.12**
- **Total: ~$0.29/month** vs Wispr's $15. Even at 10× usage we're at $3/mo.

---

## 5. Repo layout

```
hands_free/
├── BUILD_PLAN.md            # this file
├── HandsFree.xcodeproj/
├── HandsFree/
│   ├── HandsFreeApp.swift           # @main, AppDelegate wiring
│   ├── AppDelegate.swift            # menu bar, lifecycle
│   ├── Core/
│   │   ├── HotKeyManager.swift      # wraps KeyboardShortcuts
│   │   ├── AudioRecorder.swift      # AVAudioEngine capture
│   │   ├── GroqClient.swift         # transcription + chat
│   │   ├── Cleaner.swift            # prompt + skip heuristic
│   │   ├── TextInserter.swift       # pasteboard + CGEvent
│   │   ├── FocusInspector.swift     # AX API focused element
│   │   └── HistoryStore.swift       # GRDB wrapper
│   ├── UI/
│   │   ├── MenuBarView.swift
│   │   ├── RecordingPill.swift      # floating indicator
│   │   ├── SettingsWindow.swift
│   │   ├── HistoryWindow.swift
│   │   └── OnboardingWindow.swift   # perms walkthrough
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   ├── start.caf / stop.caf     # subtle chimes
│   │   └── Info.plist
│   └── Support/
│       ├── Keychain.swift
│       └── Logger.swift
└── HandsFreeTests/
    ├── CleanerTests.swift           # fixture transcripts → expected output
    └── GroqClientTests.swift        # mocked URLSession
```

---

## 6. Build phases

**Phase 0 — scaffolding** (few hours)
- Xcode project, `LSUIElement`, menu bar icon, placeholder "Hello" item.
- Add SPM deps: `KeyboardShortcuts`, `GRDB.swift`, `KeychainAccess`.

**Phase 1 — happy path dictation** (half day)
- Hotkey registered, hold records, release stops.
- Save to `/tmp/rec.wav`, POST to Groq transcription.
- Show raw transcript in a toast. No cleanup, no insertion yet.
- Requires: mic permission flow.

**Phase 2 — insertion** (few hours)
- Copy transcript to pasteboard.
- Detect focused field via AX API.
- Synthesize `Cmd+V` if field present; else toast "copied, paste anywhere".
- Requires: accessibility permission flow + onboarding window.

**Phase 3 — cleanup LLM** (few hours)
- `Cleaner.swift` with system prompt above.
- Skip heuristic: if transcript <3 words OR contains no fillers/disfluency markers, skip cleanup.
- Toggle in settings: "AI cleanup on/off".

**Phase 4 — history + settings UI** (half day)
- SQLite schema: `transcriptions(id, ts, raw, cleaned, app_bundle_id, duration_s, cost_cents)`.
- History window with search + click-to-copy.
- Settings: hotkey picker, language, API key field, cleanup toggle, sounds toggle.

**Phase 5 — polish** (day)
- Recording pill overlay near cursor.
- Proper error toasts (network down, mic denied, key missing).
- Start chime / stop chime.
- Menu bar icon states (idle / recording / processing).
- Notarized build + DMG.

**Phase 6 — v1.1 niceties** (optional)
- Hands-free double-tap mode.
- Per-app style presets (Slack = terse, Gmail = formal).
- Voice shortcuts / snippet expansion.
- Streaming transcription for faster perceived latency (Groq doesn't currently stream Whisper; would need chunked uploads).

---

## 7. Risks & open questions

- **Cmd+V synthesis occasionally fails** in sandboxed Electron apps or some games. Fallback: keep text on pasteboard and fire a notification. Every OSS clone hits this edge case; it's acceptable.
- **Clipboard clobbering**: pasting overwrites whatever the user had on the clipboard. Mitigation: save + restore previous pasteboard contents after ~500ms delay.
- **Accessibility permission UX is rough** — macOS makes users manually toggle it. The first-run wizard should deep-link to the exact System Settings pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`).
- **Groq outages / rate limits**: no local fallback in v1. Show a clear error, keep the raw audio around for retry.
- **API key storage**: Keychain is fine for personal use. If we ever distribute this publicly, we'd need to decide whether users BYO their Groq key (yes, for v1) or we proxy through our own server (no — that defeats the cost advantage).
- **Latency budget**: target <1.5s end-to-end for a 5-second utterance. Groq is fast enough; the risk is WAV upload over slow connections. We could switch to Opus/m4a compression if this bites.

---

## 8. First milestone

Get Phase 0 + Phase 1 working end-to-end: press a hotkey, speak, see the raw Groq transcript in a notification. That's the smallest useful proof the stack works, and everything after is iteration on top.

---

## Sources

- [Wispr Flow homepage](https://wisprflow.ai/)
- [Wispr Flow features](https://wisprflow.ai/features)
- [Wispr Flow hands-free docs](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)
- [Wispr Flow hotkey docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)
- [Wispr Flow setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide)
- [Wispr Flow review — tldv](https://tldv.io/blog/wisprflow/)
- [Groq Speech-to-Text docs](https://console.groq.com/docs/speech-to-text)
- [Groq Whisper Large v3 Turbo](https://console.groq.com/docs/model/whisper-large-v3-turbo)
- [Groq Llama 3.3 70B Versatile](https://console.groq.com/docs/model/llama-3.3-70b-versatile)
- [Groq Whisper performance blog](https://groq.com/blog/whisper-large-v3-turbo-now-available-on-groq-combining-speed-quality-for-speech-recognition)
- [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- [soffes/HotKey](https://github.com/soffes/HotKey)
- [SFlow — Python Groq clone](https://github.com/daniel-carreon/sflow)
- [OpenWhispr](https://github.com/OpenWhispr/openwhispr)
- [FreeFlow](https://github.com/zachlatta/freeflow)
- [VoiceTypr](https://github.com/moinulmoin/voicetypr)
- [Tambourine Voice](https://github.com/kstonekuan/tambourine-voice)
