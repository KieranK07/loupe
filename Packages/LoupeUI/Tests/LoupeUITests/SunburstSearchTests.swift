import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Finding things without losing the shape of the disk")
struct SunburstSearchTests {

    @Test("Matching ignores case and accents in both directions")
    func foldedMatching() {
        let search = SunburstSearch(query: "cafe")
        #expect(search.matches("Café Photos"))
        #expect(search.matches("CAFE"))
        #expect(search.matches("cafe.txt"))
        #expect(!search.matches("coffee"))

        let accented = SunburstSearch(query: "RÉSUMÉ")
        #expect(accented.matches("resume.pdf"))
        #expect(accented.matches("Résumé final"))
    }

    @Test("An empty or whitespace query is not a search")
    func emptyQuery() {
        #expect(!SunburstSearch(query: "").isActive)
        #expect(!SunburstSearch(query: "   ").isActive)
        #expect(!SunburstSearch(query: "  ").matches("anything"))
    }

    @Test("The ASCII path and the folding path agree")
    func fastPathAgrees() {
        let names = FixtureNames.pool + ["Café", "naïve", "ÜBER", "sm\u{00F8}rrebr\u{00F8}d", "PLAIN"]
        for query in ["c22", "LIBRARY", "node", "e4-908b", "z", "a", "cafe", "uber"] {
            let search = SunburstSearch(query: query)
            for name in names {
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .contains(search.needle)
                #expect(search.matches(name) == folded, "\(query) against \(name)")
            }
        }
    }

    @Test("Matches keep full weight; everything else is dimmed, not removed")
    func dimsRatherThanHides() throws {
        let index = SunburstIndex(Fixture.layout(
            levels: [[3, 2, 1], [2, 1]],
            nameForRing: { ring, child, _ in
                ring == 1 && child == 0 ? "node_modules" : "Library\(ring)\(child)"
            }))
        let result = SunburstSearch(query: "node").result(in: index)
        #expect(result.matchCount > 0)
        #expect(result.isDimming)

        var dimmed = 0
        for wedge in index.wedges {
            let opacity = result.opacity(for: wedge.id)
            #expect(opacity > 0, "a non-match must still be drawn, or the disk changes shape")
            if opacity < 1 { dimmed += 1 }
        }
        #expect(dimmed > 0, "nothing was dimmed")
        #expect(dimmed < index.wedges.count, "everything was dimmed")
    }

    @Test("The folders containing a match stay legible")
    func ancestorsStayLit() throws {
        let index = SunburstIndex(Fixture.layout(
            levels: [[3, 2], [4, 1]],
            nameForRing: { ring, child, _ in
                ring == 1 && child == 0 ? "Xcode-15.4.0-Release-Candidate.xip" : "plain\(ring)\(child)"
            }))
        let result = SunburstSearch(query: "xcode").result(in: index)
        #expect(result.matchCount == 2, "one match under each ring-0 wedge")

        let navigator = SunburstNavigator(index: index)
        for ring in 0..<index.ringCount {
            for offset in 0..<index.count(inRing: ring) {
                let position = SunburstPosition(ring: ring, offset: offset)
                guard let wedge = index[position], result.matched.contains(wedge.id) else { continue }
                for ancestor in navigator.ancestors(of: position) {
                    let parent = try #require(index[ancestor])
                    #expect(result.emphasis(for: parent.id) == .onPathToMatch)
                    #expect(result.opacity(for: parent.id) > SunburstSearchEmphasis.unrelated.fillOpacity)
                }
            }
        }
    }

    @Test("A query that finds nothing leaves the chart alone")
    func noMatchesNoDimming() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1]]))
        let result = SunburstSearch(query: "zzzz-not-here").result(in: index)
        #expect(result.matchCount == 0)
        #expect(!result.isDimming)
        for wedge in index.wedges {
            #expect(result.opacity(for: wedge.id) == 1)
        }
    }

    @Test("An aggregate is searched by what it says, not by the name it borrowed")
    func aggregatesSearchHonestly() throws {
        let index = SunburstIndex(Fixture.layout(
            levels: [[3, 1]],
            kindForRing: { _, child in child == 0 ? .aggregated(count: 412) : .real },
            nameForRing: { _, _, _ in "node_modules" }))
        let aggregate = try #require(index[SunburstPosition(ring: 0, offset: 0)])
        // The aggregate carries "node_modules" as its borrowed name, but the
        // chart draws "412 smaller items" — so that is what a search must see.
        let byBorrowedName = SunburstSearch(query: "node").result(in: index)
        #expect(!byBorrowedName.matched.contains(aggregate.id))
        let byWhatItSays = SunburstSearch(query: "smaller items").result(in: index)
        #expect(byWhatItSays.matched.contains(aggregate.id))
    }

    @Test("The same query over a treemap picks out the same things")
    func treemapAgrees() {
        let sunburst = SunburstIndex(Fixture.layout(
            levels: [[3, 2]],
            nameForRing: { _, child, _ in child == 0 ? "Caches" : "Library" }))
        let treemap = TreemapIndex(TreemapFixture.layout(levels: [3, 2]))
        let query = SunburstSearch(query: "libr")
        #expect(query.result(in: sunburst).matchCount > 0)
        // Same capability, same folding, applied to the other view's index.
        let tiles = query.result(in: treemap)
        let expected = treemap.tiles.filter { $0.name.lowercased().contains("libr") }.count
        #expect(tiles.matchCount == expected)
    }
}
