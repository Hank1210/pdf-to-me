import Foundation

/// Eine umkehrbare Änderung an einem `DocumentPlan`.
///
/// Jede Operation enthält genug Daten, um sie rückgängig zu machen, ohne den Ausgangszustand neu zu berechnen.
/// Operationen entstehen nur über die Methoden von `DocumentPlan` (`insert`, `remove`, `move`, `rotate`), damit
/// ihre Daten zum Plan passen. Sie liegen in den Undo- und Redo-Stapeln und werden mit der Sitzung gesichert.
public enum PlanOperation: Codable, Hashable, Sendable {
    /// Seiten an `position` einfügen; `addedSources` sind dabei neu hinzugekommene Quellen (Zusammenführen).
    case insert(pages: [PageRef], position: Int, addedSources: [SourceFile])
    /// Seiten entfernen. `positions` sind ihre Positionen vorher, aufsteigend und parallel zu `pages`.
    case remove(pages: [PageRef], positions: [Int])
    /// Seiten verschieben. `from` sind ihre Positionen vorher (aufsteigend, parallel zu `ids`), `to` die
    /// Einfügestelle in der Liste vorher (0…Anzahl, „vor der Seite an `to`“).
    case move(ids: [PageRef.ID], from: [Int], to: Int)
    /// Seiten im Uhrzeigersinn drehen.
    case rotate(ids: [PageRef.ID], by: Rotation)

    // MARK: Anwenden und Umkehren

    // Beide Funktionen prüfen, ob die Operation zum Zustand passt, und werfen sonst. Sie arbeiten auf Kopien,
    // die erst nach erfolgreicher Prüfung übernommen werden (siehe `DocumentPlan.perform`).

    func apply(sources: inout [SourceFile], pages: inout [PageRef]) throws {
        try checkShape()
        switch self {
        case let .insert(newPages, position, addedSources):
            guard (0...pages.count).contains(position) else {
                throw DocumentPlanError.positionOutOfRange(position: position, count: pages.count)
            }
            sources.append(contentsOf: addedSources)
            pages.insert(contentsOf: newPages, at: position)

        case let .remove(removed, positions):
            try Self.check(removed.map(\.id), at: positions, in: pages)
            for position in positions.reversed() {
                pages.remove(at: position)
            }

        case let .move(ids, from, to):
            guard (0...pages.count).contains(to) else {
                throw DocumentPlanError.positionOutOfRange(position: to, count: pages.count)
            }
            try Self.check(ids, at: from, in: pages)
            let moved = from.map { pages[$0] }
            for position in from.reversed() {
                pages.remove(at: position)
            }
            let target = to - from.filter { $0 < to }.count
            pages.insert(contentsOf: moved, at: target)

        case let .rotate(ids, rotation):
            try Self.rotate(ids, by: rotation, in: &pages)
        }
    }

    func revert(sources: inout [SourceFile], pages: inout [PageRef]) throws {
        try checkShape()
        switch self {
        case let .insert(newPages, position, addedSources):
            let range = position..<(position + newPages.count)
            try Self.check(newPages.map(\.id), at: Array(range), in: pages)
            pages.removeSubrange(range)
            // Hinzugefügte Quellen stehen am Ende der Liste.
            let addedIDs = addedSources.map(\.id)
            guard sources.suffix(addedIDs.count).map(\.id) == addedIDs else {
                throw DocumentPlanError.historyMismatch
            }
            sources.removeLast(addedIDs.count)

        case let .remove(removed, positions):
            for (page, position) in zip(removed, positions) {
                guard position <= pages.count else { throw DocumentPlanError.historyMismatch }
                pages.insert(page, at: position)
            }

        case let .move(ids, from, to):
            let target = to - from.filter { $0 < to }.count
            let range = target..<(target + ids.count)
            try Self.check(ids, at: Array(range), in: pages)
            let moved = Array(pages[range])
            pages.removeSubrange(range)
            for (page, position) in zip(moved, from) {
                guard position <= pages.count else { throw DocumentPlanError.historyMismatch }
                pages.insert(page, at: position)
            }

        case let .rotate(ids, rotation):
            try Self.rotate(ids, by: rotation.inverse, in: &pages)
        }
    }

    // MARK: Hilfen

    /// Prüft die innere Form, bevor etwas angewendet wird: gleich viele Kennungen wie Positionen, Positionen
    /// streng aufsteigend. Gesicherte Operationen stammen aus einer Datei und könnten beschädigt sein.
    private func checkShape() throws {
        let (count, positions): (Int, [Int])
        switch self {
        case .insert, .rotate:
            return
        case let .remove(pages, from):
            (count, positions) = (pages.count, from)
        case let .move(ids, from, _):
            (count, positions) = (ids.count, from)
        }
        guard count == positions.count, zip(positions, positions.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw DocumentPlanError.historyMismatch
        }
    }

    /// Prüft, ob an den Positionen genau diese Seiten stehen.
    private static func check(_ ids: [PageRef.ID], at positions: [Int], in pages: [PageRef]) throws {
        guard ids.count == positions.count,
              zip(ids, positions).allSatisfy({ pages.indices.contains($1) && pages[$1].id == $0 })
        else { throw DocumentPlanError.historyMismatch }
    }

    private static func rotate(_ ids: [PageRef.ID], by rotation: Rotation, in pages: inout [PageRef]) throws {
        for id in ids {
            guard let position = pages.firstIndex(where: { $0.id == id }) else {
                throw DocumentPlanError.unknownPage(id)
            }
            pages[position].rotation = pages[position].rotation.rotated(by: rotation)
        }
    }
}
