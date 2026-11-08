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
            if flags == .command, key == .downArrow {
                model.openViewer()
                return true
            }
            guard plain else { return false }
            switch key {
            case .delete, .deleteForward:
                // Remove from Album, in a manual album. Nothing happens to files anywhere.
                guard !extending, model.currentManualAlbum != nil else { return false }
                model.removeFromAlbum()
            case .carriageReturn, .enter:
                guard !extending else { return false }
                model.openViewer()
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
        if plain, !extending, event.charactersIgnoringModifiers == " " {
            model.openViewer()
            return true
        }
        // Matched by character, so it's the period key wherever a layout puts it. The menu usually
        // takes it first.
        if plain, !extending, event.charactersIgnoringModifiers == "." {
            model.toggleFavorite()
            return true
        }
        guard typeToSelect, plain, let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
            // Control characters aren't part of a name.
            characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        model.typeSelect(event.characters ?? characters)
        return true
    }
}

/// The viewer's keys. Arrow keys are matched by function, so they work on every layout. Zooming has
/// menu items, and the menu handles them.
@MainActor
enum ViewerKeys {
    private static let escape: UInt16 = 53

    static func handle(_ event: NSEvent, model: BrowserModel) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == escape, flags.isEmpty {
            model.closeViewer()
            return true
        }
        if flags == .command, event.specialKey == .upArrow {
            model.closeViewer()
            return true
        }
        guard flags.isEmpty else { return false }
        if event.charactersIgnoringModifiers == "." {
            model.toggleFavorite()
            return true
        }
        if event.charactersIgnoringModifiers == " " {
            // Space is a quick look toggle. For a video it'll play and pause, once videos play.
            model.closeViewer()
            return true
        }
        let isRepeat = event.isARepeat
        switch event.specialKey {
        case .leftArrow:
            if !model.panViewer(dx: 1, dy: 0) { model.stepViewer(by: -1, isRepeat: isRepeat) }
        case .rightArrow:
            if !model.panViewer(dx: -1, dy: 0) { model.stepViewer(by: 1, isRepeat: isRepeat) }
        case .upArrow: _ = model.panViewer(dx: 0, dy: 1)
        case .downArrow: _ = model.panViewer(dx: 0, dy: -1)
        case .home: model.stepViewer(to: 0)
        case .end: model.stepViewer(to: model.result.count - 1)
        default: return false
        }
        return true
    }
}
