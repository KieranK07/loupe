import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Tile labels obey the same rules as wedge labels")
struct TreemapLabelTests {

    private func placed(_ index: TreemapIndex, _ metrics: TreemapMetrics,
                        hovered: TreemapPosition? = nil,
                        keyboardFocus: TreemapPosition? = nil) -> [PlacedLabel] {
        let slots = TreemapLabels.slots(for: index, metrics: metrics,
                                        hovered: hovered, keyboardFocus: keyboardFocus)
        return LabelPlacement.place(slots: slots, measure: FakeText.intrinsic)
    }

    private func owner(of label: PlacedLabel, in index: TreemapIndex) -> TreemapTile? {
        index.position(ofNode: NodeRef(rawValue: label.id)).flatMap { index[$0] }
    }

    @Test("No two tile labels overlap", arguments: [[4, 3], [5, 4, 3], [3, 3, 3, 2]])
    func noOverlaps(levels: [Int]) {
        let index = TreemapIndex(TreemapFixture.layout(levels: levels))
        let metrics = TreemapFixture.metrics(width: 960, height: 640)
        let labels = placed(index, metrics)
        #expect(!labels.isEmpty, "nothing was labelled at all")
        #expect(overlappingPairs(labels.map(\.box)) == 0)
    }

    @Test("A label that is not on a plate stays inside its own tile")
    func staysInsideTile() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [5, 4, 3]))
        let metrics = TreemapFixture.metrics(width: 960, height: 640)
        for label in placed(index, metrics) where !label.needsPlate {
            let tile = try #require(owner(of: label, in: index))
            let rect = metrics.rect(for: tile)
            for corner in label.box.corners {
                #expect(rect.insetBy(dx: -1e-6, dy: -1e-6).contains(corner),
                        "\(label.text) escaped \(tile.name)")
            }
        }
    }

    @Test("Only the outermost level writes over its own children, and only on a plate")
    func headersAreOutermostOnly() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 3, 3]))
        let metrics = TreemapFixture.metrics(width: 960, height: 640)
        var headers = 0
        for label in placed(index, metrics) where label.needsPlate {
            let tile = try #require(owner(of: label, in: index))
            #expect(tile.depth == 0, "\(tile.name) at depth \(tile.depth) claimed a plate")
            headers += 1
        }
        #expect(headers > 0, "the top-level folders lost their names entirely")
    }

    @Test("A tile its children have covered is not labelled across the middle")
    func coveredTilesAreNotLabelledInPlace() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 3]))
        let metrics = TreemapFixture.metrics(width: 960, height: 640)
        for label in placed(index, metrics) where !label.needsPlate {
            let tile = try #require(owner(of: label, in: index))
            let position = try #require(index.position(ofNode: tile.node))
            #expect(index.exposure(of: position).visibleFraction >= TreemapLabels.exposureThreshold,
                    "\(tile.name) is buried but was labelled in place")
        }
    }

    @Test("Tiles too small to read are left unlabelled")
    func legibilityFloor() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [6, 5, 4]))
        let metrics = TreemapFixture.metrics(width: 500, height: 340)
        for label in placed(index, metrics) where !label.needsPlate {
            let tile = try #require(owner(of: label, in: index))
            let rect = metrics.rect(for: tile)
            #expect(rect.width >= TreemapLabels.minimumLabelWidth)
            #expect(rect.height >= TreemapLabels.nominalLineHeight)
        }
    }

    @Test("The tile under the pointer is labelled however small it is")
    func hoverAlwaysLabelled() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [6, 5, 4]))
        let metrics = TreemapFixture.metrics(width: 500, height: 340)
        // The smallest tile at the deepest level.
        let deepest = index.depthCount - 1
        let range = index.depthRanges[deepest]
        var smallest = range.lowerBound
        for i in range where index.tiles[i].frame.area < index.tiles[smallest].frame.area {
            smallest = i
        }
        let position = try #require(index.position(at: smallest))
        let target = index.tiles[smallest]

        #expect(!placed(index, metrics).contains { $0.id == target.id },
                "the premise: too small to label normally")
        let labels = placed(index, metrics, hovered: position)
        let label = try #require(labels.first { $0.id == target.id })
        #expect(label.needsPlate)
        #expect(overlappingPairs(labels.map(\.box)) == 0)
    }

    @Test("An aggregate tile says what it is rather than the name it borrowed")
    func aggregatesSayWhatTheyAre() throws {
        let index = TreemapIndex(TreemapFixture.layout(
            levels: [3],
            kindForDepth: { _, child in child == 0 ? .aggregated(count: 318) : .real }))
        let metrics = TreemapFixture.metrics(width: 900, height: 600)
        let aggregate = index.tiles[0]
        let label = try #require(placed(index, metrics).first { $0.id == aggregate.id })
        #expect(label.text.hasPrefix("318"))
        #expect(!label.text.contains(aggregate.name))
    }

    @Test("Tile labels are never rotated: a rectangle has no ring to follow")
    func alwaysHorizontal() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 4]))
        let metrics = TreemapFixture.metrics()
        #expect(TreemapLabels.slots(for: index, metrics: metrics).allSatisfy { $0.rotation == 0 })
    }
}

