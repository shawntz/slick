import CoreBridge
import Kit
import Testing

@testable import FileSearch

@Suite("Scope rules", .timeLimit(.minutes(1)))
struct ScopeTests {
    private let home = "/synthetic/home"

    private func states(_ searched: Set<ProtectedPlace> = []) -> [ProtectedPlace: PlaceState] {
        Dictionary(
            uniqueKeysWithValues: ProtectedPlace.allCases.map { ($0, searched.contains($0) ? .searched : .notSearched) }
        )
    }

    @Test func theDefaultScopeIsHomeWithoutProtectedPlaces() {
        let plan = ScopePlan(ScopeInput(home: home, states: states()))
        #expect(plan.roots == [home])
        #expect(plan.configuration.useRecommendedRules && !plan.configuration.includeHidden)
        #expect(plan.configuration.home == home)
        #expect(plan.configuration.keepsRootsInSkippedFolders)
        #expect(
            Set(plan.configuration.skipPaths) == [home + "/Desktop", home + "/Documents", home + "/Downloads"])
        #expect(plan.blocked.contains(home + "/Library/Mobile Documents/com~apple~CloudDocs"))
        #expect(plan.placeFolders.isEmpty)
        #expect(!plan.allows(home + "/Library/Preferences/x.plist"))
        #expect(plan.allows(home + "/notes.md"))
        #expect(!plan.allows(home + "/Desktop/shot.png"))
        #expect(!plan.allows(home + "/Desktop"))
        #expect(plan.allows(home + "/DesktopNotes/a.txt"), "a sibling that only starts with the name is fine")
        #expect(!plan.allows("/etc/hosts"))
        #expect(plan.isRoot(home) && !plan.isRoot(home + "/Projects"))
    }

    @Test func aSearchedPlaceJoinsTheScope() {
        let plan = ScopePlan(ScopeInput(home: home, states: states([.desktop, .iCloudDrive])))
        let cloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(plan.roots == [home, cloud], "iCloud Drive is a root of its own inside the skipped Library")
        #expect(plan.configuration.home == home, "Library stays skipped whole")
        #expect(plan.configuration.keepsRootsInSkippedFolders)
        let skipped = Set(plan.configuration.skipPaths)
        #expect(!skipped.contains(home + "/Desktop") && skipped.contains(home + "/Documents"))
        #expect(!skipped.contains(cloud))
        #expect(plan.placeFolders[.desktop] == [home + "/Desktop"])
        #expect(plan.placeFolders[.iCloudDrive] == [cloud])
        #expect(plan.expected == [cloud])
        #expect(plan.allows(home + "/Desktop/shot.png"))
        #expect(plan.allows(cloud + "/note.txt"))
        #expect(plan.isRoot(cloud))
        #expect(!plan.allows(home + "/Library/Preferences/x.plist"))
        #expect(!plan.allows(home + "/Library/Mobile Documents"))
        #expect(!plan.allows(home + "/Library/Mobile Documents/iCloud~com~example~app/a.txt"))
    }

    @Test func volumesJoinOnlyWhenTheirKindIsSearched() {
        let volumes = MountedVolumes(removable: ["/Volumes/Stick/"], network: ["/Volumes/Share"])
        let off = ScopePlan(ScopeInput(home: home, states: states(), volumes: volumes))
        #expect(off.roots == [home])
        #expect(off.blocked.contains("/Volumes/Stick") && off.blocked.contains("/Volumes/Share"))
        let on = ScopePlan(ScopeInput(home: home, states: states([.removableVolumes]), volumes: volumes))
        #expect(on.roots == [home, "/Volumes/Stick"])
        #expect(on.placeFolders[.removableVolumes] == ["/Volumes/Stick"])
        #expect(on.blocked.contains("/Volumes/Share"))
    }

    @Test func addedAndExcludedFoldersAndNames() {
        let input = ScopeInput(
            home: home, states: states(),
            extraFolders: [
                "/Projects/", "~/Desktop/Work", "relative/folder", "/Projects", "/Data/./a/../b",
                "~/Library/Containers",
            ],
            excludedFolders: ["~/Archive", "/Projects/tmp"], excludedNames: ["  *.log ", "dist", "", "a/b", "dist"],
            includesHidden: true)
        let plan = ScopePlan(input)
        #expect(
            plan.roots == [home, "/Projects", "/Data/b"],
            "a folder inside a place not searched waits for it, and one inside Library is left out")
        #expect(plan.configuration.skipPaths.contains(home + "/Archive"))
        #expect(plan.configuration.skipPaths.contains("/Projects/tmp"))
        #expect(!plan.allows("/Projects/tmp/x"))
        #expect(plan.configuration.skipNames == ["dist"])
        #expect(plan.patterns.wildcards == ["*.log"])
        #expect(plan.patterns.hides("Build.LOG") && !plan.patterns.hides("log.txt"))
        #expect(plan.configuration.includeHidden)
    }

    @Test func pathsAreShownAndSplitWithoutTheDisk() {
        #expect(Paths.display(home + "/Projects/app", home: home) == "~/Projects/app")
        #expect(Paths.display(home, home: home) == "~")
        #expect(Paths.display("/etc", home: home) == "/etc")
        #expect(Paths.name(of: "/a/b.txt") == "b.txt" && Paths.name(of: "/") == "/")
        #expect(Paths.parent(of: "/a/b.txt") == "/a" && Paths.parent(of: "/a") == "/")
        #expect(Paths.normalized("~", home: home) == home)
        #expect(Paths.normalized("/a//b/../c/", home: nil) == "/a/c")
        #expect(Paths.normalized("a", home: home) == nil)
        #expect(FileRows.folderTitle(for: "~/Doc") == "~")
        #expect(FileRows.folderTitle(for: "~/Documents/") == "~/Documents")
        #expect(FileRows.folderTitle(for: "/") == "/")
        #expect(FileRows.oneLine("two\nlines\r\n") == "two lines  ")
    }

    @Test func placeStatesFollowChoicesPermissionsAndFullDiskAccess() {
        let none: (Permission) -> Bool = { _ in false }
        let all: (Permission) -> Bool = { _ in true }
        var choices = PlaceChoices()
        #expect(choices.state(of: .desktop, isGranted: all, fullDiskAccess: false) == .notSearched)
        #expect(
            choices.state(of: .desktop, isGranted: none, fullDiskAccess: true) == .notSearched,
            "Full Disk Access granted for another feature brings nothing in")
        #expect(choices.state(of: .iCloudDrive, isGranted: none, fullDiskAccess: true) == .notSearched)
        #expect(
            choices.state(of: .removableVolumes, isGranted: none, fullDiskAccess: true) == .notSearched,
            "volumes wait for a choice even with Full Disk Access")
        choices.include([.documents, .iCloudDrive, .networkVolumes])
        #expect(choices.state(of: .documents, isGranted: none, fullDiskAccess: false) == .waitingForAccess)
        #expect(
            choices.state(of: .documents, isGranted: none, fullDiskAccess: true) == .searched,
            "a chosen place needs no prompt with Full Disk Access")
        #expect(choices.state(of: .documents, isGranted: all, fullDiskAccess: false) == .searched)
        #expect(
            choices.state(of: .iCloudDrive, isGranted: none, fullDiskAccess: true) == .waitingForAccess,
            "Full Disk Access does not count for iCloud Drive")
        #expect(choices.state(of: .iCloudDrive, isGranted: all, fullDiskAccess: false) == .searched)
        #expect(choices.state(of: .networkVolumes, isGranted: none, fullDiskAccess: true) == .searched)
        choices.turnOff(.downloads)
        #expect(choices.state(of: .downloads, isGranted: all, fullDiskAccess: true) == .turnedOff)
        choices.denied.insert(.documents)
        #expect(choices.state(of: .documents, isGranted: all, fullDiskAccess: true) == .accessDenied)
        choices.include([.documents])
        #expect(choices.state(of: .documents, isGranted: all, fullDiskAccess: false) == .searched)
    }

    @Test func kindsComeFromFlagsAndExtensions() {
        #expect(FileKind.of(name: "Tool.app", isFolder: true, isPackage: true) == .applications)
        #expect(FileKind.of(name: "Deck.key", isFolder: true, isPackage: true) == .documents)
        #expect(FileKind.of(name: "src", isFolder: true, isPackage: false) == .folders)
        #expect(FileKind.of(name: "Beach.JPG", isFolder: false, isPackage: false) == .images)
        #expect(FileKind.of(name: ".zshrc", isFolder: false, isPackage: false) == nil)
        #expect(FileKind.of(name: "main.swift", isFolder: false, isPackage: false) == .code)
        #expect(FileKind.fileExtension(of: "archive.tar.gz") == "gz")
    }
}
