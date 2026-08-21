# Gemini Watch — Google Gemini AI Chat for Apple Watch (watchOS)

**Gemini Watch is a free, open-source Apple Watch app that brings Google Gemini AI chat to your wrist.** Stream conversations with Gemini directly from watchOS — no iPhone companion app, no tethering, no subscriptions. Built natively in SwiftUI and optimized for 40mm and 41mm Apple Watch screens.

![Platform: watchOS 11+](https://img.shields.io/badge/platform-watchOS%2011%2B-black?logo=apple)
![Language: Swift](https://img.shields.io/badge/language-Swift-orange?logo=swift)
![UI: SwiftUI](https://img.shields.io/badge/ui-SwiftUI-blue?logo=swift)
![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Xcode 16+](https://img.shields.io/badge/Xcode-16%2B-1575F9?logo=xcode)

> **Keywords:** Apple Watch Gemini app · Google Gemini watchOS client · AI chat on Apple Watch · standalone watchOS AI assistant · SwiftUI Gemini API · streaming LLM Apple Watch.

---

## Table of Contents

- [Why Gemini Watch?](#why-gemini-watch)
- [Features](#features)
- [Screenshots](#screenshots)
- [Requirements](#requirements)
- [Installation & Setup](#installation--setup)
- [Getting a Google Gemini API Key](#getting-a-google-gemini-api-key)
- [Usage Guide](#usage-guide)
- [Action Button Setup (Apple Watch Ultra)](#action-button-setup-apple-watch-ultra)
- [Architecture](#architecture)
- [Privacy & Data Handling](#privacy--data-handling)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

---

## Why Gemini Watch?

Most AI assistants on Apple Watch are thin mirrors of an iPhone app — they require your phone nearby, re-route requests through a companion, or don't support streaming. **Gemini Watch runs entirely on watchOS**: it calls the Google Gemini API directly over Wi-Fi or cellular, streams tokens as they arrive, and stores every conversation locally on the watch.

If you're looking for a **native Apple Watch Gemini client**, a **lightweight LLM chat app for watchOS**, or a **SwiftUI reference implementation of the Gemini streaming API**, this project is for you.

---

## Features

- **Real-time Streaming Chat** — Tokens appear as Gemini generates them, with an animated typing cursor. Built on Server-Sent Events (SSE) from the Gemini streaming endpoint.
- **Full Conversation History** — Every chat is saved as an individual JSON file on the watch and browsable from a scrollable list. Swipe any conversation to delete it; pin important chats to the top.
- **Message Editing & Regeneration** — Long-press any user message to edit it and regenerate Gemini's reply from that point.
- **Web Search Grounding** — Enable Gemini's `google_search` tool from Settings to get grounded answers with inline citations and source links.
- **Context-Aware Quick Replies** — Smart suggestion chips appear after each response, tailored to the content (code, lists, follow-up questions, or general conversation). Toggleable from Settings.
- **Markdown & LaTeX Rendering** — Code blocks with language labels, bold and italic text, inline math (`$…$`) and block math (`$$…$$`), powered by a pre-compiled regex parser with result caching for smooth scrolling.
- **Text-to-Speech** — Tap any Gemini response to hear it spoken aloud via `AVSpeechSynthesizer`, with a Slow / Normal / Fast speech-rate slider.
- **Adjustable Creativity (Temperature)** — A Precise → Balanced → Creative → Wild slider maps directly to the Gemini `temperature` parameter (0.0–1.0), with a one-tap reset to the default.
- **Haptic Feedback** — Optional haptics on key interactions; toggleable in Settings.
- **Double Tap Gesture Support** — Use the watchOS Double Tap gesture (Apple Watch Series 9, 10, and Ultra 2) to open the input field instantly.
- **Action Button Integration (Apple Watch Ultra)** — Press the Action button, speak your question, read the reply as scrollable text — never spoken aloud. Recording stops on its own when you stop talking, so the whole flow costs one press and zero taps. Follow-up buttons under the answer let you escalate to a smarter model or continue in the full chat. See [Action Button Setup](#action-button-setup-apple-watch-ultra).
- **Gemini-Side Speech Recognition** — Send audio straight to Gemini instead of relying on on-device dictation. Handles accents and mid-sentence language switching that watchOS dictation gets wrong, transcribes and answers in a single request, and shows the transcript first so you can see what was heard.
- **Two-Tier Models for Free-Tier Keys** — A cheap "Everyday" model answers every message; one tap on **✦ Smart** re-sends the whole conversation to a stronger model. Keeps an AI Studio free-tier key viable without giving up quality when it matters.
- **Customizable System Prompt** — Edit Gemini's persona, tone, and instructions right from the in-app Settings screen, with a reset-to-default button.
- **Live Model Picker** — Switch between available Gemini models (e.g., `gemini-2.5-flash`, `gemini-2.5-pro`). The list is fetched live from the Gemini API and filtered to text-capable models.
- **Clear All Chats** — One-tap bulk delete with a confirmation dialog in the Settings "Danger Zone".
- **40mm / 41mm Optimized** — Compact typography, tight spacing, and carefully tuned tap targets designed for the smallest Apple Watch screens.
- **100% On-Device Storage** — Conversations never leave your watch except when sent to the Gemini API itself.

---

## Screenshots

<!-- Add screenshots here: chat view, conversation list, settings, streaming in progress -->
<!-- Example: ![Gemini Watch chat view on Apple Watch](docs/screenshot-chat.png) -->

*Screenshots coming soon. PRs with simulator captures welcome — see [Contributing](#contributing).*

---

## Requirements

| Requirement | Version |
|---|---|
| **Xcode** | 16 or later |
| **watchOS deployment target** | 11.0+ |
| **Apple Watch hardware** | Series 6 or later recommended |
| **Google Cloud / AI Studio account** | Required for a Gemini API key |
| **Network** | Wi-Fi or LTE on the watch for standalone use |

---

## Installation & Setup

### 1. Clone the repository

```bash
git clone https://github.com/cyroz1/gemini-watch.git
cd gemini-watch
```

### 2. Open the project in Xcode

```bash
open gemini-watch/gemini-watch.xcodeproj
```

### 3. Add your Gemini API key

Create a `Secrets.plist` file inside the **`gemini-watch Watch App`** group:

1. In Xcode: **File → New → File → Property List**.
2. Name it `Secrets.plist` and add it to the `gemini-watch Watch App` target.
3. Add a key `GEMINI_API_KEY` (type: `String`) and paste your API key as the value.

See `Secrets.plist.example` for the exact format.

> **Never commit `Secrets.plist`.** It is already listed in `.gitignore`.

### 4. Build and run

1. Select the **gemini-watch Watch App** scheme.
2. Choose an Apple Watch Simulator (or a paired physical device).
3. Press **⌘R** to build and run.

---

## Getting a Google Gemini API Key

1. Visit [Google AI Studio](https://aistudio.google.com/app/apikey).
2. Sign in with your Google account.
3. Click **Create API key** and copy the generated key.
4. Paste it into `Secrets.plist` as described above.

The free tier is sufficient for personal use. Check [Google's Gemini API pricing](https://ai.google.dev/pricing) for rate limits and paid tiers.

---

## Usage Guide

### Chat basics

- **Start a new chat** — Tap the compose button from the conversation list.
- **Send a message** — Tap the input field, dictate or scribble, and press send.
- **Regenerate a reply** — Long-press any of your own messages, edit, and resend.
- **Hear a reply aloud** — Tap any Gemini message to trigger text-to-speech.
- **Delete a conversation** — Swipe left on it in the conversation list.

### Settings

Open **Settings** from the conversation list to configure:

| Setting | What it does |
|---|---|
| **AI Model** | Picker of Gemini models your API key can access (e.g. `gemini-2.5-flash`, `gemini-2.5-pro`). Fetched live from the API. |
| **Speech → Speed** | Text-to-speech rate — Slow, Normal, or Fast. |
| **Creativity** | Maps to the Gemini `temperature` parameter (0.0–1.0). Labels: Precise, Balanced, Creative, Wild. Includes a **Reset to Default** button (0.7). |
| **Haptics** | Toggle haptic feedback on interactions. |
| **Quick Replies** | Toggle the context-aware suggestion chips that appear after each response. |
| **Web Search** | Toggle grounded answers with citations via Gemini's `google_search` tool. |
| **System Prompt** | Multiline editor for the assistant's persona and instructions. Includes a **Reset to Default** button. |
| **Clear All Chats** | Danger-zone action with a confirmation dialog — permanently deletes every saved conversation from the watch. |

---

## Action Button Setup (Apple Watch Ultra)

Press the Action button, speak a question, read the answer. No voice output, no typing.

```
Action button → speak → answer streams in as scrollable text
                              ↓
                    ┌─────────┴─────────┐
                    │                   │
             ✦ Smart              Continue →
   re-ask the same context     open the chat and
    with the better model         keep talking
```

**Cost to reach the answer: one button press, zero screen taps.**

| Step | Taps |
|---|---|
| Press Action button | 1 press |
| Mic appears, listening starts automatically | 0 |
| You stop speaking → dictation ends on its own | 0 |
| App opens and starts streaming immediately | 0 |

### One-time setup

1. Install/update Gemini Watch on your Apple Watch Ultra (or Ultra 2) at least once so the system indexes its App Intents.
2. On the watch, open the **Shortcuts** app (or build it on your iPhone under the Shortcuts app's **Watch** tab — it syncs over).
3. Create a shortcut containing a **single action: Ask Gemini**, with the **Question** field left **empty**. An empty question is the signal to record — the app opens straight into the mic.
4. Name it (e.g. "Ask Gemini") and save.
5. On the watch: **Settings → Action Button → Shortcut**, and pick it.

There is no confirmation step anywhere in the chain: the intent never asks for confirmation, the empty question means the system never prompts for one, and recording starts the moment the screen appears.

### Choosing who transcribes: Gemini or Apple

The **Question** field on the Ask Gemini action decides this, and the two modes are genuinely different tradeoffs.

| | **Gemini transcribes** (Question empty) | **Apple transcribes** (Dictate Text → Ask Gemini) |
|---|---|---|
| Setup | One action, Question left empty | Two actions; Dictate Text must use `Stop Listening: After Short Pause` |
| Recognition | Gemini's ASR — far better with accents, and it handles switching languages mid-sentence | On-device dictation, locked to your current dictation language |
| Sent to Google | ~16 kHz mono audio (≈32 tokens/sec, so a 10s question ≈320 tokens) | Text only |
| Latency | Slightly higher — a few hundred KB uploads before the answer starts | Lower |
| Taps | Zero | Zero, *only if* `After Short Pause` is set |

**Use the empty-Question (Gemini) mode if on-device dictation mangles your speech** — that's what it's for. The text mode stays available and is marginally faster when dictation happens to work well for you.

Either way it's still one request per question: in voice mode Gemini transcribes *and* answers in a single call. The transcript comes back on the first line, so you see what was heard before the answer finishes streaming, and it's saved as the user message — long-press to edit and regenerate if a word came out wrong.

> Voice mode needs a model that accepts audio input. Both defaults do (`gemini-3.5-flash-lite` and `gemini-3.7-flash` take text, image, video, audio and PDF). If you switch the Everyday model to something text-only, voice asks will fail with an API error — use the text-mode Shortcut instead, or pick an audio-capable model.

> No **Show Result** step is needed — Gemini Watch draws the answer itself, which is what makes the follow-up buttons possible. Shortcuts' own result card is text-only and can't carry them.
>
> You can also skip the manual build entirely: Gemini Watch registers "Ask Gemini" as an App Shortcut, so it already appears in the Shortcuts gallery and can be assigned to the Action button directly. Assigned that way, the system prompts you to speak the question when it runs.

### What you get

- **Scrollable text answer** — streams in token by token; the Digital Crown scrolls long replies. Nothing is ever read aloud.
- **✦ Smart** — the free-tier escape hatch. Re-sends the *whole* conversation to the smarter model when the cheap answer isn't good enough. Only appears when it would actually change the answer, and each reply is badged with the model that produced it.
- **Continue** — opens the same conversation in the full chat UI so you can keep going.
- **Follow-up chips** — context-aware suggestions; tapping one opens the chat with that follow-up already sent.
- Every Action-button ask is saved as a normal conversation, browsable later from the list.

### Model tiers and free-tier quota

Settings → **AI Models** has two pickers, both populated from the live model list:

| Picker | Default | When it runs |
|---|---|---|
| **Everyday** | `gemini-3.5-flash-lite` | Every message you send — one cheap request per turn. |
| **Smart** | `gemini-3.7-flash` | Only when you tap **✦ Smart**. |

That keeps an AI Studio free-tier key comfortable: cheap model by default, one deliberate escalation when you need it.

> Model IDs change as Google's lineup does. Both pickers read the live `/models` list from your key, so if a default ID isn't available to you, just pick a different one in Settings — no code change needed.

The Action button flow uses the same `Secrets.plist` / `GEMINI_API_KEY` setup as the rest of the app — see [Installation & Setup](#installation--setup).

---

## Architecture

Gemini Watch follows a lean MVVM architecture built entirely in SwiftUI. There is no Core Data, no Combine-heavy plumbing, and no third-party dependencies — just `URLSession`, `FileManager`, and `AVFoundation`.

| File | Purpose |
|---|---|
| `gemini_watchApp.swift` | App entry point — launches `ConversationListView`. |
| `ConversationListView.swift` | Browsable conversation list with swipe-to-delete. |
| `ContentView.swift` | Main chat UI — input bar, messages, suggestion chips. |
| `ChatViewModel.swift` | Message state, streaming orchestration, auto-persistence, debounced UI updates. |
| `GeminiService.swift` | Gemini API client — streaming SSE chat and model listing. |
| `MessageView.swift` | Message bubble with markdown rendering, streaming cursor, and TTS trigger. |
| `MarkdownParser.swift` | Pre-compiled regex parser for code blocks, math, and inline styling; result-cached. |
| `Models.swift` | `Message`, `Conversation`, and `AppSettings` data types. |
| `PersistenceManager.swift` | File-based storage (one JSON file per conversation) with UserDefaults migration. |
| `SettingsView.swift` | Model picker, speech rate, haptics, quick replies, system prompt editor. |
| `Speaker.swift` | Text-to-speech wrapper around `AVSpeechSynthesizer`. |
| `AppSettingsStore.swift` | Observable store for user preferences. |
| `Branding.swift` | Shared colors, gradients, and typography tokens. |
| `AskGeminiIntent.swift` | `AppIntent` powering the Action button / Shortcuts flow, plus the `AppShortcutsProvider` registration. |
| `QuickAskRouter.swift` | Carries the dictated question from the intent into the UI, surviving a cold launch. |
| `QuickAskView.swift` | The post-Action-button screen — streaming answer, crown scrolling, Smart / Continue / follow-up buttons. |
| `MarkdownContent.swift` | Shared markdown/code/math renderer used by both `MessageView` and `QuickAskView`. |
| `VoiceRecorder.swift` | Mic capture with level-based auto-stop, producing 16 kHz mono WAV for Gemini. |

### Data flow

```
User input → ChatViewModel → GeminiService (streaming SSE)
                    ↓                       ↓
           PersistenceManager        MessageView (token-by-token UI)
                    ↓
          One JSON file per chat
```

---

## Privacy & Data Handling

- **Conversations are stored locally** on the Apple Watch as JSON files in the app's sandboxed container.
- **Messages are transmitted only to the Google Gemini API** over HTTPS when you send a request.
- **No analytics, telemetry, or third-party SDKs** are bundled.
- **Your API key stays on the device** in `Secrets.plist`, embedded in the app bundle at build time.

Review [Google's Gemini API data usage policy](https://ai.google.dev/gemini-api/terms) to understand how Google handles prompts and responses on their side.

---

## FAQ

### Does Gemini Watch require an iPhone?

No. Gemini Watch is a **standalone watchOS app**. As long as your Apple Watch has a network connection (Wi-Fi or cellular), it can talk to Gemini without an iPhone nearby.

### Is Gemini Watch free?

Yes — the app is MIT-licensed and free. You only pay Google for any API usage above their free Gemini tier.

### Which Apple Watch models are supported?

Any Apple Watch running **watchOS 11 or later**. The layout is tuned for 40mm and 41mm cases but scales up to 44mm, 45mm, 49mm (Ultra), and 42mm/46mm Series 10.

### Can I use a different model, like `gemini-2.5-pro`?

Yes. Open **Settings → Model** to pick from any model your API key has access to. The list is fetched live from the Gemini API.

### Does it support images, voice input, or vision?

The current release focuses on text chat with text-to-speech output. Voice input uses the standard watchOS dictation / Scribble input methods, or the Action button flow below. Vision and multimodal support are on the roadmap.

### Can I use the Apple Watch Ultra Action button to talk to Gemini?

Yes. See [Action Button Setup](#action-button-setup-apple-watch-ultra). Press the Action button, speak your question, and Gemini's reply appears as **scrollable text on screen** — never spoken aloud. Buttons under the answer let you escalate to a smarter model or continue the conversation in the app.

### Why does the Action button open the app instead of showing a Shortcuts result card?

Because the result card is text-only. Getting **Smart** and **Continue** buttons under the answer requires the app to draw the screen, so `AskGeminiIntent` hands the question to the app and lets `QuickAskView` stream the reply.

### Who does the speech-to-text — watchOS or Gemini?

**Your choice, and it's set by the Shortcut.** Leave the Ask Gemini action's **Question** field empty and the app records audio for Gemini to transcribe — much better with accents and mixed-language speech. Add a **Dictate Text** step instead and watchOS transcribes on-device, sending text only. See [Choosing who transcribes](#choosing-who-transcribes-gemini-or-apple).

### If Gemini records the audio, how does it know when I've stopped talking?

The app watches the microphone's input level and ends the take after about a second of silence, with a 30-second ceiling. That auto-stop is what keeps the flow tap-free — a "Stop" button would defeat the point. If you never say anything, it gives up after 6 seconds rather than recording your pocket.

### How many taps to get an answer?

One Action-button press and zero screen taps, in both transcription modes. In text mode this depends on **Dictate Text** having `Stop Listening` set to `After Short Pause`. See [Action Button Setup](#action-button-setup-apple-watch-ultra).

### How do I keep my free AI Studio key from running out of quota?

The **Everyday** model in Settings (default `gemini-3.5-flash-lite`) answers every message — one cheap request per turn. The stronger **Smart** model only runs when you tap **✦ Smart**, which re-sends the whole conversation. See [Model tiers and free-tier quota](#model-tiers-and-free-tier-quota).

### Does Gemini Watch support web search?

Yes. Flip the **Web Search** toggle in Settings to enable Gemini's `google_search` grounding tool. Responses that use web results include inline citations with source URLs.

### Can I tune how creative the responses are?

Yes. The **Creativity** slider in Settings maps directly to the Gemini `temperature` parameter from 0.0 (Precise) to 1.0 (Wild). Tap **Reset to Default** to return to 0.7.

### How do I back up my conversations?

Conversations live in the app's sandbox on the watch. They'll be included in encrypted iCloud backups of your paired iPhone if you have that enabled.

### Does it work offline?

The UI and your saved history work offline, but sending new messages requires a network connection to reach the Gemini API.

### Is this an official Google product?

No. Gemini Watch is an **unofficial, community-built** open-source client. "Gemini" and "Google" are trademarks of Google LLC.

---

## Contributing

Contributions, bug reports, and feature requests are welcome. Please open an issue or submit a pull request on [GitHub](https://github.com/cyroz1/gemini-watch).

Good first contributions:

- Screenshots from different Apple Watch sizes.
- Localization into additional languages.
- Accessibility improvements (VoiceOver labels, Dynamic Type audit).
- Complications and Smart Stack widgets.

---

## License

Released under the [MIT License](LICENSE). Copyright © 2026 cyroz.

---

## Related Topics

`apple-watch` · `watchos` · `gemini` · `gemini-api` · `google-gemini` · `ai-chat` · `llm` · `swiftui` · `swift` · `chatbot` · `streaming` · `sse` · `on-device` · `open-source`
