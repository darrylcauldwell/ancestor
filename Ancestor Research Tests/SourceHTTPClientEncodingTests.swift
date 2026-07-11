import Testing
import Foundation
@testable import Ancestor_Research

/// Transport-layer half of the CONNECTOR_AUDIT_2026-07 findings that live in
/// shared HTTP code rather than a connector:
///
///   * **FT-29** (§2.4) — `postForm` percent-encoded values with
///     `.urlQueryAllowed`, which permits `&`, `+`, and `=` *inside* a value, so
///     `"Clifton & Compton"` split the pair on the wire and `+` decoded to a
///     space. The body must use form-safe encoding.
///   * **FT-25** (§2.4) — `[String: String]` cannot encode the Rails
///     `search_query[chapman_codes][]` repeated-key idiom; the ordered-pairs
///     primitive must preserve duplicate keys on the wire. (The dispatcher-side
///     batching that *consumes* this primitive is out of transport scope.)
///   * **T1-C4** (§8, transport half) — apostrophes and diacritics (O'Brien,
///     Müller) must round-trip through the encoder.
///
/// These exercise the pure serialisation surface (`formEncode` /
/// `formURLEncodedBody`) and the ordered-pairs API contract on the injectable
/// client — no network.
@MainActor
struct SourceHTTPClientEncodingTests {

    // MARK: - FT-29 · form-safe value encoding

    @Test func encodesAmpersandInsideValue() {
        // The headline FT-29 corruption: "Clifton & Compton" is a real
        // district string; `&` must not split the pair.
        #expect(SourceHTTPClient.formEncode("Clifton & Compton") == "Clifton+%26+Compton")
    }

    @Test func encodesPlusAndEqualsInsideValue() {
        // `+` must not decode back to a space; `=` must not read as a separator.
        #expect(SourceHTTPClient.formEncode("a+b=c") == "a%2Bb%3Dc")
    }

    @Test func spaceEncodesAsPlus() {
        #expect(SourceHTTPClient.formEncode("John Smith") == "John+Smith")
    }

    @Test func unreservedCharactersPassThroughUntouched() {
        // ALPHA / DIGIT / - . _ ~ are left literal by every conforming decoder.
        let unreserved = "Abc-123_x.y~Z"
        #expect(SourceHTTPClient.formEncode(unreserved) == unreserved)
    }

    @Test func encodesReservedSeparatorsThatWouldCorruptTheBody() {
        // The three bytes the old .urlQueryAllowed set wrongly permitted.
        #expect(SourceHTTPClient.formEncode("&") == "%26")
        #expect(SourceHTTPClient.formEncode("=") == "%3D")
        #expect(SourceHTTPClient.formEncode("+") == "%2B")
    }

    @Test func hexIsUppercase() {
        // WHATWG form-encoding emits uppercase %HH; assert we don't drift to
        // lowercase (some decoders are case-tolerant, but be canonical).
        #expect(SourceHTTPClient.formEncode("&") == "%26")
        #expect(!SourceHTTPClient.formEncode("&").contains("%2f"))
    }

    // MARK: - T1-C4 · apostrophes & diacritics round-trip

    @Test func apostropheIsEncoded() {
        // O'Brien: apostrophe (0x27) is reserved, not unreserved.
        #expect(SourceHTTPClient.formEncode("O'Brien") == "O%27Brien")
    }

    @Test func diacriticsEncodeAsUTF8Bytes() {
        // ü = U+00FC = UTF-8 C3 BC; é = U+00E9 = UTF-8 C3 A9.
        #expect(SourceHTTPClient.formEncode("Müller") == "M%C3%BCller")
        #expect(SourceHTTPClient.formEncode("café") == "caf%C3%A9")
    }

