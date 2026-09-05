import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("What the chart says out loud")
struct SunburstDescriptionTests {
    @Test("A ring-0 wedge's share is measured against the layout total")
    func shareAtRingZero() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 3]]))
        let half = SunburstDescription.shareOfParent(SunburstPosition(ring: 0, offset: 0),
                                                     in: index, basis: .physical)
        #expect(abs(half - 0.25) < 0.001)
        let rest = SunburstDescription.shareOfParent(SunburstPosition(ring: 0, offset: 1),
                                                     in: index, basis: .physical)
        #expect(abs(rest - 0.75) < 0.001)
    }

    @Test("A deeper wedge's share is measured against its own parent")
    func shareAgainstParent() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1], [1, 3]]))
        let share = SunburstDescription.shareOfParent(SunburstPosition(ring: 1, offset: 1),
                                                      in: index, basis: .physical)
        #expect(abs(share - 0.75) < 0.005)
    }

    @Test("Shares add up to the whole within a parent")
    func sharesSumToOne() {
        let index = SunburstIndex(Fixture.layout(levels: [[2, 3, 5], [1, 1, 2]]))
        let navigator = SunburstNavigator(index: index)
        for offset in 0..<index.count(inRing: 0) {
            let parent = SunburstPosition(ring: 0, offset: offset)
            let total = navigator.children(of: parent).reduce(0.0) {
                $0 + SunburstDescription.shareOfParent($1, in: index, basis: .physical)
            }
            #expect(abs(total - 1) < 0.01, "children of \(offset) summed to \(total)")
        }
    }

    @Test("Both size bases are reportable and labelled")
    func bothBases() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1]]))
        let position = SunburstPosition(ring: 0, offset: 0)
        let physical = SunburstDescription.label(for: position, in: index, basis: .physical)
        let logical = SunburstDescription.label(for: position, in: index, basis: .logical)
        #expect(physical.contains("on disk"))
        #expect(logical.contains("apparent"))
        #expect(physical != logical)
    }

    @Test("A tiny share is described honestly rather than rounded to nothing")
    func tinySharePhrasing() {
        #expect(SunburstDescription.percentPhrase(0.004) == "less than 1 percent")
        #expect(SunburstDescription.percentPhrase(0.31) == "31 percent")
        #expect(SunburstDescription.percentPhrase(0) == "0 percent")
        #expect(SunburstDescription.percentPhrase(1) == "100 percent")
    }

    @Test("An aggregate says it is a group, and how many things are in it")
    func aggregateLabel() {
        let index = SunburstIndex(Fixture.layout(
            levels: [[1, 1]],
            kindForRing: { _, child in child == 0 ? .aggregated(count: 412) : .real }))
        let label = SunburstDescription.label(for: SunburstPosition(ring: 0, offset: 0),
                                              in: index, basis: .physical)
        #expect(label.contains("412"))
        #expect(label.contains("smaller items"))
        #expect(label.contains("too small to draw"))
    }

    @Test("A directory still being walked says its total will grow")
    func stillScanningLabel() {
        let index = SunburstIndex(Fixture.layout(
            levels: [[1, 1]],
            kindForRing: { _, child in child == 0 ? .stillScanning : .real }))
        let label = SunburstDescription.label(for: SunburstPosition(ring: 0, offset: 0),
                                              in: index, basis: .physical)
        #expect(label.contains("so far"))
        #expect(label.contains("will grow"))
    }

    @Test("A label names the item, its size and what it sits inside")
    func realLabel() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1], [1, 1]]))
        let position = SunburstPosition(ring: 1, offset: 0)
        guard let wedge = index[position] else { Issue.record("no wedge"); return }
        let label = SunburstDescription.label(for: position, in: index, basis: .physical)
        #expect(label.contains(wedge.name))
        #expect(label.contains("percent of"))
        #expect(label.contains(SunburstDescription.parentName(of: position, in: index)))
    }

    @Test("The chart never claims to be a live view of the disk")
    func provenanceIsHonest() {
        let complete = SunburstIndex(Fixture.layout(levels: [[1]], isComplete: true))
        #expect(SunburstDescription.provenance(complete).hasPrefix("as of "))
        let running = SunburstIndex(Fixture.layout(levels: [[1]], isComplete: false))
        #expect(running.isComplete == false)
        #expect(SunburstDescription.provenance(running).contains("still measuring"))
        #expect(SunburstDescription.asOf(.distantPast) == "not measured yet")
    }

    @Test("The roster keeps the inner rings whole and reports what it left out")
    func rosterCoverage() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1]]))
        #expect(index.wedges.count == 4 + 16 + 64)

        let (entries, omitted) = SunburstDescription.roster(for: index, basis: .physical, limit: 30)
        #expect(entries.count == 30)
        #expect(omitted == index.wedges.count - 30)
        // Rings 0 and 1 are 20 wedges; all of them must be present.
        let inner = entries.filter { $0.position.ring <= 1 }
        #expect(inner.count == 20)
        // Presented in the order the chart draws them, so a sweep of the list
        // is a sweep of the chart.
        for (a, b) in zip(entries, entries.dropFirst()) {
            #expect(a.position.ring < b.position.ring
                || (a.position.ring == b.position.ring && a.wedge.startAngle <= b.wedge.startAngle))
        }
        #expect(SunburstDescription.omissionNotice(omitted).contains("Zoom into"))
    }

    @Test("A layout that fits under the limit is listed in full")
    func rosterFits() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 2, 3]]))
        let (entries, omitted) = SunburstDescription.roster(for: index, basis: .physical, limit: 400)
        #expect(entries.count == index.wedges.count)
        #expect(omitted == 0)
    }

    @Test("An empty layout has nothing to say and does not crash saying it")
    func emptyRoster() {
        let (entries, omitted) = SunburstDescription.roster(for: SunburstIndex(.empty), basis: .physical)
        #expect(entries.isEmpty)
        #expect(omitted == 0)
    }

    /// Loupe shows you your machine; it does not tidy it. These words are
    /// banned from anything a user can read.
    @Test("No user-facing string uses the vocabulary of a cleaner app")
    func vocabularyIsHonest() {
        let banned = ["faster", "optimize", "optimise", "clean", "junk", "boost"]
        let index = SunburstIndex(Fixture.layout(
            levels: [[1, 2], [1, 1]],
            kindForRing: { ring, child in
                if ring == 1, child == 0 { .aggregated(count: 12) }
                else if ring == 1 { .stillScanning }
                else { .real }
            }))

        var strings: [String] = [
            SunburstDescription.focusTitle(index),
            SunburstDescription.focusTotal(index, basis: .physical),
            SunburstDescription.provenance(index),
            SunburstDescription.omissionNotice(40),
            SunburstDescription.percentPhrase(0.001),
        ]
        for ramp in SunburstRamp.allCases {
            strings.append(ramp.label)
            strings.append(ramp.explanation)
        }
        for ring in 0..<index.ringCount {
            for offset in 0..<index.count(inRing: ring) {
                let position = SunburstPosition(ring: ring, offset: offset)
                strings.append(SunburstDescription.label(for: position, in: index, basis: .physical))
                strings.append(SunburstDescription.summary(for: position, in: index, basis: .logical))
            }
        }

        for string in strings {
            let lowered = string.lowercased()
            for word in banned {
                #expect(!lowered.contains(word), "\"\(string)\" contains \"\(word)\"")
            }
        }
    }
}
