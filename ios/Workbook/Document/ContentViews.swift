import SwiftUI

/// What rendered content can ask its document screen to do.
struct DocumentActions {
    var translations: [String: String] = [:]
    var openAnchor: (String) -> Void = { _ in }
    var openNested: (NestedRef) -> Void = { _ in }
    var openFigure: (Figure) -> Void = { _ in }
    /// Larger type for the workbench, read from arm's length.
    var scale: CGFloat = 1
}

extension EnvironmentValues {
    @Entry var documentActions = DocumentActions()
    /// Figures shown on the other half of the screen while their block is being
    /// read; the text half leaves their picture out rather than show it twice.
    @Entry var figuresShownAlongside: Set<String> = []
}

/// Renders a run of content nodes: consecutive text fragments flow together
/// as one paragraph, everything else stacks as blocks.
struct ContentView: View {
    @Environment(\.documentActions) private var actions
    let nodes: [ContentNode]

    private enum Piece {
        case text(AttributedString)
        case block(ContentNode)
    }

    private var pieces: [Piece] {
        var pieces: [Piece] = []
        var run = AttributedString()
        func flush() {
            let trimmed = String(run.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(.text(run)) }
            run = AttributedString()
        }
        func appendInline(_ text: AttributedString) {
            if !run.characters.isEmpty, !text.characters.isEmpty { run.append(AttributedString(" ")) }
            run.append(text)
        }
        for node in nodes {
            switch node {
            case .text(let string):
                appendInline(InlineHTML.attributed(string))
            case .html(let html, let para, let ids):
                if InlineHTML.heading(html) != nil {
                    flush()
                    pieces.append(.block(node))
                } else {
                    if para { flush() }
                    appendInline(InlineHTML.attributed(translate(html, ids)))
                    if para { flush() }
                }
            case .anchor, .unknown:
                break
            default:
                flush()
                pieces.append(.block(node))
            }
        }
        flush()
        return pieces
    }

    private func translate(_ html: String, _ ids: [String]) -> String {
        ids.reduce(html) { $0.replacingOccurrences(of: "$\($1)$", with: actions.translations[$1] ?? $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * actions.scale) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let text):
                    Text(text)
                        .font(.system(size: 16 * actions.scale))
                        .foregroundStyle(Theme.text)
                        .tint(Theme.link)
                        .fixedSize(horizontal: false, vertical: true)
                case .block(let node):
                    BlockView(node: node)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    @Environment(\.documentActions) private var actions
    let node: ContentNode

    var body: some View {
        switch node {
        case .html(let html, _, _):
            if let heading = InlineHTML.heading(html) { HeadingView(heading: heading) }
        case .plot(let items):
            VStack(alignment: .leading, spacing: 12 * actions.scale) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.position)
                            .font(.system(size: 15 * actions.scale, weight: .bold))
                            .foregroundStyle(Theme.text)
                        ContentView(nodes: item.children)
                    }
                }
            }
        case .paragraph(let children), .mixed(let children):
            ContentView(nodes: children)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6 * actions.scale) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.muted)
                        ContentView(nodes: item)
                    }
                }
            }
        case .nested(let ref):
            NestedLink(ref: ref)
        case .link(let html, let children):
            LinkView(html: html, children: children)
        case .image(let figure):
            FigureBlock(figure: figure)
        case .table(let table):
            TableBlock(table: table)
        case .warning(let warning):
            WarningBlock(warning: warning)
        case .section(let title, let key, let children):
            VStack(alignment: .leading, spacing: 4) {
                if let label = key.flatMap({ actions.translations[$0] }) ?? title {
                    Text(label).font(.system(size: 14 * actions.scale, weight: .bold)).foregroundStyle(Theme.muted)
                }
                ContentView(nodes: children)
            }
        case .text, .anchor, .unknown:
            EmptyView()
        }
    }
}

private struct HeadingView: View {
    @Environment(\.documentActions) private var actions
    let heading: InlineHTML.Heading

