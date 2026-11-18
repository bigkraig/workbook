import SwiftUI
import WebKit

/// The component diagram for a level of the tree: tap a region to drill into
/// that component, the same navigation the website's diagram offers.
///
/// The server's illustration is an SVG whose `#CC_HOTSPOT` layer holds one
/// shape per child, with id `NAV_<location>` (folders) or `FES_<location>`
/// (leaves).
struct IllustrationNavigator: View {
    @Environment(AppSettings.self) private var settings
    let illustrationId: Int
    /// Hotspot id → the child it opens.
    let targets: [String: TreeNode]
    var onSelect: (TreeNode) -> Void

    @State private var svg: Loadable<(markup: String, aspect: CGFloat)> = .loading
    /// The drawing's real proportions, reported by the web view once it has
    /// cropped away the empty page around it.
    @State private var croppedAspect: CGFloat?

    var body: some View {
        Group {
            switch svg {
            case .loading:
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 120)
            case .failed:
                EmptyView()
            case .loaded(let illustration):
                HotspotSVGView(svg: illustration.markup, hotspots: Array(targets.keys),
                               onLayout: { croppedAspect = $0 }) { id in
                    if let node = targets[id] { onSelect(node) }
                }
                // Full width of the pane: the diagram is the navigation, and a
                // height cap left it stranded beside a blank strip.
                .aspectRatio(croppedAspect ?? illustration.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.white)
            }
        }
        .task(id: "\(illustrationId)#\(settings.sessionGeneration)") { await load() }
    }

    private func load() async {
        croppedAspect = nil
        let path = "/v1/vehicle_component_tree/illustrations/\(illustrationId)"
        do {
            let data = try await MediaStore.shared.load(path, api: API(settings: settings)).data
            guard let markup = String(data: data, encoding: .utf8), markup.contains("<svg") else {
                svg = .failed("Not an illustration")
                return
            }
            svg = .loaded((SVGView.fitted(markup), RemoteImage.aspect(of: markup)))
        } catch {
            svg = .failed(error.localizedDescription)
        }
    }

    /// Hotspot ids for a level's children.
    static func targets(for children: [TreeNode]) -> [String: TreeNode] {
        var targets: [String: TreeNode] = [:]
        for child in children {
            guard let location = child.location else { continue }
            targets[(child.hasChildren ? "NAV_" : "FES_") + location] = child
        }
        return targets
    }
}

/// An SVG in a web view that reports taps on known hotspot ids.
private struct HotspotSVGView: UIViewRepresentable {
    let svg: String
    let hotspots: [String]
    var onLayout: (CGFloat) -> Void
    var onTap: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLayout: onLayout, onTap: onTap) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "hotspot")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onLayout = onLayout
        let key = svg.hashValue ^ hotspots.sorted().hashValue
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key

        // Only this script may run: the nonce'd CSP blocks anything the
        // illustration itself might carry.
        let nonce = UUID().uuidString
        let ids = (try? JSONSerialization.data(withJSONObject: hotspots)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let html = """
            <!doctype html><html><head>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'">
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
            <style>
              html, body { margin: 0; height: 100%; background: transparent; -webkit-tap-highlight-color: transparent; }
              body > svg { display: block; width: 100%; height: 100%; }
              #CC_HOTSPOT polygon, #CC_HOTSPOT path, #CC_HOTSPOT rect { fill: none; pointer-events: all; }
              #CC_HOTSPOT .selectable { fill: #C0862C; fill-opacity: .10; }
              #CC_HOTSPOT .selectable.pressed { fill-opacity: .5; }
            </style></head><body>\(svg)
            <script nonce="\(nonce)">
              // The artwork sits on a full landscape page; crop to what's drawn
              // and tell the app the new proportions.
              const svg = document.querySelector('svg');
              try {
                // The hotspot layer bounds the part of the page that's in use
                // (the page itself can carry invisible full-size elements).
                const layer = document.getElementById('CC_HOTSPOT') || svg;
                const box = layer.getBBox(), pad = Math.max(box.width, box.height) * 0.02;
                if (box.width > 0 && box.height > 0) {
                  svg.setAttribute('viewBox', `${box.x - pad} ${box.y - pad} ${box.width + 2 * pad} ${box.height + 2 * pad}`);
                  svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
                  window.webkit.messageHandlers.hotspot.postMessage({ aspect: (box.width + 2 * pad) / (box.height + 2 * pad) });
                }
              } catch (e) {}
              const ids = new Set(\(ids));
              for (const id of ids) { const el = document.getElementById(id); if (el) el.classList.add('selectable'); }
              function hotspot(target) {
                for (let el = target; el && el !== document.body; el = el.parentElement) {
                  if (el.id && ids.has(el.id)) return el;
                }
                return null;
              }
              document.addEventListener('touchstart', e => { const el = hotspot(e.target); if (el) el.classList.add('pressed'); }, { passive: true });
              document.addEventListener('touchend', () => document.querySelectorAll('.pressed').forEach(el => el.classList.remove('pressed')), { passive: true });
              document.addEventListener('click', e => {
                const el = hotspot(e.target);
                if (el) window.webkit.messageHandlers.hotspot.postMessage(el.id);
              });
            </script></body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "hotspot")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onLayout: (CGFloat) -> Void
        var onTap: (String) -> Void
        var loaded: Int?
        init(onLayout: @escaping (CGFloat) -> Void, onTap: @escaping (String) -> Void) {
            self.onLayout = onLayout
            self.onTap = onTap
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let id = message.body as? String {
                onTap(id)
            } else if let body = message.body as? [String: Any], let aspect = body["aspect"] as? Double, aspect > 0 {
                onLayout(aspect)
            }
        }
    }
}
