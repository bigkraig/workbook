import SwiftUI
import PDFKit

/// How a document that has both halves of the inner screen should divide
/// itself: text up to `leading`, the pinned figure after `leading + gap`.
struct PageSplit: Equatable {
    var leading: CGFloat
    var gap: CGFloat
}

extension EnvironmentValues {
    @Entry var pageSplit: PageSplit? = nil
    /// True when this screen is the root of the inner screen's detail pane
    /// (so it offers Close and Focus instead of a back button).
    @Entry var isDetailRoot = false
}

/// Reads one document: native content for workshop documents, PDFKit for PDFs.
struct DocumentScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    @Environment(\.pageSplit) private var pageSplit
    @Environment(\.isDetailRoot) private var isDetailRoot
    let summary: DocumentSummary

    @State private var sheet: Sheet?
    @State private var viewer: Figure?
    @State private var workbench = false
    @State private var pendingReference: NestedRef?

    private enum Sheet: String, Identifiable {
        case tools, values
        var id: String { rawValue }
    }

    var body: some View {
        let model = navigator.model(for: summary)
        Group {
            switch model.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                StatusView(systemImage: "exclamationmark.triangle", title: "Couldn't open this document",
                           message: message) { Task { await model.load(api: API(settings: settings)) } }
            case .loaded(let document):
                if document.isPDF {
                    if let data = model.pdfData { PDFReader(data: data, model: model) }
                    else { StatusView(systemImage: "doc.richtext", title: "This PDF has no file attached") }
                } else {
                    reader(document, model)
                }
            }
        }
        .background(Theme.paper)
        .navigationTitle(model.state.value?.title ?? summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { toolbar(model) }
        .task(id: "\(summary.hkapId)#\(settings.sessionGeneration)") {
            await model.load(api: API(settings: settings))
            if let document = model.state.value { navigator.loaded(document) }
        }
        .sheet(item: $sheet) { sheet in
            if let document = model.state.value { referenceSheet(sheet, document) }
        }
        .fullScreenCover(item: $viewer) { FigureViewer(figure: $0) }
        .fullScreenCover(isPresented: $workbench) {
            WorkbenchView(summary: summary) { workbench = false }
        }
        .crossReferences($pendingReference)
    }

    // MARK: - Reading

    @ViewBuilder
    private func reader(_ document: WorkshopDocument, _ model: DocumentModel) -> some View {
        if let split = pageSplit {
            // Both halves of the inner screen: text on one side of the crease,
            // the figure for what you're reading pinned on the other.
            HStack(spacing: 0) {
                content(document, model).frame(width: split.leading)
                Color.clear.frame(width: max(split.gap, 1)).overlay(Theme.line)
                pinned(document, model)
            }
        } else {
            content(document, model)
        }
    }

    private func content(_ document: WorkshopDocument, _ model: DocumentModel) -> some View {
        @Bindable var model = model
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                titleBlock(document)
                ForEach(Array(document.content.enumerated()), id: \.offset) { index, node in
                    if case .anchor = node { EmptyView() } else {
                        ContentView(nodes: [node]).id(index)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollPosition(id: $model.topBlock, anchor: .top)
        .environment(\.documentActions, actions(document, model))
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "workbook" else { return .systemAction }
            open(anchor: String(url.path.dropFirst()), document, model)
            return .handled
        })
    }

    private func titleBlock(_ document: WorkshopDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TypeBadge(type: document.documentType)
                Text(document.code).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.brass)
            }
            Text(document.title).font(.title2.weight(.bold)).foregroundStyle(Theme.text)
            if !document.tools.isEmpty || !document.techValues.isEmpty {
                // Side by side when they fit, stacked in a narrow pane.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chips(document) }
                    VStack(alignment: .leading, spacing: 8) { chips(document) }
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func chips(_ document: WorkshopDocument) -> some View {
        if !document.tools.isEmpty {
            chip("Tools", count: document.tools.count, icon: "wrench.and.screwdriver") { sheet = .tools }
        }
        if !document.techValues.isEmpty {
            chip("Values", count: document.techValues.count, icon: "gauge.with.dots.needle.50percent") { sheet = .values }
        }
    }

    private func chip(_ title: String, count: Int, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
                Text("\(count)").foregroundStyle(Theme.muted)
            }
            .font(.footnote)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color.white, in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pinned(_ document: WorkshopDocument, _ model: DocumentModel) -> some View {
        let block = min(max(model.topBlock ?? 0, 0), max(model.blockFigures.count - 1, 0))
        if let figure = model.blockFigures.indices.contains(block) ? model.blockFigures[block] : nil {
            FigureStage(figure: figure).id(figure.id)
        } else {
            // No illustrations in this document: use the half for getting around
            // it and for the numbers you'd otherwise scroll to find.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !document.toc.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            paneTitle("Contents")
                            ForEach(Array(document.toc.enumerated()), id: \.offset) { _, entry in
                                Button {
                                    if let block = model.anchors[entry.anchor] { withAnimation { model.topBlock = block } }
                                } label: {
                                    Text(entry.label)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.text)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().overlay(Theme.line)
                            }
                        }
                    }
                    if !document.techValues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            paneTitle("Technical values")
                            ForEach(document.techValues) { TechValueCard(value: $0).overlay(Rectangle().stroke(Theme.line)) }
                        }
                    }
                    if document.toc.isEmpty && document.techValues.isEmpty {
                        Text("This document has no illustrations.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(20)
            }
            .background(Color.white)
        }
    }

    private func paneTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption, design: .monospaced))
            .tracking(2.5)
            .foregroundStyle(Theme.muted)
            .padding(.bottom, 6)
    }

    // MARK: - Actions

    private func actions(_ document: WorkshopDocument, _ model: DocumentModel) -> DocumentActions {
        DocumentActions(
            translations: navigator.translations,
            openAnchor: { open(anchor: $0, document, model) },
            openNested: { pendingReference = $0 },
            openFigure: { viewer = $0 })
    }

    private func open(anchor: String, _ document: WorkshopDocument, _ model: DocumentModel) {
        if let tool = document.tools.first(where: { $0.id == anchor }) {
            navigator.push(.tool(tool.number))
        } else if document.techValues.contains(where: { $0.id == anchor }) {
            sheet = .values
        } else if let block = model.anchors[anchor] {
            withAnimation { model.topBlock = block }
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private func toolbar(_ model: DocumentModel) -> some ToolbarContent {
        if isDetailRoot {
            ToolbarItem(placement: .topBarLeading) {
                Button { navigator.closeDetail() } label: { Label("Close", systemImage: "xmark") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { withAnimation(.snappy) { navigator.focused.toggle() } } label: {
                    Label(navigator.focused ? "Show browser" : "Use both halves",
                          systemImage: navigator.focused ? "sidebar.left" : "rectangle.split.2x1")
                }
            }
        }
        if let document = model.state.value, !document.isPDF {
            ToolbarItem(placement: .topBarTrailing) {
                Button { workbench = true } label: { Label("Step by step", systemImage: "list.number") }
                    .disabled(model.steps.isEmpty)
            }
            if !document.toc.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(Array(document.toc.enumerated()), id: \.offset) { _, entry in
                            Button(entry.label) {
                                if let block = model.anchors[entry.anchor] { withAnimation { model.topBlock = block } }
                            }
                        }
                    } label: { Label("Contents", systemImage: "list.bullet.indent") }
                }
            }
        }
    }

    @ViewBuilder
    private func referenceSheet(_ sheet: Sheet, _ document: WorkshopDocument) -> some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    switch sheet {
                    case .tools:
                        ForEach(document.tools) { tool in
                            Button {
                                self.sheet = nil
                                navigator.push(.tool(tool.number))
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                        Text(tool.displayNumber).font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(Theme.brass)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                                }
                                .padding(12)
                                .background(Color.white)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    case .values:
                        ForEach(document.techValues) { TechValueCard(value: $0) }
                    }
                }
                .padding(12)
            }
            .background(Theme.paper)
            .navigationTitle(sheet == .tools ? "Tools" : "Technical values")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { self.sheet = nil } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Full-screen, pinch-zoomable illustration.
