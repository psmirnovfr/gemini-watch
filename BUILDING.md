# Building & Verifying Gemini Watch

Everything in this repo was written without a macOS toolchain — **none of it has
been compiled or run.** This file exists so the first Xcode session doesn't have
to rediscover what's here, and knows where the risk is concentrated.

Read [AGENTS.md](AGENTS.md) for architecture and the rules a change should
respect. This file is about getting it to build, and proving it works.

---

## 1. Prerequisites

| | |
|---|---|
| Xcode | 16 or later |
| Target | watchOS 11.0+ |
| Hardware | Apple Watch Ultra / Ultra 2 for the Action button; any watch for the rest |
| Accounts | Google AI Studio (free tier). Tavily (free tier) only if you want Search |

No package manager. No SPM/CocoaPods dependencies. Nothing to install.

---

## 2. Secrets

Create `gemini-watch/gemini-watch Watch App/Secrets.plist` (git-ignored) from
`Secrets.plist.example`:

```
GEMINI_API_KEY   required — https://aistudio.google.com/app/apikey
TAVILY_API_KEY   optional — https://tavily.com; without it the Search button is hidden
```

Add it to the **gemini-watch Watch App** target when Xcode asks. If the app
launches and every message errors with "No API key found", the file exists but
isn't in the target's Copy Bundle Resources phase.

**Do not commit it.** `.gitignore` already covers it.

---

## 3. First build

```bash
open gemini-watch/gemini-watch.xcodeproj
```

Select the **gemini-watch Watch App** scheme, pick a watchOS simulator, ⌘R.

**Signing:** `DEVELOPMENT_TEAM` is intentionally empty in the committed project
so the repo isn't tied to one Apple developer account. On first build, Xcode
asks you to pick your own team under **Signing & Capabilities** (automatic
signing). That choice lands in `xcuserdata/`, which is git-ignored — so it stays
local and never comes back as a diff. Simulator builds work without a team.

The project uses a **file-system synchronized root group**, so the Swift files
added over this project's history should be picked up automatically. If any are
missing from the build, check the target's Compile Sources phase before editing
`project.pbxproj` by hand.

Already configured in `project.pbxproj` (both Debug and Release):

- `INFOPLIST_KEY_NSMicrophoneUsageDescription` — required for voice capture
- `INFOPLIST_KEY_NSSiriUsageDescription` — required for the App Intent

---

## 4. Setting up the Action button

