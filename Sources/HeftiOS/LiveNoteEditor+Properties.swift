import HeftCore
import UIKit

/// The properties table on iOS: what the Mac's editor does with a mouse and
/// a menu bar, done with taps, the keyboard's suggestion strip and a menu on
/// each row's icon. Every decision about the text is `PropertySurface`'s and
/// every measurement `PropertyGeometry`'s, shared with the Mac, so the two
/// tables behave alike; `Docs/EditingSurface.md` has the reasoning.
struct PropertyEditorState {
    var leaving = PropertyLeaving()
    /// Where the caret was on the last pass, for which way it came onto a
    /// fence or into the hidden gap between key and value.
    var lastCaret: Int?
    /// The blank row Add Property made, where the menu of keys opens before
    /// anything is typed, as Obsidian's does.
    var keyMenuRow: Int?
    /// True while the editor writes through `replace`, which UIKit may
    /// report to the delegate as typing.
    var replacing = false
    /// The menu buttons over each row's icon, by row.
    var menuButtons: [Int: UIButton] = [:]
    var foldArrow: UIImageView?
    var sourceButton: UIImageView?
    var catalog: (index: ObjectIdentifier, catalog: PropertyCatalog)?
    /// The text's menu, shown by a tap on the caret in a row: UIKit's own
    /// tap, which shows it elsewhere, does not reach a row.
    var editMenu: UIEditMenuInteraction?
    /// Set by a restyle until the controls were placed against a laid-out
    /// heading: a restyle can come before TextKit lays the line out.
    var controlsPending = false

    /// Per note, for this run, as the Mac keeps them.
    @MainActor static var foldedNotes: Set<String> = []
    @MainActor static var sourceNotes: Set<String> = []
}

extension LiveNoteEditor.Coordinator: UIEditMenuInteractionDelegate {
    private var noteKey: String { document?.path ?? "" }
    var propertiesFolded: Bool { PropertyEditorState.foldedNotes.contains(noteKey) }
    var propertiesAsText: Bool { PropertyEditorState.sourceNotes.contains(noteKey) }

    private func origin(of textView: UITextView) -> CGPoint {
        CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
    }

    // MARK: Taps

    /// Every control the table draws, the icons' menus included: UIKit's own
    /// taps must not put a caret under any of them.
    func isOnPropertyControl(at point: CGPoint, in textView: MobileTextView) -> Bool {
        allTargets(in: textView).contains { $0.rect.contains(point) }
    }

    /// What a tap at `point` does in the table, if anything; an icon's menu
    /// is its own button's.
    func propertyTarget(at point: CGPoint, in textView: MobileTextView) -> PropertyGeometry.Target? {
        allTargets(in: textView).first {
            if case .typeMenu = $0.target { return false }
            return $0.rect.contains(point)
        }?.target
    }

    private func allTargets(in textView: MobileTextView) -> [(rect: CGRect, target: PropertyGeometry.Target)] {
        PropertyGeometry.targets(
            in: textView.text ?? "", layout: layout, manager: textView.textLayoutManager, origin: origin(of: textView),
            asText: propertiesAsText, folded: propertiesFolded, offersSource: true, slop: 6
        )
    }

    /// The property row a single tap at `point` lands in, and whether in
    /// its value's column. Such a tap is the editor's, not UIKit's: UIKit
    /// put the caret on hidden text (a folded item, the closing fence, the
    /// gap) and moved it again after any correction, which is the race the
    /// Mac avoids by settling a click once it is over.
    func propertyRow(at point: CGPoint, in textView: MobileTextView) -> (line: Int, inValue: Bool)? {
        guard !propertiesAsText, propertyTarget(at: point, in: textView) == nil,
              !isOnPropertyControl(at: point, in: textView)
        else { return nil }
        return PropertyGeometry.column(
            at: point, layout: layout, manager: textView.textLayoutManager, origin: origin(of: textView)
        )
    }

