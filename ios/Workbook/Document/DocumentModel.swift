import Foundation
import Observation

/// One unit of work in a document: a numbered step, or a block between steps
/// (a warning, a note, a figure). The workbench shows these one at a time.
struct WorkStep: Identifiable {
    let id: Int
    /// The heading this step sits under.
    let section: String
    /// "1", "2"… for numbered steps; nil for notes and warnings.
    let position: String?
    let nodes: [ContentNode]
    /// The illustration to show beside this step: its own, or the most recent
    /// one in the same section.
    let figure: Figure?
    /// Index of the top-level content node this step came from.
    let blockIndex: Int
}

/// A loaded document plus the reader's place in it. One instance per document
/// (held by Navigator), shared by the reading view and the workbench so the
/// position survives folding.
@Observable
final class DocumentModel {
    let summary: DocumentSummary
    var state: Loadable<WorkshopDocument> = .loading
    private(set) var steps: [WorkStep] = []
    /// Anchor id (headings, steps, technical values) → top-level block index.
    private(set) var anchors: [String: Int] = [:]
    /// Per top-level block: the figure to pin beside it.
    private(set) var blockFigures: [Figure?] = []
    var currentStep = 0
    /// Top-level block at the top of the reading view.
    var topBlock: Int? = 0
    var pdfData: Data?
    var pdfPage = 0
    var pdfPageCount = 0

    init(summary: DocumentSummary) {
        self.summary = summary
    }

    @MainActor
    func load(api: API) async {
        if case .loaded = state { return }
        state = .loading
        do {
            let document = try await api.document(summary.hkapId)
            if document.isPDF, let media = document.mediaFileId {
                pdfData = try await MediaStore.shared.load(api.mediaPath(media), api: api).data
            }
            index(document)
            state = .loaded(document)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The step containing a top-level block (for handing the reading position
    /// to the workbench).
    func step(forBlock block: Int) -> Int {
        steps.lastIndex { $0.blockIndex <= block } ?? 0
    }

    private func index(_ document: WorkshopDocument) {
        var steps: [WorkStep] = []
        var anchors: [String: Int] = [:]
        var figures: [Figure?] = []
        var section = document.title
        var lastFigure: Figure?

        for (block, node) in document.content.enumerated() {
            for id in Self.anchorIDs(in: node) where anchors[id] == nil { anchors[id] = block }

            switch node {
            case .anchor:
                break
            case .html(let html, _, _) where InlineHTML.heading(html) != nil:
                section = InlineHTML.heading(html)?.text ?? section
                lastFigure = nil
            case .plot(let items):
                for item in items {
                    let own = item.children.flatMap(\.figures).first
                    lastFigure = own ?? lastFigure
                    steps.append(WorkStep(id: steps.count, section: section, position: item.position,
                                          nodes: item.children, figure: lastFigure, blockIndex: block))
                }
            default:
                guard !Self.isBlank(node) else { break }
                let own = node.figures.first
                lastFigure = own ?? lastFigure
                steps.append(WorkStep(id: steps.count, section: section, position: nil,
                                      nodes: [node], figure: lastFigure, blockIndex: block))
            }
            figures.append(lastFigure)
        }
        // A block before its section's first figure pins that upcoming figure
        // rather than nothing.
        var upcoming: Figure?
        for block in figures.indices.reversed() {
            if case .html(let html, _, _) = document.content[block], InlineHTML.heading(html) != nil {
                figures[block] = figures[block] ?? upcoming
                upcoming = nil
                continue
            }
            if let figure = figures[block] { upcoming = figure } else { figures[block] = upcoming }
        }
        // Sections with no figure of their own (tools lists, safety notes) pin
        // the nearest one in the document — next first, then previous — so the
        // figure pane is only empty when the document has no figures at all.
        var next: Figure?
        for block in figures.indices.reversed() {
            if let figure = figures[block] { next = figure } else { figures[block] = next }
        }
        var previous: Figure?
        for block in figures.indices {
            if let figure = figures[block] { previous = figure } else { figures[block] = previous }
        }
        self.steps = steps
        self.anchors = anchors
        self.blockFigures = figures
        currentStep = min(currentStep, max(0, steps.count - 1))
    }

    private static func isBlank(_ node: ContentNode) -> Bool {
        switch node {
        case .text(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .html(let html, _, _): return InlineHTML.plain(html).trimmingCharacters(in: .whitespaces).isEmpty
        case .anchor: return true
        default: return false
        }
    }

    private static func anchorIDs(in node: ContentNode) -> [String] {
        switch node {
        case .anchor(let id): return [id]
        case .html(let html, _, _): return InlineHTML.heading(html)?.id.map { [$0] } ?? []
        case .plot(let items):
            return items.flatMap { ($0.id.map { [$0] } ?? []) + $0.children.flatMap(anchorIDs) }
        case .paragraph(let c), .mixed(let c), .section(_, _, let c): return c.flatMap(anchorIDs)
        case .list(let items): return items.flatMap { $0.flatMap(anchorIDs) }
        case .link(_, let c): return c.flatMap(anchorIDs)
        case .table(let t): return (t.value.map { [$0.id] } ?? []) + t.images.flatMap(anchorIDs)
        case .image(let figure): return [figure.id]
        case .warning(let w): return w.children.flatMap(anchorIDs)
        default: return []
        }
    }
}
