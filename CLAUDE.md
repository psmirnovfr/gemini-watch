# CLAUDE.md

Entry point for agent sessions. Two companion docs carry the detail:

- **[AGENTS.md](AGENTS.md)** — architecture, per-file responsibilities, coding
  rules, and the reasoning behind design decisions. Read before changing code.
- **[BUILDING.md](BUILDING.md)** — Xcode setup, the Action-button Shortcut,
  what has never been verified, and the verification checklist.

## What this is

A standalone watchOS SwiftUI app that talks directly to the Google Gemini API.
No iPhone companion, no server, no package manager, no third-party dependencies.
Watch-first: design for 40mm before anything else.

## Read this before you touch anything

**None of this code has ever been compiled or run.** It was written without a
macOS toolchain. Treat every API surface as unverified — `BUILDING.md` section 5
ranks where the risk is concentrated. If you have Xcode, building and fixing
compile errors is more valuable than adding features.

## Invariants

These encode decisions made deliberately, usually after rejecting the obvious
alternative. Changing one means re-reading why it exists — the reasoning is in
AGENTS.md.

1. **The Action-button path costs one press and zero screen taps.** Press →
   speak → read. No confirmation step, no send button, no transcript-review
   screen, and no blank frame between launch and a live mic. Buttons belong
   *after* the answer. Any change that adds a tap here is a regression no matter
   what else it improves.

2. **Quick Ask never speaks its answer.** Text only. No `ProvidesDialog`, no
   auto-TTS. Tap-to-speak in the chat view is a separate, opt-in thing.

3. **Recording stops itself.** `VoiceRecorder` ends the take from the input
   meter. Never add a Stop button — that's the tap invariant 1 exists to avoid.

4. **Search is user-initiated, never automatic.** The cheap answer comes first;
   the user decides whether the credits are worth spending. Do not make the
   model able to trigger a search on its own.

5. **The smart model is user-initiated, never automatic.** Same reasoning.

6. **Keep the Gemini key on the free tier.** Gemini's built-in `google_search`
   grounding has a free allowance only on billing-enabled projects, and enabling
   billing starts per-token charges on every ordinary message. That is why
   search is external. Do not reintroduce grounding as a default.

7. **Everything degrades rather than fails.** A failed search still answers from
   the model's own knowledge; a mangled transcript still shows the answer; a
   missing search key hides the button instead of breaking it.

## Cost model

The whole design exists to keep a free-tier key viable. Know what a change costs:

| Action | Gemini | Tavily |
|---|---|---|
| Voice ask (transcribe + answer) | 1 request | — |
| Text message | 1 request | — |
| Smart | 1 request (smart model) | — |
| Search | 2 requests | 1 credit per query (default 3) |

## Practical notes

- Source lives in `gemini-watch/gemini-watch Watch App/`. The Xcode project uses
  a file-system synchronized root group, so new files are usually picked up
  without editing `project.pbxproj`.
- Two git-ignored local files, both with committed `.example` templates:
  `Secrets.plist` (API keys, read at runtime) and `Config/Local.xcconfig`
  (`DEV_TEAM_ID`, `BUNDLE_ID_PREFIX`, read at build time). Never commit either,
  never add a fallback key, never log a key, and never write a team ID or
  bundle identifier back into `project.pbxproj` — it references the xcconfig
  variables so developer-specific values stay out of tracked source.
- No test target, and adding one would mean a build dependency this project has
  deliberately avoided. Verification is the checklist in BUILDING.md.
- Don't stage `.DS_Store`, `xcuserdata/`, or build products — `.gitignore`
  covers them; fix the ignore rather than committing.
- This began as a fork of `cyroz1/gemini-watch`. Leave the original MIT
  copyright in `LICENSE` intact.
