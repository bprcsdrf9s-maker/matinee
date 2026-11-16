import SwiftUI

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
                    LinearGradient(colors: [Color(white: 0.18), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
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

struct PosterCard: View {
    let meta: MetaItem
    let width: CGFloat
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: meta.poster, placeholderText: meta.name)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.06))
                )
            if showTitle {
                Text(meta.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                if let year = meta.year {
                    Text(year).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 4)
    }
}

struct ContinueCard: View {
    let entry: LibraryEntry
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: backdrop, placeholderText: entry.name, fallback: entry.poster)
                    .frame(width: width, height: width * 9 / 16)
                    .clipped()
                    .overlay(alignment: .center) {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .padding(14)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                if entry.progress > 0 {
                    ProgressLine(value: entry.progress)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var backdrop: URL? { entry.asMeta.backdrop ?? entry.poster }

    private var subtitle: String {
        var parts: [String] = []
        if let ep = entry.episodeLabel { parts.append(ep) }
        if entry.duration > 0 && entry.timeOffset > 1 {
            let left = max(0, (entry.duration - entry.timeOffset) / 1000)
            parts.append("\(Int(left / 60)) min left")
        } else if entry.timeOffset == 1 {
            parts.append("Up next")
        }
        return parts.isEmpty ? (entry.type == "series" ? "Series" : "Movie") : parts.joined(separator: " · ")
    }
}

struct RowHeader: View {
    let title: String
    var destination: Route? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let destination {
                NavigationLink(value: destination) {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
        }
    }
}

struct PosterRow: View {
    let items: [MetaItem]
    @Environment(\.sizing) private var sizing

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { meta in
                    NavigationLink(value: Route.meta(meta)) {
                        PosterCard(meta: meta, width: sizing.posterWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, sizing.hPad)
        }
        .scrollClipDisabled()
    }
}

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
            .foregroundStyle(highlighted ? Color.black : Color.primary)
            .background(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
