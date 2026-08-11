import Foundation

public enum VimMode: String, Codable, Sendable {
    case normal = "NORMAL"
    case insert = "INSERT"
    case replace = "REPLACE"
    case visual = "VISUAL"
    case visualLine = "VISUAL LINE"
    case visualBlock = "VISUAL BLOCK"
    case blockInsert = "INSERT BLOCK"
    case operatorPending = "OPERATOR"
}

public enum VimKey: Equatable, Sendable {
    case character(String)
    case escape
    case enter
    case backspace
    case delete
    case left
    case right
    case up
    case down
    case tab
    case control(Character)
}

public struct VimSnapshot: Sendable {
    public var text: String
    public var selection: NSRange

    public init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
}

public struct VimEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public enum VimHostAction: Equatable, Sendable {
    case undo
    case redo
    case scrollCenter
    case scrollTop
    case scrollBottom
    case pageUp
    case pageDown
    case beginSearch(backward: Bool)
    case nextSearch(backward: Bool)
    case searchWord(query: String, backward: Bool, origin: Int)
}

public struct VimOutput: Sendable {
    public var consumed: Bool
    public var mode: VimMode
    public var edits: [VimEdit]
    public var selection: NSRange?
    public var selections: [NSRange]?
    public var hostAction: VimHostAction?
    public var message: String?

    public init(
        consumed: Bool,
        mode: VimMode,
        edits: [VimEdit] = [],
        selection: NSRange? = nil,
        selections: [NSRange]? = nil,
        hostAction: VimHostAction? = nil,
        message: String? = nil
    ) {
        self.consumed = consumed
        self.mode = mode
        self.edits = edits
        self.selection = selection
        self.selections = selections
        self.hostAction = hostAction
        self.message = message
    }
}

public struct VimRegister: Equatable, Sendable {
    public var text: String
    public var linewise: Bool

    public init(text: String = "", linewise: Bool = false) {
        self.text = text
        self.linewise = linewise
    }
}