    /// A tap in a row: the caret where it landed, kept to its column, an
    /// empty value given its space, a list's place after its pills.
    /// True when it showed the text's menu, the caret being there already.
    @discardableResult
    func tapRow(_ line: Int, inValue: Bool, at point: CGPoint, in textView: MobileTextView) -> Bool {
        textView.refusesFocus = false
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        guard let row = PropertySurface.row(startingAt: line, in: textView.text) else { return false }
        let before = textView.isFirstResponder && textView.selectedRange.length == 0 ? textView.selectedRange.location : nil
        let landed = textView.closestPosition(to: point).map {
            textView.offset(from: textView.beginningOfDocument, to: $0)
        } ?? row.valueEnd
        var caret = min(max(landed, row.range.location), row.valueEnd)
        if let settled = PropertySurface.settlingTap(
            onLineAt: line, inValue: inValue, caret: caret, normal: false, in: textView.text
        ) {
            for step in settled.edits { replace(step.edit.range, with: step.edit.replacement, in: textView) }
            if let spaced = settled.spacedLine { properties.leaving.spacedValueLine = spaced }
            caret = settled.caret
        }
        if let target = PropertySurface.caretOutOfColonGap(
            in: textView.text, caret: caret, previous: nil, clicked: (line, inValue), leavingInsert: false, normal: false
        ) {
            caret = target
        }
        caret = PropertySurface.caretOffFoldedItem(in: textView.text, caret: caret) ?? caret
        properties.lastCaret = caret
        // A tap on the caret where it already is asks for the text's menu,
        // as anywhere else in a text view.
        if caret == before {
            showEditMenu(at: point, in: textView)
            return true
        }
        properties.editMenu?.dismissMenu()
        textView.selectedRange = NSRange(location: caret, length: 0)
        restyle(textView)
        updateSuggestions()
        return false
    }

    /// A secondary click on a row: the caret placed as a tap places it,
    /// then the text's menu with the row's in it.
    @objc func pressedRow(_ recognizer: UIGestureRecognizer) {
        guard let textView, recognizer.state == .recognized else { return }
        let point = recognizer.location(in: textView)
        guard let row = propertyRow(at: point, in: textView) else { return }
        if !tapRow(row.line, inValue: row.inValue, at: point, in: textView) {
            showEditMenu(at: point, in: textView)
        }
    }

    private func showEditMenu(at point: CGPoint, in textView: MobileTextView) {
        let interaction = properties.editMenu ?? {
            let interaction = UIEditMenuInteraction(delegate: self)
            textView.addInteraction(interaction)
            properties.editMenu = interaction
            return interaction
        }()
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func performProperty(_ target: PropertyGeometry.Target, in textView: MobileTextView) {
        switch target {
        case .fold:
            if propertiesFolded { PropertyEditorState.foldedNotes.remove(noteKey) }
            else { PropertyEditorState.foldedNotes.insert(noteKey) }
            restyle(textView)
        case .source:
            if propertiesAsText {
                PropertyEditorState.sourceNotes.remove(noteKey)
            } else {
                PropertyEditorState.sourceNotes.insert(noteKey)
                // Into the YAML, at the end of its first line, since leaving
                // it is what brings the table back.
                if let first = PropertyEditing.rows(in: textView.text).first {
                    textView.refusesFocus = false
                    if !textView.isFirstResponder { textView.becomeFirstResponder() }
                    textView.selectedRange = NSRange(location: first.valueEnd, length: 0)
                }
            }
            restyle(textView)
        case .removeItem(let start, let index):
            for step in PropertySurface.removingItem(at: index, fromListAt: start, in: textView.text) {
                applyKeepingCaret(step.edit, in: textView)
            }
            restyle(textView)
        case .addProperty:
            addProperty()
        case .typeMenu:
            break
        }
    }

    /// Add Property: a new row at the end of the frontmatter, which is made
    /// first when the note has none, with the keyboard up and the vault's
    /// keys offered before anything is typed.
    func addProperty() {
        guard let textView else { return }
        for edit in PropertySurface.tidyingAll(in: textView.text) { applyKeepingCaret(edit, in: textView) }
        properties.leaving.bareKeyLine = nil
        let adding = PropertySurface.addingProperty(in: textView.text)
        if let edit = adding.edit {
            let adapted = edit.adapted(to: LineEnding(of: textView.text))
            replace(adapted.range, with: adapted.replacement, in: textView)
        } else {
            properties.leaving.blankRow = adding.caret
        }
        textView.refusesFocus = false
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        textView.selectedRange = NSRange(location: adding.caret, length: 0)
        properties.keyMenuRow = adding.caret
        restyle(textView)
        textView.scrollRangeToVisible(textView.selectedRange)
        updateSuggestions()
    }

    // MARK: The caret

    /// Run once a selection change has settled, before the restyle: a tap
    /// settled into its row's column, the caret off a fence, out of the
    /// hidden gap and off a folded item's line; then what the rows it left
    /// need. A move here comes back through the next pass, so each pass
    /// makes at most one.
    func settlePropertyCaret(in textView: MobileTextView) {
        guard textView.isFirstResponder, textView.markedTextRange == nil else { return }
        defer { properties.lastCaret = textView.selectedRange.location }
        if textView.selectedRange.length == 0, !propertiesAsText {
            let text = textView.text ?? ""
            let caret = textView.selectedRange.location
            if let target = PropertySurface.caretOffFences(in: text, caret: caret, previous: properties.lastCaret, normal: false) {
                textView.selectedRange = NSRange(location: target, length: 0)
                return
            }
            if let block = PropertyEditing.blockRange(in: text) {
                // A caret arriving in folded properties opens them: on a
                // folded row it would stand invisible.
                if propertiesFolded, caret > 0, caret < NSMaxRange(block) {
                    PropertyEditorState.foldedNotes.remove(noteKey)
                }
            }
            if let target = PropertySurface.caretOutOfColonGap(
                in: text, caret: caret, previous: properties.lastCaret,
                clicked: nil, leavingInsert: false, normal: false
            ) {
                textView.selectedRange = NSRange(location: target, length: 0)
                return
            }
            if let target = PropertySurface.caretOffFoldedItem(in: text, caret: caret) {
                textView.selectedRange = NSRange(location: target, length: 0)
                return
            }
        }
        // YAML shown for this note goes back to the table once the caret
        // leaves it, as markup goes back once the caret leaves its line.
        if propertiesAsText, let block = PropertyEditing.blockRange(in: textView.text),
           textView.selectedRange.length == 0, textView.selectedRange.location >= NSMaxRange(block) {
            PropertyEditorState.sourceNotes.remove(noteKey)
        }
        let actions = properties.leaving.caretMoved(
            to: textView.selectedRange, in: textView.text, normal: false, asText: propertiesAsText
        )
        for action in actions {
            if case .removeBlankRow = action { properties.keyMenuRow = nil }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.carryOut(action, in: textView)
            }
        }
    }