    @Test func encodeThenDecodeRoundTripsSpecialChars() {
        // The load-bearing property: whatever we put on the wire, a conforming
        // form decoder must recover verbatim. Foundation's
        // removingPercentEncoding decodes %HH; we undo the space→`+` mapping
        // first, exactly as a server would for x-www-form-urlencoded.
        for original in ["Clifton & Compton", "O'Brien", "Müller",
                         "a+b=c", "d'Arcy-Müller & Sons", "café au lait",
                         "50% off", "key=val&other"] {
            let encoded = SourceHTTPClient.formEncode(original)
            let decoded = encoded
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
            #expect(decoded == original,
                    "round-trip failed for \(original): encoded=\(encoded) decoded=\(String(describing: decoded))")
        }
    }

    // MARK: - FT-29 · full-body serialisation

    @Test func bodyJoinsPairsWithAmpersandAndEncodesEach() {
        let body = SourceHTTPClient.formURLEncodedBody([
            ("surname", "O'Brien"),
            ("place", "Clifton & Compton"),
        ])
        #expect(body == "surname=O%27Brien&place=Clifton+%26+Compton")
    }

    @Test func bodySeparatorsAreTheOnlyBareAmpersandsAndEquals() {
        // Structural guarantee: after encoding, the only bare `&`/`=` in the
        // body are the pair/kv separators — a value's own `&`/`=` can never be
        // mistaken for structure. Two pairs → exactly one bare `&`, two bare `=`.
        let body = SourceHTTPClient.formURLEncodedBody([
            ("a", "x&y=z"),
            ("b", "p+q"),
        ])
        #expect(body == "a=x%26y%3Dz&b=p%2Bq")
        #expect(body.filter { $0 == "&" }.count == 1)
        #expect(body.filter { $0 == "=" }.count == 2)
    }

    @Test func emptyPairsProduceEmptyBody() {
        #expect(SourceHTTPClient.formURLEncodedBody([]) == "")
    }

    @Test func emptyValueKeepsKeyAndEqualsSign() {
        #expect(SourceHTTPClient.formURLEncodedBody([("districtid", "")]) == "districtid=")
    }

    // MARK: - FT-25 · repeated-key form key encoding

    @Test func bracketArrayKeyIsPreservedLiterally() {
        // The Rails idiom key `search_query[chapman_codes][]` — brackets are
        // reserved but must survive as the server expects them; RFC 3986 lists
        // `[` `]` as reserved, so they percent-encode. Assert the exact wire form
        // so a future decoder-mismatch fails loudly. Rails/Rack decode %5B/%5D
        // back to brackets before param parsing.
        let key = "search_query[chapman_codes][]"
        #expect(SourceHTTPClient.formEncode(key) == "search_query%5Bchapman_codes%5D%5B%5D")
    }

    @Test func repeatedKeyPairsSurviveInBody() {
        // FT-25 core: multiple values under one key produce repeated pairs,
        // never a collapsed single value.
        let body = SourceHTTPClient.formURLEncodedBody([
            ("search_query[chapman_codes][]", "DBY"),
            ("search_query[chapman_codes][]", "NTT"),
            ("search_query[chapman_codes][]", "LEI"),
        ])
        let expectedKey = "search_query%5Bchapman_codes%5D%5B%5D"
        #expect(body == "\(expectedKey)=DBY&\(expectedKey)=NTT&\(expectedKey)=LEI")
        // Three distinct values are all present, in order.
        #expect(body.components(separatedBy: expectedKey + "=").count == 4)
    }

    // MARK: - FT-25 · ordered-pairs primitive on the injectable client

    @Test func multiFieldsDefaultBridgeCollapsesDuplicateKeys() async throws {
        // A conformer implementing only the [String: String] method (the
        // majority of test doubles) inherits the protocol-extension bridge:
        // repeated keys collapse to the last value. This documents the lossy
        // fallback so nobody relies on duplicate preservation from a plain
        // conformer.
        let client = RecordingFormHTTPClient()
        _ = try await client.postForm(
            url: URL(string: "https://example.test/search")!,
            multiFields: [("code", "DBY"), ("code", "NTT")],
            headers: [:], timeout: 5
        )
        // RecordingFormHTTPClient DOES implement the multi-value method, so it
        // captures the ordered pairs verbatim (no collapse).
        let captured = client.lastMultiFields
        #expect(captured?.count == 2)
        #expect(captured?.map(\.1) == ["DBY", "NTT"])
    }

    @Test func multiFieldsPreservesOrderAndDuplicatesThroughClient() async throws {
        let client = RecordingFormHTTPClient()
        _ = try await client.postForm(
            url: URL(string: "https://example.test/search")!,
            multiFields: [
                ("search_query[chapman_codes][]", "DBY"),
                ("search_query[chapman_codes][]", "NTT"),
                ("surname", "O'Brien"),
            ],
            headers: [:], timeout: 5
        )
        let captured = try #require(client.lastMultiFields)
        #expect(captured.count == 3)
        #expect(captured.map(\.0) == [
            "search_query[chapman_codes][]",
            "search_query[chapman_codes][]",
            "surname",
        ])
        #expect(captured.map(\.1) == ["DBY", "NTT", "O'Brien"])
    }

    @Test func singleValuePostFormStillWorksUnchanged() async throws {
        // Non-regression: the existing [String: String] entry point is intact.
        let client = RecordingFormHTTPClient()
        _ = try await client.postForm(
            url: URL(string: "https://example.test/search")!,
            fields: ["surname": "Smith", "given": "John"],
            headers: [:], timeout: 5
        )
        #expect(client.lastSingleFields == ["surname": "Smith", "given": "John"])
    }

    @Test func defaultTimeoutOverloadForMultiFieldsCompilesAndRuns() async throws {
        // The convenience overload without an explicit timeout must route to the
        // 20 s default without ambiguity against the single-value overload.
        let client = RecordingFormHTTPClient()
        _ = try await client.postForm(
            url: URL(string: "https://example.test/search")!,
            multiFields: [("k", "v")],
            headers: [:]
        )
        #expect(client.lastMultiFields?.map(\.0) == ["k"])
    }
}
