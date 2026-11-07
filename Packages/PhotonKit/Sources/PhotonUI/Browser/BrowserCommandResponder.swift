import AppKit

/// Sits in the responder chain behind the window, so that Copy reaches the browser from wherever focus
/// is: the grid, the list, the viewer or the sidebar. A text field further up handles Copy itself.
@MainActor
final class BrowserCommandResponder: NSResponder, NSMenuItemValidation {
    private let model: BrowserModel

    init(model: BrowserModel) {
        self.model = model
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used.") }

    func install(in window: NSWindow?) {
        guard let window, window.nextResponder !== self else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    @objc func copy(_ sender: Any?) { model.copy() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? !model.actionRows.isEmpty : true
    }
}
