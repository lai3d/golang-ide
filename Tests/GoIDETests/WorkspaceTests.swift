import Foundation
import Testing
@testable import GoIDE
import GoIDECore

@MainActor
@Suite struct WorkspaceTabTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.go", "b.go", "c.go"] {
            try "package main\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    @Test func openingTheSameFileReusesItsTab() {
        let workspace = Workspace()
        let first = workspace.openFile(url("a.go"))
        workspace.openFile(url("b.go"))
        let again = workspace.openFile(url("a.go"))
        #expect(first === again)
        #expect(workspace.documents.map(\.name) == ["a.go", "b.go"])
        #expect(workspace.activeDocument === first)
    }

    @Test func newTabsOpenNextToTheActiveOne() {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.go"))!
        workspace.openFile(url("b.go"))
        workspace.activate(a)
        workspace.openFile(url("c.go"))
        #expect(workspace.documents.map(\.name) == ["a.go", "c.go", "b.go"])
    }

    @Test func closingTheActiveTabSelectsItsNeighbour() {
        let workspace = Workspace()
        workspace.openFile(url("a.go"))
        let b = workspace.openFile(url("b.go"))!
        workspace.openFile(url("c.go"))
        workspace.activate(b)
        workspace.closeDocument(b)
        #expect(workspace.documents.map(\.name) == ["a.go", "c.go"])
        #expect(workspace.activeDocument?.name == "c.go")
        workspace.closeAllDocuments()
        #expect(workspace.documents.isEmpty && workspace.activeDocument == nil)
    }

    @Test func cyclesTabs() {
        let workspace = Workspace()
        workspace.openFile(url("a.go"))
        workspace.openFile(url("b.go"))
        workspace.selectAdjacentTab(1)
        #expect(workspace.activeDocument?.name == "a.go")
        workspace.selectAdjacentTab(-1)
        #expect(workspace.activeDocument?.name == "b.go")
    }

    @Test func editsMarkDirtyAndSaveWritesToDisk() throws {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.go"))!
        workspace.updateText(of: a, to: "package main\n\nfunc x() {}\n")
        #expect(a.isDirty)
        workspace.save(a)
        #expect(!a.isDirty)
        #expect(try String(contentsOf: url("a.go"), encoding: .utf8).contains("func x()"))
    }
}

@MainActor
@Suite struct WorkspaceFormattingTests {
    @Test(.enabled(if: GoIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func formatsAndOrganizesImportsOnSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-wsfmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("main.go")
        try "package main\n\nfunc main(){\nfmt.Println( \"hi\" )\n}\n".write(to: file, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let document = try #require(workspace.activeDocument)
        #expect(workspace.lspStatus == "gopls: ready")

        await workspace.format(document)
        #expect(document.isDirty)  // formatted in memory, not yet saved
        #expect(document.text.contains("func main() {"))
        await workspace.saveFormatted(document)
        #expect(!document.isDirty)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}\n")
    }
}

@MainActor
@Suite struct WorkspaceFileSystemTests {
    let dir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("pkg"), withIntermediateDirectories: true)
        dir = base.canonicalFileURL  // real path, as FSEvents reports it
        try "module example.com/fs\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package widgets\n".write(to: dir.appendingPathComponent("pkg/a.go"), atomically: true, encoding: .utf8)
    }

