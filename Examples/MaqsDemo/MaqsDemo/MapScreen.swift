import MaqsCore
import MaqsUI
import SwiftUI

/// The one screen: the map, the app's own chrome over it, and the sheets.
struct MapScreen: View {
    @Bindable var model: DemoModel

    var body: some View {
        // The map runs under the status bar and the bottom bar; its centre and fitted boxes keep to what they leave
        // free. The reader keeps to the safe area, so its insets count the bars; only the map ignores them.
        GeometryReader { proxy in
            MaqsMapView(map: model.map)
                .ignoresSafeArea()
                .onChange(of: proxy.safeAreaInsets, initial: true) { _, insets in updateInsets(insets) }
                .onChange(of: model.sheetHeight) { updateInsets(proxy.safeAreaInsets) }
        }
        .safeAreaInset(edge: .bottom) { BottomBar(model: model) }
        .overlay(alignment: .top) {
            HStack(alignment: .top) {
                Banners(model: model)
                Spacer(minLength: 8)
                CameraButtons(model: model)
            }
            .padding(.horizontal)
        }
        .onAppear { model.map.show(DemoModel.startArea) }
        .task { await model.start() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .regions: RegionsSheet(model: model)
            case .trailSearch: TrailSearchSheet(model: model)
            case .sightLine: SightLineSheet(model: model)
            case .trail(let trail): TrailRecordSheet(model: model, trail: trail)
            case .place(let place): PlaceRecordSheet(place: place)
            }
        }
    }
}

extension MapScreen {
    /// The bars, or a sheet the map stays usable above, whichever covers more of the bottom.
    private func updateInsets(_ safeArea: EdgeInsets) {
        var insets = safeArea
        insets.bottom = max(insets.bottom, model.sheetHeight)
        model.map.contentInsets = insets
    }
}

/// The credits and the buttons that open the sheets.
private struct BottomBar: View {
    let model: DemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MapAttributionView(map: model.map)
            HStack {
                SheetButton("Regions", systemImage: "square.and.arrow.down") { model.sheet = .regions }
                Spacer()
                SheetButton("Trails", systemImage: "figure.hiking") { model.sheet = .trailSearch }
                Spacer()
                SheetButton("Sight line", systemImage: "eye") { model.sheet = .sightLine }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }
}

/// The app's own camera buttons: the map draws no compass and no location button.
private struct CameraButtons: View {
    let model: DemoModel

    var body: some View {
        VStack(spacing: 8) {
            Button {
                model.locationButtonTapped()
            } label: {
                Image(systemName: locationSymbol)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(locationLabel)
            Button {
                model.map.resetNorth()
            } label: {
                Image(systemName: "location.north.line")
                    .rotationEffect(.degrees(-model.map.camera.heading))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Turn the map to north")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var locationSymbol: String {
        guard model.map.userLocation != .hidden else { return "location" }
        return switch model.map.followMode {
        case .none: "location"
        case .position: "location.fill"
        case .heading, .course: "location.north.line.fill"
        }
    }

    private var locationLabel: String {
        guard model.map.userLocation != .hidden else { return "Show my location" }
        return switch model.map.followMode {
        case .none: "Follow my location"
        case .position: "Follow my location and heading"
        case .heading, .course: "Stop following"
        }
    }
}

/// What the map reports that the user should know: no network, paused tiles, a style error, a download to offer
/// or in progress, and the demo's own last problem.
private struct Banners: View {
    let model: DemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.map.connectivity == .offline {
                Label("Offline: the map shows the downloaded regions and what it saw before.", systemImage: "wifi.slash")
            }
            if model.map.onlineTilesPaused {
                Label("The tile server asked the map to slow down; online tiles resume shortly.", systemImage: "pause.circle")
            }
            if let error = model.map.lastError {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
            }
            ForEach(downloads, id: \.name) { download in
                ProgressView(value: download.fraction) { Text("Downloading \(download.name)") }
            }
            if let region = model.map.uninstalledRegion {
                HStack {
                    Text("\(region.displayName) is not downloaded.")
                    Button("Download \(region.totalBytes.formatted(.byteCount(style: .file)))") {
                        model.install(region.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message)
                    Button("Dismiss", systemImage: "xmark") { model.message = nil }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .font(.footnote)
        .padding(banners ? 10 : 0)
        .background(.regularMaterial.opacity(banners ? 1 : 0), in: RoundedRectangle(cornerRadius: 10))
    }

    private var banners: Bool {
        model.map.connectivity == .offline || model.map.onlineTilesPaused || model.map.lastError != nil
            || !downloads.isEmpty || model.map.uninstalledRegion != nil || model.message != nil
    }

    private var downloads: [(name: String, fraction: Double)] {
        model.maqs.state.packs.compactMap { id, state in
            guard case .downloading(let progress) = state else { return nil }
            return (model.maqs.state.catalog?.pack(id)?.displayName ?? String(describing: id), progress.fraction)
        }
        .sorted { $0.name < $1.name }
    }
}