@Suite("What the treemap says out loud")
struct TreemapDescriptionTests {

    @Test("A tile is described in the same words the sunburst would use")
    func sameSentence() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [3, 2]))
        let position = try #require(index.position(at: index.depthRanges[1].lowerBound))
        let tile = try #require(index[position])
        let sentence = TreemapDescription.label(for: position, in: index, basis: .physical)
        #expect(sentence.contains(tile.name))
        #expect(sentence.contains("percent of"))
        #expect(sentence.contains(TreemapDescription.parentName(of: position, in: index)))
    }

    @Test("A share is taken against the containing tile, not the whole volume")
    func shareOfParent() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [2, 2]))
        for i in index.depthRanges[1] {
            let position = try #require(index.position(at: i))
            let share = TreemapDescription.shareOfParent(position, in: index, basis: .physical)
            #expect(share > 0 && share <= 1)
        }
        // The depth-0 tiles are measured against the focus total instead.
        let top = try #require(index.position(at: 0))
        #expect(TreemapDescription.shareOfParent(top, in: index, basis: .physical) <= 1)
    }

    @Test("The roster covers the outer levels and admits what it left out")
    func roster() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 4, 4]))
        let built = TreemapDescription.roster(for: index, basis: .physical, limit: 30)
        #expect(built.entries.count <= 30)
        #expect(built.omitted == index.tiles.count - built.entries.count)
        #expect(TreemapDescription.omissionNotice(built.omitted).contains("Zoom into"))
    }

    @Test("A still-scanning tile says its total will grow")
    func stillScanning() throws {
        let index = TreemapIndex(TreemapFixture.layout(
            levels: [2], kindForDepth: { _, child in child == 0 ? .stillScanning : .real }))
        let position = try #require(index.position(at: 0))
        let sentence = TreemapDescription.label(for: position, in: index, basis: .physical)
        #expect(sentence.contains("so far"))
        #expect(sentence.contains("will grow"))
    }

    @Test("No user-facing string uses the vocabulary of a cleaner app")
    func vocabularyIsHonest() {
        let banned = ["faster", "optimize", "optimise", "clean", "junk", "boost"]
        let index = TreemapIndex(TreemapFixture.layout(
            levels: [2, 2],
            kindForDepth: { depth, child in
                if depth == 1, child == 0 { .aggregated(count: 12) }
                else if depth == 1 { .stillScanning }
                else { .real }
            }))
        var strings: [String] = [
            TreemapDescription.focusTitle(index),
            TreemapDescription.focusTotal(index, basis: .physical),
            TreemapDescription.provenance(index),
            TreemapDescription.omissionNotice(40),
        ]
        for i in index.tiles.indices {
            guard let position = index.position(at: i) else { continue }
            strings.append(TreemapDescription.label(for: position, in: index, basis: .physical))
            strings.append(TreemapDescription.summary(for: position, in: index, basis: .logical))
            strings.append(SunburstDescription.chartLabel(for: index.tiles[i].kind,
                                                          name: index.tiles[i].name))
        }
        for string in strings {
            let lowered = string.lowercased()
            for word in banned {
                #expect(!lowered.contains(word), "\"\(string)\" contains \"\(word)\"")
            }
        }
    }
}
