import UIKit
import WebKit

/**
 * The page's web view, which gives the page the whole screen where iOS keeps its status bar in a
 * column down one side, as iPhone Duo does. iOS reports that column as a safe-area margin, and the
 * page keeps its content out of a margin (CSS `env(safe-area-inset-*)`), which left a dark strip down
 * that side. Without the column, the page draws under it, as it draws under a status bar across the
 * top; the clock and Wi-Fi sit over the artwork there. Every other margin (a notch, the home
 * indicator, a status bar across the top) is left as iOS reports it.
 */
final class FullBleedWebView: WKWebView {
    /// The page's bottom bar, docked in the status column as a vertical bar where there is one, as
    /// apps on iPhone Duo put their tab bar there. Only under `data-status-column`, which the app sets
    /// on the page's root, so a screen with its status bar across the top keeps the bar at the bottom.
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
    /// The margins last handed to the page, so a change is passed on once.
    private var lastGiven: UIEdgeInsets?

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        guard let window, let bar = window.windowScene?.statusBarManager?.statusBarFrame,
              bar.width > 0, bar.height > bar.width else { return insets }
        // The status column's side, in this view's terms, and how far it reaches in.
        let place = convert(bar, from: window.coordinateSpace)
        if place.midX > bounds.midX {
            insets.right = max(0, insets.right - max(0, bounds.maxX - place.minX))
        } else {
            insets.left = max(0, insets.left - max(0, place.maxX - bounds.minX))
        }
        return insets
    }

    /// Records the margins as they change, with the status bar's place, for a problem report from a
    /// device whose screen is new to the app.
    private func note(_ given: UIEdgeInsets) {
        let bar = window?.windowScene?.statusBarManager?.statusBarFrame ?? .zero
        let line = "size \(bounds.size), status bar \(bar.integral), margins \(super.safeAreaInsets) given as \(given)"
        guard line != lastLogged else { return }
        lastLogged = line
        AppLog.info("layout", line)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A fold, a turn or Split View can move the status column; the page reads the margins again,
        // only when they've changed, so it can't lay itself out over and over.
        let given = safeAreaInsets
        note(given)
        updateColumn()
        guard given != lastGiven else { return }
        let first = lastGiven == nil
        lastGiven = given
        if !first { safeAreaInsetsDidChange() }
    }

    /// Where the status column is now: a vertical status bar at one side of this view.
    private var currentColumn: (side: String, width: CGFloat)? {
        guard let window, let bar = window.windowScene?.statusBarManager?.statusBarFrame,
              bar.width > 0, bar.height > bar.width else { return nil }
        let place = convert(bar, from: window.coordinateSpace)
        return place.midX > bounds.midX
            ? ("right", max(0, bounds.maxX - place.minX))
            : ("left", max(0, place.maxX - bounds.minX))
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
    }
}
