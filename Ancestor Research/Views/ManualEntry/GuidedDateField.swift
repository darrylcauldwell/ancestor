import SwiftUI
import AncestorKit

/// Guided date entry — pick a precision mode and fill the relevant fields
/// instead of guessing GEDCOM syntax. Emits a canonical string into the bound
/// text (the same field `GenealogicalDate` parses everywhere), so a hand-typed
/// date is both valid and consistently formatted. A live "reads as" line shows
/// how it will be interpreted (and warns when it can't be).
struct GuidedDateField: View {
    let label: String
    @Binding var text: String

    enum Mode: String, CaseIterable, Identifiable {
        case exact, monthYear, yearOnly, about, before, after, between
        var id: String { rawValue }
        var title: String {
            switch self {
            case .exact:     "Exact date"
            case .monthYear: "Month & year"
            case .yearOnly:  "Year only"
            case .about:     "About"
            case .before:    "Before"
            case .after:     "After"
            case .between:   "Between"
            }
        }
    }

    @State private var mode: Mode = .yearOnly
    @State private var day: String = ""
    @State private var month: Int = 0   // 0 = none
    @State private var year: String = ""
    @State private var year2: String = ""
    /// Guards the fields→text→fields loop: true while we write text ourselves.
    @State private var emitting = false

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Precision", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 150)
            }
            fields
            interpretation
        }
        .onAppear { decompose(text) }
        .onChange(of: text) { _, new in if !emitting { decompose(new) } }
        .onChange(of: mode) { _, _ in emit() }
        .onChange(of: day) { _, _ in emit() }
        .onChange(of: month) { _, _ in emit() }
        .onChange(of: year) { _, _ in emit() }
        .onChange(of: year2) { _, _ in emit() }
    }

    @ViewBuilder private var fields: some View {
        HStack(spacing: 8) {
            if mode == .exact {
                TextField("Day", text: $day).frame(width: 54)
            }
            if mode == .exact || mode == .monthYear {
                Picker("Month", selection: $month) {
                    Text("—").tag(0)
                    ForEach(1...12, id: \.self) { Text(Self.months[$0 - 1]).tag($0) }
                }
                .labelsHidden().frame(width: 90)
            }
            TextField(mode == .between ? "From year" : "Year", text: $year).frame(width: 88)
            if mode == .between {
                Text("to").foregroundStyle(.secondary)
                TextField("To year", text: $year2).frame(width: 88)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var interpretation: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let gd = GenealogicalDate(parsing: trimmed)
            if gd.bestYear != nil {
                Label("Reads as \(readsAs(gd)) · stored as “\(trimmed)”", systemImage: "checkmark.circle")
                    .font(AppTypography.badge).foregroundStyle(.secondary)
            } else {
                Label("Not recognised as a date — it will be ignored by research and date checks.",
                      systemImage: "exclamationmark.triangle")
                    .font(AppTypography.badge).foregroundStyle(.orange)
            }
        }
    }

    private func readsAs(_ gd: GenealogicalDate) -> String {
        guard let best = gd.bestYear else { return "—" }
        if let e = gd.earliest, let l = gd.latest, e != l { return "\(best) (\(e)–\(l))" }
        return "\(best)"
    }

    // MARK: - Compose (fields → canonical string)

    private func emit() {
        emitting = true
        text = compose()
        emitting = false
    }

    private func compose() -> String {
        let y = year.trimmingCharacters(in: .whitespaces)
        let d = day.trimmingCharacters(in: .whitespaces)
        let mon = (1...12).contains(month) ? Self.months[month - 1] : nil
        switch mode {
        case .exact:
            if !d.isEmpty, let mon, !y.isEmpty { return "\(d) \(mon) \(y)" }
            if let mon, !y.isEmpty { return "\(mon) \(y)" }
            return y
        case .monthYear:
            if let mon, !y.isEmpty { return "\(mon) \(y)" }
            return y
        case .yearOnly: return y
        case .about:    return y.isEmpty ? "" : "abt \(y)"
        case .before:   return y.isEmpty ? "" : "bef \(y)"
        case .after:    return y.isEmpty ? "" : "aft \(y)"
        case .between:
            let y2 = year2.trimmingCharacters(in: .whitespaces)
            return (!y.isEmpty && !y2.isEmpty) ? "\(y)-\(y2)" : y
        }
    }

    // MARK: - Decompose (existing string → fields, best-effort)

    private func decompose(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        let lower = s.lowercased()
        let years = Self.years(in: s)

        if lower.hasPrefix("abt") || lower.hasPrefix("about") || lower.hasPrefix("c.") || lower.hasPrefix("ca ") {
            mode = .about; year = years.first.map(String.init) ?? ""; return
        }
        if lower.hasPrefix("bef") { mode = .before; year = years.first.map(String.init) ?? ""; return }
        if lower.hasPrefix("aft") { mode = .after; year = years.first.map(String.init) ?? ""; return }
        if years.count >= 2 {
            mode = .between; year = String(years[0]); year2 = String(years[1]); return
        }

        // Single-witness date: detect month + optional day.
        let mon = Self.monthIndex(in: lower)
        let d = Self.leadingDay(in: s)
        year = years.first.map(String.init) ?? ""
        month = mon ?? 0
        day = d ?? ""
        if mon != nil, d != nil { mode = .exact }
        else if mon != nil { mode = .monthYear }
        else { mode = .yearOnly }
    }

    private static func years(in s: String) -> [Int] {
        let re = try? NSRegularExpression(pattern: #"\b(1[5-9]\d\d|20\d\d)\b"#)
        let ns = s as NSString
        return (re?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? [])
            .compactMap { Int(ns.substring(with: $0.range)) }
    }

    private static func monthIndex(in lower: String) -> Int? {
        for (i, m) in months.enumerated() where lower.contains(m.lowercased()) { return i + 1 }
        return nil
    }

    private static func leadingDay(in s: String) -> String? {
        guard let match = s.range(of: #"^\s*(\d{1,2})\b"#, options: .regularExpression) else { return nil }
        let day = s[match].trimmingCharacters(in: .whitespaces)
        return (Int(day).map { $0 >= 1 && $0 <= 31 } ?? false) ? day : nil
    }
}
