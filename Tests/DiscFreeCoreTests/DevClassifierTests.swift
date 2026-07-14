import XCTest
@testable import DiscFreeCore

final class DevClassifierTests: XCTestCase {

    // MARK: - Synthetic tree helpers (mirror TreeEditorTests; no disk involved)

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

    /// A fake home so the absolute-path rules point at a synthetic tree, not the real machine.
    private let home = "/fake/home"
    private var catalog: DevItemCatalog { DevItemCatalog(home: home) }

    // MARK: - Absolute path rules

    func testAbsolutePathRuleMatchesUnderInjectedHome() {
        let derived = dir("DerivedData", [file("build.o", 1_000)])
        let xcode = dir("Xcode", [derived])
        let root = dir(home, [dir("Library", [dir("Developer", [xcode])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(derived.devCategory, .xcodeBuild)
        XCTAssertEqual(derived.devSize, 1_000)
        XCTAssertEqual(root.devSize, 1_000, "aggregated up through non-matching ancestors")
        // The whole subtree is dev by definition, so its descendants are not descended into.
        XCTAssertNil(derived.children!.first!.devCategory)
        XCTAssertEqual(derived.children!.first!.devSize, 0)
    }

    func testMultiComponentAbsoluteRuleMatchesOnlyTheLeaf() {
        // `.gradle/caches` is a rule; the parent `.gradle` is not.
        let caches = dir("caches", [file("lib.jar", 4_000)])
        let gradle = dir(".gradle", [caches, file("gradle.properties", 10)])
        let root = dir(home, [gradle])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(caches.devCategory, .packageCache)
        XCTAssertNil(gradle.devCategory, "only .gradle/caches is a rule, not .gradle itself")
        XCTAssertEqual(gradle.devSize, 4_000)
    }

    func testXcarchiveBundleUnderArchivesMatchesPerBuild() {
        // Each `.xcarchive` bundle is its own xcodeArchives item so a single stale build can be
        // trashed while the rest stay. The `Archives` root and its date-folder children no longer
        // match — they aggregate via devSize like any plain container.
        let build = dir("MyApp 01.02.24, 10.30.xcarchive", [file("Info.plist", 2_000)])
        let dateFolder = dir("2024-02-01", [build])
        let archives = dir("Archives", [dateFolder])
        let xcode = dir("Xcode", [archives])
        let root = dir(home, [dir("Library", [dir("Developer", [xcode])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(build.devCategory, .xcodeArchives)
        XCTAssertEqual(build.devSize, 2_000)
        XCTAssertNil(archives.devCategory, "the Archives root itself no longer matches")
        XCTAssertNil(dateFolder.devCategory, "the date folder is a plain container")
        XCTAssertEqual(dateFolder.devSize, 2_000, "aggregated from the .xcarchive child")
        XCTAssertEqual(archives.devSize, 2_000, "aggregated up through the date folder")
    }

    func testXcarchiveMatchesInCustomLocation() {
        // A `.xcarchive` is unambiguous wherever it lives, so a custom Organizer location matches.
        let build = dir("Nightly.xcarchive", [file("dSYMs", 5_000)])
        let root = dir("/work", [dir("CustomArchives", [build])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(build.devCategory, .xcodeArchives)
        XCTAssertEqual(build.devSize, 5_000)
    }

    func testXcarchiveFileDoesNotMatch() {
        // The catalog matches directories only (the `node.isDirectory` guard in `category(for:)`),
        // so a FILE whose name merely ends in `.xcarchive` must not match.
        let bogus = file("stray.xcarchive", 3_000)
        let root = dir("/work", [dir("misc", [bogus])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertNil(bogus.devCategory, "a file named *.xcarchive must not match (directories only)")
        XCTAssertEqual(root.devSize, 0)
    }

    func testGradleWrapperClassifiedAsPackageCache() {
        let wrapper = dir("wrapper", [file("dists", 5_000)])
        let gradle = dir(".gradle", [wrapper])
        let root = dir(home, [gradle])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(wrapper.devCategory, .packageCache)
        XCTAssertEqual(wrapper.devSize, 5_000)
        XCTAssertNil(gradle.devCategory, "the enclosing .gradle has no project marker sibling here")
    }

    func testKonanClassifiedAsPackageCache() {
        let konan = dir(".konan", [file("kotlin-native-prebuilt", 8_000)])
        let root = dir(home, [konan])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(konan.devCategory, .packageCache)
        XCTAssertEqual(konan.devSize, 8_000)
    }

    func testAndroidSystemImagesClassifiedAsPackageCache() {
        let images = dir("system-images", [file("android-34", 12_000)])
        let sdk = dir("sdk", [images])
        let root = dir(home, [dir("Library", [dir("Android", [sdk])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(images.devCategory, .packageCache)
        XCTAssertEqual(images.devSize, 12_000)
    }

    func testAndroidAvdChildrenClassifiedPerDevice() {
        // Each `<name>.avd` directory is its own simulators item; the `avd` parent itself does not
        // match, and the sibling `.ini` file stays unmatched (children-of matches directories only).
        let pixel = dir("Pixel_6.avd", [file("userdata.img", 3_000)])
        let iniFile = file("Pixel_6.ini", 50)
        let avd = dir("avd", [pixel, iniFile])
        let android = dir(".android", [avd])
        let root = dir(home, [android])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(pixel.devCategory, .simulators)
        XCTAssertEqual(pixel.devSize, 3_000)
        XCTAssertNil(iniFile.devCategory, "a file child of avd must not match")
        XCTAssertNil(avd.devCategory, "the avd parent itself must not match the children-of rule")
        XCTAssertEqual(avd.devSize, 3_000, "aggregated from the device child, not the .ini file")
    }

    func testCoreSimulatorDevicesClassifiedPerDevice() {
        // Each UUID-named device directory is its own simulators item; the Devices parent itself
        // does not match, so the user can reclaim one simulator instead of the whole folder.
        let deviceA = dir("11111111-2222-3333-4444-555555555555", [file("data.img", 8_000)])
        let deviceB = dir("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", [file("data.img", 6_000)])
        let devices = dir("Devices", [deviceA, deviceB])
        let coreSim = dir("CoreSimulator", [devices])
        let root = dir(home, [dir("Library", [dir("Developer", [coreSim])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(deviceA.devCategory, .simulators)
        XCTAssertEqual(deviceB.devCategory, .simulators)
        XCTAssertEqual(deviceA.devSize, 8_000)
        XCTAssertNil(devices.devCategory, "the Devices parent itself must not match")
        XCTAssertEqual(devices.devSize, 14_000, "aggregated from both device children")
    }

    // MARK: - Per-device/OS-version device-support rule

    func testDeviceSupportChildrenClassifiedPerDevice() {
        // Each device/OS-version folder inside a `<platform> DeviceSupport` container is its own
        // deviceSupport item across platforms; the container itself does not match (its devSize
        // aggregates the children), so the user can reclaim one OS version at a time.
        let iosVersion = dir("iPhone14,2 15.0 (19A346)", [file("Symbols", 500)])
        let iosOld = dir("15.0 (19A346) arm64e", [file("Symbols", 250)])
        let iosContainer = dir("iOS DeviceSupport", [iosVersion, iosOld])
        let watchVersion = dir("Watch6,1 10.0 (21R355)", [file("Symbols", 300)])
        let watchContainer = dir("watchOS DeviceSupport", [watchVersion])
        let xcode = dir("Xcode", [iosContainer, watchContainer])
        let root = dir(home, [dir("Library", [dir("Developer", [xcode])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(iosVersion.devCategory, .deviceSupport)
        XCTAssertEqual(iosOld.devCategory, .deviceSupport)
        XCTAssertEqual(watchVersion.devCategory, .deviceSupport)
        XCTAssertEqual(iosVersion.devSize, 500)
        XCTAssertNil(iosContainer.devCategory,
                     "the '<platform> DeviceSupport' container itself must not match")
        XCTAssertEqual(iosContainer.devSize, 750, "aggregated from both version children")
        XCTAssertNil(watchContainer.devCategory)
        XCTAssertEqual(watchContainer.devSize, 300)
    }

    func testDeviceSupportContainerRequiresLeadingSpaceSuffix() {
        // A container whose name is exactly "DeviceSupport" (no leading " " before the suffix) is
        // not a `<platform> DeviceSupport` directory, so its children must not be classified.
        let child = dir("15.0 (19A346)", [file("x", 200)])
        let bare = dir("DeviceSupport", [child])
        let xcode = dir("Xcode", [bare])
        let root = dir(home, [dir("Library", [dir("Developer", [xcode])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertNil(child.devCategory,
                     "a child of 'DeviceSupport' (missing the ' ' before the suffix) must not match")
        XCTAssertNil(bare.devCategory)
    }

    func testDeviceSupportOnlyMatchesDirectlyUnderXcode() {
        // A "<platform> DeviceSupport" directory located anywhere but directly under
        // ~/Library/Developer/Xcode must not have its children classified as deviceSupport.
        let child = dir("iPhone14,2 15.0 (19A346)", [file("z", 111)])
        let stray = dir("iOS DeviceSupport", [child])
        let root = dir(home, [dir("elsewhere", [stray])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertNil(child.devCategory, "device support outside ~/Library/Developer/Xcode must not match")
        XCTAssertNil(stray.devCategory)
    }

    // MARK: - Children-of rule (~/Library/Caches → appCaches)

    func testCachesChildDirectoryClassifiedAsAppCaches() {
        let googleCache = dir("Google", [file("data", 3_000)])
        let looseFile = file("loose.log", 500)                  // a FILE child must not match
        let caches = dir("Caches", [googleCache, looseFile])
        let root = dir(home, [dir("Library", [caches])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(googleCache.devCategory, .appCaches,
                       "a directory child of ~/Library/Caches is an app cache")
        XCTAssertEqual(googleCache.devSize, 3_000)
        XCTAssertNil(looseFile.devCategory, "a file child of ~/Library/Caches must not match")
        XCTAssertNil(caches.devCategory, "~/Library/Caches itself must not match the children-of rule")
        XCTAssertEqual(caches.devSize, 3_000, "aggregated from the app-cache child, not the loose file")
    }

    func testExactPathInsideCachesWinsOverAppCachesBlanket() {
        // exactPaths are checked before the children-of blanket, so pinned cache folders keep
        // their precise category while everything else under Caches becomes appCaches.
        let xcodeCache = dir("com.apple.dt.Xcode", [file("x", 4_000)])
        let spm = dir("org.swift.swiftpm", [file("y", 2_000)])
        let googleCache = dir("Google", [file("z", 1_000)])
        let caches = dir("Caches", [xcodeCache, spm, googleCache])
        let root = dir(home, [dir("Library", [caches])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(xcodeCache.devCategory, .xcodeBuild, "exactPaths win over the appCaches blanket")
        XCTAssertEqual(spm.devCategory, .packageCache, "exactPaths win over the appCaches blanket")
        XCTAssertEqual(googleCache.devCategory, .appCaches)
    }

    // MARK: - New exactPath rules (logs, iOS backups, Adobe media caches)

    func testLibraryLogsClassifiedAsLogs() {
        let logs = dir("Logs", [file("DiagnosticReports", 1_500)])
        let root = dir(home, [dir("Library", [logs])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(logs.devCategory, .logs)
        XCTAssertEqual(logs.devSize, 1_500)
    }

    func testMobileSyncBackupClassifiedAsIosBackups() {
        let uuidBackup = dir("00008030-ABC", [file("Manifest.db", 9_000)])
        let backup = dir("Backup", [uuidBackup])
        let mobileSync = dir("MobileSync", [backup])
        let appSupport = dir("Application Support", [mobileSync])
        let root = dir(home, [dir("Library", [appSupport])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(backup.devCategory, .iosBackups)
        XCTAssertEqual(backup.devSize, 9_000)
        XCTAssertNil(uuidBackup.devCategory, "per-backup UUID dirs are inside the matched root")
    }

    func testAdobeMediaCacheDirsClassifiedAsAdobeCache() {
        let mediaCacheFiles = dir("Media Cache Files", [file("a.cfa", 6_000)])
        let mediaCache = dir("Media Cache", [file("b.pek", 4_000)])
        let common = dir("Common", [mediaCacheFiles, mediaCache])
        let appSupport = dir("Application Support", [dir("Adobe", [common])])
        let root = dir(home, [dir("Library", [appSupport])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(mediaCacheFiles.devCategory, .adobeCache)
        XCTAssertEqual(mediaCache.devCategory, .adobeCache)
    }

    // MARK: - Name rules with and without their guard

    func testTargetMatchesOnlyNextToCargoToml() {
        let withGuard = dir("target", [file("app", 9_000)])
        let cargoProject = dir("rustproj", [withGuard, file("Cargo.toml", 100)])

        let withoutGuard = dir("target", [file("app", 7_000)])
        let plainProject = dir("otherproj", [withoutGuard, file("main.c", 50)])

        let root = dir("/work", [cargoProject, plainProject])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(withGuard.devCategory, .projectArtifacts)
        XCTAssertEqual(withGuard.devSize, 9_000)
        XCTAssertNil(withoutGuard.devCategory, "'target' without a sibling Cargo.toml must not match")
        XCTAssertEqual(withoutGuard.devSize, 0)
    }

    func testVenvMatchesOnlyWithPyvenvChild() {
        let withGuard = dir("venv", [file("pyvenv.cfg", 10), file("packages", 5_000)])
        let withoutGuard = dir(".venv", [file("packages", 3_000)])
        let root = dir("/work", [dir("a", [withGuard]), dir("b", [withoutGuard])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(withGuard.devCategory, .projectArtifacts)
        XCTAssertEqual(withGuard.devSize, 5_010)
        XCTAssertNil(withoutGuard.devCategory, "a venv without a pyvenv.cfg child must not match")
    }

    func testBuildMatchesNextToAnyGradleMarker() {
        let buildDir = dir("build", [file("classes", 6_000)])
        let project = dir("gradleproj", [buildDir, file("build.gradle.kts", 40)])
        let root = dir("/work", [project])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(buildDir.devCategory, .projectArtifacts)
    }

    func testProjectGradleDirMatchesNextToProjectMarker() {
        let nextToWrapper = dir(".gradle", [file("8.5", 6_000)])
        let wrapperProject = dir("app", [nextToWrapper, file("gradlew", 30)])

        let nextToSettings = dir(".gradle", [file("8.6", 4_000)])
        let settingsProject = dir("lib", [nextToSettings, file("settings.gradle.kts", 40)])

        let root = dir("/work", [wrapperProject, settingsProject])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(nextToWrapper.devCategory, .projectArtifacts)
        XCTAssertEqual(nextToSettings.devCategory, .projectArtifacts)
    }

    func testProjectGradleDirDoesNotMatchWithoutProjectMarker() {
        let bare = dir(".gradle", [file("8.5", 6_000)])
        let randomFolder = dir("random", [bare, file("notes.txt", 10)])
        let root = dir("/work", [randomFolder])

        DevClassifier.classify(root, using: catalog)

        XCTAssertNil(bare.devCategory, "a bare .gradle without a project-marker sibling must not match")
        XCTAssertEqual(bare.devSize, 0)
    }

    func testUnguardedNameRuleMatchesAnywhere() {
        let terraform = dir(".terraform", [file("providers", 800)])
        let root = dir("/work", [dir("deep", [dir("infra", [terraform])])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(terraform.devCategory, .packageCache)
        XCTAssertEqual(root.devSize, 800)
    }

    // MARK: - Deliberately-removed name rules (must never match)

    func testPycacheNeverMatches() {
        // The `__pycache__` name rule was removed: bytecode caches are unactionable noise and
        // always live inside something already captured at a useful granularity.
        let pycache = dir("__pycache__", [file("mod.pyc", 800)])
        let root = dir("/work", [dir("pkg", [pycache])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertNil(pycache.devCategory, "__pycache__ must not be classified anywhere")
        XCTAssertEqual(root.devSize, 0)
    }

    func testPodsNeverMatchesEvenNextToPodfile() {
        // The `Pods` name rule was removed: `Pods/` is often committed to git, and that cannot be
        // determined from the in-memory tree, so trashing it risks a wall of repo churn.
        let pods = dir("Pods", [file("lib", 5_000)])
        let project = dir("iosapp", [pods, file("Podfile", 100)])
        let root = dir("/work", [project])

        DevClassifier.classify(root, using: catalog)

        XCTAssertNil(pods.devCategory, "Pods must not be classified even next to a Podfile")
        XCTAssertEqual(root.devSize, 0)
    }

    func testCocoaPodsCacheExactPathStillMatches() {
        // The `Pods` name rule is gone, but `~/Library/Caches/CocoaPods` is a real cache and stays.
        let cocoaPods = dir("CocoaPods", [file("data", 7_000)])
        let caches = dir("Caches", [cocoaPods])
        let root = dir(home, [dir("Library", [caches])])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(cocoaPods.devCategory, .packageCache, "CocoaPods cache stays as an exactPath")
        XCTAssertEqual(cocoaPods.devSize, 7_000)
    }

    // MARK: - Outermost match wins

    func testOutermostNodeModulesWins() {
        let inner = dir("node_modules", [file("dep2", 200)])
        let nested = dir("some-pkg", [inner])
        let outer = dir("node_modules", [file("dep1", 1_000), nested])  // 1_200
        let root = dir("/work", [outer])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(outer.devCategory, .packageCache)
        XCTAssertEqual(outer.devSize, 1_200)
        XCTAssertNil(inner.devCategory, "the inner node_modules is inside the outer match")
        XCTAssertEqual(inner.devSize, 0, "descendants of a match root are not descended into")
    }

    // MARK: - devSize aggregation up through non-matching ancestors

    func testDevSizeAggregatesThroughNonMatchingAncestors() {
        let nmA = dir("node_modules", [file("d", 800)])
        let projA = dir("projA", [nmA, file("src.js", 50)])   // dev 800, alloc 850
        let nmB = dir("node_modules", [file("e", 300)])
        let projB = dir("projB", [nmB])                        // dev 300, alloc 300
        let workspace = dir("workspace", [projA, projB])       // dev 1_100
        let root = dir("/work", [workspace, file("README", 20)])

        DevClassifier.classify(root, using: catalog)

        XCTAssertEqual(projA.devSize, 800)
        XCTAssertEqual(projB.devSize, 300)
        XCTAssertEqual(workspace.devSize, 1_100)
        XCTAssertEqual(root.devSize, 1_100, "the top-level file contributes no dev bytes")
        XCTAssertNil(projA.devCategory)
        XCTAssertNil(workspace.devCategory)
    }

    // MARK: - TreeEditor keeps devSize consistent on removal

    func testRemoveSubtractsDevSizeFromAncestors() throws {
        let nm = dir("node_modules", [file("d", 800)])
        let projA = dir("projA", [nm, file("src.js", 50)])  // dev 800, alloc 850
        let root = dir("/work", [projA])

        DevClassifier.classify(root, using: catalog)
        XCTAssertEqual(root.devSize, 800)

        try TreeEditor.remove(nm, keeping: root)

        XCTAssertEqual(projA.devSize, 0)
        XCTAssertEqual(root.devSize, 0)
        // allocatedSize stays consistent too (only the plain file remains).
        XCTAssertEqual(projA.allocatedSize, 50)
        XCTAssertEqual(root.allocatedSize, 50)
    }

    // MARK: - "inside a dev item" parent-chain helper

    func testIsWithinDevItem() {
        let deep = file("mod.pyc", 100)
        let sub = dir("sub", [deep])
        let nm = dir("node_modules", [sub])           // dev root
        let proj = dir("proj", [nm, file("src.js", 10)])
        let root = dir("/work", [proj])

        DevClassifier.classify(root, using: catalog)

        XCTAssertTrue(DevClassifier.isWithinDevItem(nm), "the dev-item root itself counts")
        XCTAssertTrue(DevClassifier.isWithinDevItem(sub), "a descendant of a dev root")
        XCTAssertTrue(DevClassifier.isWithinDevItem(deep))
        XCTAssertFalse(DevClassifier.isWithinDevItem(proj), "proj holds a dev item but is not one")
        XCTAssertFalse(DevClassifier.isWithinDevItem(root))
    }

    // MARK: - Risk tier / consequence copy

    /// The exhaustive switches in `riskTier`/`consequence` already force every case to be
    /// handled at compile time; this guards the tier mapping and against an accidental empty
    /// string. Iterating `DevCategory.allCases` fails the moment a new category is added without
    /// an expected tier here, so the mapping cannot silently drift.
    func testRiskTierAndConsequenceForEveryCategory() {
        let expectedTier: [DevCategory: DevRiskTier] = [
            .xcodeBuild: .safe,
            .packageCache: .costsTime,
            .projectArtifacts: .costsTime,
            .simulators: .losesState,
            .xcodeArchives: .losesState,
            .deviceSupport: .costsTime,
            .docker: .losesState,
            .appCaches: .costsTime,
            .logs: .safe,
            .iosBackups: .losesState,
            .adobeCache: .costsTime,
        ]
        for category in DevCategory.allCases {
            guard let tier = expectedTier[category] else {
                XCTFail("no expected tier registered for \(category.rawValue)")
                continue
            }
            XCTAssertEqual(category.riskTier, tier, "unexpected tier for \(category.rawValue)")
            XCTAssertFalse(
                category.consequence.isEmpty,
                "\(category.rawValue) must have a non-empty consequence"
            )
            XCTAssertFalse(
                category.displayName.isEmpty,
                "\(category.rawValue) must have a non-empty displayName"
            )
        }
    }
}
