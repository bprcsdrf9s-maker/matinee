import Foundation
import Observation

/// Loads the Board's catalog rows.
@MainActor
@Observable
final class HomeModel {
    struct Row: Identifiable {
        let addon: AddonDescriptor
        let catalog: ManifestCatalog
        var items: [MetaItem]
        var id: String { addon.transportUrl + "|" + catalog.type + "|" + catalog.id }
        var title: String { catalog.title(addonName: addon.manifest.name) }
    }

    private(set) var rows: [Row] = []
    private(set) var loading = false
    @ObservationIgnored private var loadedKey = ""

    func load(_ boards: [(addon: AddonDescriptor, catalog: ManifestCatalog)], force: Bool = false) async {
        let key = boards.map { $0.addon.transportUrl + $0.catalog.id + $0.catalog.type }.joined()
        guard force || key != loadedKey, !boards.isEmpty else { return }
        loadedKey = key
        loading = rows.isEmpty
        let results = await withTaskGroup(of: (Int, [MetaItem]).self) { group in
            for (i, board) in boards.enumerated() {
                group.addTask {
                    let items = (try? await AddonClient.catalog(board.addon, board.catalog)) ?? []
                    return (i, items)
                }
            }
            var out: [(Int, [MetaItem])] = []
            for await r in group { out.append(r) }
            return out
        }
        let byIndex = Dictionary(uniqueKeysWithValues: results)
        rows = boards.enumerated().compactMap { i, board in
            guard let items = byIndex[i], !items.isEmpty else { return nil }
            return Row(addon: board.addon, catalog: board.catalog, items: items)
        }
        loading = false
    }
}
