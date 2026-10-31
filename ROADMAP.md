# GoIDE Roadmap

Status: ✅ done · 🚧 in progress · ⏸ waiting on a decision · ⬜ planned

Estimates are Claude Code session time.

## Done

- ✅ App scaffold: sidebar, editor, Go highlighting, Problems/Output panels, go build/test/run
- ✅ gopls over LSP: live diagnostics
- ✅ Completion (with auto-imports), hover, go to definition + back stack

## Phase 1 — Editor essentials

| # | Item | Notes | Est. |
|---|---|---|---|
| 1.1 | ✅ Line-number gutter | Ruler with line numbers, current-line highlight, error/warning markers | 0.3h |
| 1.2 | ✅ Tabs | Multiple open files; each keeps its own buffer, undo, scroll, dirty state; ⌘W closes, ⌃⇥ cycles | 0.7h |
| 1.3 | ✅ Format on save | gopls `textDocument/formatting` + organize imports; manual ⌥⇧F, toggle in Go menu | 0.4h |
| 1.4 | ✅ File system | Watch the folder (FSEvents) to refresh the tree and reload unmodified open files; new file/folder, rename, move to Trash | 0.6h |
| 1.5 | ✅ Find in project | ⌘⇧F search panel (literal / regex, case), results grouped by file, click to jump | 0.5h |

## Phase 2 — Language intelligence

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ✅ Signature help | Parameter hints while typing a call (`(` / `,`) | 0.4h |
| 2.2 | ✅ Find references | ⇧⌘R / context menu, results in a References panel | 0.4h |
| 2.3 | ✅ Rename symbol | `prepareRename` + `textDocument/rename` (⌃⌘E / context menu), WorkspaceEdit across files | 0.4h |
| 2.4 | ✅ Quick fixes | Code actions at the caret (⌥↩ / context menu): quick fixes, refactorings, source actions | 0.5h |
| 2.5 | ✅ Navigation | Open Quickly (⌘P / ⇧⌘O): fuzzy files + workspace symbols; Outline sidebar | 0.7h |

## Phase 3 — Run & debug

| # | Item | Notes | Est. |
|---|---|---|---|
| 3.1 | ✅ Test integration | `go test -json` runner: Tests panel, gutter ▶ / ✓ / ✗ per test, run at cursor / package / all, clickable `file.go:N` | 0.7h |
| 3.2 | ✅ Debugger (Delve DAP) | Gutter breakpoints, launch/continue/step/stop, call stack, variables, debug single tests | 2–3h |

## Phase 4 — Polish & release

| # | Item | Notes | Est. |
|---|---|---|---|
| 4.1 | ✅ Settings | ⌘, — font size, tab width, format on save, go/gopls/dlv path overrides | 0.5h |
| 4.2 | ✅ CI & packaging | GitHub Actions build + test + bundle, app icon, tagged releases with `GoIDE.zip` | 0.5h |

**User must do manually** (duration outside Claude's control): Apple Developer Program enrollment,
Developer ID certificate, notarization credentials — only needed to ship a signed/notarized build to others.

## Phase 5 — Deeper language features & Git

Released so far: [v0.1.0](https://github.com/lai3d/golang-ide/releases/tag/v0.1.0) (phases 1–4).

| # | Item | Notes | Est. |
|---|---|---|---|
| 5.1 | ✅ Occurrence highlights | Highlight other uses of the symbol under the caret (`textDocument/documentHighlight`) | 0.3h |
| 5.2 | ✅ Inlay hints | Parameter names and inferred types inline (`textDocument/inlayHint`), toggle in Settings | 0.5h |
| 5.3 | ✅ Semantic highlighting | gopls semantic tokens over the regex lexer: types, params, consts, packages, fields | 0.6h |
| 5.4 | ✅ Call hierarchy | Incoming / outgoing calls tree for the function at the caret | 0.5h |
| 5.5 | ✅ Git status | Sidebar badges (M / A / ? / D), gutter change bars vs HEAD, branch in the toolbar | 0.7h |
| 5.6 | ✅ Inline blame | Author, date and summary of the caret line's last commit, at the end of the line | 0.4h |
| 5.7 | ✅ Multiple windows | One project per window (File ▸ New Window, ⇧⌘N) | 0.8h |
| 5.8 | ✅ Code folding | `textDocument/foldingRange`; gutter chevrons, `{⋯}` placeholders, ⌥⌘← / ⌥⌘→, fold/unfold all (⇧⌥⌘← / →) | 1h |

## Phase 6 — Everyday workflow

| # | Item | Notes | Est. |
|---|---|---|---|
| 6.1 | ✅ Session restore | Recent projects on the welcome screen; reopen the last project's tabs | 0.4h |
| 6.2 | ✅ Replace in project | Replace field in the search sidebar: preview, replace one / all (undoable in open files) | 0.5h |
| 6.3 | ✅ Diff vs HEAD | Side-by-side diff of the current file against HEAD | 0.6h |
| 6.4 | ✅ Source control panel | Changed files, stage / unstage / discard, commit message + commit | 0.8h |
| 6.5 | ✅ Debugger extras | Conditional breakpoints, hover to evaluate while paused, watch expressions | 0.7h |
| 6.6 | ✅ Integrated terminal | SwiftTerm (PTY + xterm emulation): login shell in the project folder, ⌃`, survives tab switches, restart on exit | 0.8h |
| 6.7 | ✅ Go module tools | Go menu: vet (⌃⌥⌘V), generate, Modules ▸ tidy / update / download / verify; clickable `file.go:N` in Output | 0.3h |

## Phase 7 — Productivity

Released so far: [v0.2.0](https://github.com/lai3d/golang-ide/releases/tag/v0.2.0) (phases 1–6).

| # | Item | Notes | Est. |
|---|---|---|---|
| 7.1 | ✅ Editing commands | Toggle comment (⌘/), auto-close brackets & quotes, move line (⌥⌘[ / ⌥⌘]), duplicate line (⇧⌘D), indent / outdent (⌘] / ⌘[) | 0.6h |
| 7.2 | ✅ Snippets | gopls snippet completions with tab stops; built-in Go snippets (`iferr`, `fori`, `forr`, `func`, `test`, …) | 0.8h |
| 7.3 | ✅ Implementations | Jump to Implementation (⌥⌘J), Jump to Type Definition (⌃⌥⌘J), context menu; several results list in References | 0.3h |
| 7.4 | ✅ Breadcrumbs | Path › type › function above the editor, following the caret | 0.4h |
| 7.5 | ✅ Test coverage | Go ▸ Test with Coverage (⌃⇧⌘U): covered / uncovered lines tinted, total and per-file % in the Tests panel | 0.7h |
| 7.6 | ✅ Run configurations | Toolbar picker + Edit Configurations sheet: main package (auto-detected `cmd/…`), arguments, environment; used by Run and Debug | 0.6h |

## Later / ideas

- tree-sitter-go for incremental parsing (if semantic tokens + the regex lexer fall short)
- Developer ID signing + notarization in the release workflow (needs the user's Apple Developer account)
