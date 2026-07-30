import Foundation
import AppKit
import AncestorKit

// WikiTree MergeEdit launcher (WT2 — WIKITREE_MERGEEDIT_SPEC §1/§5).
//
// Turns a WT1 payload into a temp self-submitting HTML form and opens it in
// the DEFAULT BROWSER, where the member's WikiTree session lives. WikiTree
// renders its MergeEdit review page (checkbox per change) and the member
// saves there — the app never holds credentials, never talks to wikitree.com
// itself, and never commits anything. Field encoding (form fields with
// JSON-encoded values) is the spec §7.1 best-guess, adjusted at live verify
// if the demo app shows otherwise.

nonisolated enum WikiTreeMergeEditLauncher {

    static let endpoint = "https://www.wikitree.com/wiki/Special:MergeEdit"

    /// Render the self-submitting form. Pure — unit-tested; `open(_:)` is the
    /// only side-effectful part.
    ///
    /// SPEC INVARIANT enforced here: when the payload carries a bio append,
    /// `Bio` is added to the person object AND `options.mergeBio = 1` is sent
    /// — never one without the other (MergeEdit otherwise REPLACES the whole
    /// biography).
    static func reviewPageHTML(for payload: WikiTreeMergeEditPayload) -> String {
        var person = payload.personFields
        var fields: [(String, String)] = [("user_name", payload.userName)]

        if let bio = payload.bioAppend {
            person["Bio"] = bio
        }
        fields.append(("person", jsonString(person)))
        if !payload.expectedFields.isEmpty {
            fields.append(("expected", jsonString(payload.expectedFields)))
        }
        if payload.bioAppend != nil {
            fields.append(("options", #"{"mergeBio":1}"#))
        }
        fields.append(("summary", payload.summary))

        let inputs = fields.map { name, value in
            #"<input type="hidden" name="\#(escape(name))" value="\#(escape(value))">"#
        }.joined(separator: "\n    ")

        return """
        <meta charset="utf-8">
        <title>Opening WikiTree review page…</title>
        <p>Sending the proposed changes for <strong>\(escape(payload.userName))</strong> \
        to WikiTree's review page. Nothing is saved until you confirm there.</p>
        <form id="mergeedit" method="POST" action="\(endpoint)">
            \(inputs)
            <button type="submit">Open WikiTree review page</button>
        </form>
        <script>document.getElementById("mergeedit").submit();</script>
        """
    }

    /// Write the form to a temp file and open it in the default browser.
    /// Returns the file URL (for logging/cleanup).
    @discardableResult
    static func open(_ payload: WikiTreeMergeEditPayload) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikitree-mergeedit-\(UUID().uuidString).html")
        try reviewPageHTML(for: payload).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
        return url
    }

    // MARK: - Helpers

    private static func jsonString(_ dict: [String: String]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// HTML attribute/content escaping — payload values contain user data and
    /// wikitext (refs with quotes, ampersands in URLs).
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
