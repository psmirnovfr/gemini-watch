import SwiftUI

struct MessageView: View {
    let message: Message
    let isStreaming: Bool
    let onRegenerate: (() -> Void)?

    /// Injected via environment — not a direct singleton reference (#18)
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSources = false

    init(message: Message, isStreaming: Bool = false, onRegenerate: (() -> Void)? = nil) {
        self.message = message
        self.isStreaming = isStreaming
        self.onRegenerate = onRegenerate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // MARK: - Markdown Content
            MarkdownContent(text: message.text, isStreaming: isStreaming)

            // MARK: - Model Badge
            // Shows which model produced the reply once more than one is in
            // play (e.g. after escalating a fast answer to the smart model).
            if message.role == .model, let modelName = message.modelName {
                Text(modelName.shortModelLabel)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // MARK: - Streaming Cursor
            if isStreaming {
                StreamingDots(reduceMotion: reduceMotion)
                    .padding(.top, 2)
            }

            // MARK: - TTS Indicator
            if message.role == .model && speaker.currentMessageId == message.id && speaker.isSpeaking {
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                        .font(.system(size: 8))
                        .symbolEffect(.variableColor.iterative.reversing)
                    Text("Speaking…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            // MARK: - Sources (web-search grounding)
            if let sources = message.sources, !sources.isEmpty {
                Button {
                    showSources = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                            .font(.system(size: 8))
                        Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(GeminiBrand.gradient)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            // MARK: - Timestamp (#14)
            Text(message.createdAt.relativeString)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .sheet(isPresented: $showSources) {
            SourcesSheet(sources: message.sources ?? [])
        }
        .padding(6)
        .frame(maxWidth: message.role == .model ? .infinity : nil, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(message.role == .user ? Color.blue.opacity(0.3) : Color.gray.opacity(0.15))
        )
        // Tap to speak (#18 — reads settings from environment)
        .onTapGesture {
            if message.role == .model {
                speaker.speak(
                    text: message.text,
                    messageId: message.id,
                    rate: settingsStore.settings.speechRate,
                    hapticsEnabled: settingsStore.settings.hapticsEnabled
                )
            }
        }
        // Context menu: Speak shortcut (#11 — no clipboard on watchOS, so Speak is the most useful action)
        .contextMenu {
            if message.role == .model {
                Button {
                    speaker.speak(
                        text: message.text,
                        messageId: message.id,
                        rate: settingsStore.settings.speechRate,
                        hapticsEnabled: settingsStore.settings.hapticsEnabled
                    )
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2")
                }
                if speaker.isSpeaking && speaker.currentMessageId == message.id {
                    Button {
                        speaker.stop()
                    } label: {
                        Label("Stop Speaking", systemImage: "speaker.slash")
                    }
                }
                if let onRegenerate, !isStreaming {
                    Button {
                        onRegenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: speaker.currentMessageId)
    }
}

// MARK: - Sources Sheet

private struct SourcesSheet: View {
    let sources: [GroundingSource]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources) { source in
                    // `Link` on watchOS hands off to the paired iPhone.
                    if let url = URL(string: source.uri) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .lineLimit(2)
                                Text(shortHost(for: source.uri))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func shortHost(for uri: String) -> String {
        URL(string: uri)?.host?.replacingOccurrences(of: "www.", with: "") ?? uri
    }
}

// MARK: - Streaming Dots

private struct StreamingDots: View {
    let reduceMotion: Bool

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            HStack(spacing: 3) {
                staticDot(opacity: 0.35)
                staticDot(opacity: 0.6)
                staticDot(opacity: 0.85)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    dot(phase: t)
                    dot(phase: t - 0.2)
                    dot(phase: t - 0.4)
                }
            }
        }
    }

    private func staticDot(opacity: Double) -> some View {
        Circle()
            .fill(GeminiBrand.gradient)
            .frame(width: 5, height: 5)
            .opacity(opacity)
    }

    private func dot(phase: TimeInterval) -> some View {
        let opacity = 0.25 + 0.55 * abs(sin(phase * .pi * 1.3))
        return Circle()
            .fill(GeminiBrand.gradient)
            .frame(width: 5, height: 5)
            .opacity(opacity)
    }
}
