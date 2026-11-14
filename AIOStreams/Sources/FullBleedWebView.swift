import UIKit
import WebKit

/**
 * The page's web view, which fits the page to a status bar in a column down one side, as iPhone Duo
 * has. iOS reports that column as a safe-area margin, and the page keeps out of it as it keeps out of
 * a notch (CSS `env(safe-area-inset-*)`): the column is a keep-out zone, so nothing the page shows can
 * sit under the clock. Two things go into it on purpose: the page's bar, docked there as a vertical
 * bar as Duo apps put their tab bar, and the hero's art, which runs under it to the edge rather than
 * leaving a dark strip.
 */
final class FullBleedWebView: WKWebView {
    /// What goes into the status column, and the few layers that don't read the safe area. Only
    /// under `data-status-column`, which the app sets on the page's root, so a screen with its status
    /// bar across the top keeps the bar at the bottom.
    static let columnStyle = """
    (() => {
      if (window.top !== window) return;
      const css = `
        html[data-status-column] [data-ui='mobile-nav'] {
          left: auto !important; right: 0 !important; top: auto !important;
          width: var(--status-column-width) !important;
          padding: 0 0 calc(0.75rem + env(safe-area-inset-bottom)) 0 !important;
          justify-content: center !important;
        }
        html[data-status-column='left'] [data-ui='mobile-nav'] { right: auto !important; left: 0 !important; }
        html[data-status-column] [data-ui='mobile-nav'][data-away] { transform: translateX(150%) !important; }
        html[data-status-column='left'] [data-ui='mobile-nav'][data-away] { transform: translateX(-150%) !important; }
        html[data-status-column] [data-ui='mobile-nav'] > [data-surface] {
          flex-direction: column !important; width: auto !important; max-width: none !important;
        }
        html[data-status-column] [data-ui='mobile-nav-item'] {
          flex: none !important; width: 3rem !important; padding: 0.75rem 0 !important;
        }
        html[data-status-column] [data-ui='mobile-nav-item'] > span {
          position: absolute !important; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap;
        }
        /* The bar no longer takes room at the foot of the page. */
        html[data-status-column] { --nav-bar: env(safe-area-inset-bottom) !important; }
        /* The hero's art runs on under the column, its text and dots kept out of it. */
        html[data-status-column] [data-page] [data-ui='hero'] { width: calc(100% + var(--status-column-width)) !important; }
        html[data-status-column='right'] [data-page] [data-ui='hero'] { margin-right: calc(-1 * var(--status-column-width)) !important; }
        html[data-status-column='left'] [data-page] [data-ui='hero'] { margin-left: calc(-1 * var(--status-column-width)) !important; }
        html[data-status-column='right'] [data-ui='hero'] [data-ui='hero-content'] { padding-right: var(--status-column-width) !important; }
        html[data-status-column='left'] [data-ui='hero'] [data-ui='hero-content'] { padding-left: var(--status-column-width) !important; }
        html[data-status-column='right'] [data-ui='hero'] [data-ui='hero-dots'] { right: calc(1rem + var(--status-column-width)) !important; }
        /* Dialogs and sheets lay themselves out over the whole screen without reading the safe area
           (a phone's has none at its sides), so they're kept out of the column here. */
        html[data-status-column='right'] .UI-Modal__overlay > div { right: var(--status-column-width) !important; }
        html[data-status-column='left'] .UI-Modal__overlay > div { left: var(--status-column-width) !important; }
        html[data-status-column='right'] .UI-Drawer__content:not([data-side='left']) { right: var(--status-column-width) !important; }
        html[data-status-column='left'] .UI-Drawer__content:not([data-side='right']) { left: var(--status-column-width) !important; }
        @media (min-width: 1024px) {
          html[data-status-column] [data-page] [data-ui='hero'] {
            width: calc(100% + var(--side-bar, 0px) + var(--status-column-width)) !important;
          }
        }
        @media (max-width: 639px) {
          html[data-status-column='right'] [data-ui='hero'] [data-ui='hero-dots'] { right: var(--status-column-width) !important; }
          html[data-status-column='left'] [data-ui='hero'] [data-ui='hero-dots'] { left: var(--status-column-width) !important; }
        }`;
      const add = () => {
        const style = document.createElement('style');
        style.dataset.ui = 'ios-status-column';
        style.textContent = css;
        document.head.appendChild(style);
      };
      if (document.head) add(); else document.addEventListener('DOMContentLoaded', add);
    })();
    """

    /// The status column's side and width, while there is one.
    private var column: (side: String, width: CGFloat)?

    private var lastLogged: String?

    /// Records the margins as they change, with the status bar's place, for a problem report from a
    /// device whose screen is new to the app.
    private func note() {
        let bar = window?.windowScene?.statusBarManager?.statusBarFrame ?? .zero
        let found = currentColumn.map { "\($0.side) \(Int($0.width))" } ?? "none"
        let line = "size \(bounds.size), status bar \(bar.integral), margins \(safeAreaInsets), column \(found)"
        guard line != lastLogged else { return }
        lastLogged = line
        AppLog.info("layout", line)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A fold, a turn or Split View can move the status column.
        note()
        updateColumn()
    }

    /// Where the status column is now, and how far it reaches in. A vertical status bar at one side,
    /// where iOS reports it so; else a margin on one side far wider than the other's. A notched iPhone
    /// turned sideways has the same margin on both sides, so it never counts.
    private var currentColumn: (side: String, width: CGFloat)? {
        if let window, let bar = window.windowScene?.statusBarManager?.statusBarFrame,
           bar.width > 0, bar.height > bar.width {
            let place = convert(bar, from: window.coordinateSpace)
            return place.midX > bounds.midX
                ? ("right", max(0, bounds.maxX - place.minX))
                : ("left", max(0, place.maxX - bounds.minX))
        }
        let margins = safeAreaInsets
        let difference = margins.right - margins.left
        guard abs(difference) > 20 else { return nil }
        return difference > 0 ? ("right", difference) : ("left", -difference)
    }

    private func updateColumn() {
        let now = currentColumn
        guard now?.side != column?.side || now?.width != column?.width else { return }
        column = now
        applyColumn()
    }

    /// Marks the page's root with the column, or clears it; again after each page load.
    func applyColumn() {
        let script: String
        if let column {
            script = "document.documentElement.dataset.statusColumn = '\(column.side)';"
                + "document.documentElement.style.setProperty('--status-column-width', '\(Int(column.width))px');"
        } else {
            script = "delete document.documentElement.dataset.statusColumn;"
                + "document.documentElement.style.removeProperty('--status-column-width');"
        }
        evaluateJavaScript(script)
        probe()
    }

    /// Logs the side margins the page actually has (its CSS `env(safe-area-inset-*)`), which tell
    /// whether WebKit followed the margins given it.
    func probe() {
        let measure = """
        (() => {
          const probe = document.createElement('div');
          probe.style.cssText = 'position:fixed;visibility:hidden;padding-left:env(safe-area-inset-left);padding-right:env(safe-area-inset-right)';
          document.documentElement.appendChild(probe);
          const style = getComputedStyle(probe);
          const read = `page margins left ${style.paddingLeft}, right ${style.paddingRight}, width ${innerWidth}`;
          probe.remove();
          return read;
        })()
        """
        evaluateJavaScript(measure) { result, _ in
            if let read = result as? String { AppLog.info("layout", read) }
        }
    }
}
