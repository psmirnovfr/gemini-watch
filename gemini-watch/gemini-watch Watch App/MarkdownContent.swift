import SwiftUI

/// Renders parsed markdown parts. Extracted from `MessageView` so surfaces that
/// need the same rich text without the bubble chrome or tap-to-speak gesture
/// (notably `QuickAskView`) can reuse it instead of duplicating the switch.
struct MarkdownContent: View {
    let text: String
    /// Rich parsing is intentionally deferred while streaming — re-running every
    /// regex for every token is costly on watch hardware and makes long
    /// responses stutter.
    var isStreaming: Bool = false
    var fontSize: CGFloat = 12

    var body: some View {
        if isStreaming {
            Text(text)
                .font(.system(size: fontSize))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let parts = MarkdownParser.shared.parse(text)

            ForEach(parts.indices, id: \.self) { index in
                let part = parts[index]
                switch part.type {
                case .code(let language):
                    VStack(alignment: .leading, spacing: 0) {
                        if let language = language, !language.isEmpty {
                            Text(language.uppercased())
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 1)
                        }
                        Text(part.text)
                            .font(.system(size: 9, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(5)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(5)

                case .blockMath:
                    Text(part.text)
                        .font(.system(size: 10, design: .serif))
                        .italic()
                        .padding(3)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)

                case .inlineMath:
                    Text(part.text)
                        .font(.system(size: 10, design: .serif))
                        .italic()
                        .padding(.horizontal, 2)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(2)

                case .text:
                    Text(LocalizedStringKey(part.text))
                        .font(.system(size: fontSize))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
