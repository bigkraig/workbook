import SwiftUI

/// The start screen: the garage, and the documents you were last in.
///
/// On the iPhone Duo's inner screen the two sit either side of the crease:
/// the cars on the left as cards you can recognise at a glance, and on the
/// right the way straight back into what you were reading. On the cover
/// screen the same two stack.
struct VehicleListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    @State private var vehicles: Loadable<[Vehicle]> = .loading
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            // On the inner screen the split sits on the crease.
            let crease = ReservedLayout.crease(in: geo).flatMap { $0.height > $0.width ? $0.midX : nil }
            let leading = min(max(crease ?? geo.size.width / 2, 320), geo.size.width - 320)
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { garage(columns: 2) }.frame(width: leading)
                        Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                        ScrollView { continueReading(includingLatest: true).padding(.top, 78) }
                    }
                } else {
                    ScrollView {
                        // One column: the way back into the last document
                        // comes first, then the cars, then the older ones.
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            if let latest = navigator.recents.first {
                                Button { open(latest) } label: { LatestCard(recent: latest) }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 18)
                                    .padding(.bottom, 22)
                            }
                            garage(columns: geo.size.width > 380 ? 2 : 1, withHeader: false)
                            if navigator.recents.count > 1 { continueReading(includingLatest: false) }
                        }
                    }
                }
            }
        }
        .background(Theme.ink.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: settings.sessionGeneration) { await load() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - Garage

    @ViewBuilder
    private func garage(columns: Int, withHeader: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if withHeader { header }
            switch vehicles {
            case .loading:
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(40)
            case .failed(let message):
                StatusView(systemImage: "wifi.exclamationmark", title: "Couldn't load vehicles",
                           message: message) { Task { await load() } }
                    .colorScheme(.dark)
            case .loaded(let vehicles):
                sectionTitle("Garage")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                    ForEach(vehicles) { vehicle in
                        Button { navigator.vehicle = vehicle } label: {
                            VehicleCard(vehicle: vehicle,
                                        recent: navigator.recents.filter { $0.vehicle == vehicle }.count)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            WorkbookMark().frame(width: 34, height: 34).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("WORKBOOK")
                    .font(.system(.headline, design: .monospaced))
                    .tracking(5)
                    .foregroundStyle(.white)
                Text("Service reference").font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .monospaced))
            .tracking(3)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
    }

    // MARK: - Continue

    @ViewBuilder
    private func continueReading(includingLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(includingLatest ? "Continue" : "Earlier")
            if let latest = navigator.recents.first {
                if includingLatest {
                    Button { open(latest) } label: { LatestCard(recent: latest) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
                ForEach(navigator.recents.dropFirst()) { recent in
                    Button { open(recent) } label: { RecentRow(recent: recent) }
                        .buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.07)).padding(.leading, 18)
                }
            } else {
                Text("Documents you open show up here, so you can get straight back to them.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 28)
    }

    private func open(_ recent: Navigator.Recent) {
        navigator.vehicle = recent.vehicle
        navigator.open(recent.document)
    }

    private func load() async {
        do { vehicles = .loaded(try await API(settings: settings).vehicles()) }
        catch APIError.notSignedIn { vehicles = .loading }
        catch { vehicles = .failed(error.localizedDescription) }
    }
}

/// A car in the garage: its picture large enough to pick out, then its name.
private struct VehicleCard: View {
    @Environment(AppSettings.self) private var settings
    let vehicle: Vehicle
    /// How many recent documents are from this car.
    let recent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(path: API(settings: settings).vehicleImagePath(vehicle))
                .frame(maxWidth: .infinity)
                .frame(height: 66)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(vehicle.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                Text("\(vehicle.vehicle) · \(String(vehicle.year))")
                    .font(.system(.caption, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.brass)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(Theme.ink2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            if recent > 0 {
                Text("\(recent) recent")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// The document you were last in, made the obvious thing to tap.
private struct LatestCard: View {
    @Environment(AppSettings.self) private var settings
    let recent: Navigator.Recent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LAST OPENED")
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.ink.opacity(0.6))
                Text(recent.document.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if !recent.document.code.isEmpty {
                        Text(recent.document.code).font(.system(.footnote, design: .monospaced))
                    }
                    Text(recent.vehicle.name).font(.footnote)
                }
                .foregroundStyle(Theme.ink.opacity(0.7))
            }
            Spacer(minLength: 0)
            RemoteImage(path: API(settings: settings).vehicleImagePath(recent.vehicle))
                .frame(width: 84, height: 46)
            Image(systemName: "arrow.right").font(.headline).foregroundStyle(Theme.ink)
        }
        .padding(16)
        .background(Theme.brass, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct RecentRow: View {
    let recent: Navigator.Recent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TypeBadge(type: recent.document.documentType)
            VStack(alignment: .leading, spacing: 3) {
                Text(recent.document.title).font(.subheadline).foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if !recent.document.code.isEmpty {
                        Text(recent.document.code)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.brass)
                    }
                    Text(recent.vehicle.name).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// The Workbook mark: a bound service workbook with a brass bookmark ribbon.
struct WorkbookMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 40
            let book = Path(roundedRect: CGRect(x: 9 * s, y: 5 * s, width: 22 * s, height: 30 * s), cornerRadius: 2.5 * s)
            context.fill(book, with: .foreground)
            var ribbon = Path()
            ribbon.move(to: CGPoint(x: 21 * s, y: 5 * s))
            ribbon.addLine(to: CGPoint(x: 26 * s, y: 5 * s))
            ribbon.addLine(to: CGPoint(x: 26 * s, y: 18 * s))
            ribbon.addLine(to: CGPoint(x: 23.5 * s, y: 15.5 * s))
            ribbon.addLine(to: CGPoint(x: 21 * s, y: 18 * s))
            ribbon.closeSubpath()
            context.fill(ribbon, with: .color(Theme.brass))
        }
    }
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("The Workbook server address. Change it only for a development server.")
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        settings.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let trimmed = server.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, trimmed != settings.serverURL {
                            settings.serverURL = trimmed
                            settings.sessionGeneration += 1
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { server = settings.serverURL }
        }
    }
}
