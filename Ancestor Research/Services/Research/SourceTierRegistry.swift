import Foundation

/// Maps URL domains to trust tiers and evidence directness.
/// The Field Researcher's contribution is trusted as much as the source
/// it cited, not more and not less. Unknown domains default to community/derivative.
nonisolated struct SourceTierRegistry {

    /// Look up the trust tier for a URL.
    static func lookup(url: String) -> SourceTierEntry {
        guard let host = extractHost(from: url) else {
            return .unknown
        }
        let normalised = host.lowercased()
            .replacingOccurrences(of: "www.", with: "")

        // Exact match first
        if let entry = entries[normalised] {
            return entry
        }

        // Subdomain match (e.g. discovery.nationalarchives.gov.uk → nationalarchives.gov.uk)
        for (domain, entry) in entries {
            if normalised.hasSuffix(".\(domain)") || normalised == domain {
                return entry
            }
        }

        return .unknown
    }

    /// Check if a URL is from a restricted (paywalled/licenced) source.
    static func isRestricted(url: String) -> Bool {
        let entry = lookup(url: url)
        return entry.restricted
    }

    // MARK: - Host Extraction

    private static func extractHost(from urlString: String) -> String? {
        if let url = URL(string: urlString) {
            return url.host
        }
        // Fallback: strip protocol and path
        var s = urlString
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if let range = s.range(of: "/") { s = String(s[..<range.lowerBound]) }
        return s.isEmpty ? nil : s
    }

    // MARK: - Registry

    /// Hand-curated registry of known genealogy domains.
    /// Grows over time as the Field Researcher encounters new sites.
    private static let entries: [String: SourceTierEntry] = [
        // Official archives — primary trust
        "cwgc.org": .init(
            trustTier: .primary, directness: .primary,
            category: .officialArchive, restricted: false,
            description: "Commonwealth War Graves Commission"),
        "probatesearch.service.gov.uk": .init(
            trustTier: .primary, directness: .primary,
            category: .officialArchive, restricted: false,
            description: "HMCTS Probate Calendar"),
        "nationalarchives.gov.uk": .init(
            trustTier: .primary, directness: .primary,
            category: .officialArchive, restricted: false,
            description: "The National Archives"),
        "legislation.gov.uk": .init(
            trustTier: .primary, directness: .primary,
            category: .officialArchive, restricted: false,
            description: "UK legislation"),

        // Volunteer transcription projects — transcription trust
        "freebmd.org.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .volunteerTranscription, restricted: false,
            description: "FreeBMD — GRO civil registration indexes"),
        "freecen.org.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .volunteerTranscription, restricted: false,
            description: "FreeCen — census transcriptions"),
        "freereg.org.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .volunteerTranscription, restricted: false,
            description: "FreeREG — parish register transcriptions"),
        "wirksworth.org.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .volunteerTranscription, restricted: false,
            description: "Wirksworth parish records and pedigrees"),
        "genuki.org.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .academicResource, restricted: false,
            description: "UK genealogical information service"),
        "archive.org": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .academicResource, restricted: false,
            description: "Internet Archive — digitised historical documents"),
        "onlineparishclerks.org.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .volunteerTranscription, restricted: false,
            description: "Online Parish Clerks — volunteer transcriptions"),
        "dustydocs.com": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .volunteerTranscription, restricted: false,
            description: "Derbyshire parish register transcriptions"),
        "derbyshire-opc.org.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .volunteerTranscription, restricted: false,
            description: "Derbyshire Online Parish Clerks"),

        // Commercial providers — transcription trust, restricted access
        "ancestry.co.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .commercialProvider, restricted: true,
            description: "Ancestry — subscription genealogy service"),
        "ancestry.com": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .commercialProvider, restricted: true,
            description: "Ancestry — subscription genealogy service"),
        "findmypast.co.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .commercialProvider, restricted: true,
            description: "FindMyPast — subscription genealogy service"),
        "britishnewspaperarchive.co.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .commercialProvider, restricted: true,
            description: "British Newspaper Archive — paywalled"),
        "thegenealogist.co.uk": .init(
            trustTier: .transcription, directness: .directTranscription,
            category: .commercialProvider, restricted: true,
            description: "TheGenealogist — subscription service"),

        // Community — community trust, derivative
        "findagrave.com": .init(
            trustTier: .community, directness: .derivative,
            category: .communityCompilation, restricted: false,
            description: "Find a Grave — volunteer-submitted memorials"),
        "familysearch.org": .init(
            trustTier: .community, directness: .derivative,
            category: .communityCompilation, restricted: false,
            description: "FamilySearch — community-edited tree and records"),
        "wikitree.com": .init(
            trustTier: .community, directness: .derivative,
            category: .communityCompilation, restricted: false,
            description: "WikiTree — collaborative family tree"),
        "geni.com": .init(
            trustTier: .community, directness: .derivative,
            category: .communityCompilation, restricted: false,
            description: "Geni — collaborative family tree"),
        "rootschat.com": .init(
            trustTier: .community, directness: .derivative,
            category: .communityCompilation, restricted: false,
            description: "RootsChat — genealogy forum"),
        "rootsweb.com": .init(
            trustTier: .community, directness: .derivative,
            category: .communityCompilation, restricted: false,
            description: "RootsWeb — genealogy mailing lists and trees"),

        // Blocked (not in entries — handled by isBlocked)
    ]

    /// URLs that should never be accepted as evidence sources.
    static func isBlocked(url: String) -> (blocked: Bool, reason: String) {
        guard let host = extractHost(from: url)?.lowercased().replacingOccurrences(of: "www.", with: "") else {
            return (true, "invalid URL")
        }

        // Social media
        let socialMedia = ["facebook.com", "twitter.com", "x.com", "reddit.com",
                           "instagram.com", "tiktok.com", "youtube.com"]
        if socialMedia.contains(where: { host.hasSuffix($0) }) {
            return (true, "social media is not a genealogical source")
        }

        // AI content generators
        let aiSites = ["chatgpt.com", "claude.ai", "perplexity.ai", "bard.google.com"]
        if aiSites.contains(where: { host.hasSuffix($0) }) {
            return (true, "AI-generated content is not a primary source")
        }

        return (false, "")
    }
}

/// A single entry in the Source Tier Registry.
nonisolated struct SourceTierEntry: Sendable {
    let trustTier: SourceTrustTier
    let directness: EvidenceDirectness
    let category: SourceCategory
    let restricted: Bool
    let description: String

    /// Default for unknown domains.
    static let unknown = SourceTierEntry(
        trustTier: .community, directness: .derivative,
        category: .unknown, restricted: false,
        description: "Unknown source"
    )
}

/// Category of a genealogical source.
nonisolated enum SourceCategory: String, Sendable {
    case officialArchive
    case volunteerTranscription
    case communityCompilation
    case commercialProvider
    case academicResource
    case unknown
}
