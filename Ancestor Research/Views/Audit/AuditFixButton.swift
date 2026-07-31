import SwiftUI

/// The per-rule one-click fix for an audit finding — extracted from the
/// Health screen so the profile card's Health strip offers the SAME fixes
/// (owner request 2026-07-31: everything actionable visible where the
/// person is). One switch, two hosts; the closures are the only
/// host-specific behaviour:
///  - `onFixed` — refresh the host's finding list after a write.
///  - `onCompare` — open the host's compare sheet for duplicate pairs;
///    nil (the profile card) falls back to a "Review in Health" jump,
///    keeping merge judgement in the full-context surface.
///  - `onEnriched` — the FreeBMD-enrich success launchpad (Health's
///    research/open dialog); nil falls back to a success message.
struct AuditFixButton: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry

    let result: AuditResult
    var onFixed: () -> Void = {}
    var onCompare: ((_ leftID: String, _ rightID: String) -> Void)? = nil
    var onEnriched: ((_ profileID: String, _ profileName: String, _ count: Int) -> Void)? = nil

    var body: some View {
        switch result.ruleID {
        case "fertilityGap":
            // No deterministic data-fix exists (the missing children's
            // names are unknown) — the affordance is a research launch.
            Button {
                appState.researchProfileID = result.profileID
            } label: {
                Label("Research", systemImage: "magnifyingglass")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Search the record sources for the children her 1911 census statement says are missing from the tree")
        case "marriedSurnameFromSpouse":
            if let her = appState.snapshot.profiles[result.profileID],
               let s = MarriedSurnameFromSpouseRule.suggestion(for: her, in: appState.snapshot) {
                Button {
                    appState.setMarriedSurname(profileID: result.profileID, surname: s.marriedSurname)
                    onFixed()
                } label: {
                    Label("Set “\(s.marriedSurname)”", systemImage: "person.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Record \(s.marriedSurname) as her married surname so research finds her death and probate records")
            }
        case "censusAgeBirthYear":
            if let t = appState.snapshot.profiles[result.profileID],
               let s = CensusAgeBirthYearRule.suggestion(for: t, in: appState.snapshot) {
                Button {
                    appState.setBirthYearFromCensus(profileID: result.profileID, year: s.year, censusYear: s.censusYear, sourceID: s.sourceID)
                    onFixed()
                } label: {
                    Label("Set birth year ~\(String(s.year))", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
            }
        case "freebmdLinkMissing":
            // Targeted, budget-light: re-locate this person's FreeBMD entries
            // by vol/page (one narrow query each) to capture the link + the
            // mother's maiden name. Stops the moment FreeBMD throttles.
            if let db = appState.currentDatabase {
                Button {
                    Task {
                        let outcome = await FreeBMDCitationEnricher.enrich(
                            profileID: result.profileID, registry: registry, db: db)
                        appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
                        appState.runPostLoadAudit()
                        onFixed()
                        // Report the ACTUAL outcome, not a catch-all "no match".
                        if outcome.throttled {
                            appState.errorMessage = "FreeBMD is rate-limiting — enriched \(outcome.enriched) here; try again when it clears (usually minutes)."
                        } else if let reason = outcome.unavailableReason {
                            appState.errorMessage = "FreeBMD couldn't run the lookup for \(result.profileName): \(reason). Try again later."
                        } else if outcome.enriched > 0 {
                            if let onEnriched {
                                onEnriched(result.profileID, result.profileName, outcome.enriched)
                            } else {
                                appState.successMessage = "Enriched \(outcome.enriched) FreeBMD link\(outcome.enriched == 1 ? "" : "s") for \(result.profileName) — the mother's maiden name may unlock new parents on the next research."
                                appState.successResearchProfileID = result.profileID
                            }
                        } else if outcome.queriesRun == 0 {
                            appState.errorMessage = "\(result.profileName)'s FreeBMD records carry no volume/page, so there's nothing to re-locate. The missing link is only provenance."
                        } else {
                            appState.errorMessage = "FreeBMD returned no matching entry for \(result.profileName) — the stored record may be a transcription that no longer resolves. Not a data error; the missing link is only provenance."
                        }
                    }
                } label: {
                    Label("Enrich from FreeBMD", systemImage: "link.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("One narrow vol/page query per record — captures the citation link and the mother's maiden name (which can surface new parents on the next research). Gentle on FreeBMD; stops if throttled.")
            }
        case "duplicateDetection":
            if let otherID = result.relatedProfileIDs?.first {
                HStack(spacing: 6) {
                    if let onCompare {
                        Button {
                            onCompare(result.profileID, otherID)
                        } label: {
                            Label("Compare", systemImage: "rectangle.on.rectangle")
                        }
                        .buttonStyle(.glassProminent).controlSize(.mini)
                        .help("Compare the two profiles side by side and merge only if they are truly the same person")
                    } else {
                        // Merge is a judgement call — the profile card links to
                        // Health's full-context compare rather than acting inline.
                        Button {
                            appState.requestSidebarTab = .health
                        } label: {
                            Label("Review in Health", systemImage: "rectangle.on.rectangle")
                        }
                        .buttonStyle(.glassProminent).controlSize(.mini)
                        .help("Open Health to compare the possible duplicate side by side — merging is never offered inline")
                    }
                    // The false-positive exit — pairwise and permanent
                    // (v51 dismissed_duplicates), previously reachable only
                    // inside the Compare sheet.
                    Button {
                        appState.dismissDuplicatePair(result.profileID, otherID)
                        onFixed()
                    } label: {
                        Label("Not a duplicate", systemImage: "person.2.slash")
                    }
                    .buttonStyle(.glass).controlSize(.mini)
                    .help("Record that these are two different people — this pair stops being flagged; other possible duplicates keep surfacing")
                }
            }
        case "givenNameContainsMiddle":
            if let p = appState.snapshot.profiles[result.profileID],
               let split = p.impliedGivenMiddleSplit {
                Button {
                    appState.applyGivenMiddleSplit(profileID: result.profileID)
                    onFixed()
                } label: {
                    Label("Split to “\(split.first)” + “\(split.middle)”", systemImage: "textformat.abc")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Move the extra word out of the given name and into the middle name")
            }
        case "missingCoParent":
            if let coID = result.relatedProfileIDs?.first, let co = appState.snapshot.profiles[coID] {
                Button {
                    appState.addCoParent(childID: result.profileID, coParentID: coID)
                    onFixed()
                } label: {
                    Label("Add \(co.displayName)", systemImage: "person.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Link \(co.displayName) as the other parent — matching this child's siblings")
            }
        case "excessParentEdges" where result.relatedProfileIDs?.isEmpty == false:
            Button {
                appState.repairExcessPlaceholderParents(for: result.profileID)
                onFixed()
            } label: {
                Label("Remove placeholders", systemImage: "wand.and.stars")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Absorb the blank placeholder parents into the real parents and re-home shared siblings")
        case "censusParentUnlock":
            Button {
                _ = appState.applyChildhoodCensusForParentUnlock(profileID: result.profileID)
                onFixed()
            } label: {
                Label("Apply childhood census", systemImage: "person.2.badge.plus")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Apply the best-matching childhood census (same county, closest age) so its household's Head and Wife can be added as this person's parents")
        case "censusRelationship" where result.severity == .info:
            let missingCount = appState.snapshot.profiles[result.profileID].map { subject in
                CensusRelationshipReconciler.findings(for: subject, in: appState.snapshot)
                    .filter { $0.kind == .missing }.count
            } ?? 0
            if missingCount > 1 {
                Button {
                    appState.addMissingCensusRelatives(for: result.profileID)
                    onFixed()
                } label: {
                    Label("Add all \(missingCount)", systemImage: "person.2.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Create all \(missingCount) census relatives missing from the tree and link them, citing the census")
            }
        default:
            EmptyView()
        }
    }
}
