import SwiftUI

/// iPhone Duo fold and camera regions (iOS 27.1 reserved regions), in the
/// proxy's local coordinates and grown by their hit-target margins. Empty on
/// any other device.
enum ReservedLayout {
    /// The fold, when it's bent (active). A flat-open fold isn't active.
    static func fold(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division).first(where: \.isActive)?.paddedFrame
    }

    /// Where the crease is even when the phone is open flat, so a two-pane
    /// layout can put its divider on it.
    static func crease(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
    }
}

private extension ReservedRegion {
    var paddedFrame: CGRect {
        CGRect(x: frame.minX - margins.leading, y: frame.minY - margins.top,
               width: frame.width + margins.leading + margins.trailing,
               height: frame.height + margins.top + margins.bottom)
    }
}

/// How the phone is being held, as far as layout cares.
enum Posture: Equatable {
    /// Cover screen, or any ordinary phone: one column.
    case compact
    /// Inner screen open flat (or an iPad): two panes. `divider` is the
    /// crease's x-position when there is one.
    case open(divider: CGFloat?)
    /// Half-folded with the crease upright, held like a book: two panes with
    /// nothing on the bend.
    case book(fold: CGRect)
    /// Half-folded with the crease across, standing on the bench: the upper
    /// half is upright, the lower half lies flat.
    case tabletop(fold: CGRect)

    static func current(_ proxy: GeometryProxy, wide: Bool) -> Posture {
        #if DEBUG
        // The simulator's hinge can't be scripted; `-workbook.debug.posture
        // tabletop|book|open` fakes a posture so each layout can be checked.
        if let fake = DebugOptions.posture {
            let size = proxy.size
            switch fake {
            case "tabletop": return .tabletop(fold: CGRect(x: 0, y: size.height / 2 - 14, width: size.width, height: 28))
            case "book": return .book(fold: CGRect(x: size.width / 2 - 14, y: 0, width: 28, height: size.height))
            case "open": return .open(divider: size.width / 2)
            default: break
            }
        }
        #endif
        if let fold = ReservedLayout.fold(in: proxy) {
            return fold.width >= fold.height ? .tabletop(fold: fold) : .book(fold: fold)
        }
        guard wide else { return .compact }
        if let crease = ReservedLayout.crease(in: proxy), crease.height > crease.width,
           crease.midX > proxy.size.width * 0.3, crease.midX < proxy.size.width * 0.7 {
            return .open(divider: crease.midX)
        }
        return .open(divider: nil)
    }

    var isTabletop: Bool {
        if case .tabletop = self { return true }
        return false
    }
}

/// Whether to use two panes: the iPhone Duo's inner screen and iPads, which
/// are regular in both directions. A big phone on its side is regular-width
/// but compact-height and keeps the single column.
struct WideLayout: DynamicProperty {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    var isWide: Bool { horizontal == .regular && vertical == .regular }
}

#if DEBUG
/// Launch options for checking layouts in the simulator, e.g.
/// `-workbook.debug.open 75104700 -workbook.debug.posture tabletop`.
enum DebugOptions {
    static var posture: String? { UserDefaults.standard.string(forKey: "workbook.debug.posture") }
    /// hkap id of a document to open at launch.
    static var open: String? { UserDefaults.standard.string(forKey: "workbook.debug.open") }
    static var focused: Bool { UserDefaults.standard.bool(forKey: "workbook.debug.focused") }
    /// Step to start the workbench on.
    static var step: Int { UserDefaults.standard.integer(forKey: "workbook.debug.step") }
}
#endif
