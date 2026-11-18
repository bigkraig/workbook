import SwiftUI

/// One level of the component tree: its sub-folders, then every document
/// under it. The root level also searches the whole vehicle.
struct BrowseView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    let vehicle: Vehicle
    /// nil for the vehicle's root.
    let node: TreeNode?

    @State private var level: Loadable<TreeNode> = .loading
    @State private var documents: Loadable<[DocumentSummary]> = .loading
    @State private var query = ""
    @State private var results: Loadable<[DocumentSummary]>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let results {
                    Section { documentList(results, empty: "No documents match “\(query)”.") } header: {
                        sectionHeader("Search results", count: results.value?.count)
                    }
                } else {
                    folders
                    Section { documentList(documents, empty: "No documents here.") } header: {
                        sectionHeader("Workshop literature", count: documents.value?.count)
                    }
                }
            }
        }
        .background(Theme.paper, ignoresSafeAreaEdges: [.bottom, .horizontal])
        .background(Theme.ink, ignoresSafeAreaEdges: [.top, .horizontal])
        .navigationTitle(node?.title ?? vehicle.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.ink, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if node == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { navigator.vehicle = nil } label: {
                        Label("Vehicles", systemImage: "car.2")
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search \(vehicle.name) documents")
        .task(id: "\(settings.sessionGeneration)") { await load() }
        .task(id: query) { await search() }
        .onChange(of: navigator.pendingSearch, initial: true) { _, pending in
            // A deep link asked for a search of this vehicle.
            guard node == nil, let pending else { return }
            query = pending
            navigator.pendingSearch = nil
        }
    }

    @ViewBuilder
    private var folders: some View {
        switch level {
        case .loading:
            ProgressView().tint(.white).frame(maxWidth: .infinity).padding(24).background(Theme.ink)
        case .failed(let message):
            StatusView(systemImage: "exclamationmark.triangle", title: "Couldn't load this section",
                       message: message) { Task { await load() } }
        case .loaded(let level):
            VStack(spacing: 0) {
                if let illustration = level.illustrationId, illustration > 0, !(level.children ?? []).isEmpty {
                    IllustrationNavigator(illustrationId: illustration,
                                          targets: IllustrationNavigator.targets(for: level.children ?? [])) {
                        navigator.nodes.append($0)
                    }
                }
                ForEach(level.children ?? []) { child in
                    Button { navigator.nodes.append(child) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: child.hasChildren ? "folder.fill" : "folder")
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 22)
                            Text(child.nodeValue)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(Theme.brass)
                            Text(child.title).font(.subheadline).foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.ink)
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack {
            Image(systemName: "books.vertical").font(.footnote)
            Text(title.uppercased())
                .font(.system(.caption, design: .monospaced))
                .tracking(2.5)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.brass, in: Capsule())
                    .foregroundStyle(Theme.ink)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.ink2)
    }

    @ViewBuilder
    private func documentList(_ list: Loadable<[DocumentSummary]>, empty: String) -> some View {
        switch list {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(24)
        case .failed(let message):
            StatusView(systemImage: "exclamationmark.triangle", title: "Couldn't load documents", message: message)
        case .loaded(let documents) where documents.isEmpty:
            Text(empty).font(.subheadline).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity).padding(28)
        case .loaded(let documents):
            ForEach(documents) { document in
                Button { navigator.open(document) } label: {
                    DocumentRow(document: document, selected: navigator.openDocument == document)
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.line)
            }
        }
    }

    private func load() async {
        let api = API(settings: settings)
        do {
            let loaded: TreeNode
            if let node { loaded = try await api.node(node.nodeId) } else { loaded = try await api.rootNode(vehicle) }
            level = .loaded(loaded)
            documents = .loaded(try await api.documents(node: loaded.nodeId))
        } catch APIError.notSignedIn {
            // RootView is presenting the login sheet; reload when the session changes.
        } catch {
            if level.value == nil { level = .failed(error.localizedDescription) }
            documents = .failed(error.localizedDescription)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = nil; return }
        results = .loading
        // Debounce typing; .task(id:) cancels the previous run.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do { results = .loaded(try await API(settings: settings).search(vehicle, query: text)) }
        catch is CancellationError {}
        catch { if !Task.isCancelled { results = .failed(error.localizedDescription) } }
    }
}