struct FigureViewer: View {
    @Environment(\.dismiss) private var dismiss
    let figure: Figure

    var body: some View {
        FigureStage(figure: figure)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(12)
            }
            .background(Color.white.ignoresSafeArea())
    }
}

/// A PDF document (bulletins, scanned manuals), scrolling vertically at the
/// full width of its pane, with the pages' blank margins trimmed so the text
/// is as large as the screen allows. Follows `model.pdfPage`.
struct PDFReader: UIViewRepresentable {
    let data: Data
    let model: DocumentModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = UIColor(Theme.paper)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        let document = PDFDocument(data: data)
        if let document, PDFMargins.trim(document) { view.displayBox = .cropBox }
        view.document = document
        model.pdfPageCount = view.document?.pageCount ?? 0
        if let page = view.document?.page(at: model.pdfPage) { view.go(to: page) }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard let document = view.document, let current = view.currentPage else { return }
        let index = document.index(for: current)
        if index != model.pdfPage, let page = document.page(at: model.pdfPage) { view.go(to: page) }
    }

    final class Coordinator: NSObject {
        let model: DocumentModel
        init(model: DocumentModel) { self.model = model }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage,
                  let index = view.document?.index(for: page), index != model.pdfPage else { return }
            model.pdfPage = index
        }
    }
}

