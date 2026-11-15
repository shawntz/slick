import Foundation
import Kit

/// Offers to open a typed web address, at the top of root search. Runs on the main thread inside
/// the keystroke, so it does only what ``AddressDetector`` does: no I/O, no locks, and nil at once
/// for ordinary words.
final class AddressProvider: InstantProvider {
    /// The namespace of address rows: `web-address:<link>`.
    static let rowNamespace = "web-address"

    private unowned let feature: QuicklinksFeature

    init(feature: QuicklinksFeature) {
        self.feature = feature
    }

    let namespace = AddressProvider.rowNamespace

    func answer(for query: String) -> InstantAnswer? {
        guard let address = AddressDetector.detect(query) else { return nil }
        return InstantAnswer(rows: [Self.row(for: address, typed: query)], claimsTop: true)
    }

    /// The row stands for its link, so other features' actions for links are offered on it too. Root
    /// keeps nothing: the row answers one query.
    static func row(for address: AddressDetector.Address, typed: String) -> Row {
        let link = address.url.absoluteString
        return Row(
            id: ItemID(rowNamespace, link), title: Strings.openAddress(typed.trimmingCharacters(in: .whitespaces)),
            subtitle: link, icon: .favicon(domain: address.host), memory: .never, represents: .url(address.url))
    }

    /// Built from the row's key, which is the link.
    func actions(for row: Row) -> [Action] {
        guard let url = URL(string: row.id.key) else { return [] }
        return feature.actions.addressActions(for: url)
    }
}