    var body: some View {
        Text(heading.text)
            .font(.system(size: (heading.level <= 2 ? 21 : 18) * actions.scale, weight: .bold))
            .foregroundStyle(heading.level <= 2 ? Theme.muted : Theme.text)
            .padding(.top, heading.level <= 2 ? 14 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A cross-reference to another document ("5X00IN05 Information on aluminium repairs").
private struct NestedLink: View {
    @Environment(\.documentActions) private var actions
    let ref: NestedRef

    var body: some View {
        Button { actions.openNested(ref) } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 20 * actions.scale))
                    .foregroundStyle(Theme.ink)
                Text("\(ref.aposNumber) \(ref.title)")
                    .font(.system(size: 14 * actions.scale, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tool / technical value / part reference, or a jump within the document.
private struct LinkView: View {
    @Environment(\.documentActions) private var actions
    let html: String
    let children: [ContentNode]
    @State private var expanded = false

    var body: some View {
        let anchor = InlineHTML.anchor(html)
        let isValue = anchor?.classes.contains("qv-techvalue") ?? false
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isValue, !children.isEmpty {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } else if let target = anchor?.target, !target.isEmpty {
                    actions.openAnchor(target)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(for: anchor?.classes ?? ""))
                        .font(.system(size: 13 * actions.scale, weight: .semibold))
                        .foregroundStyle(Theme.link)
                    Text(anchor?.text ?? InlineHTML.plain(html))
                        .font(.system(size: 16 * actions.scale, weight: isValue ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                }
                .frame(minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { ContentView(nodes: children) }
        }
    }

    private func icon(for classes: String) -> String {
        if classes.contains("qv-tool") { return "wrench.and.screwdriver" }
        if classes.contains("qv-techvalue") { return "gauge.with.dots.needle.50percent" }
        if classes.contains("qv-ersatzteil") { return "shippingbox" }
        return "chevron.right"
    }
}

/// An illustration in the flow of the document. Tap for the full-screen,
/// zoomable version.
private struct FigureBlock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.documentActions) private var actions
    @Environment(\.figuresShownAlongside) private var alongside
    let figure: Figure

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !alongside.contains(figure.id) || figure.inTable {
            Button { actions.openFigure(figure) } label: {
                RemoteImage(path: API(settings: settings).figurePath(figure.key))
                    .frame(maxWidth: figure.inTable ? 200 : .infinity)
                    .padding(8)
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Theme.line))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
            }
            if !figure.title.isEmpty {
                Text(figure.title).font(.system(size: 13 * actions.scale)).foregroundStyle(Theme.muted)
            }
            if !figure.legend.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(figure.legend.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            ContentView(nodes: entry.label).frame(width: 34 * actions.scale, alignment: .leading)
                            ContentView(nodes: entry.content)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct TableBlock: View {
    @Environment(\.documentActions) private var actions
    let table: TableData
    /// Width the table has to work with, measured from the title/placeholder row.
    @State private var available: CGFloat = 320

    /// Each column's width. Cells need a definite width: inside a horizontal
    /// scroll view an unconstrained Text measures as one long line, and the
    /// row then clips it when it wraps.
    ///
    /// The table is fitted to the width it has whenever every column can keep
    /// its longest word (or its whole text, for short cells like "25 Nm") on
    /// one line; columns with more to say get the room that's left. Only a
    /// table too wide for that gets fixed columns and scrolls sideways.
    private var layout: (widths: [CGFloat], shrink: CGFloat) {
        let header = table.header.count
        let rows = table.header + table.rows
        let count = max(1, rows.map { $0.reduce(0) { $0 + $1.columns } }.max() ?? 1)
        var minimum = [CGFloat](repeating: 44, count: count)
        var weight = [CGFloat](repeating: 1, count: count)
        let glyph = 7.2 * actions.scale       // average glyph of the body face
        for (index, row) in rows.enumerated() {
            var column = 0
            for cell in row {
                defer { column += cell.columns }
                guard cell.columns == 1, column < count else { continue }
                let text = cell.nodes.map(Self.plain).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let longestWord = text.split(whereSeparator: \.isWhitespace).map(\.count).max() ?? 0
                let unbroken = text.count <= 8 ? text.count : min(longestWord, 16)
                // Short values ("25 Nm", "Class") are sized generously: digits and
                // capitals run wider than the average glyph.
                let width = (text.count <= 8 ? glyph * 1.25 : glyph) * (index < header ? 1.12 : 1)   // headers are bold
                minimum[column] = max(minimum[column], CGFloat(unbroken) * width + 14)
                weight[column] = max(weight[column], CGFloat(min(text.count, 60)))
            }
        }
        let needed = minimum.reduce(0, +)
        let spare = available - 2 - needed
        guard spare >= 0 else {
            // A little too wide: set the table slightly smaller rather than make
            // the reader scroll sideways for the last column. Much too wide: scroll.
            let shrink = (available - 2) / needed
            if shrink >= 0.86 { return (minimum.map { $0 * shrink }, shrink) }
            return (minimum.map { max($0, 132) }, 1)
        }
        // Share what's left among the columns that would otherwise wrap.
        let hungry = zip(weight, minimum).map { max(0, $0 * glyph + 14 - $1) }
        let appetite = hungry.reduce(0, +)
        guard appetite > 0 else { return (minimum, 1) }
        return (zip(minimum, hungry).map { $0 + min($1, spare * $1 / appetite) }, 1)
    }

    private func shrunk(by factor: CGFloat) -> DocumentActions {
        var copy = actions
        copy.scale *= factor
        return copy
    }

    private static func plain(_ node: ContentNode) -> String {
        switch node {
        case .text(let text): return text
        case .html(let html, _, _): return InlineHTML.plain(html)
        case .paragraph(let children), .mixed(let children): return children.map(plain).joined(separator: " ")
        default: return "            "       // a figure or nested block: give it some room
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = table.title, !title.isEmpty {
                Text(title).font(.system(size: 16 * actions.scale, weight: .bold)).foregroundStyle(Theme.text)
            }
            if let value = table.value {
                TechValueCard(value: value)
                if !table.images.isEmpty { ContentView(nodes: table.images) }
            } else if !table.rows.isEmpty || !table.header.isEmpty {
                Color.clear.frame(height: 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
                ScrollView(.horizontal, showsIndicators: false) {
                    let layout = layout
                    let widths = layout.widths
                    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { _, row in
                            gridRow(row, header: true, widths: widths)
                        }
                        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                            Divider().overlay(Theme.line)
                            gridRow(row, header: false, widths: widths)
                        }
                    }
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Theme.line))
                    .environment(\.documentActions, shrunk(by: layout.shrink))
                }
            }
        }
    }

    private func gridRow(_ row: [TableData.Cell], header: Bool, widths: [CGFloat]) -> some View {
        // Where each cell starts, so a spanning cell gets its columns' widths.
        let starts = row.reduce(into: [0]) { $0.append($0.last! + $1.columns) }
        return GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                let span = widths.dropFirst(starts[index]).prefix(cell.columns).reduce(0, +)
                ContentView(nodes: cell.nodes)
                    .fontWeight(header ? .bold : .regular)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .frame(width: max(span, 40), alignment: .leading)
                    .gridCellColumns(cell.columns)
            }
        }
        .background(header ? Theme.paper : Color.white)
    }
}

