import Foundation

/// CONFLICT_LAYER_SPEC §4.1 C1 — witness identity ⟨G1⟩⟨G4⟩⟨G9⟩.
///
/// A WitnessKey identifies the UNDERLYING ORIGINAL register entry an
/// attestation transcribes. Two attestations with the same witness are ONE
/// witness — FreeBMD's "SMITH John, Belper Q2 1860 7b/143", FamilySearch's
/// vol-less transcription of the same GRO line, and a FindAGrave copy of
/// the same index row corroborate NOTHING between them (DS-03).
///
/// ⟨G9⟩ Deliberately **not Codable** — keys are COMPUTED from record
/// fields, never persisted; a stored key would be a second source of truth
/// that silently rots when derivation improves.
///
/// Matching is CONSERVATIVE (§4.1): components that are mutually non-nil
/// must agree; a missing component MATCHES a present one. When
/// independence cannot be proven, it is not counted — the safe direction
/// for corroboration (mirrors when-in-doubt-split).
public nonisolated struct WitnessKey: Hashable, Sendable {

    /// The original-record space this attestation transcribes, derived
    /// from the source's lineage (⟨G4⟩: FreeBMD declares
    /// `independentTranscription(of: "GRO-indexes")`; FamilySearch E&W BMD
    /// collections map statically to the same space) — never from LLM
    /// output.
    public enum ArchiveClass: Hashable, Sendable {
        case groIndex                    // E&W civil-registration indexes
        case censusEnumeration(Int)      // one person, one enumeration per year
        case parishRegister(String?)     // keyed by parish where known
        case cwgcRegister                // independent war-graves register
        case probateCalendar
        case memorial(String)            // headstone/memorial content — per-record
    }

    public let archiveClass: ArchiveClass
    public let eventShape: String        // "birth"/"death"/"marriage"/"census"/…
    public let year: Int?
    public let quarter: String?
    public let district: String?
    public let volume: String?
    public let page: String?
    /// ⟨G1⟩ A GRO vol/page identifies an index PAGE holding 2–4 entries,
    /// not a single line — name components split siblings sharing a page.
    public let surnameNorm: String?
    public let givenInitial: String?
}

public nonisolated enum WitnessIdentity {

    /// Static source → original-record-space mapping ⟨G4⟩. FreeBMD's is
    /// read straight off its declared lineage payload; FamilySearch's E&W
    /// index collections and FindAGrave's index-derived death rows map to
    /// the same GRO space (their BMD data transcribes the same indexes).
    /// CWGC is its own register (independent primary); parish sources key
    /// by parish; census sources by enumeration year.
    static let groTranscribers: Set<String> = ["freebmd", "familysearch", "findagrave"]

    /// Derive the witness key for a record. Deterministic, content-only.
    public static func key(for record: SourceRecord) -> WitnessKey {
        let sourceID = record.common.sourceID
        let surnameNorm = record.common.surname?
            .uppercased().trimmingCharacters(in: .whitespaces)
        let givenInitial = record.common.givenName?
            .trimmingCharacters(in: .whitespaces).uppercased().first.map(String.init)

        func norm(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s.uppercased()
                .trimmingCharacters(in: .whitespaces)
                .drop(while: { $0 == "0" })
                .description
        }

        switch record {
        case .birth(let r):
            return WitnessKey(
                archiveClass: groTranscribers.contains(sourceID) ? .groIndex : .groIndex,
                eventShape: "birth", year: r.birthYear,
                quarter: norm(r.quarter), district: norm(r.district),
                volume: norm(r.volume), page: norm(r.page),
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        case .death(let r):
            // CWGC's register is an independent primary, never a GRO copy.
            let archive: WitnessKey.ArchiveClass = sourceID == "cwgc" ? .cwgcRegister : .groIndex
            return WitnessKey(
                archiveClass: archive,
                eventShape: "death", year: r.deathYear,
                quarter: norm(r.quarter), district: norm(r.district),
                volume: norm(r.volume), page: norm(r.page),
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        case .marriage(let r):
            return WitnessKey(
                archiveClass: .groIndex,
                eventShape: "marriage", year: r.marriageYear,
                quarter: norm(r.quarter), district: norm(r.district),
                volume: norm(r.volume), page: norm(r.page),
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        case .census(let r):
            // One person is enumerated once per census year: same year =
            // same witness for the subject, regardless of transcriber.
            return WitnessKey(
                archiveClass: .censusEnumeration(r.censusYear),
                eventShape: "census", year: r.censusYear,
                quarter: nil, district: norm(r.district),
                volume: nil, page: nil,
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        case .parish(let r):
            return WitnessKey(
                archiveClass: .parishRegister(r.parish?.uppercased()),
                eventShape: (r.eventType ?? "parish").lowercased(),
                year: r.eventYear,
                quarter: nil, district: nil, volume: nil, page: nil,
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        case .burial(let r):
            // Memorial content (headstone transcription) is genuinely its
            // own witness — per-record identity.
            return WitnessKey(
                archiveClass: .memorial(record.common.id),
                eventShape: "burial", year: r.deathYear,
                quarter: nil, district: nil, volume: nil, page: nil,
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        case .probate(let r):
            return WitnessKey(
                archiveClass: .probateCalendar,
                eventShape: "probate", year: r.deathYear,
                quarter: nil, district: nil, volume: nil, page: nil,
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        default:
            return WitnessKey(
                archiveClass: .memorial(record.common.id),
                eventShape: "other", year: nil,
                quarter: nil, district: nil, volume: nil, page: nil,
                surnameNorm: surnameNorm, givenInitial: givenInitial)
        }
    }

    /// Conservative same-witness test (§4.1): archive class and event
    /// shape must agree exactly; every other component must agree when
    /// BOTH sides carry it (mutually non-nil), and a missing component
    /// matches a present one. Census enumeration identity rides entirely
    /// on the archive class (year is inside it).
    public static func sameWitness(_ a: WitnessKey, _ b: WitnessKey) -> Bool {
        guard a.archiveClass == b.archiveClass, a.eventShape == b.eventShape else { return false }
        func agree<T: Equatable>(_ x: T?, _ y: T?) -> Bool {
            guard let x, let y else { return true }
            return x == y
        }
        return agree(a.year, b.year)
            && agree(a.quarter, b.quarter)
            && agree(a.district, b.district)
            && agree(a.volume, b.volume)
            && agree(a.page, b.page)
            && agree(a.surnameNorm, b.surnameNorm)
            && agree(a.givenInitial, b.givenInitial)
    }

    /// Group records into witness families (greedy union against family
    /// representatives) and return one representative per family.
    public static func witnessRepresentatives(of records: [SourceRecord]) -> [SourceRecord] {
        var representatives: [(key: WitnessKey, record: SourceRecord)] = []
        for record in records {
            let k = key(for: record)
            if !representatives.contains(where: { sameWitness($0.key, k) }) {
                representatives.append((k, record))
            }
        }
        return representatives.map(\.record)
    }

    /// The number of INDEPENDENT witnesses among these records — what
    /// convergence may legitimately count (DS-03).
    public static func independentWitnessCount(of records: [SourceRecord]) -> Int {
        witnessRepresentatives(of: records).count
    }
}
