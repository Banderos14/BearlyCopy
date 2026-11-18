import Foundation

/// Spins the main run loop for `seconds`. A plain (non-async) function, so async tests can call it
/// without the "run(until:) is unavailable from asynchronous contexts" warning (an error in Swift 6).
func spinMainRunLoop(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}
