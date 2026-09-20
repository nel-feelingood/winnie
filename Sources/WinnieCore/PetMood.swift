import Foundation

/// Sprite names double as the file names the artist delivers (`idle.png`, ...).
public enum PetState: String, CaseIterable, Sendable {
    case idle, hover, thinking, talking, drag, error, sleep
}

public enum ChatActivity: Equatable, Sendable {
    case none, thinking, talking, error
}

/// Resolves competing inputs into the one sprite to show. Pure so the
/// priority order can be tested without a window.
public struct PetMood: Equatable, Sendable {
    public var isDragging = false
    public var isHovering = false
    public var isAsleep = false
    public var activity: ChatActivity = .none

    public init() {}

    public var state: PetState {
        if isDragging { return .drag }
        switch activity {
        case .error: return .error
        case .thinking: return .thinking
        case .talking: return .talking
        case .none: break
        }
        if isHovering { return .hover }
        return isAsleep ? .sleep : .idle
    }
}
