import SwiftUI
import WebKit

/// An image from the API. Workshop illustrations are mostly SVG (which UIKit
/// can't decode), tool and vehicle photos are PNG/JPEG; this loads the bytes
/// through the authenticated session and picks the right renderer.
struct RemoteImage: View {
    @Environment(AppSettings.self) private var settings
    let path: String
    /// Pinch-zoom and pan (SVG only); off for inline figures so the page scrolls.
    var zoomable = false
    @State private var media: Loadable<Media> = .loading

    enum Media {
        case raster(UIImage)
        case svg(String, aspect: CGFloat)
    }

    var body: some View {
        Group {
            switch media {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            case .failed:
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .loaded(.raster(let image)):
                Image(uiImage: image).resizable().scaledToFit()
            case .loaded(.svg(let svg, let aspect)):
                SVGView(svg: svg, zoomable: zoomable)
                    .aspectRatio(aspect, contentMode: .fit)
            }
        }
        .task(id: path + "#\(settings.sessionGeneration)") { await load() }
    }

    private func load() async {
        do {
            let (data, contentType) = try await MediaStore.shared.load(path, api: API(settings: settings))
            if !contentType.contains("svg"), let image = UIImage(data: data) {
                media = .loaded(.raster(image))
            } else if let svg = String(data: data, encoding: .utf8), svg.contains("<svg") {
                media = .loaded(.svg(svg, aspect: Self.aspect(of: svg)))
            } else {
                media = .failed("Unsupported image")
            }
        } catch {
            media = .failed(error.localizedDescription)
        }
    }

    /// Width / height from the root element's viewBox (or width/height attributes).
    static func aspect(of svg: String) -> CGFloat {
        guard let tag = svg.firstMatch(of: /<svg\b[^>]*>/) else { return 4 / 3 }
        let root = String(tag.0)
        if let box = root.firstMatch(of: /viewBox\s*=\s*"\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)/),
           let w = Double(box.1), let h = Double(box.2), w > 0, h > 0 {
            return w / h
        }
        if let w = root.firstMatch(of: /\bwidth\s*=\s*"([\d.]+)/).flatMap({ Double($0.1) }),
           let h = root.firstMatch(of: /\bheight\s*=\s*"([\d.]+)/).flatMap({ Double($0.1) }), w > 0, h > 0 {
            return w / h
        }
        return 4 / 3
    }
}

/// Renders an SVG string in a transparent web view, scaled to fit.
struct SVGView: UIViewRepresentable {
    let svg: String
    let zoomable: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Illustrations are static; never run script from document content.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.isUserInteractionEnabled = zoomable
        webView.scrollView.isScrollEnabled = zoomable
        webView.scrollView.bounces = false
        guard context.coordinator.loaded != svg.hashValue else { return }
        context.coordinator.loaded = svg.hashValue
        let scale = zoomable ? "minimum-scale=1, maximum-scale=10" : "maximum-scale=1, user-scalable=no"
        let html = """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1, \(scale)">
            <style>
              html, body { margin: 0; height: 100%; background: transparent; }
              body > svg { display: block; width: 100%; height: 100%; }
            </style></head><body>\(Self.fitted(svg))</body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Drop any XML prolog/doctype, and give a root without a viewBox one
    /// built from its width/height so it scales instead of clipping.
    static func fitted(_ svg: String) -> String {
        guard let start = svg.range(of: "<svg") else { return svg }
        var body = String(svg[start.lowerBound...])
        guard let tag = body.firstMatch(of: /<svg\b[^>]*>/) else { return body }
        let root = String(tag.0)
        if !root.contains("viewBox"),
           let w = root.firstMatch(of: /\bwidth\s*=\s*"([\d.]+)/).map({ String($0.1) }),
           let h = root.firstMatch(of: /\bheight\s*=\s*"([\d.]+)/).map({ String($0.1) }) {
            body.replaceSubrange(tag.range, with: root.replacingOccurrences(of: "<svg", with: "<svg viewBox=\"0 0 \(w) \(h)\""))
        }
        return body
    }

    final class Coordinator {
        var loaded: Int?
    }
}

/// A figure filling the available space, pinch-zoomable; used full-screen and
/// in the pinned / workbench panes.
struct FigureStage: View {
    @Environment(AppSettings.self) private var settings
    let figure: Figure

    var body: some View {
        VStack(spacing: 6) {
            RemoteImage(path: API(settings: settings).figurePath(figure.key), zoomable: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !figure.title.isEmpty {
                Text(figure.title)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(Color.white)
    }
}
