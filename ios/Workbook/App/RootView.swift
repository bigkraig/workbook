import SwiftUI

/// Chooses the layout for how the phone is being held, over one shared
/// navigation state (see Navigator):
///
/// - cover screen / ordinary phone: a single stack;
/// - inner screen open flat, or half-folded like a book: the component
///   browser on one side of the crease and the document on the other;
/// - half-folded standing on the bench: the open document as a workbench
///   (figure upright, current step lying flat).
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    private let layout = WideLayout()
    /// The hinge, once it has reported; nil until then (and on other devices),
    /// which is treated as open flat.
    @State private var hinge: DeviceHinge?

    /// Half-folded far enough to stand on the bench or hold like a book.
    private var bent: Bool {
        guard let hinge, hinge.status == .partiallyOpen else { return false }
        return (60...135).contains(hinge.angle.degrees)
    }

    var body: some View {
        @Bindable var settings = settings
        GeometryReader { geo in
            let posture = Posture.current(geo, wide: layout.isWide, bent: bent)
            Group {
                if let vehicle = navigator.vehicle {
                    arranged(posture, vehicle: vehicle, size: geo.size)
                } else {
                    NavigationStack { VehicleListView() }
                }
            }
            .animation(.snappy(duration: 0.25), value: navigator.focused)
        }
        .background(Theme.ink.ignoresSafeArea())
        .onHingeChange { _, context in hinge = context.hinge }
        .fullScreenCover(isPresented: $settings.needsLogin) { SignInView() }
        .onOpenURL { url in
            Task { await navigator.open(link: url, api: API(settings: settings)) }
        }
        .task(id: settings.sessionGeneration) {
            if let link = navigator.pendingLink {
                await navigator.open(link: link, api: API(settings: settings))
            }
            if navigator.translations.isEmpty,
               let translations = try? await API(settings: settings).translations() {
                navigator.translations = translations
            }
        }
    }

    @ViewBuilder
    private func arranged(_ posture: Posture, vehicle: Vehicle, size: CGSize) -> some View {
        switch posture {
        case .compact:
            compact(vehicle)
        case .open(let divider):
            panes(vehicle, leading: divider ?? min(max(size.width * 0.42, 340), 460), gap: 0)
        case .book(let fold):
            panes(vehicle, leading: fold.minX, gap: fold.width)
        case .tabletop(let fold):
            if let document = navigator.topDocument {
                WorkbenchView(summary: document) { navigator.detail.removeLast() }
            } else {
                // Nothing to work through yet: detail upright, browser on the flat half.
                VStack(spacing: 0) {
                    detailPane(vehicle).frame(height: max(0, fold.minY))
                    Theme.ink.frame(height: fold.height)
                    browser(vehicle)
                }
            }
        }
    }

    // MARK: - One column

    private func compact(_ vehicle: Vehicle) -> some View {
        @Bindable var navigator = navigator
        return NavigationStack(path: $navigator.path) {
            BrowseView(vehicle: vehicle, node: nil)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .node(let node): BrowseView(vehicle: vehicle, node: node)
                    case .detail(let detail): DetailScreen(route: detail)
                    }
                }
        }
        .id(vehicle.id)
    }

    // MARK: - Two panes

    private func panes(_ vehicle: Vehicle, leading: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !navigator.focused || navigator.detail.isEmpty {
                browser(vehicle).frame(width: leading)
                Theme.ink.frame(width: max(gap, 1))
                detailPane(vehicle)
            } else {
                detailPane(vehicle)
                    .environment(\.pageSplit, PageSplit(leading: leading, gap: gap))
            }
        }
    }

    private func browser(_ vehicle: Vehicle) -> some View {
        @Bindable var navigator = navigator
        return NavigationStack(path: $navigator.nodes) {
            BrowseView(vehicle: vehicle, node: nil)
                .navigationDestination(for: TreeNode.self) { BrowseView(vehicle: vehicle, node: $0) }
        }
        .id(vehicle.id)
    }

    @ViewBuilder
    private func detailPane(_ vehicle: Vehicle) -> some View {
        if let root = navigator.detail.first {
            NavigationStack(path: Binding(
                get: { Array(navigator.detail.dropFirst()) },
                set: { navigator.detail = [root] + $0 })) {
                DetailScreen(route: root)
                    .environment(\.isDetailRoot, true)
                    .navigationDestination(for: DetailRoute.self) { DetailScreen(route: $0) }
            }
            .id(root)
        } else {
            DetailPlaceholder(vehicle: vehicle)
        }
    }
}

struct DetailScreen: View {
    let route: DetailRoute

    var body: some View {
        switch route {
        case .document(let document): DocumentScreen(summary: document)
        case .tool(let number): ToolScreen(number: number)
        }
    }
}

/// The detail side before anything is open: the vehicle, and recent documents.
private struct DetailPlaceholder: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    let vehicle: Vehicle

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                RemoteImage(path: API(settings: settings).vehicleImagePath(vehicle))
                    .frame(maxWidth: 300, maxHeight: 150)
                    .padding(.top, 28)
                Text(vehicle.name).font(.title2.weight(.bold)).foregroundStyle(Theme.text)
                Text("Choose a document to read it here.")
                    .font(.subheadline).foregroundStyle(Theme.muted)

                let recents = navigator.recents.filter { $0.vehicle == vehicle }
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("RECENT")
                            .font(.system(.caption, design: .monospaced)).tracking(2.5)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        ForEach(recents) { recent in
                            Button { navigator.open(recent.document) } label: { DocumentRow(document: recent.document) }
                                .buttonStyle(.plain)
                            Divider().overlay(Theme.line)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }
}
