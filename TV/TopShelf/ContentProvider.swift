import TVServices

/// The app's Top Shelf: its Continue watching and Next up, as the app last saw them. Selecting a title
/// opens its page; Play plays it.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let shelf = TopShelfStore.load() else { return completionHandler(nil) }
        let sections = shelf.sections.compactMap { section -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            let items = section.entries.map { entry -> TVTopShelfSectionedItem in
                let item = TVTopShelfSectionedItem(identifier: entry.id)
                item.title = entry.title
                item.imageShape = .hdtv
                if let image = entry.image {
                    item.setImageURL(image, for: .screenScale1x)
                    item.setImageURL(image, for: .screenScale2x)
                }
                if let progress = entry.progress { item.playbackProgress = progress }
                if let open = TopShelfStore.openURL(entry.id) { item.displayAction = TVTopShelfAction(url: open) }
                if let play = TopShelfStore.playURL(entry.id) { item.playAction = TVTopShelfAction(url: play) }
                return item
            }
            guard !items.isEmpty else { return nil }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }
}
