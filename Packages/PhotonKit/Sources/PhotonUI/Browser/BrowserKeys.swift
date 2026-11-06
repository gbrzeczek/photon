import AppKit

/// The keys grid and list share, from the table in docs/PLAN.md. Arrow and paging keys are matched by
/// their function, so they work on every keyboard layout. Everything with a menu item goes through the
/// menu, where it's discoverable.
@MainActor
enum BrowserKeys {
    /// Returns whether the event was used.
    static func handle(_ event: NSEvent, model: BrowserModel, typeToSelect: Bool) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let extending = flags.contains(.shift)
        let plain = flags.isDisjoint(with: [.command, .option, .control])

        if let key = event.specialKey {
            if flags.contains(.command), !flags.contains(.shift), key == .upArrow {
                model.openParent()
                return true
            }
            guard plain else { return false }
            switch key {
            case .leftArrow: model.move(.left, extending: extending)
            case .rightArrow: model.move(.right, extending: extending)
            case .upArrow: model.move(.up, extending: extending)
            case .downArrow: model.move(.down, extending: extending)
            case .home: model.move(.home, extending: extending)
            case .end: model.move(.end, extending: extending)
            case .pageUp: model.move(.pageUp, extending: extending)
            case .pageDown: model.move(.pageDown, extending: extending)
            default: return false
            }
            return true
        }
        guard typeToSelect, plain, let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
            // Space opens the viewer, and control characters aren't part of a name.
            characters != " ", characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        model.typeSelect(event.characters ?? characters)
        return true
    }
}
