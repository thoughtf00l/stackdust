import XCTest
@testable import Stackdust
@testable import StackdustCore

final class SunburstLayoutTests: XCTestCase {

    // MARK: - Synthetic tree helpers (mirror DevClassifierTests; no disk involved)

    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, allocatedSize: size, parent: nil)
    }

    private func dir(_ name: String, _ children: [FileNode]) -> FileNode {
        let node = FileNode(name: name, isDirectory: true, parent: nil)
        node.children = children
        for child in children { child.parent = node }
        node.allocatedSize = children.reduce(0) { $0 + $1.allocatedSize }
        return node
    }

    private let catalog = DevItemCatalog(home: "/fake/home")

    /// The segment drawn for a given node, if any.
    private func segment(for node: FileNode, in segments: [SunburstSegment]) -> SunburstSegment? {
        segments.first { $0.node === node }
    }

    /// A focus (not inside a dev item) with:
    /// - `node_modules`  → dev root, alloc 1000 (dep1 600 + dep2 400)
    /// - `proj`          → not dev; holds an inner `node_modules` (300) + `src.js` (100), so
    ///                     alloc 400 but dev 300 (reclaimable share 0.75)
    /// - `notes.txt`     → non-dev file, dev 0
    private func classifiedFixture() -> (focus: FileNode, nodeModules: FileNode, dep1: FileNode,
                                         dep2: FileNode, proj: FileNode, innerNM: FileNode,
                                         srcJS: FileNode, notes: FileNode) {
        let dep1 = file("dep1", 600)
        let dep2 = file("dep2", 400)
        let nodeModules = dir("node_modules", [dep1, dep2])              // dev root, 1000

        let innerNM = dir("node_modules", [file("x", 300)])             // dev root, 300
        let srcJS = file("src.js", 100)
        let proj = dir("proj", [innerNM, srcJS])                        // alloc 400, dev 300

        let notes = file("notes.txt", 500)
        let focus = dir("/work", [nodeModules, proj, notes])           // alloc 1900, dev 1300

        DevClassifier.classify(focus, using: catalog)
        return (focus, nodeModules, dep1, dep2, proj, innerNM, srcJS, notes)
    }

    // MARK: - Sizing (always allocatedSize)

    func testFocusDisplayTotalIsAllocatedSize() {
        let f = classifiedFixture()
        XCTAssertEqual(SunburstLayout.focusDisplayTotal(focus: f.focus), 1900)
    }

    func testRowsIncludeEveryChildByAllocatedSize() {
        let f = classifiedFixture()
        let rows = SunburstLayout.rows(focus: f.focus, highlight: false)

        XCTAssertEqual(rows.map { ObjectIdentifier($0.node!) },
                       [f.nodeModules, f.notes, f.proj].map(ObjectIdentifier.init))
        XCTAssertEqual(rows.map(\.displaySize), [1000, 500, 400])
        // A container that merely holds dev items is not itself dev (drives trash consequence text).
        XCTAssertEqual(rows.map(\.isDev), [true, false, false])
    }

    // MARK: - Highlight tinting

    /// Toggling highlight never moves a slice: geometry is `allocatedSize` in both cases. With
    /// highlighting off every fraction is forced to 1 so `color` renders the full branch color.
    func testHighlightPreservesGeometryAndForcesFullColorWhenOff() {
        let f = classifiedFixture()
        let plain = SunburstLayout.build(focus: f.focus, highlight: false, palette: ThemeStore.defaultPalette)
        let highlight = SunburstLayout.build(focus: f.focus, highlight: true, palette: ThemeStore.defaultPalette)

        XCTAssertEqual(plain.count, highlight.count)
        for node in [f.nodeModules, f.proj, f.notes, f.dep1, f.dep2, f.innerNM, f.srcJS] {
            let p = try! XCTUnwrap(segment(for: node, in: plain))
            let h = try! XCTUnwrap(segment(for: node, in: highlight))
            XCTAssertEqual(p.startAngle, h.startAngle, accuracy: 1e-9)
            XCTAssertEqual(p.endAngle, h.endAngle, accuracy: 1e-9)
        }
        XCTAssertTrue(plain.allSatisfy { $0.reclaimableFraction == 1 })
    }

    /// Each segment's fraction reflects its reclaimable share: 1 for a dev item and its
    /// descendants, `devSize / allocatedSize` for a container, 0 for clean content.
    func testHighlightFractionsReflectReclaimableShare() {
        let f = classifiedFixture()
        let segments = SunburstLayout.build(focus: f.focus, highlight: true, palette: ThemeStore.defaultPalette)

        // Dev item → exactly 1, and so is every descendant inside it.
        XCTAssertEqual(try! XCTUnwrap(segment(for: f.nodeModules, in: segments)).reclaimableFraction,
                       1, accuracy: 1e-9)
        XCTAssertEqual(try! XCTUnwrap(segment(for: f.dep1, in: segments)).reclaimableFraction,
                       1, accuracy: 1e-9)
        // Container with mixed content → its reclaimable share (300 / 400).
        XCTAssertEqual(try! XCTUnwrap(segment(for: f.proj, in: segments)).reclaimableFraction,
                       0.75, accuracy: 1e-9)
        // Clean file → 0 (renders gray).
        XCTAssertEqual(try! XCTUnwrap(segment(for: f.notes, in: segments)).reclaimableFraction,
                       0, accuracy: 1e-9)
    }

    /// The bug this replaces: a container whose only reclaimable content sits deeper than the
    /// visible rings used to render all-gray. Now it gets a partial fraction (strictly between
    /// 0 and 1) even though the buried dev item is never drawn.
    func testHighlightTintsContainerWithDeepJunkPartially() {
        let deepNM = dir("node_modules", [file("dep", 200)])            // dev root, 200
        // Bury it deeper than SunburstLayout.maxDepth (5) below the container.
        var buried: FileNode = deepNM
        for level in (1...6).reversed() {
            buried = dir("level\(level)", [buried])
        }
        let plain = file("data.bin", 800)
        let container = dir("container", [buried, plain])               // alloc 1000, dev 200
        let clean = file("readme.txt", 500)                             // dev 0
        let focus = dir("/work", [container, clean])

        DevClassifier.classify(focus, using: catalog)
        let segments = SunburstLayout.build(focus: focus, highlight: true, palette: ThemeStore.defaultPalette)

        // The container is not itself a dev item, but its reclaimable share (200 / 1000)
        // tints it between gray and full color.
        let containerSeg = try! XCTUnwrap(segment(for: container, in: segments))
        XCTAssertFalse(containerSeg.isDev)
        XCTAssertGreaterThan(containerSeg.reclaimableFraction, 0)
        XCTAssertLessThan(containerSeg.reclaimableFraction, 1)
        XCTAssertEqual(containerSeg.reclaimableFraction, 0.2, accuracy: 1e-9)

        // A clean sibling stays gray.
        XCTAssertEqual(try! XCTUnwrap(segment(for: clean, in: segments)).reclaimableFraction, 0)

        // The buried dev item is beyond maxDepth, so it is never drawn — the container's tint is
        // the only on-screen signal that junk exists below.
        XCTAssertNil(segment(for: deepNM, in: segments))
    }

    // MARK: - isDev flag threading

    func testHighlightThreadsIsDevThroughADevRoot() {
        // container (not dev) → node_modules (dev root) → sub → mod.js
        let mod = file("mod.js", 100)
        let sub = dir("sub", [mod])
        let nodeModules = dir("node_modules", [sub])          // dev root
        let container = dir("container", [nodeModules])       // holds a dev item, not one itself
        let plain = file("plain.txt", 50)
        let focus = dir("/work", [container, plain])

        DevClassifier.classify(focus, using: catalog)
        let segments = SunburstLayout.build(focus: focus, highlight: true, palette: ThemeStore.defaultPalette)

        // A container of a dev item is not itself dev. Here its content is entirely reclaimable
        // (devSize == allocatedSize), so its fraction is 1.
        let containerSeg = try! XCTUnwrap(segment(for: container, in: segments))
        XCTAssertFalse(containerSeg.isDev)
        XCTAssertEqual(containerSeg.reclaimableFraction, 1, accuracy: 1e-9)

        // The dev root and every descendant are dev, with fraction 1.
        let nmSeg = try! XCTUnwrap(segment(for: nodeModules, in: segments))
        XCTAssertTrue(nmSeg.isDev)
        XCTAssertEqual(nmSeg.reclaimableFraction, 1, accuracy: 1e-9)

        let subSeg = try! XCTUnwrap(segment(for: sub, in: segments))
        XCTAssertTrue(subSeg.isDev, "a descendant of a dev root is dev")

        let modSeg = try! XCTUnwrap(segment(for: mod, in: segments))
        XCTAssertTrue(modSeg.isDev)

        // A plain non-dev sibling has no reclaimable content → fraction 0.
        let plainSeg = try! XCTUnwrap(segment(for: plain, in: segments))
        XCTAssertFalse(plainSeg.isDev)
        XCTAssertEqual(plainSeg.reclaimableFraction, 0, accuracy: 1e-9)
    }

    // MARK: - Tail grouping ("Other")

    /// A directory with two large children and a long tail of sub-0.1% ones renders the two large
    /// wedges plus one synthetic "Other" wedge that spans the tail's combined angle and closes the
    /// ring. The panel mirrors this: two rows plus a trailing "Other — N items" row.
    func testTailGroupsIntoOneOtherWedgeAndClosesRing() {
        let big1 = file("big1", 120_000)
        let big2 = file("big2", 100_000)
        let tiny = (0..<50).map { file("tiny\($0)", 1) }           // each 1 B, well under 0.1%
        let focus = dir("/work", [big1, big2] + tiny)              // total 220_050

        let segments = SunburstLayout.build(focus: focus, highlight: false, palette: ThemeStore.defaultPalette)

        let others = segments.filter(\.isOther)
        XCTAssertEqual(others.count, 1, "the whole tail collapses to a single wedge")
        let other = others[0]
        XCTAssertNil(other.node, "the Other wedge has no backing node")
        XCTAssertEqual(other.size, 50, "its size is the sum of the 50 tail entries")
        XCTAssertEqual(other.label, "Other")

        // The two large children are drawn as their own segments (not folded into Other).
        XCTAssertNotNil(segment(for: big1, in: segments))
        XCTAssertNotNil(segment(for: big2, in: segments))
        // Files have no children, so nothing recurses: two big wedges + one Other.
        XCTAssertEqual(segments.count, 3)

        // The Other wedge is last and its end closes the full circle.
        XCTAssertEqual(other.endAngle, 2 * Double.pi, accuracy: 1e-9)
        let maxEnd = segments.map(\.endAngle).max() ?? 0
        XCTAssertEqual(maxEnd, 2 * Double.pi, accuracy: 1e-9)

        // Panel: the two children, then one trailing "Other — 50 items" row.
        let rows = SunburstLayout.rows(focus: focus, highlight: false)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.prefix(2).map { ObjectIdentifier($0.node!) },
                       [big1, big2].map(ObjectIdentifier.init))
        XCTAssertTrue(rows.prefix(2).allSatisfy { !$0.isOther })
        let otherRow = rows[2]
        XCTAssertTrue(otherRow.isOther)
        XCTAssertNil(otherRow.node, "not drillable / no Reveal / no Trash: it has no node")
        XCTAssertEqual(otherRow.name, "Other")
        XCTAssertEqual(otherRow.otherCount, 50)
        XCTAssertEqual(otherRow.displaySize, 50)
        XCTAssertFalse(otherRow.isDev)
    }

    /// A lone sub-threshold entry is left as-is, never wrapped in an "Other" of one.
    func testSingleTinyEntryIsNotGrouped() {
        let big1 = file("big1", 120_000)
        let big2 = file("big2", 100_000)
        let tiny = file("tiny", 1)
        let focus = dir("/work", [big1, big2, tiny])

        let segments = SunburstLayout.build(focus: focus, highlight: false, palette: ThemeStore.defaultPalette)
        XCTAssertTrue(segments.allSatisfy { !$0.isOther }, "no synthetic wedge for a single tiny entry")
        XCTAssertTrue(segments.allSatisfy { $0.node != nil })

        let rows = SunburstLayout.rows(focus: focus, highlight: false)
        XCTAssertTrue(rows.allSatisfy { !$0.isOther }, "the tiny entry keeps its own row")
        XCTAssertEqual(rows.count, 3)
        XCTAssertNotNil(rows.first { $0.node === tiny })
    }

    /// The Other wedge's `reclaimableFraction` is the tail's combined `devSize / size`, so highlight
    /// mode reports the grouped tail's reclaimable share honestly. devSize is set directly here (no
    /// classifier pass) so the expected share is exact.
    func testOtherWedgeReflectsTailReclaimableShare() {
        let big1 = file("big1", 120_000)
        let big2 = file("big2", 100_000)
        // Four tail files of 10 B: two fully reclaimable, two clean → combined share 20 / 40 = 0.5.
        let devA = file("devA", 10); devA.devSize = 10
        let devB = file("devB", 10); devB.devSize = 10
        let cleanA = file("cleanA", 10)           // devSize 0
        let cleanB = file("cleanB", 10)           // devSize 0
        let focus = dir("/work", [big1, big2, devA, devB, cleanA, cleanB])

        let highlighted = SunburstLayout.build(focus: focus, highlight: true, palette: ThemeStore.defaultPalette)
        let other = try! XCTUnwrap(highlighted.first(where: \.isOther))
        XCTAssertNil(other.node)
        XCTAssertEqual(other.reclaimableFraction, 0.5, accuracy: 1e-9)

        // Highlighting off forces the fraction to 1, like every other segment.
        let plain = SunburstLayout.build(focus: focus, highlight: false, palette: ThemeStore.defaultPalette)
        let plainOther = try! XCTUnwrap(plain.first(where: \.isOther))
        XCTAssertEqual(plainOther.reclaimableFraction, 1, accuracy: 1e-9)
    }

    // MARK: - Panel rows tint like their matching wedge

    /// Every panel row carries the same reclaimable fraction as the depth-1 wedge for the same
    /// node, so a row and its wedge blend to the same color. Asserted highlight on and off.
    func testRowFractionsMatchMatchingSegments() {
        let f = classifiedFixture()

        // Highlight on: each row's fraction equals its matching depth-1 segment's fraction.
        let segments = SunburstLayout.build(focus: f.focus, highlight: true, palette: ThemeStore.defaultPalette)
        let rows = SunburstLayout.rows(focus: f.focus, highlight: true)
        for row in rows {
            let node = try! XCTUnwrap(row.node)            // this fixture has no "Other" row
            let seg = try! XCTUnwrap(segment(for: node, in: segments))
            XCTAssertEqual(row.reclaimableFraction, seg.reclaimableFraction, accuracy: 1e-9,
                           "row \(row.name) must tint like its wedge")
        }
        // Sanity: the mix spans the range — dev root 1, mixed container 0.75, clean file 0
        // (rows are size-sorted: node_modules 1000, notes 500, proj 400).
        XCTAssertEqual(rows.map(\.reclaimableFraction), [1.0, 0.0, 0.75])

        // Highlight off: every row is forced to full color (fraction 1), like every segment.
        let plainRows = SunburstLayout.rows(focus: f.focus, highlight: false)
        XCTAssertTrue(plainRows.allSatisfy { $0.reclaimableFraction == 1 })
    }

    /// The synthetic "Other" row carries the same combined reclaimable share as the "Other" wedge,
    /// so the grouped tail tints identically in the panel and the chart. Highlight on and off.
    func testOtherRowFractionMatchesOtherWedge() {
        let big1 = file("big1", 120_000)
        let big2 = file("big2", 100_000)
        // Four 10 B tail files: two fully reclaimable, two clean → combined share 20 / 40 = 0.5.
        let devA = file("devA", 10); devA.devSize = 10
        let devB = file("devB", 10); devB.devSize = 10
        let cleanA = file("cleanA", 10)
        let cleanB = file("cleanB", 10)
        let focus = dir("/work", [big1, big2, devA, devB, cleanA, cleanB])

        let segments = SunburstLayout.build(focus: focus, highlight: true, palette: ThemeStore.defaultPalette)
        let rows = SunburstLayout.rows(focus: focus, highlight: true)
        let otherWedge = try! XCTUnwrap(segments.first(where: \.isOther))
        let otherRow = try! XCTUnwrap(rows.first(where: \.isOther))
        XCTAssertEqual(otherRow.reclaimableFraction, otherWedge.reclaimableFraction, accuracy: 1e-9)
        XCTAssertEqual(otherRow.reclaimableFraction, 0.5, accuracy: 1e-9)

        // Highlight off forces the Other row to fraction 1, like the Other wedge.
        let plainRows = SunburstLayout.rows(focus: focus, highlight: false)
        XCTAssertEqual(try! XCTUnwrap(plainRows.first(where: \.isOther)).reclaimableFraction, 1,
                       accuracy: 1e-9)
    }
}