/// Finds the printed area of a PDF's pages and crops every page to it.
/// Workshop PDFs are laid out for paper, with a margin all round that costs a
/// fifth of the width on a phone.
enum PDFMargins {
    /// Sets each page's crop box to the area that has ink on it, judged from a
    /// sample of pages so every page gets the same crop and stays aligned.
    /// Returns false (and changes nothing) when there's nothing worth trimming.
    static func trim(_ document: PDFDocument) -> Bool {
        let count = document.pageCount
        guard count > 0 else { return false }
        let samples = Set((0..<min(count, 8)).map { $0 * count / min(count, 8) })
        var union: CGRect?
        for index in samples {
            guard let page = document.page(at: index) else { continue }
            // The mapping below assumes unrotated pages.
            guard page.rotation == 0 else { return false }
            guard let ink = inkBounds(of: page) else { continue }
            union = union?.union(ink) ?? ink
        }
        // Fractions of the page, origin at the top left. Pad a little, and
        // don't bother for less than a few percent of gain.
        guard var area = union?.insetBy(dx: -0.015, dy: -0.015).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
              area.width < 0.95 || area.height < 0.95, area.width > 0.3, area.height > 0.3 else { return false }
        area = area.standardized
        for index in 0..<count {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            // PDF space has its origin at the bottom left.
            page.setBounds(CGRect(x: media.minX + area.minX * media.width,
                                  y: media.minY + (1 - area.maxY) * media.height,
                                  width: area.width * media.width,
                                  height: area.height * media.height), for: .cropBox)
        }
        return true
    }

    /// The bounding box of everything that isn't near-white, as fractions of
    /// the page (origin top left), from a small rendering of it.
    private static func inkBounds(of page: PDFPage) -> CGRect? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else { return nil }
        let width = 160, height = max(1, Int((160 * media.height / media.width).rounded()))
        guard let image = page.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox).cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return nil }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                if pixels[p] < 235 || pixels[p + 1] < 235 || pixels[p + 2] < 235 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's first row is the top of the page.
        return CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                      width: CGFloat(maxX - minX + 1) / CGFloat(width),
                      height: CGFloat(maxY - minY + 1) / CGFloat(height))
    }
}
