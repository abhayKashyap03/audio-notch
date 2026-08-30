import SwiftUI
import AppKit

/// Spacing constants, in one place. The pill is small enough that a couple of points
/// either way is the difference between "designed" and "crammed".
enum Style {
    /// Breathing room between an island wing's content and the outer corner. The
    /// corner radius eats into this visually, so it is larger than it looks.
    static let wingInset: CGFloat = 20
    /// Inset for the single-run pill layouts.
    static let pillInset: CGFloat = 16
    /// Inset for the opened panel.
    static let panelInset: CGFloat = 16
}

/// Every size decision in one place, so the AppKit hit region and the SwiftUI frame
/// can never disagree about how big the pill currently is.
struct Layout: Equatable {
    var placement: Placement
    /// How many rows the open panel will draw (sources + devices).
    var rows: Int
    /// Whether anything is making sound, which changes the resting pill.
    var active: Bool
    /// The strings the pill will actually draw, so it can size itself to them instead
    /// of guessing a fixed width and leaving the content jammed against the corners.
    var leadName: String = ""
    var leadSubtitle: String = ""
    /// Height the panel's content actually laid out to. Row-count arithmetic is only
    /// ever an estimate, so the real measurement wins once SwiftUI reports it.
    var measuredBody: CGFloat?

    /// Width of a string in the rounded system font, matching what SwiftUI renders.
    private static func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: size) ?? font
        }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Bars + project/detail stack + the "+N" badge. The slack covers SwiftUI's own
    /// spacing, which measurement of the strings alone does not account for.
    private var leadContent: CGFloat {
        let text = max(Self.width(leadName, 9.5, .semibold), Self.width(leadSubtitle, 8.5, .medium))
        return 16 + 6 + max(text, 40) + 12
    }

    /// A dot plus a percentage per provider, then the tone bar.
    /// Volume readout plus the output-device glyph.
    private var trailContent: CGFloat { 68 }

    /// Wings are kept equal so the gap stays centred on the hardware notch.
    var islandWing: CGFloat {
        max(leadContent, trailContent) + Style.wingInset * 2
    }

    /// The opened panel keeps a band either side of the notch too: clock and refresh
    /// on one side, usage on the other. Sized so neither can wrap.
    var islandBandWing: CGFloat {
        max(62, trailContent) + Style.wingInset * 2
    }

    /// Body of the open panel, excluding any notch band above it.
    private var panelBody: CGFloat {
        measuredBody ?? (92 + CGFloat(max(rows, 1)) * 34 + 44)
    }

    func size(for mode: NotchMode) -> CGSize {
        switch placement.edge {
        case .island: return islandSize(mode)
        case .left, .right: return sideSize(mode)
        case .top: return topSize(mode)
        }
    }

    private func topSize(_ mode: NotchMode) -> CGSize {
        switch mode {
        case .mini: return CGSize(width: 52, height: 9)
        case .pill:
            let lead = active ? leadContent + 12 : 0   // source chip plus its divider
            return CGSize(width: lead + trailContent + Style.pillInset * 2, height: 30)
        case .expanded: return CGSize(width: 320, height: panelBody)
        }
    }

    private func sideSize(_ mode: NotchMode) -> CGSize {
        switch mode {
        case .mini: return CGSize(width: 9, height: 46)
        case .pill:
            return CGSize(width: 38, height: active ? 74 : 48)
        case .expanded: return CGSize(width: 320, height: panelBody)
        }
    }

    /// Island mode wraps the hardware notch: the shape is flush with the top of the
    /// screen and wide enough that the cutout disappears inside it, with readouts
    /// sitting either side of the gap.
    private func islandSize(_ mode: NotchMode) -> CGSize {
        let notch = placement.notch
        switch mode {
        case .mini:
            return CGSize(width: notch.width + 28, height: notch.height)
        case .pill:
            return CGSize(width: notch.width + islandWing * 2, height: notch.height)
        case .expanded:
            return CGSize(width: max(notch.width + islandBandWing * 2, 372),
                          height: notch.height + panelBody)
        }
    }

    /// Horizontal gap the content must leave in the middle for the cutout.
    var notchGap: CGFloat { placement.edge.isIsland ? placement.notch.width : 0 }
}
