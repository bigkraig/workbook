import SwiftUI

/// A special tool: photo, description, suppliers with their part numbers, and
/// the documents that call for it.
struct ToolScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    let number: String
    @State private var tool: Loadable<ToolData> = .loading

    var body: some View {
        Group {
            switch tool {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                StatusView(systemImage: "wrench.and.screwdriver", title: "Couldn't load this tool",
                           message: message) { Task { await load() } }
            case .loaded(let tool):
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(tool)
                        if let distributors = tool.distributors, !distributors.isEmpty { suppliers(distributors) }
                        if let documents = tool.referencingDocuments, !documents.isEmpty { references(documents) }
                    }
                    .padding(16)
                }
            }
        }
        .background(Theme.paper)
        .navigationTitle(number)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: "\(number)#\(settings.sessionGeneration)") { await load() }
    }

    private func summary(_ tool: ToolData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.title).font(.title2.weight(.bold)).foregroundStyle(Theme.text)
            Text(tool.toolNumberPag).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.brass)
            RemoteImage(path: API(settings: settings).toolImagePath(tool.toolNumberPag))
                .frame(maxWidth: 260, maxHeight: 200)
            if !tool.description.isEmpty {
                Text(tool.description).font(.subheadline).foregroundStyle(Theme.text)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Type", tool.toolType)
                row("Classification", tool.dealerClassification)
                row("Status", tool.state.capitalized)
                if let vw = tool.toolNumberVw, !vw.isEmpty { row("VW number", vw) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.footnote).foregroundStyle(Theme.muted)
            Text(value).font(.footnote).foregroundStyle(Theme.text)
        }
    }

    private func suppliers(_ distributors: [ToolData.Distributor]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Suppliers")
            ForEach(distributors, id: \.self) { distributor in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(distributor.name).font(.subheadline).foregroundStyle(Theme.text)
                        let contact = [distributor.city, distributor.phone].compactMap { $0 }.filter { !$0.isEmpty }
                        if !contact.isEmpty {
                            Text(contact.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(distributor.partNumber)
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider().overlay(Theme.line)
            }
        }
        .background(Color.white)
    }

    private func references(_ documents: [DocumentSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Used in")
            ForEach(documents) { document in
                Button { navigator.push(.document(document)) } label: { DocumentRow(document: document) }
                    .buttonStyle(.plain)
                Divider().overlay(Theme.line)
            }
        }
        .background(Color.white)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .monospaced))
            .tracking(2.5)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    private func load() async {
        guard let vehicle = navigator.vehicle else { return }
        do { tool = .loaded(try await API(settings: settings).tool(number, vehicle: vehicle)) }
        catch APIError.notSignedIn {}
        catch { tool = .failed(error.localizedDescription) }
    }
}
