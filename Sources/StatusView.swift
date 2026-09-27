import SwiftUI

struct StatusView: View {
    @ObservedObject private var sync = HealthSync.shared
    @Environment(\.dismiss) private var dismiss
    private let config = AppConfig.shared

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var lastSyncText: String {
        guard let d = sync.lastSync else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        NavigationStack {
            List {
                if config.health.enabled {
                    Section("Apple Health") {
                        LabeledContent("Connected", value: sync.isPaired ? "Yes" : "No")
                        LabeledContent("Last sync", value: lastSyncText)
                        LabeledContent("Days sent", value: "\(sync.daysSent)")
                        LabeledContent("Waiting to send", value: "\(sync.pendingCount)")
                        if sync.needsRepair {
                            Text("Pair again: open settings in \(config.name) and tap Connect Apple Health.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        } else if let error = sync.lastError {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button(sync.isSyncing ? "Syncing..." : "Sync now") { sync.syncRecent(days: 7) }
                            .disabled(!sync.isPaired || sync.isSyncing)
                        if sync.isPaired {
                            Button("Unpair", role: .destructive) { sync.unpair() }
                        }
                    }
                } else {
                    Section {
                        Text("\(config.name) does not use Apple Health.")
                    }
                }
                Section {
                    Text("\(config.name) \(version) · LiteWrap")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sync status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
