import Foundation
import Testing
@testable import GoIDECore

@Suite struct GitTests {
    @Test func parsesPorcelainStatus() {
        let porcelain = " M a.go\0A  b.go\0?? new.go\0R  newname.go\0oldname.go\0 D gone.go\0UU c.go\0"
        let statuses = Git.parseStatus(porcelain, root: "/r")
        #expect(statuses == ["/r/a.go": .modified, "/r/b.go": .added, "/r/new.go": .untracked,
                             "/r/newname.go": .renamed, "/r/gone.go": .deleted, "/r/c.go": .conflicted])
    }

    @Test func classifiesLineChanges() {
        let base = "a\nb\nc\nd\ne\n"
        let current = "a\nB\nc\nnew1\nnew2\nd\n"  // b->B modified; 2 added after c; e deleted
        let changes = LineChanges.compute(base: base, current: current)
        #expect(changes.lines == [1: .modified, 3: .added, 4: .added])
        #expect(changes.deletions == [6])
        #expect(LineChanges.compute(base: base, current: base).isEmpty)
    }

    @Test(.enabled(if: ToolLocator.find("git") != nil))
    func readsRealRepository() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        Git.run(["init", "-q", "-b", "trunk"], in: dir)
        try "package main\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        Git.run(["add", "."], in: dir)
        Git.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: dir)
        try "package main\n\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\n".write(to: dir.appendingPathComponent("extra.go"), atomically: true, encoding: .utf8)

        #expect(Git.topLevel(of: dir)?.path == dir.path)
        #expect(Git.currentBranch(in: dir) == "trunk")
        let statuses = Git.status(in: dir)
        #expect(statuses[dir.appendingPathComponent("main.go").path] == .modified)
        #expect(statuses[dir.appendingPathComponent("extra.go").path] == .untracked)
        #expect(Git.headContents(of: dir.appendingPathComponent("main.go"), topLevel: dir) == "package main\n")
        #expect(Git.headContents(of: dir.appendingPathComponent("extra.go"), topLevel: dir) == nil)

        // Blame the buffer: line 0 is committed, line 2 is new (uncommitted).
        let buffer = "package main\n\nfunc main() {}\n"
        let committed = try #require(Git.blame(file: dir.appendingPathComponent("main.go"), line: 0, contents: buffer, topLevel: dir))
        #expect(committed.author == "t" && committed.summary == "init" && !committed.isUncommitted)
        let fresh = try #require(Git.blame(file: dir.appendingPathComponent("main.go"), line: 2, contents: buffer, topLevel: dir))
        #expect(fresh.isUncommitted)
    }
}

@Suite struct SideBySideDiffTests {
    @Test func alignsAndFoldsUnchangedLines() {
        let base = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...20).map { "line \($0)" }
        lines[9] = "line 10 changed"          // changed
        lines.insert("inserted", at: 15)      // added after line 15
        lines.remove(at: 19)                  // line 19 removed (index shifted by the insert)
        let rows = SideBySideDiff.rows(base: base, current: lines.joined(separator: "\n") + "\n", context: 1)
        let kinds = rows.map(\.kind)
        #expect(kinds.first == .gap(8))
        #expect(rows.contains { $0.kind == .changed && $0.left?.text == "line 10" && $0.right?.text == "line 10 changed" })
        #expect(rows.contains { $0.kind == .added && $0.right?.text == "inserted" && $0.left == nil })
        #expect(rows.contains { $0.kind == .removed && $0.left?.number == 19 && $0.right == nil })
        #expect(SideBySideDiff.rows(base: base, current: base) == [DiffRow(id: 0, kind: .gap(20), left: nil, right: nil)])
    }
}
