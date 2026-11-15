import Foundation

extension Array {
    /// Moves the elements at `offsets` so they sit before `destination`, as a list's drag and drop
    /// reports it.
    mutating func reorder(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.compactMap { indices.contains($0) ? self[$0] : nil }
        let before = offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) where indices.contains(index) { remove(at: index) }
        insert(contentsOf: moving, at: Swift.min(Swift.max(destination - before, 0), count))
    }
}
