import Foundation

/// Loading state of one piece of UI data.
public enum LoadState<Value> {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(CoreError, previous: Value?)

    public var value: Value? {
        switch self {
        case .idle: return nil
        case .loading(let previous): return previous
        case .loaded(let value): return value
        case .failed(_, let previous): return previous
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var error: CoreError? {
        if case .failed(let error, _) = self { return error }
        return nil
    }

    /// Start loading, keeping what is on screen to avoid flicker.
    public var reloading: LoadState<Value> { .loading(previous: value) }

    public func failing(_ error: CoreError) -> LoadState<Value> { .failed(error, previous: value) }
}

extension LoadState: Equatable where Value: Equatable {}
