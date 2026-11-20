import Foundation
import Observation

/// What the detail side shows: a document, or a tool reached from one.
enum DetailRoute: Hashable {
    case document(DocumentSummary)
    case tool(String)
}

/// One stack entry in the single-column (cover screen / phone) layout.
enum Route: Hashable {
    case node(TreeNode)
    case detail(DetailRoute)
}

/// Navigation state shared by every layout, so folding and unfolding the
/// phone rearranges the same place instead of starting over: the cover screen
/// pushes documents onto one stack; the inner screen shows `nodes` on one side
/// of the crease and `detail` on the other; half-folded, the open document
/// becomes the workbench.
@Observable
final class Navigator {
    var vehicle: Vehicle? {
        didSet {
            guard vehicle != oldValue else { return }
            nodes = []
            detail = []
            models = [:]
            if let vehicle, let data = try? JSONEncoder().encode(vehicle) {
                UserDefaults.standard.set(data, forKey: Keys.vehicle)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.vehicle)
            }
        }
    }
    /// Component-tree folders drilled into.
    var nodes: [TreeNode] = []
    /// The open document first, then anything opened from it.
    var detail: [DetailRoute] = []
    /// Inner screen: hide the browser and give the document both halves.
    var focused = false
    var recents: [Recent] = []
    /// Search text a deep link asked for; the vehicle's root browser picks it up.
    var pendingSearch: String?
    /// A deep link that arrived before sign-in (or before the vehicle list
    /// could be loaded); retried when the session changes.
    var pendingLink: URL?
    /// UI strings the server's documents refer to by key (`$LblFrom$`).
    var translations: [String: String] = [:]

    private var models: [String: DocumentModel] = [:]

    struct Recent: Codable, Hashable, Identifiable {
        let vehicle: Vehicle
        let document: DocumentSummary
        var id: String { vehicle.id + "/" + document.hkapId }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.vehicle) {
            vehicle = try? JSONDecoder().decode(Vehicle.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: Keys.recents) {
            recents = (try? JSONDecoder().decode([Recent].self, from: data)) ?? []
        }
        #if DEBUG
        // `-workbook.debug.vehicle 981810:2016:Cayman GT4`
        if let parts = UserDefaults.standard.string(forKey: "workbook.debug.vehicle")?.split(separator: ":"),
           parts.count == 3, let year = Int(parts[1]) {
            vehicle = Vehicle(year: year, vehicle: String(parts[0]), name: String(parts[2]))
        }
        if let hkap = DebugOptions.open {
            let document = DocumentSummary(hkapId: hkap, title: "Document \(hkap)", documentType: "RM",
                                           fileFormat: "xml", vehicleComponent: nil, componentIndex: nil)
            detail = [.document(document)]
            focused = DebugOptions.focused
            model(for: document).currentStep = DebugOptions.step
        }
        #endif
    }

    /// The single-column path: folders, then the detail stack.
    var path: [Route] {
        get { nodes.map(Route.node) + detail.map(Route.detail) }
        set {
            nodes = newValue.compactMap { if case .node(let node) = $0 { return node } else { return nil } }
            detail = newValue.compactMap { if case .detail(let route) = $0 { return route } else { return nil } }
        }
    }

    /// The document the detail side is rooted at.
    var openDocument: DocumentSummary? {
        if case .document(let document)? = detail.first { return document }
        return nil
    }

    /// The document on top of the detail stack (what the workbench shows).
    var topDocument: DocumentSummary? {
        if case .document(let document)? = detail.last { return document }
        return nil
    }

    /// Open a document from a list: replaces whatever the detail side showed.
    func open(_ document: DocumentSummary) {
        detail = [.document(document)]
        // Once something is open, reading it is the point: give it the whole
        // inner screen. The browser is one tap away in the document's toolbar.
        focused = true
        remember(document)
    }

    /// Follow a cross-reference or tool link from inside a document.
    func push(_ route: DetailRoute) {
        detail.append(route)
        if case .document(let document) = route { remember(document) }
    }

    func closeDetail() {
        detail = []
        focused = false
    }

    /// Loaded document + reading position, kept while the vehicle is selected
    /// so every posture shows the same step.
    func model(for document: DocumentSummary) -> DocumentModel {
        if let model = models[document.hkapId] { return model }
        let model = DocumentModel(summary: document)
        models[document.hkapId] = model
        return model
    }

    /// Open a `workbook://` deep link (from Carnet or anywhere else):
    ///
    ///     workbook://vehicle/2016/981810
    ///     workbook://vehicle/2016/981810/document/75104700
    ///     workbook://vehicle/2016/981810/tool/VAS%206910
    ///     workbook://vehicle/2016/981810/search?q=brake%20fluid
    ///
    /// `workbook://session` is the sign-in callback, not a link.
    @MainActor
    func open(link url: URL, api: API) async {
        guard url.scheme == "workbook", url.host() == "vehicle" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, let year = Int(parts[0]) else { return }
        do {
            guard let match = try await api.vehicles().first(where: { $0.year == year && $0.vehicle == parts[1] }) else {
                pendingLink = nil
                return
            }
            pendingLink = nil
            vehicle = match
            // Same vehicle as before keeps its stacks (didSet only clears on change).
            nodes = []
            detail = []
            focused = false
            guard parts.count >= 3 else { return }
            switch parts[2] {
            case "document" where parts.count >= 4:
                open(DocumentSummary(hkapId: parts[3], title: "", documentType: "", fileFormat: "xml",
                                     vehicleComponent: nil, componentIndex: nil))
            case "tool" where parts.count >= 4:
                detail = [.tool(parts[3])]
            case "search":
                pendingSearch = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "q" })?.value
            default:
                break
            }
        } catch {
            // Not signed in yet, or offline: keep it for after sign-in.
            pendingLink = url
        }
    }

    /// Record a document in Recents once its real title is known (documents
    /// opened by deep link start without one).
    func loaded(_ document: WorkshopDocument) {
        remember(DocumentSummary(hkapId: document.hkapId, title: document.title,
                                 documentType: document.documentType,
                                 fileFormat: document.isPDF ? "pdf" : "xml",
                                 vehicleComponent: nil, componentIndex: document.code))
    }

    private func remember(_ document: DocumentSummary) {
        guard let vehicle, !document.title.isEmpty else { return }
        let entry = Recent(vehicle: vehicle, document: document)
        recents.removeAll { $0.id == entry.id }
        recents.insert(entry, at: 0)
        recents = Array(recents.prefix(12))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Keys.recents)
        }
    }

    private enum Keys {
        static let vehicle = "workbook.vehicle"
        static let recents = "workbook.recents"
    }
}
