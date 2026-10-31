# GoIDE

A native macOS IDE for Go, written in Swift (SwiftUI + AppKit).

> Early scaffold — usable for editing small Go projects, not yet a daily driver.

## Features

- Project sidebar (open any Go module folder)
- NSTextView editor with Go syntax highlighting, auto-indent, find bar, undo
- **gopls** integration over LSP: live diagnostics as you type, shown as underlines and in the Problems panel (click to jump)
- `go build ./...` (⌘B), `go test ./...` (⌘U), `go run .` (⌘R), stop (⌘.) with an Output panel

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)
- Go, plus gopls: `go install golang.org/x/tools/gopls@latest`

GoIDE looks for `go` and `gopls` on `PATH`, `$GOBIN`, `$GOPATH/bin`, `~/go/bin`, `/opt/homebrew/bin` and `/usr/local/go/bin`, so it works when launched from Finder too.

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

## Roadmap

- Completion, hover, go-to-definition, find references, rename (gopls)
- Format on save (gofmt / `textDocument/formatting`)
- Line-number gutter, tabs for multiple open files
- tree-sitter-go for incremental highlighting
- Debugging via Delve's DAP mode (breakpoints, stepping, variables)
