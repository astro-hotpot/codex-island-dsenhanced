import AppKit

struct NotchInfo {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    /// On notched screens, align the silhouette with the physical notch's
    /// safe-area boundary. visibleFrame measures the menu bar instead and
    /// can leave the island shorter than the hardware notch.
    /// Non-notched screens continue to use the visible menu-bar height.
    ///
    /// auxiliaryTopLeftArea / auxiliaryTopRightArea give the menu-bar regions
    /// on either side of the notch; the notch's own width is
    /// (screen width - left - right).
    static func detect(from screen: NSScreen?) -> NotchInfo {
        guard let screen else {
            return NotchInfo(width: IslandSpacingStore.compactWidth, height: menuBarFallback(), hasNotch: false)
        }
        let safeTop = screen.safeAreaInsets.top
        let visualHeight = safeTop > 0 ? safeTop : visibleMenuBarHeight(of: screen)

        if safeTop > 0 {
            let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightW = screen.auxiliaryTopRightArea?.width ?? 0
            let width: CGFloat = (leftW > 0 && rightW > 0)
                ? screen.frame.width - leftW - rightW
                : 200
            return NotchInfo(width: width, height: visualHeight, hasNotch: true)
        }
        return NotchInfo(width: IslandSpacingStore.compactWidth, height: visualHeight, hasNotch: false)
    }

    private static func visibleMenuBarHeight(of screen: NSScreen) -> CGFloat {
        menuBarHeight(
            safeTop: screen.safeAreaInsets.top,
            visibleFrameDelta: screen.frame.maxY - screen.visibleFrame.maxY,
            statusBarThickness: NSStatusBar.system.thickness
        )
    }

    /// Pure height rule, separated from NSScreen so the test harness can
    /// drive it (see Tests/NotchHeightTests.swift).
    ///
    /// `visibleFrame.maxY` sits 1pt BELOW the menu bar's bottom edge (AppKit
    /// reserves that strip), so the raw frame/visibleFrame delta over-reports
    /// the bar by 1pt — measured 39pt against a 38pt bar on a notched 14".
    /// That extra point made the silhouette's bottom edge dip into app
    /// content below the menu bar. Correct for the gap, and clamp to the
    /// physical notch height so a stale visibleFrame reading (login, display
    /// wake) can never push the silhouette below the real bar either.
    static func menuBarHeight(
        safeTop: CGFloat,
        visibleFrameDelta: CGFloat,
        statusBarThickness: CGFloat
    ) -> CGFloat {
        let fromVisibleFrame = visibleFrameDelta - 1
        if fromVisibleFrame > 0 {
            return safeTop > 0 ? min(fromVisibleFrame, safeTop) : fromVisibleFrame
        }
        // Auto-hide menu bar — visibleFrame == frame, so derive from the
        // physical notch (if present) or the system status bar thickness.
        if safeTop > 0 { return safeTop }
        return statusBarThickness > 0 ? statusBarThickness : 24
    }

    private static func menuBarFallback() -> CGFloat {
        menuBarHeight(safeTop: 0, visibleFrameDelta: 0, statusBarThickness: NSStatusBar.system.thickness)
    }
}
