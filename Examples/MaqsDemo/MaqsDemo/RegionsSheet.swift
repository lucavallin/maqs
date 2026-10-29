import MaqsCore
import SwiftUI

/// The catalog of the latest data release: each region's size and state, with download, cancel and remove.
struct RegionsSheet: View {
    let model: DemoModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let catalog = model.maqs.state.catalog {
                    Section {
                        ForEach(catalog.regions) { region in
                            RegionRow(model: model, region: region, state: model.maqs.state.packs[region.id]) {
                                if let box = region.bbox { model.map.show(box) }
                                dismiss()
                            }
                        }
                    } footer: {
                        Text("Data release \(catalog.release). Each region holds the basemap, terrain, trails and places.")
                    }
                } else if model.maqs.state.lastRefreshError == nil {
                    ProgressView("Loading the catalog")
                }
                if let error = model.maqs.state.lastRefreshError {
                    Section("Catalog") {
                        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .refreshable { await model.refreshCatalog(policy: .always) }
            .navigationTitle("Regions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// One region: its name, size and state, and the action that fits the state.
private struct RegionRow: View {
    let model: DemoModel
    let region: PackSummary
    let state: PackState?
    let showOnMap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(region.displayName).font(.headline)
                Spacer()
                Text(region.totalBytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
            }
            switch state {
            case .downloading(let progress)?:
                ProgressView(value: progress.fraction) {
                    Text("\(progress.bytesReceived.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                }
            case .failed(let error)?:
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            default:
                Text(statusText).foregroundStyle(.secondary)
            }
            HStack {
                actions
                Spacer()
                Button("Show", systemImage: "map", action: showOnMap)
            }
            .buttonStyle(.bordered)
        }
        .font(.subheadline)
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .queued?, .downloading?, .verifying?:
            Button("Cancel", systemImage: "xmark", role: .cancel) { model.cancelInstall(region.id) }
        default:
            switch region.status {
            case .notInstalled:
                Button("Download", systemImage: "arrow.down.circle") { model.install(region.id) }
            case .installed:
                Button("Remove", systemImage: "trash", role: .destructive) { model.remove(region.id) }
            case .updateAvailable, .partiallyInstalled:
                Button("Update", systemImage: "arrow.triangle.2.circlepath") { model.install(region.id) }
                Button("Remove", systemImage: "trash", role: .destructive) { model.remove(region.id) }
            }
        }
    }

    private var statusText: String {
        switch state {
        case .queued?: return "Waiting for another download"
        case .verifying?: return "Checking the files"
        default: break
        }
        return switch region.status {
        case .notInstalled: "Not downloaded"
        case .installed(let release): "Installed from \(release)"
        case .updateAvailable(let release, let bytes):
            "Update to \(release) available, \(bytes.formatted(.byteCount(style: .file)))"
        case .partiallyInstalled(let missing):
            "Missing \(missing.map(\.rawValue).sorted().joined(separator: ", "))"
        }
    }
}
