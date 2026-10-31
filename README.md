# GoIDE

A native macOS IDE for Go, written in Swift (SwiftUI + AppKit).

> Early but usable: editing, navigation, refactoring, testing and debugging for Go modules.

## Features

**Editor**
- Tabs with independent buffers, undo and scroll; unsaved-changes prompts
- Go syntax highlighting, line-number gutter with error/warning markers, current-line highlight, auto-indent
- Format on save (gofmt + organize imports via gopls), Format Document (⌥⇧F)

**Project**
- Sidebar file tree that follows changes on disk (FSEvents); new/rename/trash from the context menu
- Open files reload when changed externally (or offer Reload / Keep Mine if you have edits)
- Find in project (⇧⌘F): match case, whole word, regex
- Open Quickly (⌘P / ⇧⌘O): fuzzy file finder + workspace symbols; Outline sidebar for the current file

**Language (gopls)**
- Live diagnostics: underlines, gutter dots, Problems panel
- Completion with auto-imports, hover docs, signature help while typing calls
- Jump to definition (⌘-click / ⌃⌘J) and back (⌃⌘←), find references (⇧⌘R)
- Rename symbol across files (⌃⌘E), quick fixes and refactorings (⌥↩)

**Run, test & debug**
- `go build ./...` (⌘B), `go run .` (⌘R), stop (⌘.) with an Output panel
- Tests via `go test -json` (⌘U all, ⌃⌘U package, ⌃⌥⌘U at cursor): Tests panel, gutter ▶ / ✓ / ✗
- Debugger (Delve DAP, ⌥⌘R): click line numbers for breakpoints, continue / step over (F6) / into (F7) / out (F8), call stack, expandable variables; debug a single test

See [ROADMAP.md](ROADMAP.md) for what's next.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)
- Go, plus gopls and Delve:
  `go install golang.org/x/tools/gopls@latest`
  `go install github.com/go-delve/delve/cmd/dlv@latest`

GoIDE looks for `go`, `gopls` and `dlv` on `PATH`, `$GOBIN`, `$GOPATH/bin`, `~/go/bin`, `/opt/homebrew/bin` and `/usr/local/go/bin`, so it works when launched from Finder too.

## Build & run

```sh
swift run GoIDE Examples/hello     # run in debug, opening the example project
swift test                         # unit tests + a gopls end-to-end test
./scripts/bundle.sh                # build build/GoIDE.app (release, ad-hoc signed)
open build/GoIDE.app
```

You can also open `Package.swift` in Xcode.

## Layout

| Path | What |
|---|---|
| `Sources/GoIDECore` | UI-independent core: JSON-RPC/LSP client, message framing, Go highlighter, LSP position math, file tree |
| `Sources/GoIDE` | SwiftUI app: workspace state, editor view, sidebar, panels |
| `Tests/GoIDECoreTests` | swift-testing tests |
| `Examples/hello` | Small Go module for trying things out |


## License

MIT — see [LICENSE](LICENSE).
