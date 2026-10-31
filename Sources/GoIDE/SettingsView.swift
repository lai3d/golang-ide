import GoIDECore
import SwiftUI

/// GoIDE ▸ Settings… (⌘,)
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "editor"

    var body: some View {
        TabView(selection: $tab) {
            EditorSettingsTab()
                .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
                .tag("editor")
            GoSettingsTab()
                .tabItem { Label("Go", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag("go")
            ToolsSettingsTab()
                .tabItem { Label("Go Tools", systemImage: "wrench.and.screwdriver") }
                .tag("tools")
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct EditorSettingsTab: View {
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = 13.0
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = 4
    @AppStorage("formatOnSave") private var formatOnSave = true
    @AppStorage("inlayHints") private var inlayHints = true
    @AppStorage("inlineBlame") private var inlineBlame = true
    @AppStorage(SessionStore.reopenLastKey) private var reopenLast = true

    var body: some View {
        Form {
            LabeledContent("Font size") {
                HStack {
                    Slider(value: $fontSize, in: 9...24, step: 1).frame(width: 180)
                    Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Tab width", selection: $tabWidth) {
                ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            Toggle("Format and organize imports on save", isOn: $formatOnSave)
            Toggle("Show inlay hints (parameter names, inferred types)", isOn: $inlayHints)
            Toggle("Show Git blame for the current line", isOn: $inlineBlame)
            Toggle("Reopen the last project at launch", isOn: $reopenLast)
            Text("func main() {\n\tfmt.Println(\"preview\")\n}")
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// gopls options; applied live to every open window.
private struct GoSettingsTab: View {
    @AppStorage(GoplsOptions.gofumptKey) private var gofumpt = false
    @AppStorage(GoplsOptions.localKey) private var local = ""
    @AppStorage(GoplsOptions.staticcheckKey) private var staticcheck = false
    @AppStorage(GoplsOptions.shadowKey) private var shadow = false
    @AppStorage(GoplsOptions.buildTagsKey) private var buildTags = ""

    var body: some View {
        Form {
            Section("Formatting") {
                Toggle("Format with gofumpt (stricter gofmt)", isOn: $gofumpt)
                TextField("Local import prefix", text: $local, prompt: Text("github.com/you/project"))
                Text("Imports with this prefix are grouped after third-party ones (goimports -local).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Diagnostics") {
                Toggle("Staticcheck analyzers", isOn: $staticcheck)
                Toggle("Report shadowed variables", isOn: $shadow)
            }
            Section("Build") {
                TextField("Build tags", text: $buildTags, prompt: Text("integration, e2e"))
                Text("Used by gopls and by Build, Run, Test, Vet and Debug.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
        .onChange(of: gofumpt) { Workspace.scheduleGoplsSettingsUpdate() }
        .onChange(of: local) { Workspace.scheduleGoplsSettingsUpdate() }
        .onChange(of: staticcheck) { Workspace.scheduleGoplsSettingsUpdate() }
        .onChange(of: shadow) { Workspace.scheduleGoplsSettingsUpdate() }
        .onChange(of: buildTags) { Workspace.scheduleGoplsSettingsUpdate() }
    }
}

private struct ToolsSettingsTab: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Form {
            Section {
                ToolPathRow(name: "go", hint: "https://go.dev/dl/")
                ToolPathRow(name: "gopls", hint: "go install golang.org/x/tools/gopls@latest")
                ToolPathRow(name: "dlv", hint: "go install github.com/go-delve/delve/cmd/dlv@latest")
            } footer: {
                Text("Leave empty to search PATH, $GOBIN, $GOPATH/bin, ~/go/bin and Homebrew.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Restart gopls") { Task { await workspace.restartLanguageServer() } }
                .disabled(workspace.rootURL == nil)
        }
    }
}

private struct ToolPathRow: View {
    let name: String
    let hint: String
    @AppStorage private var path: String

    init(name: String, hint: String) {
        self.name = name
        self.hint = hint
        _path = AppStorage(wrappedValue: "", ToolLocator.overrideKey(for: name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(name) {
                TextField("Auto-detect", text: $path).textFieldStyle(.roundedBorder)
            }
            Group {
                if let found = ToolLocator.find(name) {
                    Text("Using \(found.path)").foregroundStyle(.secondary)
                } else {
                    Text("Not found — \(hint)").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .textSelection(.enabled)
        }
    }
}
