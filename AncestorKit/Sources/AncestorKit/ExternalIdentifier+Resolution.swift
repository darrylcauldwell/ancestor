import Foundation

/// Collection-level operations on a profile's `[ExternalIdentifier]`: the
/// `externalIDs` projection, deprecation-chain resolution, and the idempotent
/// merge used by the `externalIDs` setter and ingest.
///
/// Kept as free functions on `Array` (not baked into `Profile`) so they are
/// unit-testable in isolation and reusable by ingest/manual-entry paths that
/// assemble identifier lists before a `Profile` exists.
public extension Array where Element == ExternalIdentifier {

    /// The `[String: String]` projection: current primary value per system.
    ///
    /// This is the backwards-compatible face of the old
    /// `Profile.externalIDs`. For each system it surfaces the `.primary`
    /// record's value; if a system has no `.primary` (only `.persistent`
    /// and/or `.deprecated` records) it falls back to a `.persistent` value,
    /// then to the resolved survivor of a `.deprecated` chain — so a lookup
    /// never silently vanishes. Systems with only unresolvable deprecated
    /// records are omitted (the old dict couldn't represent them either).
    var primaryValuesBySystem: [String: String] {
        var result: [String: String] = [:]
        // Group by system, preserving deterministic winner selection.
        for system in Set(map(\.system)) {
            let forSystem = filter { $0.system == system }
            if let primary = forSystem.first(where: { $0.kind == .primary }) {
                result[system] = primary.value
            } else if let persistent = forSystem.first(where: { $0.kind == .persistent }) {
                result[system] = persistent.value
            } else if let survivor = forSystem
                .compactMap({ resolveCurrentValue(from: $0.value, system: system) })
                .first {
                result[system] = survivor
            }
        }
        return result
    }

    /// Follow the append-only supersession chain from `value` within `system`
    /// to the current (non-deprecated) identifier value. Returns the input
    /// unchanged when it is already current or not present as a deprecated
    /// record; returns `nil` only when the chain dead-ends at a `.deprecated`
    /// record whose `supersededBy` is `nil` (merged away, survivor unknown).
    ///
    /// Guards against cyclic/self-referential chains (append-only discipline
    /// should prevent them, but a corrupt row must not spin) by bounding the
    /// walk to the number of records for the system.
    func resolveCurrentValue(from value: String, system: String) -> String? {
        let forSystem = filter { $0.system == system }
        var current = value
        var seen: Set<String> = []
        var steps = 0
        while steps <= forSystem.count {
            steps += 1
            guard !seen.contains(current) else { return current } // cycle guard
            seen.insert(current)
            // Is `current` a deprecated record pointing elsewhere?
            guard let record = forSystem.first(where: { $0.value == current }) else {
                // `current` isn't a stored record for this system — treat it
                // as a live external value (e.g. the survivor we were pointed
                // to but never stored a row for).
                return current
            }
            if record.kind == .deprecated {
                guard let next = record.supersededBy else { return nil } // dead end
                current = next
                continue
            }
            return current // reached a primary/persistent record
        }
        return current
    }

    /// Idempotent upsert of a `(system, value)` primary. Recording the same
    /// `(system, value)` twice is a no-op (acceptance criterion 2). If a
    /// *different* value is already `.primary` for the system, the existing
    /// primary is left in place and the new one is NOT auto-added as primary —
    /// promoting a second primary is a deliberate act, not a side effect of a
    /// string-map merge. (The string-map setter, which cannot express intent,
    /// uses `settingPrimary` below instead.)
    func upsertingPrimary(system: String, value: String) -> [ExternalIdentifier] {
        if contains(where: { $0.system == system && $0.value == value }) {
            return self // idempotent — already present in any kind
        }
        var copy = self
        copy.append(ExternalIdentifier(system: system, value: value, kind: .primary))
        return copy
    }

    /// Mark `value` deprecated within `system`, forwarding to `survivor`.
    /// Idempotent: if the record is already deprecated to the same survivor,
    /// no change. Appends a fresh `.deprecated` record if `value` was not
    /// previously present. Chains stay append-only — an existing record's
    /// value is never rewritten, only its `kind`/`supersededBy` flipped.
    func deprecating(system: String, value: String, supersededBy survivor: String) -> [ExternalIdentifier] {
        var copy = self
        if let idx = copy.firstIndex(where: { $0.system == system && $0.value == value }) {
            if copy[idx].kind == .deprecated && copy[idx].supersededBy == survivor { return copy }
            copy[idx].kind = .deprecated
            copy[idx].supersededBy = survivor
        } else {
            copy.append(ExternalIdentifier(
                system: system, value: value, kind: .deprecated, supersededBy: survivor))
        }
        return copy
    }
}

/// Bridge between the legacy `[String: String]` shape and the record list.
public extension Array where Element == ExternalIdentifier {

    /// Build a record list from a legacy `[String: String]` map — every entry
    /// becomes a `.primary` record (the migration/backfill rule). Order is
    /// stable (sorted by system) so encodes are deterministic across runs.
    init(legacy map: [String: String]) {
        self = map
            .sorted { $0.key < $1.key }
            .map { ExternalIdentifier(system: $0.key, value: $0.value, kind: .primary) }
    }

    /// Merge a legacy `[String: String]` map into an existing record list,
    /// used by the `externalIDs` *setter* so assigning through the projection
    /// stays lossless for records the map cannot express (deprecated /
    /// persistent). For each `(system, value)`:
    /// - if that exact `(system, value)` already exists, leave it;
    /// - else set it as the system's primary, demoting any *stale* prior
    ///   primary for that system to `.persistent` (preserving it, since the
    ///   old dict would have overwritten and lost it — stash-don't-destroy).
    /// Records for systems absent from the map are untouched.
    func mergingLegacyMap(_ map: [String: String]) -> [ExternalIdentifier] {
        var copy = self
        for (system, value) in map.sorted(by: { $0.key < $1.key }) {
            if copy.contains(where: { $0.system == system && $0.value == value }) {
                // Ensure the matching record is the primary if a different
                // stale primary exists for the system.
                if let existingPrimaryIdx = copy.firstIndex(where: {
                    $0.system == system && $0.kind == .primary && $0.value != value
                }) {
                    copy[existingPrimaryIdx].kind = .persistent
                    if let idx = copy.firstIndex(where: { $0.system == system && $0.value == value }) {
                        copy[idx].kind = .primary
                    }
                }
                continue
            }
            // New value for the system.
            if let existingPrimaryIdx = copy.firstIndex(where: {
                $0.system == system && $0.kind == .primary
            }) {
                copy[existingPrimaryIdx].kind = .persistent
            }
            copy.append(ExternalIdentifier(system: system, value: value, kind: .primary))
        }
        return copy
    }
}