    /// The keyboard went down: every row is left at once, before the save
    /// that follows, so a blank row, a value's space or a typed item is not
    /// written as it stood.
    func leaveProperties(in textView: MobileTextView) {
        let away = (textView.text as NSString).length
        let actions = properties.leaving.caretMoved(
            to: NSRange(location: away, length: 0), in: textView.text, normal: false, asText: propertiesAsText
        )
        for action in actions { carryOut(action, in: textView, caret: away) }
        properties.leaving = PropertyLeaving()
        properties.keyMenuRow = nil
    }

    /// One thing leaving a row asks for, against the text as it is now.
    private func carryOut(_ action: PropertyLeaving.Action, in textView: MobileTextView, caret: Int? = nil) {
        guard textView.markedTextRange == nil else { return }
        let text = textView.text ?? ""
        let at = caret ?? textView.selectedRange.location
        switch action {
        case .removeBlankRow(let start):
            guard let range = PropertySurface.removingBlankRow(at: start, caret: at, in: text) else { return }
            applyKeepingCaret(MarkdownEditing.Edit(range: range, replacement: "", selection: NSRange(location: at, length: 0)), in: textView)
        case .unspaceValue(let start):
            guard let range = PropertySurface.unspacingValue(onLineAt: start, in: text) else { return }
            applyKeepingCaret(MarkdownEditing.Edit(range: range, replacement: "", selection: NSRange(location: at, length: 0)), in: textView)
        case .spaceValue(let start):
            guard caret == nil, textView.isFirstResponder,
                  let edit = PropertySurface.spacingValue(onLineAt: start, caret: at, normal: false, in: text)
            else { return }
            replace(edit.range, with: edit.replacement, in: textView)
            properties.leaving.spacedValueLine = start
            textView.selectedRange = edit.selection
        case .tidyRow(let start):
            guard let edit = PropertySurface.tidyingRow(at: start, caret: at, in: text) else { return }
            applyKeepingCaret(edit, in: textView)
        case .commitItem(let start):
            guard let edit = PropertySurface.committingTypedItem(onKeyLineAt: start, in: text) else { return }
            applyKeepingCaret(edit, in: textView)
        }
        restyle(textView)
    }

