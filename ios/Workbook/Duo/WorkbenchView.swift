import SwiftUI

/// Step-by-step mode for working on the car.
///
/// On iPhone Duo standing half-folded on the bench, the upright half shows the
/// illustration for the current step and the flat half shows the step with
/// big previous/next targets. Anywhere else (cover screen, open flat) it's the
/// same two areas stacked, so it also works as a hands-busy reading mode.
/// The screen stays awake while it's up.
struct WorkbenchView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    let summary: DocumentSummary
    var onClose: () -> Void

    @State private var override: Figure?
    @State private var pendingReference: NestedRef?

    var body: some View {
        let model = navigator.model(for: summary)
        GeometryReader { geo in
            // A bent, horizontal fold splits the two areas exactly; otherwise
            // give the figure a little under half.
            let fold = ReservedLayout.fold(in: geo).flatMap { $0.width >= $0.height ? $0 : nil }
            let stageHeight = fold?.minY ?? geo.size.height * 0.44
            VStack(spacing: 0) {
                stage(model)
                    .frame(height: max(0, stageHeight))
                    .clipped()
                Theme.ink.frame(height: fold?.height ?? 1)
                panel(model)
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .task(id: "\(summary.hkapId)#\(settings.sessionGeneration)") {
            await model.load(api: API(settings: settings))
            // Pick up where the reading view was.
            if model.currentStep == 0, let block = model.topBlock, block > 0 {
                model.currentStep = model.step(forBlock: block)
            }
        }
        .onChange(of: model.currentStep) { _, step in
            override = nil
            if model.steps.indices.contains(step) { model.topBlock = model.steps[step].blockIndex }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .crossReferences($pendingReference)
    }

    // MARK: - Upright half

    @ViewBuilder
    private func stage(_ model: DocumentModel) -> some View {
        if case .loaded(let document) = model.state, document.isPDF, let data = model.pdfData {
            PDFReader(data: data, model: model)
        } else if let figure = override ?? currentStep(model)?.figure {
            FigureStage(figure: figure).id(figure.id)
        } else {
            VStack(spacing: 10) {
                TypeBadge(type: summary.documentType)
                Text(currentStep(model)?.section ?? summary.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text(summary.title).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ink)
        }
    }

    // MARK: - Flat half

    @ViewBuilder
    private func panel(_ model: DocumentModel) -> some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            StatusView(systemImage: "exclamationmark.triangle", title: "Couldn't open this document", message: message)
        case .loaded(let document):
            if document.isPDF {
                pager(title: summary.title, label: "PAGE", index: model.pdfPage, count: model.pdfPageCount,
                      move: { model.pdfPage = min(max(0, model.pdfPage + $0), max(0, model.pdfPageCount - 1)) }) {
                    Spacer(minLength: 0)
                }
            } else if model.steps.isEmpty {
                StatusView(systemImage: "list.number", title: "No steps in this document")
            } else {
                let step = model.steps[min(model.currentStep, model.steps.count - 1)]
                pager(title: step.section, label: step.position == nil ? "NOTE" : "STEP",
                      index: model.currentStep, count: model.steps.count,
                      move: { model.currentStep = min(max(0, model.currentStep + $0), model.steps.count - 1) }) {
                    ScrollView {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            if let position = step.position {
                                Text(position)
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Theme.brass)
                            }
                            ContentView(nodes: step.nodes)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    .id(step.id)
                    .environment(\.documentActions, DocumentActions(
                        translations: navigator.translations,
                        openAnchor: { anchor in
                            if let tool = document.tools.first(where: { $0.id == anchor }) {
                                navigator.push(.tool(tool.number))
                            } else if let block = model.anchors[anchor] {
                                model.currentStep = model.step(forBlock: block)
                            }
                        },
                        openNested: { pendingReference = $0 },
                        openFigure: { override = $0 },
                        scale: 1.2))
                }
            }
        }
    }

    /// Header, content, and the big previous/next bar.
    private func pager<Content: View>(title: String, label: String, index: Int, count: Int,
                                      move: @escaping (Int) -> Void,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(label) \(index + 1) OF \(max(count, 1))")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(Theme.brass)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .frame(width: 48, height: 48)
                        .background(Color.white, in: Circle())
                }
                .accessibilityLabel("Close step by step")
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ProgressView(value: Double(index + 1), total: Double(max(count, 1)))
                .tint(Theme.brass)
                .padding(.horizontal, 18)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 12) {
                stepButton("Previous", systemImage: "chevron.left", enabled: index > 0, primary: false) { move(-1) }
                stepButton("Next", systemImage: "chevron.right", enabled: index < count - 1, primary: true) { move(1) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 40).onEnded { drag in
            guard abs(drag.translation.width) > abs(drag.translation.height) * 1.5 else { return }
            move(drag.translation.width < 0 ? 1 : -1)
        })
    }

    /// Large enough to hit with a knuckle or a gloved thumb.
    private func stepButton(_ title: String, systemImage: String, enabled: Bool, primary: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !primary { Image(systemName: systemImage) }
                Text(title)
                if primary { Image(systemName: systemImage) }
            }
            .font(.title3.weight(.bold))
            .foregroundStyle(primary ? Color.white : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(primary ? Theme.ink : Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func currentStep(_ model: DocumentModel) -> WorkStep? {
        model.steps.indices.contains(model.currentStep) ? model.steps[model.currentStep] : nil
    }
}

/// Resolves a cross-reference to its document(s) and opens it, asking which
/// one when several match.
private struct CrossReferences: ViewModifier {
    @Environment(AppSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    @Binding var pending: NestedRef?
    @State private var choices: [DocumentSummary] = []
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .task(id: pending) {
                guard let ref = pending, let vehicle = navigator.vehicle else { return }
                defer { pending = nil }
                do {
                    let matches = try await API(settings: settings).resolve(ref, vehicle: vehicle)
                    switch matches.count {
                    case 0: notice = "“\(ref.title)” isn't available for this vehicle."
                    case 1: navigator.push(.document(matches[0]))
                    default: choices = matches
                    }
                } catch {
                    notice = error.localizedDescription
                }
            }
            .confirmationDialog("Which document?", isPresented: .constant(!choices.isEmpty), titleVisibility: .visible) {
                ForEach(choices) { choice in
                    Button("\(choice.code) \(choice.title)") { choices = []; navigator.push(.document(choice)) }
                }
                Button("Cancel", role: .cancel) { choices = [] }
            }
            .alert(notice ?? "", isPresented: .constant(notice != nil)) {
                Button("OK") { notice = nil }
            }
    }
}

extension View {
    func crossReferences(_ pending: Binding<NestedRef?>) -> some View {
        modifier(CrossReferences(pending: pending))
    }
}
