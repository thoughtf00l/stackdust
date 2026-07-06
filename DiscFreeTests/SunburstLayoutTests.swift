import XCTest
@testable import DiscFree

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

    private func extent(_ segment: SunburstSegment) -> Double {
        segment.endAngle - segment.startAngle
    }

    // MARK: - .devOnly effective sizing

    /// A focus (not inside a dev item) with:
    /// - `node_modules`  → dev root, alloc 1000 (dep1 600 + dep2 400)
    /// - `proj`          → not dev; holds an inner `node_modules` (300) + `src.js` (100), so
    ///                     alloc 400 but dev 300
    /// - `notes.txt`     → non-dev file, dev 0
    private func devOnlyFixture() -> (focus: FileNode, nodeModules: FileNode, dep1: FileNode,
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

    func testDevOnlyAnglesUseDevSizeAndSkipZeroDevSubtrees() {
        let f = devOnlyFixture()
        let segments = SunburstLayout.build(focus: f.focus, mode: .devOnly)

        // The non-dev file is skipped entirely.
        XCTAssertNil(segment(for: f.notes, in: segments), "a zero-dev subtree must be skipped")

        // Top-level angles are proportional to effective dev sizes (1000 vs 300), not
        // allocated sizes (1000 vs 400). Total angle for the two included branches is 2π.
        let nm = try! XCTUnwrap(segment(for: f.nodeModules, in: segments))
        let proj = try! XCTUnwrap(segment(for: f.proj, in: segments))
        XCTAssertEqual(extent(nm) / extent(proj), 1000.0 / 300.0, accuracy: 0.001)
        XCTAssertEqual(extent(nm) + extent(proj), 2 * .pi, accuracy: 0.001)
    }

    func testDevOnlyUsesAllocatedSizeInsideADevRoot() {
        let f = devOnlyFixture()
        let segments = SunburstLayout.build(focus: f.focus, mode: .devOnly)

        // dep1/dep2 live inside the dev root, so they are drawn and sized by allocatedSize.
        let dep1 = try! XCTUnwrap(segment(for: f.dep1, in: segments))
        let dep2 = try! XCTUnwrap(segment(for: f.dep2, in: segments))
        XCTAssertEqual(extent(dep1) / extent(dep2), 600.0 / 400.0, accuracy: 0.001)
        XCTAssertTrue(dep1.isDev)
        XCTAssertTrue(dep2.isDev)
    }

    func testDevOnlySkipsNonDevSiblingInsideAContainer() {
        let f = devOnlyFixture()
        let segments = SunburstLayout.build(focus: f.focus, mode: .devOnly)

        // Under `proj` only the inner node_modules (dev) is drawn; src.js (dev 0) is skipped.
        XCTAssertNotNil(segment(for: f.innerNM, in: segments))
        XCTAssertNil(segment(for: f.srcJS, in: segments), "a non-dev file inside a container is skipped")

        // The inner node_modules fills its parent's full arc (its 300 == proj's dev total).
        let proj = try! XCTUnwrap(segment(for: f.proj, in: segments))
        let inner = try! XCTUnwrap(segment(for: f.innerNM, in: segments))
        XCTAssertEqual(extent(inner), extent(proj), accuracy: 0.001)
    }

    func testFocusDisplayTotalIsEffectiveDevTotalInDevOnly() {
        let f = devOnlyFixture()
        XCTAssertEqual(SunburstLayout.focusDisplayTotal(focus: f.focus, mode: .devOnly), 1300)
        XCTAssertEqual(SunburstLayout.focusDisplayTotal(focus: f.focus, mode: .all), 1900)
        XCTAssertEqual(SunburstLayout.focusDisplayTotal(focus: f.focus, mode: .devHighlight), 1900)
    }

    // MARK: - .devHighlight isDev flag threading

    func testDevHighlightThreadsIsDevThroughADevRoot() {
        // container (not dev) → node_modules (dev root) → sub → mod.js
        let mod = file("mod.js", 100)
        let sub = dir("sub", [mod])
        let nodeModules = dir("node_modules", [sub])          // dev root
        let container = dir("container", [nodeModules])       // holds a dev item, not one itself
        let plain = file("plain.txt", 50)
        let focus = dir("/work", [container, plain])

        DevClassifier.classify(focus, using: catalog)
        let segments = SunburstLayout.build(focus: focus, mode: .devHighlight)

        // A container of a dev item is not itself dev, and is grayed.
        let containerSeg = try! XCTUnwrap(segment(for: container, in: segments))
        XCTAssertFalse(containerSeg.isDev)
        XCTAssertTrue(containerSeg.grayed)

        // The dev root and every descendant are dev, and keep their colors.
        let nmSeg = try! XCTUnwrap(segment(for: nodeModules, in: segments))
        XCTAssertTrue(nmSeg.isDev)
        XCTAssertFalse(nmSeg.grayed)

        let subSeg = try! XCTUnwrap(segment(for: sub, in: segments))
        XCTAssertTrue(subSeg.isDev, "a descendant of a dev root is dev")
        XCTAssertFalse(subSeg.grayed)

        let modSeg = try! XCTUnwrap(segment(for: mod, in: segments))
        XCTAssertTrue(modSeg.isDev)

        // A plain non-dev sibling is grayed.
        let plainSeg = try! XCTUnwrap(segment(for: plain, in: segments))
        XCTAssertFalse(plainSeg.isDev)
        XCTAssertTrue(plainSeg.grayed)
    }

    func testDevHighlightGeometryMatchesAll() {
        // Same sizes/angles as .all; only coloring differs.
        let f = devOnlyFixture()
        let all = SunburstLayout.build(focus: f.focus, mode: .all)
        let highlight = SunburstLayout.build(focus: f.focus, mode: .devHighlight)

        XCTAssertEqual(all.count, highlight.count)
        for node in [f.nodeModules, f.proj, f.notes, f.dep1, f.dep2, f.innerNM, f.srcJS] {
            let a = try! XCTUnwrap(segment(for: node, in: all))
            let h = try! XCTUnwrap(segment(for: node, in: highlight))
            XCTAssertEqual(a.startAngle, h.startAngle, accuracy: 1e-9)
            XCTAssertEqual(a.endAngle, h.endAngle, accuracy: 1e-9)
        }
        // .all never grays anything.
        XCTAssertFalse(all.contains { $0.grayed })
    }

    // MARK: - Rows per mode

    func testRowsAllModeIncludesEveryChildByAllocatedSize() {
        let f = devOnlyFixture()
        let rows = SunburstLayout.rows(focus: f.focus, mode: .all)

        XCTAssertEqual(rows.map { ObjectIdentifier($0.node) },
                       [f.nodeModules, f.notes, f.proj].map(ObjectIdentifier.init))
        XCTAssertEqual(rows.map(\.displaySize), [1000, 500, 400])
        XCTAssertEqual(rows.map(\.isDev), [true, false, false])
    }

    func testRowsDevHighlightMatchesAll() {
        let f = devOnlyFixture()
        let all = SunburstLayout.rows(focus: f.focus, mode: .all)
        let highlight = SunburstLayout.rows(focus: f.focus, mode: .devHighlight)

        XCTAssertEqual(all.map { ObjectIdentifier($0.node) },
                       highlight.map { ObjectIdentifier($0.node) })
        XCTAssertEqual(all.map(\.displaySize), highlight.map(\.displaySize))
        XCTAssertEqual(all.map(\.isDev), highlight.map(\.isDev))
    }

    func testRowsDevOnlyDropsNonDevAndUsesEffectiveSize() {
        let f = devOnlyFixture()
        let rows = SunburstLayout.rows(focus: f.focus, mode: .devOnly)

        // notes.txt (dev 0) is dropped; effective dev sizes drive both value and order.
        XCTAssertEqual(rows.map { ObjectIdentifier($0.node) },
                       [f.nodeModules, f.proj].map(ObjectIdentifier.init))
        XCTAssertEqual(rows.map(\.displaySize), [1000, 300])
        // A container that merely holds dev items is not itself dev (drives trash gating).
        XCTAssertEqual(rows.map(\.isDev), [true, false])
    }
}
