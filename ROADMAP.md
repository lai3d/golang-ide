# GoIDE Roadmap

Status: ✅ done · 🚧 in progress · ⬜ planned

Estimates are Claude Code session time.

## Done

- ✅ App scaffold: sidebar, editor, Go highlighting, Problems/Output panels, go build/test/run
- ✅ gopls over LSP: live diagnostics
- ✅ Completion (with auto-imports), hover, go to definition + back stack

## Phase 1 — Editor essentials

| # | Item | Notes | Est. |
|---|---|---|---|
| 1.1 | ⬜ Line-number gutter | Ruler with line numbers, current-line highlight, error/warning markers | 0.3h |
| 1.2 | ⬜ Tabs | Multiple open files; each keeps its own buffer, undo, scroll, dirty state; ⌘W closes, ⌃⇥ cycles | 0.7h |
| 1.3 | ⬜ Format on save | gopls `textDocument/formatting` + organize imports; manual ⌃⇧F | 0.4h |
| 1.4 | ⬜ File system | Watch the folder (FSEvents) to refresh the tree and reload unmodified open files; new file/folder, rename, move to Trash | 0.6h |
| 1.5 | ⬜ Find in project | ⌘⇧F search panel (literal / regex, case), results grouped by file, click to jump | 0.5h |

## Phase 2 — Language intelligence

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ⬜ Signature help | Parameter hints while typing a call (`(` / `,`) | 0.4h |
| 2.2 | ⬜ Find references | ⇧⌘R / context menu, results in a References panel | 0.4h |
| 2.3 | ⬜ Rename symbol | `textDocument/rename`, apply WorkspaceEdit across files | 0.4h |
| 2.4 | ⬜ Quick fixes | Code actions for diagnostics (⌘.) — e.g. add import, fill struct | 0.5h |
| 2.5 | ⬜ Navigation | Quick Open file (⌘P), document outline, go to symbol in workspace (⌘⇧O) | 0.7h |

## Phase 3 — Run & debug

| # | Item | Notes | Est. |
|---|---|---|---|
| 3.1 | ⬜ Test integration | Run test/package under cursor, parse `go test -json`, pass/fail list | 0.7h |
| 3.2 | ⬜ Debugger (Delve DAP) | Gutter breakpoints, launch/continue/step/stop, call stack, variables | 2–3h |

## Phase 4 — Polish & release

| # | Item | Notes | Est. |
|---|---|---|---|
| 4.1 | ⬜ Settings | Font size, tab width, format on save, gopls/go/dlv paths | 0.5h |
| 4.2 | ⬜ CI & packaging | GitHub Actions build + test, app icon, release `.app` zip | 0.5h |

**User must do manually** (duration outside Claude's control): Apple Developer Program enrollment,
Developer ID certificate, notarization credentials — only needed to ship a signed/notarized build to others.

## Later / ideas

- tree-sitter-go for incremental highlighting and code folding
- Inlay hints, semantic tokens, call hierarchy
- Git status in the sidebar, inline blame
- Multiple windows / workspaces
