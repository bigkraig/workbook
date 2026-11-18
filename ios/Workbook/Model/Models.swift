import Foundation

struct Vehicle: Codable, Hashable, Identifiable {
    let year: Int
    let vehicle: String
    let name: String
    var id: String { "\(year)/\(vehicle)" }
}

struct TreeNode: Codable, Hashable, Identifiable {
    let nodeId: Int
    let nodeValue: String
    let name: String?
    let illustrationId: Int?
    let isFolder: Bool?
    let totalChildren: Int?
    let parentNodeId: Int?
    let children: [TreeNode]?
    var id: Int { nodeId }
    var title: String { name ?? nodeValue }
    var hasChildren: Bool { (totalChildren ?? 0) > 0 }

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id", nodeValue = "node_value", name
        case illustrationId = "illustration_id", isFolder = "is_folder"
        case totalChildren = "total_children", parentNodeId = "parent_node_id", children
    }
}

/// A row in a document list (tree node, vehicle list, search, tool references).
struct DocumentSummary: Codable, Hashable, Identifiable {
    let hkapId: String
    let title: String
    let documentType: String
    let fileFormat: String
    let vehicleComponent: String?
    let componentIndex: String?
    var id: String { hkapId }
    var isPDF: Bool { fileFormat.lowercased() == "pdf" }
    /// The component / labor-operation number shown next to the title.
    var code: String { componentIndex ?? vehicleComponent ?? "" }

    enum CodingKeys: String, CodingKey {
        case hkapId = "hkap_id", title
        case documentType = "document_type", fileFormat = "file_format"
        case vehicleComponent = "vehicle_component"
        case componentIndex = "vehicle_component_with_document_index"
    }
}

struct ToolData: Codable {
    let title: String
    let toolNumberPag: String
    let toolNumberVw: String?
    let toolType: String
    let dealerClassification: String
    let description: String
    let state: String
    let distributors: [Distributor]?
    let referencingDocuments: [DocumentSummary]?

    struct Distributor: Codable, Hashable {
        let name: String
        let partNumber: String
        let city: String?
        let phone: String?
        let email: String?
        let web: String?
        enum CodingKeys: String, CodingKey {
            case name, partNumber = "part_number", city, phone, email, web
        }
    }

    enum CodingKeys: String, CodingKey {
        case title, toolNumberPag = "tool_number_pag", toolNumberVw = "tool_number_vw"
        case toolType = "tool_type", dealerClassification = "dealer_classification"
        case description, state, distributors
        case referencingDocuments = "referencing_documents"
    }
}

/// A tool listed at the top of a document.
struct DocumentTool: Hashable, Identifiable {
    let id: String
    let label: String
    let number: String
    let displayNumber: String
}

struct TechValue: Hashable, Identifiable {
    let id: String
    let usageLocation: String
    let description: String
    let kind: String
    let baseValue: String
    let tolerance1: [String]
    let tolerance2: [String]
}

struct TocEntry: Hashable {
    let label: String
    let anchor: String
}

/// A fully loaded document: metadata plus either a content tree (XML
/// documents) or a media id (PDFs).
struct WorkshopDocument {
    let hkapId: String
    let title: String
    let documentType: String
    let code: String
    let isPDF: Bool
    let mediaFileId: String?
    let content: [ContentNode]
    let toc: [TocEntry]
    let tools: [DocumentTool]
    let techValues: [TechValue]

    init(json: [String: Any]) {
        let p = (json["payload"] as? [String: Any]) ?? json
        hkapId = Self.string(p["hkapId"])
        title = Self.string(p["title"])
        documentType = Self.string(p["documentType"])
        code = Self.string(p["vehicleComponentWithDocumentIndex"]).isEmpty
            ? Self.string(p["kdnr"]) : Self.string(p["vehicleComponentWithDocumentIndex"])
        isPDF = Self.string(p["fileFormat"]).lowercased() == "pdf"
        mediaFileId = p["mediaCloudFileId"] as? String
        content = ContentNode.parseChildren(p["content"])
        toc = (p["toc"] as? [[String: Any]] ?? []).map {
            TocEntry(label: Self.string($0["label"]), anchor: Self.string($0["anchor"]))
        }
        tools = (p["tools"] as? [[String: Any]] ?? []).map {
            DocumentTool(id: Self.string($0["id"]), label: Self.string($0["label"]),
                         number: Self.string($0["toolNumber"]),
                         displayNumber: Self.string($0["toolDisplayNumber"]))
        }
        techValues = (p["techvalues"] as? [[String: Any]] ?? []).enumerated().map { index, v in
            TechValue(id: (v["id"] as? String) ?? "tv\(index)",
                      usageLocation: Self.string(v["usageLocation"]),
                      description: Self.string(v["description"]),
                      kind: Self.string(v["kind"]),
                      baseValue: Self.string(v["baseValue"]),
                      tolerance1: v["tolerance1"] as? [String] ?? [],
                      tolerance2: v["tolerance2"] as? [String] ?? [])
        }
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}
