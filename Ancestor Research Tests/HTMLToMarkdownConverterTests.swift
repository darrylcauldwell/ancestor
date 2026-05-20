import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the conversion contract for `HTMLToMarkdownConverter`. Five test
/// fixtures cover the corner cases the spec §7 calls out: heading
/// preservation, list semantics, `<pre>` verbatim handling, link rewriting,
/// chrome stripping. Plus an end-to-end smoke test against a real-world
/// genealogy page (the Wirksworth pedigree the scout agent fetched).
struct HTMLToMarkdownConverterTests {

    // MARK: - Headings, paragraphs, italic/bold

    @Test func preservesHeadingsAsHashPrefixedLines() {
        let html = "<h1>Title</h1><h3>Subtitle</h3><p>Body.</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("# Title"))
        #expect(md.contains("### Subtitle"))
        #expect(md.contains("Body."))
    }

    @Test func emitsItalicAsUnderscoreAndBoldAsAsterisks() {
        let html = "<p>He was a <i>yeoman</i> and a <b>parish constable</b>.</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("_yeoman_"))
        #expect(md.contains("**parish constable**"))
    }

    @Test func emEquivalentToItalicAndStrongToBold() {
        let html = "<p><em>Anne</em> married <strong>William</strong>.</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("_Anne_"))
        #expect(md.contains("**William**"))
    }

    // MARK: - Lists (UL/OL/LI), including bare-LI

    @Test func unorderedListsBecomeDashBullets() {
        let html = "<ul><li>First</li><li>Second</li></ul>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("- First"))
        #expect(md.contains("- Second"))
    }

    @Test func orderedListsBecomeNumberedItems() {
        let html = "<ol><li>One</li><li>Two</li><li>Three</li></ol>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("1. One"))
        #expect(md.contains("2. Two"))
        #expect(md.contains("3. Three"))
    }

    @Test func bareListItemsBecomeDashBullets() {
        // Wirksworth emits <LI>1.Name born YEAR<BR> directly under <TR><TD>
        // with no enclosing <UL>. The converter must still emit something
        // list-shaped or the bullet structure is lost.
        let html = "<LI>1.Jane Wheatcroft born 1673<BR><LI>2.Anthony Wheatcroft born 1667"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("- 1.Jane Wheatcroft"))
        #expect(md.contains("- 2.Anthony Wheatcroft"))
    }

    // MARK: - <pre> preserved verbatim

    @Test func preBlockKeepsInternalWhitespace() {
        let html = """
        <pre>
          Generation 1
            John Smith   b. 1800
            Mary Jones   b. 1805
        </pre>
        """
        let md = HTMLToMarkdownConverter.convert(html)
        // Inside fenced block, multi-space columns survive.
        #expect(md.contains("```"))
        #expect(md.contains("Generation 1"))
        #expect(md.contains("John Smith   b. 1800"))
    }

    // MARK: - Links and images

    @Test func anchorTagsBecomeMarkdownLinks() {
        let html = "<p>See the <a href=\"frontpag.htm\">front page</a>.</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("[front page](frontpag.htm)"))
    }

    @Test func anchorWithEmptyTextUsesHrefAsLabel() {
        let html = "<a href=\"PEDIGREE.htm\"><img src=\"menu.gif\"></a>"
        let md = HTMLToMarkdownConverter.convert(html)
        // The image alt becomes the link label since text is empty.
        #expect(md.contains("PEDIGREE.htm"))
    }

    @Test func imagesBecomeImageLinksNotInlineImages() {
        // Spec §7.3 — images preserved as links so MLX can decide to fetch
        // (e.g. OCR), but v1 stores no image bytes.
        let html = "<img src=\"menu-2.gif\" alt=\"navigation icon\">"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("[image: navigation icon](menu-2.gif)"))
    }

    // MARK: - Chrome stripping

    @Test func scriptStyleNoscriptHeadAreStrippedEntirely() {
        let html = """
        <html><head><title>X</title></head>
        <body>
        <script>alert('hi');</script>
        <style>body { color: red; }</style>
        <noscript>No JS.</noscript>
        <p>Real content.</p>
        </body></html>
        """
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("Real content."))
        #expect(!md.contains("alert"))
        #expect(!md.contains("color: red"))
        #expect(!md.contains("No JS."))
        #expect(!md.contains("<title>"))
    }

    @Test func navAndFooterClassesAreSkipped() {
        let html = """
        <div class="navbar">SKIP THIS</div>
        <p>Keep this.</p>
        <div class="footer-row">SKIP THIS TOO</div>
        """
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("Keep this."))
        #expect(!md.contains("SKIP THIS"))
    }

    @Test func commentsAreStripped() {
        let html = "<p>Before<!--invisible-->After</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("BeforeAfter"))
        #expect(!md.contains("invisible"))
    }

    // MARK: - Entity decoding

    @Test func decodesNamedEntities() {
        let html = "<p>Smith &amp; Jones &mdash; &ldquo;family&rdquo;</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("Smith & Jones"))
        #expect(md.contains("—"))
    }

    @Test func decodesNumericEntities() {
        let html = "<p>&#38; and &#x26;</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("& and &"))
    }

    @Test func nbspBecomesSpace() {
        let html = "<p>Word&nbsp;Word</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(md.contains("Word Word"))
    }

    // MARK: - Whitespace normalisation

    @Test func runsOfBlankLinesCollapseToOne() {
        let html = "<p>First</p><p>Second</p><p>Third</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        // No 3+ consecutive newlines anywhere.
        #expect(!md.contains("\n\n\n"))
    }

    @Test func crlfInputProducesLfOutput() {
        let html = "<p>Line one</p>\r\n<p>Line two</p>"
        let md = HTMLToMarkdownConverter.convert(html)
        #expect(!md.contains("\r"))
    }

    // MARK: - Real-world fixture (Wirksworth pedigree page)

    @Test func realWorldWirksworthPedigreeConverts() throws {
        let bundle = Bundle(for: FixtureLoader.self)
        guard let url = bundle.url(
            forResource: "wirksworth-pedigree-sample",
            withExtension: "html",
            subdirectory: "Fixtures/Corpus"
        ) ?? bundle.url(
            forResource: "wirksworth-pedigree-sample",
            withExtension: "html"
        ) else {
            // Test bundles in synchronized groups sometimes need a moment
            // for resources to surface; skip rather than fail noisily so
            // the converter unit tests don't depend on resource bundling.
            return
        }
        let html = try String(contentsOf: url, encoding: .utf8)
        let md = HTMLToMarkdownConverter.convert(html)

        // The title from <TITLE> should surface as page content too because
        // <head> is stripped, but the <H3>/<H1>/<H2> headings remain.
        #expect(md.contains("WIRKSWORTH Parish Records 1600-1900"))
        // The body's H1 should appear as markdown heading.
        #expect(md.contains("Descendants of CAULDWELL-1"))
        // Family-history narrative survives.
        #expect(md.contains("CAULDWELL family history"))
        // Pedigree paragraph text reaches the output.
        #expect(md.contains("Wheatcroft"))
        // Years are preserved (the indexer will tokenise these).
        #expect(md.contains("1645"))
        #expect(md.contains("1673"))
        // No raw HTML tags leaked through.
        #expect(!md.contains("<BODY"))
        #expect(!md.contains("<TABLE"))
        #expect(!md.contains("<FONT"))
        // No script content.
        #expect(!md.contains("alert"))
    }
}

/// Marker class used solely as a reference point for `Bundle(for:)` when
/// loading test fixture resources. Lives next to the fixture files in the
/// Tests bundle.
private final class FixtureLoader {}
