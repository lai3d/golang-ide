import Foundation
import Testing
@testable import GoIDE

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
