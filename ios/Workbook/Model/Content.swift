import Foundation

/// The API's document body: a tree of typed nodes (`{"type": …, "inputs": …}`)
/// mixed with bare strings. Mirrors the web app's WorkshopChildren components.
indirect enum ContentNode {
    case text(String)
    case html(String, para: Bool, translateIds: [String])
    case anchor(String)
    case plot([PlotItem])
    case paragraph([ContentNode])
    case mixed([ContentNode])
    case list([[ContentNode]])
    case nested(NestedRef)
    case link(html: String, children: [ContentNode])
    case image(Figure)
    case table(TableData)
    case warning(WarningData)
    case section(title: String?, titleKey: String?, children: [ContentNode])
    case unknown(String)
}

struct PlotItem {
    let position: String
    let id: String?
    let children: [ContentNode]
}

/// A cross-reference to another document, resolved by labor-operation number.
struct NestedRef: Hashable {
    let aposNumber: String
    let documentType: String
    let title: String
}

struct Figure: Identifiable {
    let id: String
    let key: String
    let title: String
    let inTable: Bool
    let legend: [(label: [ContentNode], content: [ContentNode])]
}

struct TableData {
    struct Cell {
        let nodes: [ContentNode]
        let columns: Int
    }
    let title: String?
    let header: [[Cell]]
    let rows: [[Cell]]
    /// Set for the "technical value" form of a table (a single spec, no grid).
    let value: TechValue?
    let images: [ContentNode]
}

struct WarningData {
    let category: String
    let source: String?
    let consequences: [[ContentNode]]
    let actions: [[ContentNode]]
    let children: [ContentNode]
}

extension ContentNode {
    /// Parse a `Children` value: a node, a bare string/number, or any nesting
    /// of arrays of those.
    static func parseChildren(_ value: Any?) -> [ContentNode] {
        switch value {
        case nil, is NSNull:
            return []
        case let string as String:
            return [.text(string)]
        case let number as NSNumber:
            return [.text(number.stringValue)]
        case let array as [Any]:
            return array.flatMap { parseChildren($0) }
        case let dict as [String: Any]:
            return [parseNode(dict)]
        default:
            return []
        }
    }

    private static func parseNode(_ dict: [String: Any]) -> ContentNode {
        let type = dict["type"] as? String ?? ""
        // `plot` carries its items directly as `inputs`; everything else has a dictionary.
        let inputs = dict["inputs"] as? [String: Any] ?? [:]
        func str(_ key: String) -> String { WorkshopDocument.string(inputs[key]) }

        switch type {
        case "static":
            return .html(str("html"), para: inputs["para"] as? Bool ?? false,
                         translateIds: inputs["translateIds"] as? [String] ?? [])
        case "anchor":
            return .anchor(str("id"))
        case "plot":
            let items = dict["inputs"] as? [[String: Any]] ?? []
            return .plot(items.map {
                PlotItem(position: WorkshopDocument.string($0["position"]),
                         id: $0["id"] as? String,
                         children: parseChildren($0["children"]))
            })
        case "paragraph":
            return .paragraph(parseChildren(inputs["children"]))
        case "mixed":
            return .mixed(parseChildren(inputs["children"]))
        case "list":
            let items = inputs["items"] as? [Any] ?? []
            return .list(items.map { parseChildren($0) })
        case "nested":
            return .nested(NestedRef(aposNumber: str("aposNumber"),
                                     documentType: str("documentType"),
                                     title: str("title")))
        case "link":
            return .link(html: str("html"), children: parseChildren(inputs["children"]))
        case "image":
            let legend = (inputs["legend"] as? [[Any]] ?? []).compactMap { pair -> (label: [ContentNode], content: [ContentNode])? in
                guard pair.count >= 2 else { return nil }
                return (parseChildren(pair[0]), parseChildren(pair[1]))
            }
            return .image(Figure(id: str("id").isEmpty ? UUID().uuidString : str("id"),
                                 key: str("key"), title: str("title"),
                                 inTable: inputs["inTable"] as? Bool ?? false,
                                 legend: legend))
        case "table":
            return .table(parseTable(inputs))
        case "warning":
            func lists(_ key: String) -> [[ContentNode]] {
                (inputs[key] as? [Any] ?? []).map { parseChildren($0) }
            }
            return .warning(WarningData(category: str("category"),
                                        source: inputs["source"] as? String,
                                        consequences: lists("consequences"),
                                        actions: lists("actions"),
                                        children: parseChildren(inputs["children"])))
        case "section":
            return .section(title: inputs["title"] as? String,
                            titleKey: inputs["titleUiText"] as? String,
                            children: parseChildren(inputs["children"]))
        default:
            return .unknown(type)
        }
    }

    private static func parseTable(_ inputs: [String: Any]) -> TableData {
        func cells(_ row: Any) -> [TableData.Cell] {
            (row as? [Any] ?? []).map { cell in
                // A spanning cell is `[node, colspan, rowspan]`.
                if let parts = cell as? [Any], parts.count == 3, let columns = parts[1] as? Int, parts[2] is Int {
                    return TableData.Cell(nodes: parseChildren(parts[0]), columns: max(1, columns))
                }
                return TableData.Cell(nodes: parseChildren(cell), columns: 1)
            }
        }
        let header = (inputs["header"] as? [Any] ?? []).map(cells)
        let rows = (inputs["data"] as? [Any] ?? []).map(cells)
        var value: TechValue?
        if rows.isEmpty, let base = inputs["baseValue"] as? String {
            value = TechValue(id: (inputs["id"] as? String) ?? UUID().uuidString,
                              usageLocation: WorkshopDocument.string(inputs["usageLocation"]),
                              description: WorkshopDocument.string(inputs["description"]),
                              kind: WorkshopDocument.string(inputs["kind"]),
                              baseValue: base,
                              tolerance1: inputs["tolerance1"] as? [String] ?? [],
                              tolerance2: inputs["tolerance2"] as? [String] ?? [])
        }
        return TableData(title: inputs["title"] as? String, header: header, rows: rows,
                         value: value, images: parseChildren(inputs["images"]))
    }

    /// Every figure in this subtree, in document order.
    var figures: [Figure] {
        switch self {
        case .image(let figure): return [figure]
        case .plot(let items): return items.flatMap { $0.children.flatMap(\.figures) }
        case .paragraph(let c), .mixed(let c), .section(_, _, let c): return c.flatMap(\.figures)
        case .list(let items): return items.flatMap { $0.flatMap(\.figures) }
        case .link(_, let c): return c.flatMap(\.figures)
        case .table(let t):
            return t.images.flatMap(\.figures)
                + (t.header + t.rows).flatMap { $0.flatMap { $0.nodes.flatMap(\.figures) } }
        case .warning(let w):
            return w.children.flatMap(\.figures) + w.actions.flatMap { $0.flatMap(\.figures) }
        default: return []
        }
    }
}