/// One technical value (a torque, a gap, a fill quantity).
struct TechValueCard: View {
    let value: TechValue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value.usageLocation.isEmpty ? value.kind : value.usageLocation)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                let detail = [value.description, value.usageLocation.isEmpty ? "" : value.kind]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value.baseValue)
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.text)
                let tolerance = (value.tolerance1 + value.tolerance2).joined(separator: "  ")
                if !tolerance.isEmpty {
                    Text(tolerance).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.brass).frame(width: 3) }
    }
}

private struct WarningBlock: View {
    @Environment(\.documentActions) private var actions
    let warning: WarningData

    private var style: (label: String, color: Color, icon: String, dark: Bool) {
        switch warning.category {
        case "0Hinweis": return ("NOTICE", Color(red: 0.69, green: 0.69, blue: 0.70), "info.circle", true)
        case "1Vorsicht": return ("CAUTION", Color(red: 1, green: 0.82, blue: 0.2), "exclamationmark.triangle.fill", true)
        case "2Warnung": return ("WARNING", Color(red: 0.96, green: 0.55, blue: 0.1), "exclamationmark.triangle.fill", true)
        case "environment": return ("ENVIRONMENT", Color(red: 0.42, green: 0.72, blue: 0.47), "leaf.fill", true)
        case "3Gefahr": return ("DANGER", Color(red: 0.84, green: 0, blue: 0.11), "exclamationmark.triangle.fill", false)
        default: return ("INFORMATION", Color(red: 0.69, green: 0.69, blue: 0.70), "info.circle", true)
        }
    }

    var body: some View {
        let style = style
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: style.icon)
                Text(style.label).font(.system(size: 14 * actions.scale, weight: .heavy)).tracking(1)
            }
            .foregroundStyle(style.dark ? Theme.ink : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.color)

            VStack(alignment: .leading, spacing: 8) {
                if !warning.children.isEmpty { ContentView(nodes: warning.children) }
                if let source = warning.source, !source.isEmpty {
                    Text(source).font(.system(size: 16 * actions.scale, weight: .bold)).foregroundStyle(Theme.text)
                }
                ForEach(Array(warning.consequences.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.muted)
                        ContentView(nodes: item)
                    }
                }
                ForEach(Array(warning.actions.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.text)
                        ContentView(nodes: item)
                    }
                }
            }
            .padding(12)
        }
        .background(Color.white)
        .overlay(Rectangle().stroke(style.color, lineWidth: 2))
    }
}