    /// An edit that leaves the caret where it was, moved along by it.
    func applyKeepingCaret(_ edit: MarkdownEditing.Edit, in textView: MobileTextView) {
        let edit = edit.adapted(to: LineEnding(of: textView.text))
        let selection = textView.selectedRange
        replace(edit.range, with: edit.replacement, in: textView)
        if selection.length == 0 {
            let caret = min(PropertySurface.caret(selection.location, keptThrough: edit), (textView.text as NSString).length)
            textView.selectedRange = NSRange(location: caret, length: 0)
        }
    }

    /// Where the caret is drawn while a list's next item is typed: after
    /// it, past the pills, rather than on the key line the text is on.
    func listCaretRect(in textView: MobileTextView) -> CGRect? {
        guard !propertiesAsText, textView.isFirstResponder else { return nil }
        return PropertyGeometry.listCaret(
            in: textView.text ?? "", selection: textView.selectedRange, layout: layout,
            manager: textView.textLayoutManager, origin: origin(of: textView), normal: false
        )
    }

    // MARK: Typing

    /// What the keyboard types into the table that is not plain typing:
    /// into the hidden gap it goes to the value, Return, Tab and a space in
    /// a list make a pill, Tab after a key goes to its value, and Backspace
    /// takes the last pill but never the hidden colon. True when handled.
    func handlePropertyTyping(_ typed: String, in range: NSRange, of textView: MobileTextView) -> Bool {
        guard !properties.replacing, !propertiesAsText, textView.markedTextRange == nil else { return false }
        let text = textView.text ?? ""
        let selection = textView.selectedRange
        guard selection.length == 0, let block = PropertyEditing.blockRange(in: text),
              range.location < NSMaxRange(block)
        else { return false }
        if typed.isEmpty, range.length == 1 {
            let forward = range.location == selection.location
            if PropertySurface.deletionCrossesColonGap(selection: selection, forward: forward, in: text),
               forward || PropertyListContext.detect(in: text, selection: selection) == nil {
                return true
            }
            if !forward, let edit = PropertySurface.backspaceRemovingItem(selection: selection, in: text) {
                apply(edit)
                return true
            }
            return false
        }
        guard range.length == 0, range.location == selection.location else { return false }
        let edit: MarkdownEditing.Edit?
        switch typed {
        case " ": edit = PropertySurface.tagEndedBySpace(selection: selection, in: text)
        case "\n": edit = PropertySurface.listReturn(selection: selection, in: text)?.edit
        case "\t":
            edit = PropertySurface.itemAddedByTab(selection: selection, in: text)
                ?? PropertySurface.movingToValue(selection: selection, in: text)
        default: edit = nil
        }
        if let edit = edit ?? PropertySurface.valueInsertion(of: typed, selection: selection, in: text) {
            apply(edit)
            updateSuggestions()
            return true
        }
        return false
    }

    /// ↑ and ↓ a property at a time, and ⌘⌫ deleting one, from a hardware
    /// keyboard, as on the Mac.
    func handlePropertyKey(_ key: UIKey) -> Bool {
        guard let textView, textView.isFirstResponder, !propertiesAsText, textView.selectedRange.length == 0,
              textView.markedTextRange == nil
        else { return false }
        let modifiers = key.modifierFlags.intersection([.command, .shift, .alternate, .control])
        let text = textView.text ?? ""
        let caret = textView.selectedRange.location
        switch key.keyCode {
        case .keyboardUpArrow, .keyboardDownArrow:
            guard modifiers.isEmpty,
                  let target = PropertySurface.rowMove(in: text, caret: caret, down: key.keyCode == .keyboardDownArrow)
            else { return false }
            textView.selectedRange = NSRange(location: target, length: 0)
            textView.scrollRangeToVisible(textView.selectedRange)
            return true
        case .keyboardDeleteOrBackspace:
            guard modifiers == .command, let edit = PropertySurface.deletingProperty(at: caret, in: text) else { return false }
            apply(edit)
            return true
        default:
            return false
        }
    }

    // MARK: Suggestions

    /// The vault's keys, or the key's values, for the strip; for `tags`,
    /// the vault's tags.
    func propertySuggestions(_ context: PropertyCompletionContext, in text: String, index: VaultIndex) -> [String] {
        if case .value(let key, let siblings) = context.part, ["tags", "tag"].contains(key.lowercased()) {
            let taken = Set(siblings.map { $0.lowercased() })
            return Array(TagCompletionContext(query: context.query, queryRange: context.queryRange)
                .suggestions(from: index.allTags)
                .filter { !taken.contains($0.lowercased()) && $0.lowercased() != context.query.lowercased() }
                .prefix(8))
        }
        let identity = ObjectIdentifier(index)
        let catalog: PropertyCatalog
        if let cached = properties.catalog, cached.index == identity {
            catalog = cached.catalog
        } else {
            catalog = index.propertyCatalog
            properties.catalog = (identity, catalog)
        }
        return Array(context.suggestions(from: catalog, in: text).prefix(8))
    }

