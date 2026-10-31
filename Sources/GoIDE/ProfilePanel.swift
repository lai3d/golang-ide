import GoIDECore
import SwiftUI

/// Bottom panel: the pprof top table of the last profile run.
struct ProfilePanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var byLine = false
    @State private var sortByCum = false
    @State private var projectOnly = false
    @State private var filter = ""
    @State private var selection: ProfileRow.ID?

    var body: some View {
        if let session = workspace.profile {
            VStack(spacing: 0) {
                header(session)
                Divider()
                if session.isLoading {
                    ProgressView("Profiling \(session.title)…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = session.error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    table(rows(session))
                }
            }
        } else {
            VStack(spacing: 8) {
                Text("No profile yet.").foregroundStyle(.secondary)
                HStack {
                    Button("CPU Profile Benchmarks") { workspace.profilePackage(.cpu, benchmarks: true) }
                    Button("Memory Profile Benchmarks") { workspace.profilePackage(.memory, benchmarks: true) }
                }
                .disabled(workspace.rootURL == nil || workspace.isRunning)
                Text("Profiles the package of the current file (Go ▸ Profile).")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ session: ProfileSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.kind == .cpu ? "cpu" : "memorychip")
            VStack(alignment: .leading, spacing: 0) {
                Text("\(session.kind.rawValue) · \(session.title)").font(.callout.weight(.semibold)).lineLimit(1)
                if !session.report.type.isEmpty {
                    Text("\(session.report.type), total \(session.report.total)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Toggle("Project only", isOn: $projectOnly).toggleStyle(.checkbox)
                .help("Hide runtime and standard-library rows")
            Picker("View", selection: $byLine) {
                Text("Functions").tag(false)
                Text("Lines").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Sort", selection: $sortByCum) {
                Text("Flat").tag(false)
                Text("Cum").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { workspace.openProfileInBrowser() } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open in pprof web UI (flame graph, source)")
                .disabled(session.isLoading || session.error != nil)
            Button { rerun(session) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Profile again")
                .disabled(workspace.isRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func rows(_ session: ProfileSession) -> [ProfileRow] {
        var rows = byLine ? session.lines : session.report.rows
        if projectOnly, let root = workspace.rootURL.map({ Workspace.key(for: $0) + "/" }) {
            rows = rows.filter { $0.file?.hasPrefix(root) == true }
        }
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = rows.filter { $0.function.localizedCaseInsensitiveContains(query) }
        }
        if sortByCum { rows.sort { $0.cumPercent > $1.cumPercent } }
        return rows
    }

    private func table(_ rows: [ProfileRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Flat") { row in
                PercentCell(value: row.flat, percent: row.flatPercent, color: .orange)
            }
            .width(min: 140, ideal: 150)
            TableColumn("Cum") { row in
                PercentCell(value: row.cum, percent: row.cumPercent, color: .blue)
            }
            .width(min: 140, ideal: 150)
            TableColumn("Function") { row in
                HStack(spacing: 4) {
                    Text(row.shortName).font(.system(size: 12, design: .monospaced))
                    Text(row.package).font(.caption).foregroundStyle(.secondary)
                    if row.isInline { Text("inline").font(.caption2).foregroundStyle(.tertiary) }
                }
                .lineLimit(1)
                .help(row.function)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Location") { row in
                if let file = row.file, let line = row.line {
                    Text("\(workspace.displayPath(file)):\(line)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .width(min: 100)
        }
        .contextMenu(forSelectionType: ProfileRow.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Button("Show Source") { workspace.reveal(row) }.disabled(row.file == nil)
                Button("Copy Function Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.function, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) { workspace.reveal(row) }
        }
    }

    private func rerun(_ session: ProfileSession) {
        workspace.profilePackage(session.kind, benchmarks: session.benchmarks)
    }
}

private struct PercentCell: View {
    let value: String
    let percent: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(color.opacity(0.7))
                        .frame(width: max(2, proxy.size.width * min(percent, 100) / 100))
                }
            }
            .frame(width: 28, height: 5)
            Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                .frame(minWidth: 56, alignment: .trailing)
            Text(String(format: "%.1f%%", percent))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                .fixedSize()
        }
    }
}
