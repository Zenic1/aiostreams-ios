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
    private var lastLogged: String?
    /// The margins last handed to the page, so a change is passed on once.
    private var lastGiven: UIEdgeInsets?

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        guard let window, let bar = window.windowScene?.statusBarManager?.statusBarFrame,
              bar.width > 0, bar.height > bar.width else { return insets }
        // The status column's side, in this view's terms, and how far it reaches in.
        let column = convert(bar, from: window.coordinateSpace)
        if column.midX > bounds.midX {
            insets.right = max(0, insets.right - max(0, bounds.maxX - column.minX))
        } else {
            insets.left = max(0, insets.left - max(0, column.maxX - bounds.minX))
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
        guard given != lastGiven else { return }
        let first = lastGiven == nil
        lastGiven = given
        if !first { safeAreaInsetsDidChange() }
    }
}