    /// A suggestion taken: a key written with its colon, a value, or for a
    /// list a new pill.
    func acceptProperty(_ destination: String, in textView: MobileTextView) {
        let text = textView.text ?? ""
        let selection = textView.selectedRange
        if let list = PropertyListContext.detect(in: text, selection: selection) {
            apply(list.adding(destination, in: text))
        } else if let context = PropertyCompletionContext.detect(
            in: text, selection: selection, emptyKey: properties.keyMenuRow == selection.location
        ) {
            apply(context.accepting(destination))
        }
        properties.keyMenuRow = nil
    }

    // MARK: Drawn controls

    /// After every restyle: the fold arrow and `{}` beside the heading, a
    /// menu button over each row's icon, and the caret redrawn where the
    /// layout now puts a list's typed item.
    func layoutPropertyControls(in textView: MobileTextView) {
        let text = textView.text ?? ""
        let heading = PropertyGeometry.heading(
            in: text, layout: layout, manager: textView.textLayoutManager, origin: origin(of: textView),
            asText: propertiesAsText
        )
        let arrow = properties.foldArrow ?? makeImage(in: textView)
        properties.foldArrow = arrow
        let source = properties.sourceButton ?? makeImage(in: textView)
        properties.sourceButton = source
        let symbol = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        arrow.isHidden = heading == nil || propertiesAsText
        source.isHidden = heading == nil
        if let heading {
            arrow.frame = heading.arrow
            arrow.image = UIImage(systemName: propertiesFolded ? "chevron.right" : "chevron.down", withConfiguration: symbol)
            source.frame = heading.source
            source.image = UIImage(systemName: "curlybraces", withConfiguration: symbol)
            source.tintColor = propertiesAsText ? .tintColor : .tertiaryLabel
        }

        var live = Set<Int>()
        for case let (rect, .typeMenu(start)) in allTargets(in: textView) {
            live.insert(start)
            let button = properties.menuButtons[start] ?? makeMenuButton(in: textView)
            properties.menuButtons[start] = button
            // Left alone when nothing moved: a restyle comes as a menu opens,
            // and moving or restacking its button closed it.
            if button.frame != rect { button.frame = rect }
            button.tag = start
            let key = PropertySurface.key(onLineAt: start, in: text) ?? ""
            button.accessibilityLabel = key.isEmpty ? "Property" : "\(key) property"
        }
        for (start, button) in properties.menuButtons where !live.contains(start) {
            button.removeFromSuperview()
            properties.menuButtons[start] = nil
        }
        // Over the text's own views, which UIKit adds as it lays text out;
        // only when one has come above them.
        let controls: [UIView] = [arrow, source] + Array(properties.menuButtons.values)
        let lowest = controls.compactMap { textView.subviews.firstIndex(of: $0) }.min() ?? 0
        if textView.subviews[lowest...].contains(where: { view in !controls.contains { $0 === view } && !(view is UIImageView) }) {
            for control in controls { textView.bringSubviewToFront(control) }
        }
        // Placed again after the next layout pass while the heading or the
        // rows were not laid out yet.
        let rowsMissing = live.isEmpty && !propertiesAsText && !propertiesFolded && !PropertyEditing.rows(in: text).isEmpty
        properties.controlsPending = PropertyEditing.blockRange(in: text) != nil && (heading == nil || rowsMissing)
        // The caret's place after a list's typed item moves with the layout,
        // which lands after the edit that moved it.
        if PropertyEditing.blockRange(in: text) != nil {
            for interaction in textView.interactions {
                (interaction as? UITextSelectionDisplayInteraction)?.setNeedsSelectionUpdate()
            }
        }
    }

    /// After a layout pass: the controls placed, if the last restyle came
    /// before the heading was laid out.
    func placePendingPropertyControls(in textView: MobileTextView) {
        guard properties.controlsPending else { return }
        layoutPropertyControls(in: textView)
    }

    private func makeImage(in textView: UITextView) -> UIImageView {
        let image = UIImageView()
        image.contentMode = .center
        image.tintColor = .tertiaryLabel
        image.isUserInteractionEnabled = false
        image.isHidden = true
        textView.addSubview(image)
        return image
    }

