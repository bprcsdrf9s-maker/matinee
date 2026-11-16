import SwiftUI

// MARK: - Top bar

/// Logo plus a full-width search pill, shown at the top of Board, Discover and Library.
struct TopBar: View {
    @Environment(\.sizing) private var sizing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.pill)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accent, Color(red: 0.36, green: 0.27, blue: 0.95)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .offset(x: 1.5)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            NavigationLink(value: Route.search) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                    Spacer(minLength: 0)
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Theme.pill, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, sizing.hPad)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

// MARK: - Posters

/// A poster with no caption, like Stremio's boards. Shows a check when the title is watched.
/// With no width it fills the space it's given (grid cells) at the poster's own aspect ratio.
struct PosterCard: View {
    let meta: MetaItem
    var width: CGFloat? = nil
    var progress: Double? = nil

    @Environment(AppModel.self) private var model

    var body: some View {
        let watched = model.entry(for: meta.id)?.isWatched == true
        Color.clear
            .aspectRatio(1 / meta.posterAspect, contentMode: .fit)
            .frame(width: width)
            .overlay { RemoteImage(url: meta.poster, placeholderText: meta.name) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if watched { WatchedBadge().padding(6) }
            }
            .overlay(alignment: .bottom) {
                if let progress, progress > 0 {
                    ProgressLine(value: progress)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(meta.name)
    }
}

/// Grid columns for a set of posters: 3 across on iPhone (2 for wide channel art), more on iPad.
func posterColumns(for items: [MetaItem], sizing: Sizing) -> [GridItem] {
    let landscape = !items.isEmpty && items.prefix(6).allSatisfy { $0.posterShape == "landscape" }
    let count = landscape ? max(2, sizing.gridColumns - 1) : sizing.gridColumns
    return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
}

// MARK: - Rows

struct RowHeader: View {
    let title: String
    var destination: Route? = nil

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let destination {
                NavigationLink(value: destination) {
                    Text("See All")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.pill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PosterRow: View {
    let items: [MetaItem]
    @Environment(\.sizing) private var sizing

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(items) { meta in
                    NavigationLink(value: Route.meta(meta)) {
                        PosterCard(meta: meta,
                                   width: meta.posterShape == "landscape" ? sizing.landscapeWidth : sizing.posterWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, sizing.hPad)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Dropdown pills

/// A rounded dropdown pill like the Discover filters; tapping opens a sheet of options.
struct FilterPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(Theme.pill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Bottom sheet listing options with a check on the current one.
struct OptionSheet: View {
    let title: String
    let options: [String]
    let selected: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onSelect(option)
                            dismiss()
                        } label: {
                            HStack {
                                Text(option)
                                    .foregroundStyle(option == selected ? Theme.accent : .primary)
                                Spacer()
                                if option == selected {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                            .font(.body)
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.11))
    }
}

// MARK: - Floating tab bar

enum MainTab: String, CaseIterable, Identifiable {
    case board, discover, library, addons, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: return "Board"
        case .discover: return "Discover"
        case .library: return "Library"
        case .addons: return "Addons"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .board: return "house"
        case .discover: return "safari"
        case .library: return "square.stack"
        case .addons: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .board: return "house.fill"
        case .discover: return "safari.fill"
        case .library: return "square.stack.fill"
        case .addons: return "puzzlepiece.extension.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct FloatingTabBar: View {
    @Binding var selection: MainTab
    /// Tapping the current tab again pops it back to its first screen.
    var onReselect: (MainTab) -> Void = { _ in }
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    if selected { onReselect(tab) }
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selected ? tab.selectedSymbol : tab.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selected ? Theme.accent : Color.primary.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                                .matchedGeometryEffect(id: "tab", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .frame(maxWidth: 440)
        .padding(.horizontal, 20)
    }
}
