import Testing
@testable import OpenLens

/// Server directories are spelled the way the server's own OS spells them.
/// Windows servers report `C:\...` and refuse `/C:/...`.
struct ServerPathTests {

    // MARK: - Absolute paths

    @Test(arguments: [
        "/",
        "/Users/me/OpenLens",
        #"C:\Users\me\code"#,
        "C:/Users/me/code",
        "C:",
        #"C:\"#,
        "/C:/Users/me/code",
        #"\\server\share"#,
        #"\\server\share\code"#,
    ])
    func absolutePathsAreRecognized(path: String) {
        #expect(ServerPath.isAbsolute(path))
        #expect(ServerPath.normalized(path) != nil)
    }

    @Test(arguments: ["", "relative/path", "code", "~/code", "C:relative", #"\\server"#, #"\\server\"#, "file:///Users/me"])
    func relativeOrMalformedPathsAreNotAbsolute(path: String) {
        #expect(!ServerPath.isAbsolute(path))
        #expect(ServerPath.normalized(path) == nil)
        #expect(ServerPath.comparisonKey(path) == nil)
    }

    // MARK: - Normalization

    @Test func posixPathsNormalizeAsBefore() {
        #expect(ServerPath.normalized("/Users/me/OpenLens") == "/Users/me/OpenLens")
        #expect(ServerPath.normalized("/Users/me/OpenLens/") == "/Users/me/OpenLens")
        #expect(ServerPath.normalized("/Users//me///OpenLens") == "/Users/me/OpenLens")
        #expect(ServerPath.normalized("/Users/me/./tmp/../OpenLens") == "/Users/me/OpenLens")
        #expect(ServerPath.normalized("/") == "/")
        #expect(ServerPath.normalized("//") == "/")
        #expect(ServerPath.normalized("/..") == "/")
    }

    @Test func windowsPathsKeepTheirSpellingAndSeparators() {
        #expect(ServerPath.normalized(#"C:\Users\me\code"#) == #"C:\Users\me\code"#)
        #expect(ServerPath.normalized("C:/Users/me/code") == "C:/Users/me/code")
        #expect(ServerPath.normalized(#"C:\Users\me\code\"#) == #"C:\Users\me\code"#)
        #expect(ServerPath.normalized(#"C:\Users\\me\.\tmp\..\code"#) == #"C:\Users\me\code"#)
        #expect(ServerPath.normalized(#"c:\users\Me\Code"#) == #"c:\users\Me\Code"#)
    }

    @Test func theMalformedLeadingSlashFormIsRepaired() {
        #expect(ServerPath.normalized("/C:/Users/me/code") == "C:/Users/me/code")
        #expect(ServerPath.normalized("/C:") == #"C:\"#)
    }

    @Test func windowsRootsStayRoots() {
        #expect(ServerPath.normalized("C:") == #"C:\"#)
        #expect(ServerPath.normalized(#"C:\"#) == #"C:\"#)
        #expect(ServerPath.normalized("C:/") == "C:/")
        #expect(ServerPath.normalized(#"C:\.."#) == #"C:\"#)
        #expect(ServerPath.isRoot("C:"))
        #expect(ServerPath.isRoot("/"))
        #expect(!ServerPath.isRoot(#"C:\Users"#))
    }

    @Test func uncPathsKeepServerAndShareAsTheirRoot() {
        #expect(ServerPath.normalized(#"\\server\share\code\"#) == #"\\server\share\code"#)
        #expect(ServerPath.normalized(#"\\server\share\code\..\.."#) == #"\\server\share\"#)
        #expect(ServerPath.isRoot(#"\\server\share"#))
    }

    // MARK: - Comparison

    @Test func windowsSpellingsOfOneFolderAreEquivalent() {
        let spellings = [
            #"C:\Users\x\code"#,
            "C:/Users/x/code",
            "/C:/Users/x/code",
            #"c:\users\X\Code"#,
            #"C:\Users\x\code\"#,
        ]
        for lhs in spellings {
            for rhs in spellings {
                #expect(ServerPath.areEquivalent(lhs, rhs), "\(lhs) vs \(rhs)")
            }
        }
        #expect(!ServerPath.areEquivalent(#"C:\Users\x\code"#, #"C:\Users\x\other"#))
        #expect(!ServerPath.areEquivalent(#"C:\Users\x\code"#, #"D:\Users\x\code"#))
        #expect(ServerPath.areEquivalent(#"\\Server\Share\Code"#, "\\\\server\\share\\code\\"))
    }

    @Test func posixComparisonStaysCaseSensitive() {
        #expect(ServerPath.areEquivalent("/Users/me/code", "/Users/me//code/"))
        #expect(!ServerPath.areEquivalent("/Users/me/code", "/users/me/code"))
        #expect(!ServerPath.areEquivalent("/Users/me/code", nil))
        #expect(!ServerPath.areEquivalent("relative", "relative"))
    }

    // MARK: - Components

    @Test func lastComponentFollowsThePathsOwnSeparators() {
        #expect(ServerPath.lastComponent("/Users/me/OpenLens") == "OpenLens")
        #expect(ServerPath.lastComponent(#"C:\Users\me\code"#) == "code")
        #expect(ServerPath.lastComponent("C:/Users/me/code/") == "code")
        #expect(ServerPath.lastComponent(#"\\server\share\code"#) == "code")
        #expect(ServerPath.lastComponent("/") == "/")
        #expect(ServerPath.lastComponent(#"C:\"#) == #"C:\"#)
        #expect(ServerPath.lastComponent("relative/name") == "name")
    }

    @Test func parentWalksUpToTheRootAndStops() {
        #expect(ServerPath.parent(of: #"C:\a\b"#) == #"C:\a"#)
        #expect(ServerPath.parent(of: #"C:\a"#) == #"C:\"#)
        #expect(ServerPath.parent(of: #"C:\"#) == nil)
        #expect(ServerPath.parent(of: "C:/a/b") == "C:/a")
        #expect(ServerPath.parent(of: "/a/b") == "/a")
        #expect(ServerPath.parent(of: "/a") == "/")
        #expect(ServerPath.parent(of: "/") == nil)
        #expect(ServerPath.parent(of: #"\\server\share\a"#) == #"\\server\share\"#)
        #expect(ServerPath.parent(of: #"\\server\share"#) == nil)
        #expect(ServerPath.parent(of: "relative/path") == nil)
    }

    @Test func joinUsesTheDirectorysSeparator() {
        #expect(ServerPath.join(#"C:\a"#, "b") == #"C:\a\b"#)
        #expect(ServerPath.join(#"C:\a\"#, "b") == #"C:\a\b"#)
        #expect(ServerPath.join(#"C:\"#, "b") == #"C:\b"#)
        #expect(ServerPath.join("C:/a", "b") == "C:/a/b")
        #expect(ServerPath.join(#"\\server\share"#, "b") == #"\\server\share\b"#)
        #expect(ServerPath.join("/a", "b") == "/a/b")
        #expect(ServerPath.join("/a/", "/b") == "/a/b")
        #expect(ServerPath.join("/", "b") == "/b")
    }

    // MARK: - Call sites

    @Test func workspaceDirectoriesKeepTheServersWindowsSpelling() {
        #expect(WorkspaceSelectionBuilder.normalizedDirectory(#" C:\Users\x\code "#) == #"C:\Users\x\code"#)
        #expect(WorkspaceSelectionBuilder.normalizedDirectory("/C:/Users/x/code") == "C:/Users/x/code")
        #expect(WorkspaceSelectionBuilder.normalizedDirectory("/Users/me/OpenLens/") == "/Users/me/OpenLens")
        #expect(WorkspaceSelectionBuilder.normalizedDirectory("relative/location") == nil)
        #expect(WorkspaceSelectionBuilder.displayName(for: #"C:\Users\x\code"#) == "code")
        #expect(WorkspaceSelectionBuilder.displayName(for: "/") == "/")
    }

    @Test func aWindowsProjectIsOfferedUnderItsOwnPath() {
        let snapshot = WorkspaceSelectionSnapshot(
            currentProject: OCProject(id: "code", worktree: #"C:\Users\x\code"#),
            projects: [OCProject(id: "code", worktree: #"C:\Users\x\code"#)],
            pathInfo: nil
        )

        let result = WorkspaceSelectionBuilder.makeOptions(
            snapshot: snapshot,
            recentDirectories: [],
            preferredDirectory: nil
        )

        let selected = result.options.first { $0.id == result.defaultOptionID }
        #expect(selected?.directory == #"C:\Users\x\code"#)
        #expect(selected?.title == "code")
        #expect(selected?.availability == .available)
    }

    @Test func windowsSubfoldersAreListedUnderTheSelectedDrivePath() {
        let entries = [
            OCWorkspaceFileEntry(name: "src", path: "src", absolute: nil, type: "directory", ignored: false),
            OCWorkspaceFileEntry(name: "docs", path: "docs", absolute: #"C:\Users\x\code\docs"#, type: "directory", ignored: false),
            OCWorkspaceFileEntry(name: ".git", path: ".git", absolute: nil, type: "directory", ignored: false),
        ]

        let folders = WorkspaceService.folderItems(from: entries, directory: #"C:\Users\x\code"#)

        #expect(folders.map(\.path) == [#"C:\Users\x\code\docs"#, #"C:\Users\x\code\src"#])
        #expect(folders.map(\.name) == ["docs", "src"])
    }

    @Test func windowsServersMayAskForGlobalFormsInWindowsFolders() {
        #expect(InteractiveFormSafety.fitsGlobalDirectory(#"C:\Users\x\code"#))
        #expect(InteractiveFormSafety.fitsGlobalDirectory("/Users/me/code"))
        #expect(!InteractiveFormSafety.fitsGlobalDirectory("relative"))
        #expect(!InteractiveFormSafety.fitsGlobalDirectory("C:\\Users\\x\0"))
    }

    @Test func windowsFileReferencesStayInsideTheirSessionFolder() throws {
        let reference = try ServerFileReference(
            path: ServerFileReference.path("Sources/My File.swift", in: #"C:\Users\x\code"#),
            sessionDirectory: #"C:\Users\x\code"#,
            lines: .init(start: 2)
        )
        #expect(reference.path == #"C:\Users\x\code\Sources\My File.swift"#)
        #expect(reference.name == "My File.swift")
        #expect(reference.uri == "file:///C:/Users/x/code/Sources/My%20File.swift?start=2")
        #expect(reference.relativePath(in: "C:/Users/x/code/") == #"Sources\My File.swift"#)

        let fromToolURI = try ServerFileReference(path: "/C:/Users/x/code/a.txt", sessionDirectory: #"C:\Users\x\code"#)
        #expect(fromToolURI.path == #"C:\Users\x\code\a.txt"#)

        let invalidPaths = [
            #"C:\Users\x\other\a.txt"#,
            #"C:\Users\x\code"#,
            #"C:\Users\x\code\..\secrets.txt"#,
            #"C:\Users\x\code\.\a.txt"#,
            #"C:\Users\x\code\\a.txt"#,
            #"C:\Users\x\code\a.txt:stream"#,
            #"C:\Users\x\codex\a.txt"#,
            #"D:\Users\x\code\a.txt"#,
            "C:relative.txt",
            "/Users/x/code/a.txt",
        ]
        for path in invalidPaths {
            #expect(throws: PromptAttachmentError.fileOutsideSession, "\(path)") {
                try ServerFileReference(path: path, sessionDirectory: #"C:\Users\x\code"#)
            }
        }
    }
}