    private func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    @Test func reloadsCleanDocumentsAndFlagsDirtyOnes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir.canonicalFileURL)
        let main = try #require(workspace.activeDocument)
        let other = try #require(workspace.openFile(url("pkg/a.go")))
        workspace.updateText(of: other, to: "package widgets // edited\n")

        try "package main\n\nfunc main() { println() }\n".write(to: url("main.go"), atomically: true, encoding: .utf8)
        try "package widgets // external\n".write(to: url("pkg/a.go"), atomically: true, encoding: .utf8)
        workspace.handleFileSystemChanges([url("main.go").path, url("pkg/a.go").path])

        #expect(main.text.contains("println()") && !main.isDirty)
        #expect(other.text.contains("edited") && other.hasExternalChange)
        workspace.reloadFromDisk(other)
        #expect(other.text.contains("external") && !other.isDirty && !other.hasExternalChange)
    }

    @Test func createsRenamesAndTrashes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir.canonicalFileURL)

        let created = try workspace.createFile(named: "b.go", in: url("pkg"))
        #expect(try String(contentsOf: created, encoding: .utf8) == "package widgets\n")
        #expect(workspace.activeDocument?.name == "b.go")
        #expect(throws: FileOperationError.self) { try workspace.createFile(named: "b.go", in: url("pkg")) }

        let renamed = try workspace.renameItem(at: url("pkg"), to: "widgets")
        #expect(workspace.activeDocument?.url.path == renamed.appendingPathComponent("b.go").path)
        #expect(workspace.fileTree.contains { $0.name == "widgets" })

        try workspace.trashItem(at: renamed)
        #expect(!workspace.documents.contains { $0.name == "b.go" })
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func derivesPackageNames() throws {
        try FileManager.default.createDirectory(at: url("My-Tool"), withIntermediateDirectories: true)
        #expect(Workspace.packageName(for: url("My-Tool")) == "mytool")
        #expect(Workspace.packageName(for: dir) == "main")
    }
}

@MainActor
@Suite struct WorkspaceSearchTests {
    @Test func searchesProjectIncludingUnsavedBuffers() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "package main\n\nfunc main() { greet() }\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc greet() {}\n".write(to: dir.appendingPathComponent("greet.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        workspace.searchQuery = "greet"
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 2)

        // Edit greet.go without saving: the search sees the buffer.
        let greet = try #require(workspace.openFile(dir.appendingPathComponent("greet.go")))
        workspace.updateText(of: greet, to: "package main\n\nfunc greet() {}\nfunc greetAgain() {}\n")
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 3)

        let file = try #require(workspace.searchResults.first { $0.path.hasSuffix("main.go") })
        workspace.open(file.matches[0], in: file)
        #expect(workspace.activeDocument?.name == "main.go")
        #expect(workspace.activeDocument?.revealTarget?.position == TextPosition(line: 2, character: 14))
        #expect(workspace.activeDocument?.revealTarget?.length == 5)

        workspace.searchOptions.regex = true
        workspace.searchQuery = "("
        await workspace.performSearch()
        #expect(workspace.searchError != nil && workspace.searchResults.isEmpty)
    }
}

@MainActor
@Suite struct WorkspaceReferencesTests {
    @Test(.enabled(if: GoIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func findsReferencesAcrossFilesUsingBuffers() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/r\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() { greet(); greet() }\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc greet() {}\n".write(to: dir.appendingPathComponent("greet.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        await workspace.findReferences(in: main, at: ("package main\n\nfunc main() { " as NSString).length + 1)
        #expect(workspace.bottomTab == .references)
        #expect(workspace.referenceTitle == "3 references to ‘greet’")
        #expect(workspace.referenceResults.map { ($0.path as NSString).lastPathComponent } == ["greet.go", "main.go"])
    }
}

@MainActor
@Suite struct WorkspaceRenameTests {
    @Test(.enabled(if: GoIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func renamesAcrossOpenAndClosedFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/r\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() { greet() }\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        let greetFile = dir.appendingPathComponent("greet.go")
        try "package main\n\nfunc greet() {}\n".write(to: greetFile, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        let offset = ("package main\n\nfunc main() { " as NSString).length + 2

        #expect(await workspace.prepareRename(in: main, at: offset) == "greet")
        #expect(await workspace.prepareRename(in: main, at: 2) == nil)  // "package" keyword

        let error = await workspace.renameSymbol(in: main, at: offset, to: "salute")
        #expect(error == nil)
        #expect(main.text == "package main\n\nfunc main() { salute() }\n" && main.isDirty)  // open: buffer
        #expect(try String(contentsOf: greetFile, encoding: .utf8) == "package main\n\nfunc salute() {}\n")  // closed: disk
    }
}
