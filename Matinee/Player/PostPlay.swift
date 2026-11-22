import SwiftUI
import UIKit

/// "More Like This" at the end of a movie: a button while the credits roll, and a full screen of
/// similar titles when the movie ends or is closed during the credits. Series go on to the next
/// episode instead, so this is for movies only.
enum PostPlay {
    static func eligible(_ request: PlaybackRequest) -> Bool {
        guard let seed = request.seed else { return false }
        return seed.type == "movie" && request.nextVideoId == nil && seed.id.hasPrefix("tt")
    }

    /// The credits: the last 5% of the movie, at least 90 seconds and at most 6 minutes.
    static func inCredits(position: Double, duration: Double) -> Bool {
        guard duration > 300, position.isFinite else { return false }
        let window = max(90, min(360, duration * 0.05))
        return duration - position <= window
    }
}

/// Full-screen list of similar titles. Picking one opens its page; Close goes back where you were.
struct PostPlayView: View {
    let finishedTitle: String
    let backdrop: URL?
    let load: () async -> [MetaItem]
    let onPick: (MetaItem) -> Void
    let onClose: () -> Void

    @State private var items: [MetaItem]? = nil

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let art = backdrop ?? items?.first?.background {
                RemoteImage(url: art)
                    .ignoresSafeArea()
                    .opacity(0.35)
                    .overlay(LinearGradient(colors: [Theme.background.opacity(0.2), Theme.background],
                                            startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
            content
        }
        .task {
            if items == nil { items = await load() }
        }
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                Text("More Like This").font(.system(size: 64, weight: .heavy))
                Text("Because you watched \(finishedTitle)").font(.title3).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 80)
            row
            Button("Back to Browse", action: onClose)
                .padding(.horizontal, 80)
            Spacer(minLength: 0)
        }
        .padding(.top, 80)
        #else
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("More Like This").font(.system(size: 34, weight: .heavy))
                    Text("Because you watched \(finishedTitle)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Theme.pill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 24)
            row
            Button(action: onClose) {
                Text("Back to Browse")
                    .font(.headline)
                    .padding(.horizontal, 22).frame(height: 44)
                    .background(Theme.pill, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .center)
        #endif
    }

    @ViewBuilder private var row: some View {
        if let items {
            if items.isEmpty {
                Text("Nothing similar found right now.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, rowPadding)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: rowSpacing) {
                        ForEach(items) { item in
                            Button { onPick(item) } label: { poster(item) }
                                #if os(tvOS)
                                .buttonStyle(.card)
                                #else
                                .buttonStyle(.plain)
                                #endif
                        }
                    }
                    .padding(.horizontal, rowPadding)
                    .padding(.vertical, rowVerticalPadding)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: posterWidth * 1.5)
        }
    }

    private func poster(_ item: MetaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.poster, placeholderText: item.name)
                .frame(width: posterWidth, height: posterWidth * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            #if os(iOS)
            Text(item.name).font(.footnote.weight(.semibold)).lineLimit(1).frame(width: posterWidth, alignment: .leading)
            if let year = item.releaseInfo { Text(year).font(.caption).foregroundStyle(.secondary) }
            #endif
        }
    }

    #if os(tvOS)
    private let posterWidth: CGFloat = 240
    private let rowPadding: CGFloat = 80
    private let rowSpacing: CGFloat = 48
    private let rowVerticalPadding: CGFloat = 30
    #else
    private var posterWidth: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 150 : 118 }
    private let rowPadding: CGFloat = 24
    private let rowSpacing: CGFloat = 12
    private let rowVerticalPadding: CGFloat = 0
    #endif
}

#if os(iOS)
/// The "More Like This" button that shows in the player while the credits roll.
final class PostPlayButton: UIButton {
    var onTap: (() -> Void)?

    static func make() -> PostPlayButton {
        var config = UIButton.Configuration.filled()
        config.title = "More Like This"
        config.image = UIImage(systemName: "square.grid.2x2.fill")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .white
        config.baseForegroundColor = .black
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = .systemFont(ofSize: 16, weight: .semibold)
            return a
        }
        let b = PostPlayButton(configuration: config)
        b.isHidden = true
        b.alpha = 0
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addAction(UIAction { [weak b] _ in b?.onTap?() }, for: .touchUpInside)
        return b
    }

    /// Bottom-right, above the player's own controls.
    func pin(in view: UIView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
        ])
    }

    func setShown(_ shown: Bool) {
        guard shown == isHidden else { return }
        if shown { isHidden = false }
        UIView.animate(withDuration: 0.25, animations: { self.alpha = shown ? 1 : 0 }) { _ in
            if !shown { self.isHidden = true }
        }
    }
}
#endif