    private func makeMenuButton(in textView: UITextView) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        // Made once, and asked for its items as it opens, by the row the
        // button is over now: replaced on every restyle, a menu being
        // opened was taken away.
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak button] completion in
            guard let self, let button else { return completion([]) }
            completion(self.propertyMenu(forLineAt: button.tag))
        }])
        button.showsMenuAsPrimaryAction = true
        textView.addSubview(button)
        return button
    }

    /// A property's menu, at its icon, as the Mac's: why it is red if it
    /// is, its type, Cut, Copy and Paste for the property whole, and Remove.
    func propertyMenu(forLineAt start: Int) -> [UIMenuElement] {
        guard let textView, let key = PropertySurface.key(onLineAt: start, in: textView.text) else { return [] }
        let types = PropertyTypes.types(in: renderContext?.vaultRoot)
        let current = PropertyTypes.type(of: key, in: types)
        var elements: [UIMenuElement] = []
        if let warning = PropertySurface.warning(forLineAt: start, in: textView.text, types: types) {
            elements.append(UIAction(title: warning, image: UIImage(systemName: "exclamationmark.triangle"),
                                     attributes: .disabled) { _ in })
        }
        elements.append(UIMenu(title: "Property type", image: UIImage(systemName: "info.circle"), children:
            PropertyType.pickable.map { type in
                UIAction(title: type.title, image: UIImage(systemName: type.symbol), state: current == type ? .on : .off) {
                    [weak self] _ in self?.pickType(type, for: key)
                }
            }))
        elements.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Cut Property", image: UIImage(systemName: "scissors")) { [weak self] _ in
                self?.copyProperty(atLineAt: start)
                self?.removeProperty(atLineAt: start)
            },
            UIAction(title: "Copy Property", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copyProperty(atLineAt: start)
            },
            UIAction(title: "Paste Property", image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: UIPasteboard.general.hasStrings ? [] : .disabled) { [weak self] _ in
                self?.pasteProperties(afterLineAt: start)
            },
        ]))
        elements.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.removeProperty(atLineAt: start)
            },
        ]))
        return elements
    }

    /// The text's own menu, from a long press or a tap on the caret, with
    /// the row's menu added when it is on a property: what a right-click
    /// gives on the Mac. A selection keeps its Cut, Copy and Paste first.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        menu(adding: suggestedActions, for: range, in: textView)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let textView else { return nil }
        return menu(adding: suggestedActions, for: textView.selectedRange, in: textView)
            ?? UIMenu(children: suggestedActions)
    }

    private func menu(adding suggested: [UIMenuElement], for range: NSRange, in textView: UITextView) -> UIMenu? {
        guard !propertiesAsText, let row = PropertySurface.row(at: range.location, in: textView.text),
              NSMaxRange(range) <= row.valueEnd
        else { return nil }
        let items = propertyMenu(forLineAt: row.range.location)
        guard !items.isEmpty else { return nil }
        return UIMenu(children: suggested + [
            UIMenu(title: "Property", image: UIImage(systemName: "list.bullet.rectangle"), children: items),
        ])
    }

    private func pickType(_ type: PropertyType, for key: String) {
        guard let textView, let root = renderContext?.vaultRoot else { return }
        do {
            try PropertyTypes.set(type, for: key, in: root)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        // The value follows a change between a single value and a list.
        if let edit = PropertyEditing.converting(key: key, toList: type.isList, in: textView.text) {
            applyKeepingCaret(edit, in: textView)
        }
        _ = PropertyTypes.types(in: root)
        restyle(textView)
    }

    private func copyProperty(atLineAt start: Int) {
        guard let textView, let property = PropertySurface.propertyText(atLineAt: start, in: textView.text) else { return }
        UIPasteboard.general.string = property.text
    }

    private func pasteProperties(afterLineAt start: Int) {
        guard let textView, let pasted = UIPasteboard.general.string,
              let edit = PropertySurface.pasting(pasted, afterLineAt: start, in: textView.text)
        else { return }
        applyKeepingCaret(edit, in: textView)
        restyle(textView)
    }

    private func removeProperty(atLineAt start: Int) {
        guard let textView, let edit = PropertySurface.removingProperty(atLineAt: start, in: textView.text) else { return }
        applyKeepingCaret(edit, in: textView)
        restyle(textView)
    }
}


