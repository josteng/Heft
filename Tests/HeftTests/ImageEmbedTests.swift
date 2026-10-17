import Foundation
import HeftCore
import Testing

/// Reading and rewriting the size written into a picture's link.
@Suite("Image embed sizes")
struct ImageEmbedTests {

    private func embed(_ source: String, _ written: String? = nil) throws -> ImageEmbed {
        let range = (source as NSString).range(of: written ?? source)
        return try #require(ImageEmbed(source, range: range))
    }

    private func resized(_ source: String, to width: Int?, _ written: String? = nil) throws -> String {
        try embed(source, written).resizing(toWidth: width).applied(to: source)
    }

    @Test("A wikilink embed's size is read and rewritten")
    func wikiSizes() throws {
        #expect(try embed("![[shot.png|300]]").width == 300)
        #expect(try embed("![[shot.png|300x200]]").height == 200)
        #expect(try resized("![[shot.png]]", to: 250) == "![[shot.png|250]]")
        #expect(try resized("![[shot.png|300]]", to: 250) == "![[shot.png|250]]")
        // Both sides become one: a new width keeps the picture's proportions.
        #expect(try resized("![[shot.png|300x200]]", to: 250) == "![[shot.png|250]]")
        #expect(try resized("![[shot.png|300]]", to: nil) == "![[shot.png]]")
    }

    @Test("A Markdown image's size lives in its alt text")
    func markdownSizes() throws {
        #expect(try embed("![300](shot.png)").width == 300)
        #expect(try embed("![a cat|300](shot.png)").width == 300)
        #expect(try embed("![a cat](shot.png)").width == nil)
        #expect(try resized("![](shot.png)", to: 250) == "![250](shot.png)")
        #expect(try resized("![a cat](shot.png)", to: 250) == "![a cat|250](shot.png)")
        #expect(try resized("![a cat|300](shot.png)", to: 250) == "![a cat|250](shot.png)")
        #expect(try resized("![300](shot.png)", to: 250) == "![250](shot.png)")
        #expect(try resized("![a cat|300](shot.png)", to: nil) == "![a cat](shot.png)")
        #expect(try resized("![300](shot.png)", to: nil) == "![](shot.png)")
    }

    @Test("The alt's words and its size come apart")
    func altSplits() {
        #expect(ImageEmbed.markdownAlt("a|b|300") == ("a|b", 300, nil))
        #expect(ImageEmbed.markdownAlt("300x200") == ("", 300, 200))
        #expect(ImageEmbed.markdownAlt("page 3") == ("page 3", nil, nil))
    }

    @Test("Inside a table the pipe stays escaped")
    func tablePipe() throws {
        let row = "| ![[shot.png\\|300]] | x |"
        #expect(try embed(row, "![[shot.png\\|300]]").width == 300)
        #expect(try resized(row, to: 120, "![[shot.png\\|300]]") == "| ![[shot.png\\|120]] | x |")
        let fresh = "| ![[shot.png]] | x |"
        #expect(try resized(fresh, to: 120, "![[shot.png]]") == "| ![[shot.png\\|120]] | x |")
    }

    @Test("A caption is not a size and is never overwritten")
    func captionIsLeftAlone() {
        let source = "![[shot.png|a caption]]"
        #expect(ImageEmbed(source, range: NSRange(location: 0, length: 23)) == nil)
    }

    @Test("The rewritten embed stays selected")
    func selectionCoversEmbed() throws {
        let source = "See ![[shot.png]] here"
        let edit = try embed(source, "![[shot.png]]").resizing(toWidth: 90)
        #expect(edit.selection == NSRange(location: 4, length: 16))
    }

    @Test("Removing takes the line when the picture was all of it")
    func removal() throws {
        let alone = "before\n![[shot.png]]\nafter"
        #expect(try embed(alone, "![[shot.png]]").removing(in: alone).applied(to: alone) == "before\nafter")
        let inline = "see ![[shot.png]] here"
        #expect(try embed(inline, "![[shot.png]]").removing(in: inline).applied(to: inline) == "see  here")
    }
}
