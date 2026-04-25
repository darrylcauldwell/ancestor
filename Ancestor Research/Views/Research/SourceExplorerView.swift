import SwiftUI

/// Source Explorer — manual search tool for testing and exploring record sources.
/// Enter a name and year, pick a source, see raw scored results.
struct SourceExplorerView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry

    @State private var surname = ""
    @State private var givenName = ""
    @State private var birthYear = ""
    @State private var deathYear = ""
    @State private var selectedSourceID: String?
    @State private var results: [SourceRecord] = []
    @State private var isSearching = false
    @State private var searchMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Search form
            searchForm
                .padding()
            Divider()

            // Results
            if isSearching {
                ProgressView("Searching...")
                    .frame(maxHeight: .infinity)
            } else if let message = searchMessage {
                ContentUnavailableView {
                    Label("Search", systemImage: "magnifyingglass")
                } description: {
                    Text(message)
                }
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label("Source Explorer", systemImage: "globe.desk")
                } description: {
                    Text("Enter a name and select a source to search.")
                }
            } else {
                resultsList
            }
        }
        .navigationTitle("Source Explorer")
    }

    // MARK: - Search Form

    private var searchForm: some View {
        HStack(spacing: 12) {
            TextField("Surname", text: $surname)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            TextField("Given name", text: $givenName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            TextField("Birth year", text: $birthYear)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)

            TextField("Death year", text: $deathYear)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)

            // Source picker
            Picker("Source", selection: $selectedSourceID) {
                Text("All sources").tag(nil as String?)
                ForEach(registry.allSources(), id: \.sourceID) { source in
                    Text(source.displayName).tag(source.sourceID as String?)
                }
            }
            .frame(width: 150)

            Button("Search") {
                Task { await performSearch() }
            }
            .buttonStyle(.glassProminent)
            .disabled(surname.isEmpty || isSearching)
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                ForEach(results) { record in
                    resultCard(record)
                }
            }
            .padding()
        }
    }

    private func resultCard(_ record: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Source badge
                Text(record.sourceID.uppercased())
                    .font(AppTypography.badge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)

                // Record type badge
                Text(recordTypeLabel(record))
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)

                Spacer()

                // Detail URL link
                if let urlStr = record.detailURL, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(AppTypography.cardMeta)
                    }
                }
            }

            // Name
            Text(record.name ?? "Unknown")
                .font(AppTypography.cardTitle)

            // Summary line
            Text(RecordScorer.summarise(record: record, searchType: recordType(record)))
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)

            // Raw fields (collapsed by default)
            if !record.rawFields.isEmpty {
                DisclosureGroup("Raw fields") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(record.rawFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack(alignment: .top) {
                                Text(key)
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 100, alignment: .trailing)
                                Text(value)
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(AppTypography.cardMeta)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    // MARK: - Search Logic

    private func performSearch() async {
        isSearching = true
        searchMessage = nil
        results = []

        let surnameValue = surname.isEmpty ? nil : surname
        let givenValue = givenName.isEmpty ? nil : givenName
        let birthYearValue = Int(birthYear)
        let deathYearValue = Int(deathYear)

        var allResults: [SourceRecord] = []

        let sourcesToSearch: [any RecordSource]
        if let sourceID = selectedSourceID,
           let source = registry.source(for: sourceID) {
            sourcesToSearch = [source]
        } else {
            sourcesToSearch = registry.enabledSources()
        }

        for source in sourcesToSearch {
            for recordType in source.recordTypes {
                // Build source-specific params
                let params: SourceQueryParams = switch source.sourceID {
                case "freebmd": .freeBMD(FreeBMDParams(districtCode: nil, wildcardSurname: false, motherSurname: nil, spouseSurname: nil))
                case "freecen": .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: birthYearValue.flatMap { _ in nil }))
                case "findagrave": .findAGrave(FindAGraveParams(yearRangeWidth: 5, location: nil))
                case "cwgc": .cwgc(CWGCParams(conflict: nil))
                default: .generic
                }

                let specificQuery = RecordQuery(
                    surname: surnameValue,
                    givenName: givenValue,
                    recordType: recordType,
                    yearFrom: birthYearValue.map { $0 - 2 },
                    yearTo: deathYearValue ?? birthYearValue.map { $0 + 80 },
                    gender: nil,
                    region: nil,
                    sourceParams: params
                )
                let queryResult = await source.search(specificQuery)
                allResults.append(contentsOf: queryResult.records)
            }
        }

        results = allResults
        isSearching = false

        if allResults.isEmpty {
            searchMessage = "No results found across \(sourcesToSearch.count) source\(sourcesToSearch.count == 1 ? "" : "s")"
        }
    }

    // MARK: - Helpers

    private func recordTypeLabel(_ record: SourceRecord) -> String {
        switch record {
        case .birth: "Birth"
        case .death: "Death"
        case .marriage: "Marriage"
        case .census: "Census"
        case .burial: "Burial"
        case .military: "Military"
        case .probate: "Probate"
        case .parish: "Parish"
        case .pedigree: "Pedigree"
        }
    }

    private func recordType(_ record: SourceRecord) -> RecordType {
        switch record {
        case .birth: .birth
        case .death: .death
        case .marriage: .marriage
        case .census: .census
        case .burial: .burial
        case .military: .military
        case .probate: .probate
        case .parish: .parish
        case .pedigree: .pedigree
        }
    }
}
