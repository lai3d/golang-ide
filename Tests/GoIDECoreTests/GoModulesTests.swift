import Foundation
import Testing
@testable import GoIDECore

@Suite struct GoModulesTests {
    @Test func parsesGoMod() {
        let text = """
        module example.com/app // the app

        go 1.23.0

        toolchain go1.24.1

        require github.com/pkg/errors v0.9.1

        require (
        \tgolang.org/x/text v0.14.0
        \tgithub.com/google/uuid v1.6.0 // indirect
        )

        replace github.com/pkg/errors => ../errors
        replace (
        \tgolang.org/x/text v0.14.0 => golang.org/x/text v0.15.0
        )
        """
        let file = GoModFile.parse(text)
        #expect(file.module == "example.com/app")
        #expect(file.moduleLine == 0)
        #expect(file.goVersion == "1.23.0")
        #expect(file.toolchain == "go1.24.1")
        #expect(file.requires.map(\.path) == ["github.com/pkg/errors", "golang.org/x/text", "github.com/google/uuid"])
        #expect(file.direct.count == 2)
        #expect(file.indirect.map(\.path) == ["github.com/google/uuid"])
        #expect(file.requires[1].line == 9)
        #expect(file.requires[1].version == "v0.14.0")
        let local = file.replacement(for: "github.com/pkg/errors")
        #expect(local?.newPath == "../errors")
        #expect(local?.isLocal == true)
        let versioned = file.replacement(for: "golang.org/x/text")
        #expect(versioned?.oldVersion == "v0.14.0")
        #expect(versioned?.newVersion == "v0.15.0")
    }

    @Test func parsesQuotedModulePath() {
        let file = GoModFile.parse("module \"example.com/quoted\"\ngo 1.22\n")
        #expect(file.module == "example.com/quoted")
        #expect(file.goVersion == "1.22")
    }

    @Test func parsesGoWork() {
        let text = """
        go 1.23

        use ./api
        use (
        \t./cmd/tool // tool
        \t.
        )
        """
        let file = GoWorkFile.parse(text)
        #expect(file.goVersion == "1.23")
        #expect(file.uses.map(\.path) == ["./api", "./cmd/tool", "."])
        #expect(file.uses[1].line == 4)
        let root = URL(fileURLWithPath: "/w")
        #expect(file.moduleDirectories(relativeTo: root).map(\.path) == ["/w/api", "/w/cmd/tool", "/w"])
    }

    @Test func decodesModuleList() {
        let json = """
        {
        \t"Path": "example.com/app",
        \t"Main": true,
        \t"Dir": "/w/app",
        \t"GoMod": "/w/app/go.mod"
        }
        {
        \t"Path": "golang.org/x/text",
        \t"Version": "v0.14.0",
        \t"Update": {"Path": "golang.org/x/text", "Version": "v0.21.0"},
        \t"Indirect": true,
        \t"Dir": "/m/{weird}\\"dir"
        }
        """
        let modules = GoModuleList.parse(Data(json.utf8))
        #expect(modules.count == 2)
        #expect(modules[0].isMain)
        #expect(modules[1].latestVersion == "v0.21.0")
        #expect(modules[1].indirect)
        #expect(modules[1].dir == "/m/{weird}\"dir")
    }

    @Test func findsModulesAndRelativePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gomods-\(UUID().uuidString)").canonicalFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["", "b", "a/inner", "vendor/x", "testdata/y"] {
            let d = root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "module m\n".write(to: d.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        }
        let root2 = root.canonicalFileURL
        let found = GoModuleFinder.goModFiles(under: root2).map { String($0.path.dropFirst(root2.path.count)) }
        #expect(found == ["/go.mod", "/a/inner/go.mod", "/b/go.mod"])
        #expect(GoModuleFinder.relativeUsePath(root2.appendingPathComponent("a/inner"), root: root2) == "./a/inner")
        #expect(GoModuleFinder.relativeUsePath(root2, root: root2) == ".")
    }
}

@Suite struct ToolEnvironmentTests {
    @Test func dropsInheritedWorkingDirectory() {
        let env = ToolLocator.environment(base: ["PATH": "/usr/bin", "PWD": "/var/x", "OLDPWD": "/tmp", "HOME": "/h"])
        #expect(env["PWD"] == nil)
        #expect(env["OLDPWD"] == nil)
        #expect(env["HOME"] == "/h")
        #expect(env["PATH"]?.contains("/usr/bin") == true)
    }

    /// `go build` from a symlinked $PWD used to fail with "outside main module".
    @Test func goBuildsWhenLaunchedFromSymlinkedDirectory() throws {
        guard ToolLocator.find("go") != nil else { return }
        let real = FileManager.default.temporaryDirectory.canonicalFileURL
            .appendingPathComponent("pwdmod-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.canonicalFileURL
            .appendingPathComponent("pwdlink-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try "module example.com/pwd\n\ngo 1.21\n".write(to: real.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() {}\n".write(to: real.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        // As if GoIDE had been started from a shell inside the symlinked folder.
        let env = ToolLocator.environment(base: ProcessInfo.processInfo.environment.merging(["PWD": link.path]) { $1 })
        let process = Process()
        process.executableURL = ToolLocator.find("go")
        process.arguments = ["build", "-o", "/dev/null", real.path]
        process.currentDirectoryURL = real
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
