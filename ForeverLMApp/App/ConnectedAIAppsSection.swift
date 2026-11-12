// Settings › MCP: the AI apps holding access to this learner's ForeverLM, each with Disconnect.

import SwiftUI

/// The AI apps connected through the hosted connector, as the gateway lists
/// them, each with Disconnect: every grant that app holds ends at once, and it
/// has to ask to be approved again (security audit, 2026-11-12: there was no
/// way to take access back from an app). Hidden while the list is empty or
/// cannot be read.
struct ConnectedAIAppsSection: View {
    @State private var rows: [ConnectedAssistants.Row]?
    @State private var confirming: ConnectedAssistants.Row?
    @State private var disconnecting: String?
    @State private var problem: String?

    var body: some View {
        Group {
            if let rows, !rows.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connected AI apps")
                            .font(.headline)
                        ForEach(rows) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name)
                                    if let lastActive = row.lastActive {
                                        Text("Last active \(lastActive, format: .relative(presentation: .named))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if disconnecting == row.name {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Disconnect") { confirming = row }
                                        .buttonStyle(.bordered)
                                        .disabled(disconnecting != nil)
                                        .accessibilityIdentifier("settings.mcp.disconnectApp.\(row.name)")
                                }
                            }
                        }
                        if let problem {
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
        }
        .task { rows = await ConnectedAssistants.fetchRows() }
        .confirmationDialog(
            "Disconnect \(confirming?.name ?? "this app")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { row in
            Button("Disconnect", role: .destructive) { disconnect(row) }
        } message: { row in
            Text("\(row.name) loses access to your library at once. To use ForeverLM from it again, connect it and approve it here.")
        }
    }

    private func disconnect(_ row: ConnectedAssistants.Row) {
        disconnecting = row.name
        problem = nil
        Task {
            let done = await ConnectedAssistants.disconnect(name: row.name)
            disconnecting = nil
            if done {
                rows?.removeAll { $0.name == row.name }
            } else {
                problem = "Could not disconnect \(row.name). Check that you are online and signed in, then try again."
            }
        }
    }
}