1. Build and run once on the watch, so the system indexes the app's App Intents.
2. On the watch, open **Shortcuts** (or the iPhone Shortcuts app's Watch tab).
3. New shortcut → single action: **Ask Gemini** → leave **Question empty**.
4. **Settings → Action Button → Shortcut** → pick it.

An empty Question is the signal to record. Filling it in (via a **Dictate Text**
step) switches to on-device transcription and sends text only — useful as a
fallback if the audio path misbehaves.

---

## 5. What has never been verified

Ranked by how likely it is to bite. This is the honest list.

### High — API surfaces written from documentation, never compiled

| Area | File | What could be wrong |
|---|---|---|
| App Intents | `AskGeminiIntent.swift` | `openAppWhenRun = true`, optional `@Parameter var question: String?`, and `AppShortcut` phrase interpolation are all written to spec but unchecked. If the intent doesn't appear in Shortcuts at all, start here. |
| Mic permission | `VoiceRecorder.swift` | `AVAudioApplication.requestRecordPermission` is watchOS 10+; if unavailable, fall back to `AVAudioSession.sharedInstance().requestRecordPermission`. |
| Audio session | `VoiceRecorder.swift` | `.record` + `.measurement` then `setActive(true)`, retried 3× because activation can lose a race with app foregrounding on an Action-button launch. If recording silently fails right after launch, instrument `activateSession()`. |
| Tavily shape | `SearchProvider.swift` | Request assumes `Bearer` auth and a `{results: [{title, url, content}]}` response. Verify against current Tavily docs. |

### Medium — behaviour that needs a real device

| Area | Where | What to look for |
|---|---|---|
| Silence detection | `VoiceRecorder.swift` tuning constants | `speechThresholdDB: -32`, `trailingSilence: 1.1s`, `noSpeechTimeout: 6s`, `maxDuration: 30s`. All guessed. Too eager → cuts you off mid-sentence; too lax → hangs after you finish. **Tune these first on real hardware**; they decide whether the flow feels right. |
| 40mm layout | `QuickAskView.actionButtons` | The 2×2 icon grid was sized by reasoning, not seen. Check nothing clips on the smallest screen. |
| Crown scrolling | `QuickAskView` | A long answer must scroll with the crown with no taps. If it doesn't, the `ScrollView` inside `fullScreenCover` + `NavigationStack` isn't taking crown focus. |
| Audio upload | `GeminiService` | 16 kHz mono WAV as inline base64, 45s timeout. A 30s take is ~1 MB before encoding; watch LTE may need longer. |
| Transcript split | `ChatViewModel` | Depends on the model honouring `TRANSCRIPT:` on line one. The parser fails open — if the format is ignored, all text still reaches the answer, but the user bubble reads "🎤 Voice message". |
| Model IDs | `Models.swift` | `gemini-3.5-flash-lite` / `gemini-3.7-flash` were confirmed against Google's docs but not against a live key. Both are user-changeable in Settings. |

### Low

- `fullScreenCover(item:)` presentation over a `NavigationStack` on watchOS.
- `DispatchQueue.main.async` hop in `ConversationListView.openFromQuickAsk`,
  which exists so dismissing the cover doesn't swallow the navigation push.

---

## 6. Verification checklist

### The critical path — must cost **one press and zero taps**

This is the whole point of the app. Everything else is secondary.

1. Press the Action button.
2. The mic screen appears immediately — "Getting ready…" then "Speak now".
   **Never a blank frame.**
3. Speak. It shows "Listening…" with a level meter.
4. Stop talking. Recording ends **on its own** within ~1 second.
5. The transcript appears first, then the answer streams.
6. A long answer scrolls with the **crown**, no taps.
7. Only now do buttons appear: **🔍 Search / 🧠 Smart / 🎤 Ask / 💬 Chat**.

Two first-run permission alerts are unavoidable (microphone, notifications).
Notifications are deliberately requested from the conversation list, never
behind a Quick Ask — if one appears mid-ask, that's a regression.

### Everything else

- [ ] Missing `Secrets.plist` → clear error, not a crash
- [ ] Text chat: send, stream, stop keeps partial text
- [ ] Long-press a user message → edit → regenerates from that point
- [ ] **Smart** re-asks with the smart model; the model badge changes
- [ ] **Search** shows generated queries, returns a cited answer with sources
- [ ] Search button is *absent* (not broken) with no `TAVILY_API_KEY`
- [ ] **Ask** records a follow-up into the *same* conversation
- [ ] **Chat** opens the same conversation in the full UI
- [ ] Conversations persist across relaunch; delete and pin work
- [ ] Settings persist; model pickers populate from the live list
- [ ] Denying mic permission → readable error with a working Retry
- [ ] Pressing the Action button twice doesn't double-send
- [ ] Relaunching after an ask doesn't replay the old question
- [ ] Answers are **never spoken aloud** unless you tap a message

---

## 7. Cost model

Worth keeping in mind while testing, since the design exists to protect a free tier.

| Action | Gemini | Tavily |
|---|---|---|
| Voice ask (transcribe + answer) | 1 request | — |
| Text message | 1 request | — |
| 🧠 Smart | 1 request (smart model) | — |
| 🔍 Search | 2 requests (queries + answer) | 1 credit per query |

Default 3 queries per search ⇒ ~330 searches on Tavily's 1,000/month free tier.

Nothing searches automatically, and nothing uses the smart model automatically.
Both are always a deliberate tap. If you find yourself adding an automatic
trigger for either, re-read the reasoning in AGENTS.md first.

---

## 8. Tuning quick reference

| Want to change | Where |
|---|---|
| How fast recording stops | `VoiceRecorder.trailingSilence` |
| Mic sensitivity | `VoiceRecorder.speechThresholdDB` |
| Max recording length | `VoiceRecorder.maxDuration` |
| Results fed per query | `ChatViewModel.resultsPerQuery` |
| Queries per search | Settings → Search (1–5) |
| Default models | `AppSettings.defaultFastModel` / `defaultSmartModel` |
| Context window | `GeminiService.buildContents` (last 20 messages) |

---

## 9. No test target

There is none, and adding one would mean adding a build dependency the project
has deliberately avoided. Verification is the checklist above, run on a
simulator and then on a real watch — the Action button, microphone, and crown
can only be properly judged on hardware.
