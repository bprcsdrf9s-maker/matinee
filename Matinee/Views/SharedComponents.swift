import SwiftUI

// Views used by both the iPhone/iPad app and the Apple TV app.

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholderText: String? = nil
    /// Tried when `url` fails to load.
    var fallback: URL? = nil

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure where fallback != nil:
                RemoteImage(url: fallback, contentMode: contentMode, placeholderText: placeholderText)
            default:
                ZStack {
                    LinearGradient(colors: [Color(white: 0.16), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                    if let placeholderText {
                        Text(placeholderText)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
        }
    }
}

// MARK: - Badges

struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 20, height: 20)
            .background(Theme.accent, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2))
            .accessibilityLabel("Watched")
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Misc

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

struct Chip: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(highlighted ? Theme.onAccent : Color.primary)
            .background(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
