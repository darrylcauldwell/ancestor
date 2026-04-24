import Foundation

/// Compares two FamilyGraphSnapshots and produces a visual diff.
/// Used after WikiTree refresh to show what changed before committing.
nonisolated struct DiffEngine {

    nonisolated struct DiffResult: Sendable {
        let added: [Profile]
        let removed: [Profile]
        let modified: [ProfileDiff]
        let relationshipsAdded: [Relationship]
        let relationshipsRemoved: [Relationship]

        var isEmpty: Bool {
            added.isEmpty && removed.isEmpty && modified.isEmpty &&
            relationshipsAdded.isEmpty && relationshipsRemoved.isEmpty
        }

        var changeCount: Int {
            added.count + removed.count + modified.count +
            relationshipsAdded.count + relationshipsRemoved.count
        }
    }

    nonisolated struct ProfileDiff: Identifiable, Sendable {
        let id: String
        let profile: Profile
        let fieldChanges: [FieldDiff]
    }

    nonisolated struct FieldDiff: Identifiable, Sendable {
        var id: String { field.rawValue }
        let field: ProfileField
        let oldValue: String?
        let newValue: String?
    }

    /// Compare old snapshot against new snapshot.
    static func diff(old: FamilyGraphSnapshot, new: FamilyGraphSnapshot) -> DiffResult {
        let oldIDs = Set(old.profiles.keys)
        let newIDs = Set(new.profiles.keys)

        // Added profiles
        let addedIDs = newIDs.subtracting(oldIDs)
        let added = addedIDs.compactMap { new.profiles[$0] }

        // Removed profiles
        let removedIDs = oldIDs.subtracting(newIDs)
        let removed = removedIDs.compactMap { old.profiles[$0] }

        // Modified profiles
        let commonIDs = oldIDs.intersection(newIDs)
        var modified: [ProfileDiff] = []

        for id in commonIDs {
            guard let oldProfile = old.profiles[id],
                  let newProfile = new.profiles[id] else { continue }

            let fieldChanges = diffProfile(old: oldProfile, new: newProfile)
            if !fieldChanges.isEmpty {
                modified.append(ProfileDiff(
                    id: id, profile: newProfile, fieldChanges: fieldChanges
                ))
            }
        }

        // Relationship diffs
        let oldRelSet = Set(old.relationships.map { RelKey(from: $0.from, to: $0.to, type: $0.type) })
        let newRelSet = Set(new.relationships.map { RelKey(from: $0.from, to: $0.to, type: $0.type) })

        let addedRelKeys = newRelSet.subtracting(oldRelSet)
        let removedRelKeys = oldRelSet.subtracting(newRelSet)

        let relationshipsAdded = new.relationships.filter { rel in
            addedRelKeys.contains(RelKey(from: rel.from, to: rel.to, type: rel.type))
        }
        let relationshipsRemoved = old.relationships.filter { rel in
            removedRelKeys.contains(RelKey(from: rel.from, to: rel.to, type: rel.type))
        }

        return DiffResult(
            added: added, removed: removed, modified: modified,
            relationshipsAdded: relationshipsAdded,
            relationshipsRemoved: relationshipsRemoved
        )
    }

    /// Compare two profiles field by field.
    private static func diffProfile(old: Profile, new: Profile) -> [FieldDiff] {
        var diffs: [FieldDiff] = []

        if old.firstName != new.firstName {
            diffs.append(FieldDiff(field: .firstName, oldValue: old.firstName, newValue: new.firstName))
        }
        if old.lastName != new.lastName {
            diffs.append(FieldDiff(field: .lastName, oldValue: old.lastName, newValue: new.lastName))
        }
        if old.birthDate?.original != new.birthDate?.original {
            diffs.append(FieldDiff(field: .birthDate, oldValue: old.birthDate?.original, newValue: new.birthDate?.original))
        }
        if old.birthLocation != new.birthLocation {
            diffs.append(FieldDiff(field: .birthLocation, oldValue: old.birthLocation, newValue: new.birthLocation))
        }
        if old.deathDate?.original != new.deathDate?.original {
            diffs.append(FieldDiff(field: .deathDate, oldValue: old.deathDate?.original, newValue: new.deathDate?.original))
        }
        if old.deathLocation != new.deathLocation {
            diffs.append(FieldDiff(field: .deathLocation, oldValue: old.deathLocation, newValue: new.deathLocation))
        }
        if old.bio != new.bio {
            diffs.append(FieldDiff(field: .bio, oldValue: old.bio != nil ? "(bio changed)" : nil, newValue: new.bio != nil ? "(bio changed)" : nil))
        }

        return diffs
    }

    /// Hashable key for relationship comparison.
    private struct RelKey: Hashable {
        let from: String
        let to: String
        let type: RelationshipType
    }
}
