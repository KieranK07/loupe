import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

@Suite("What the bubble chart says")
struct BubbleDescriptionTests {

    /// The load-bearing sentence. A circle pack is the most enjoyable of the
    /// three views to look at and the least trustworthy to measure with, and the
    /// contract says the UI has to admit that rather than let the picture imply
    /// otherwise. If this ever stops being said out loud, this test is what
    /// notices.
    @Test("The chart admits what it is bad at, in the footer and out loud")
    func caveatIsSaid() {
        let index = BubbleIndex(BubbleFixture.nested())
        #expect(BubbleDescription.footer(index).contains(BubbleDescription.shortCaveat))
        #expect(BubbleDescription.footer(index).contains("as of"))
        let summary = BubbleDescription.accessibilitySummary(index, basis: .physical)
        #expect(summary.contains(BubbleDescription.comparisonCaveat))
        // Not a vague hedge: it says which view to use instead.
        #expect(BubbleDescription.comparisonCaveat.lowercased().contains("treemap"))
    }

    @Test("An incomplete scan says so")
    func provenance() {
        let running = BubbleIndex(BubbleFixture.layout(BubbleFixture.nested().circles,
                                                       isComplete: false))
        #expect(BubbleDescription.provenance(running).contains("still measuring"))
        #expect(!BubbleDescription.provenance(BubbleIndex(BubbleFixture.nested()))
            .contains("still measuring"))
    }

    @Test("Share of parent comes from bytes, and from the recovered parent")
    func shareOfParent() throws {
        let parent = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.4, depth: 0,
                                          seed: 0, hasChildren: true, name: "Parent")
        var child = BubbleFixture.circle(slot: 2, x: 0.5, y: 0.5, r: 0.2, depth: 1,
                                         seed: 0, name: "Child")
        child = BubbleCircle(node: child.node, centerX: 0.5, centerY: 0.5, radius: 0.2,
                             depth: 1, physicalBytes: parent.physicalBytes / 4,
                             logicalBytes: parent.logicalBytes / 4, itemCount: 3,
                             name: "Child", kind: .real, colorSeed: 0, hasChildren: false)
        let index = BubbleIndex(BubbleFixture.layout([parent, child]))
        let position = try #require(index.position(ofNode: child.node))
        #expect(abs(BubbleDescription.shareOfParent(position, in: index, basis: .physical) - 0.25)
                < 1e-9)
        #expect(BubbleDescription.parentName(of: position, in: index) == "Parent")

        // A depth-0 circle is measured against the focus, which the breadcrumb
        // names.
        let top = try #require(index.position(ofNode: parent.node))
        #expect(BubbleDescription.parentName(of: top, in: index) == "Users")
    }

    @Test("The same folder is described in the same words as in the other two charts")
    func wordingIsShared() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let position = try #require(index.position(at: 0))
        let circle = try #require(index[position])
        let expected = SunburstDescription.itemSentence(
            name: circle.name, kind: circle.kind,
            size: ByteFormat.string(circle.physicalBytes, basis: .physical),
            share: SunburstDescription.percentPhrase(
                BubbleDescription.shareOfParent(position, in: index, basis: .physical)),
            container: BubbleDescription.parentName(of: position, in: index),
            itemCount: circle.itemCount)
        #expect(BubbleDescription.label(for: position, in: index, basis: .physical) == expected)
    }

    @Test("An aggregate is described as a group, never as the folder it borrowed")
    func aggregateWording() throws {
        let layout = BubbleFixture.nested { depth, offset in
            depth == 0 && offset == 1 ? .aggregated(count: 42) : .real
        }
        let index = BubbleIndex(layout)
        let position = try #require(index.circles(atDepth: 0)
            .firstIndex { $0.isAggregated }
            .flatMap { index.position(at: $0) })
        let label = BubbleDescription.label(for: position, in: index, basis: .physical)
        #expect(label.contains("42 smaller items"))
        #expect(!label.contains(index[position]!.name))
        let readout = try #require(BubbleDescription.readout(for: position, in: index,
                                                             basis: .physical))
        #expect(readout.title == "42 smaller items")
        #expect(readout.footnote != nil)
    }

    @Test("A directory still being walked says its total will grow")
    func stillScanningWording() throws {
        let layout = BubbleFixture.nested { depth, offset in
            depth == 0 && offset == 0 ? .stillScanning : .real
        }
        let index = BubbleIndex(layout)
        let position = try #require(index.position(at: 0))
        #expect(BubbleDescription.label(for: position, in: index, basis: .physical)
            .contains("Still being measured"))
    }

    @Test("The roster keeps the outer levels whole and says what it left out")
    func roster() {
        let index = BubbleIndex(BubbleFixture.nested())
        let built = BubbleDescription.roster(for: index, basis: .physical)
        // 4 + 12 at depths 0 and 1, plus the 12 at depth 2 because the limit is
        // nowhere near reached.
        #expect(built.entries.count == index.circles.count)
        #expect(built.omitted == 0)
        // Entries come out in the index's own order, so VoiceOver walks the
        // chart the way it is painted.
        #expect(built.entries.map(\.position.depth) == index.circles.map { Int($0.depth) })

        let tight = BubbleDescription.roster(for: index, basis: .physical, limit: 6)
        #expect(tight.entries.count == 6)
        #expect(tight.omitted == index.circles.count - 6)
        #expect(BubbleDescription.omissionNotice(tight.omitted).contains("Zoom into a folder"))
    }

    @Test("The rotor label is the short name and the element carries the sentence")
    func rosterEntryLabels() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let entry = try #require(BubbleDescription.roster(for: index, basis: .physical)
            .entries.first)
        #expect(entry.rotorLabel == entry.circle.name)
        #expect(entry.label.count > entry.rotorLabel.count)
    }

    @Test("Basis changes the numbers, not the words")
    func basisIsRespected() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let position = try #require(index.position(at: 0))
        let physical = BubbleDescription.summary(for: position, in: index, basis: .physical)
        let logical = BubbleDescription.summary(for: position, in: index, basis: .logical)
        #expect(physical != logical)
        #expect(index[position]!.bytes(.logical) > index[position]!.bytes(.physical))
    }

    @Test("Search marks the matches and lights the path down to them")
    func search() throws {
        // Named explicitly rather than taken from the shared fixture: the
        // fixture's names repeat, and a hit whose own parent happens to share
        // its name would prove nothing about the ancestry walk.
        let outer = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.45, depth: 0,
                                         seed: 0, hasChildren: true, name: "Library")
        let middle = BubbleFixture.circle(slot: 2, x: 0.5, y: 0.5, r: 0.25, depth: 1,
                                          seed: 0, hasChildren: true, name: "Caches")
        let deepest = BubbleFixture.circle(slot: 3, x: 0.5, y: 0.5, r: 0.1, depth: 2,
                                           seed: 0, name: "com.apple.Safari")
        let index = BubbleIndex(BubbleFixture.layout([outer, middle, deepest]))
        let result = SunburstSearch(query: "safari").result(in: index)
        #expect(result.matched.contains(deepest.id))
        #expect(result.isDimming)
        // Its ancestors are kept legible rather than dimmed, or a hit three
        // levels in looks unattached to anything.
        #expect(result.onPath.contains(middle.id))
        #expect(result.onPath.contains(outer.id))
        #expect(result.emphasis(for: deepest.id) == .match)
        #expect(result.emphasis(for: middle.id) == .onPathToMatch)

        // A query with no hits dims nothing: greying out the whole chart says
        // nothing the match count does not, and makes a working window look
        // broken.
        let miss = SunburstSearch(query: "no such thing anywhere").result(in: index)
        #expect(!miss.isDimming)
        #expect(miss.opacity(for: deepest.id) == 1)
        #expect(SunburstSearch.inactive.result(in: index) == .inactive)
    }

    @Test("The legend is the outermost level, largest first")
    func legend() {
        let index = BubbleIndex(BubbleFixture.nested())
        let entries = ChartLegendEntry.entries(for: index, palette: SunburstPalette(),
                                               scheme: .light, basis: .physical)
        #expect(entries.count == 4)
        let depthZero = Set(index.circles(atDepth: 0).map(\.id))
        #expect(entries.allSatisfy { depthZero.contains($0.id) })
    }

    @Test("An empty index describes nothing rather than crashing")
    func emptyIndex() {
        let index = BubbleIndex(.empty)
        #expect(BubbleDescription.roster(for: index, basis: .physical).entries.isEmpty)
        #expect(BubbleDescription.label(for: BubblePosition(depth: 0, offset: 0),
                                        in: index, basis: .physical).isEmpty)
        #expect(BubbleDescription.readout(for: BubblePosition(depth: 0, offset: 0),
                                          in: index, basis: .physical) == nil)
        #expect(BubbleDescription.focusTitle(index) == "All items")
    }
}
