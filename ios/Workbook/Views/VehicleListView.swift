import SwiftUI

/// The start screen: pick a vehicle, or jump back into a recent document.
struct VehicleListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    @State private var vehicles: Loadable<[Vehicle]> = .loading
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch vehicles {
                case .loading:
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(40)
                case .failed(let message):
                    StatusView(systemImage: "wifi.exclamationmark", title: "Couldn't load vehicles",
                               message: message) { Task { await load() } }
                        .colorScheme(.dark)
                case .loaded(let vehicles):
                    ForEach(vehicles) { vehicle in
                        Button { navigator.vehicle = vehicle } label: { VehicleRow(vehicle: vehicle) }
                            .buttonStyle(.plain)
                    }
                    if !navigator.recents.isEmpty { recents }
                }
            }
        }
        .background(Theme.ink.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: settings.sessionGeneration) { await load() }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.system(.caption, design: .monospaced))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 18)
                .padding(.top, 26)
                .padding(.bottom, 8)
            ForEach(navigator.recents) { recent in
                Button {
                    navigator.vehicle = recent.vehicle
                    navigator.open(recent.document)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TypeBadge(type: recent.document.documentType)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recent.document.title).font(.subheadline).foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Text(recent.vehicle.name).font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        do { vehicles = .loaded(try await API(settings: settings).vehicles()) }
        catch APIError.notSignedIn { vehicles = .loading }
        catch { vehicles = .failed(error.localizedDescription) }
    }
}

struct VehicleRow: View {
    @Environment(AppSettings.self) private var settings
    let vehicle: Vehicle

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(path: API(settings: settings).vehicleImagePath(vehicle))
                .frame(width: 84, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.name).font(.headline).foregroundStyle(.white)
                Text("\(vehicle.vehicle) · \(String(vehicle.year))")
                    .font(.system(.caption, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.brass)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
