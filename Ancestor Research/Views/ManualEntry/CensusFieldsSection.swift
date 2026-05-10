import SwiftUI

/// Per-family census fields (M16.4). Renders the census-type picker,
/// year, and address; the per-person age + occupation columns are
/// rendered by AddFamilyView itself because they live alongside the
/// existing parent/child rows.
struct CensusFieldsSection: View {
    @Binding var censusType: CensusType
    @Binding var yearText: String
    @Binding var address: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Census record")
            Picker("Census", selection: $censusType) {
                ForEach(CensusType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: censusType) { _, newValue in
                if let year = newValue.year {
                    yearText = String(year)
                }
            }

            HStack(spacing: 8) {
                TextField("Year", text: $yearText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                TextField("Address", text: $address)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

/// Per-person census-row inputs. Used inside the parent + child rows
/// when census mode is active so the user can capture an age (with
/// inferred birth-year preview) and an occupation alongside identity.
struct CensusPersonRow: View {
    @Binding var ageText: String
    @Binding var occupation: String
    let censusYear: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Age at census", text: $ageText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 130)
                TextField("Occupation", text: $occupation)
                    .textFieldStyle(.roundedBorder)
            }
            if let preview = birthYearPreview {
                Text(preview)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Inferred birth-year hint when both age + census year are known.
    /// Nil when either is missing or the age isn't a number — the user
    /// can fix the typo without us scolding them.
    private var birthYearPreview: String? {
        guard let year = censusYear else { return nil }
        let trimmed = ageText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let age = Int(trimmed) else { return nil }
        let birthYear = CensusType.computeBirthYear(censusYear: year, ageAtCensus: age)
        return "Born ~\(birthYear) (±1)"
    }
}
