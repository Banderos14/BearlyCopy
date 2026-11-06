import AppKit
import ScreenCaptureKit

/// Phase 9.4, Capture Final Window: one still image of one window that the
/// user picks in macOS's own content picker. The system shows the picker and
/// handles screen-capture consent; Prompt Relay never chooses a window, never
/// lists windows, never records, and never captures the screen. Nothing
/// happens unless the user starts it, and a cancelled or failed pick adds
/// nothing.
///
/// Phase 14: auto screenshots use windows the user picked the same way, one
/// per link (`PickedWindow`), kept for this app run only. Prompt Relay's own
/// windows are excluded from the picker.
public protocol WindowCapturing: AnyObject {
    /// Manual: the picker, then one still image. nil: cancelled.
    @MainActor func captureWindow(completion: @escaping @MainActor (Result<WindowCapture.Shot, Error>?) -> Void)
    /// Auto screenshots: the user picks a window to link. nil: cancelled.
    @MainActor func pickWindow(completion: @escaping @MainActor (Result<PickedWindow, Error>?) -> Void)
    /// One still image of a picked window; fails if it is gone (never
    /// another window or the screen).
    @MainActor func capture(_ window: PickedWindow) async throws -> WindowCapture.Shot
    /// Drops what Prompt Relay holds for a picked window.
    @MainActor func forget(_ window: PickedWindow)
}

public enum WindowCaptureError: Error, Equatable {
    case failed, noImage, noSource
    /// macOS declined (screen-capture consent missing or revoked).
    case permissionDenied
}

@MainActor
public final class WindowCapture: NSObject, WindowCapturing, SCContentSharingPickerObserver {
    public struct Shot: Equatable, Sendable {
        public let png: Data
        /// The picked window's app and title, for the file name only.
        public let label: String
        /// Phase 14: small grayscale thumbnail for the settle check (memory only).
        public var fingerprint: [UInt8]? = nil

        public init(png: Data, label: String, fingerprint: [UInt8]? = nil) {
            self.png = png; self.label = label; self.fingerprint = fingerprint
        }
    }

    private var completion: (@MainActor (Result<Shot, Error>?) -> Void)?
    private var pickCompletion: (@MainActor (Result<PickedWindow, Error>?) -> Void)?
    /// Picked windows for auto screenshots (memory only).
    private var filters: [String: SCContentFilter] = [:]

    public func pickWindow(completion: @escaping @MainActor (Result<PickedWindow, Error>?) -> Void) {
        guard self.completion == nil, pickCompletion == nil else { return }
        pickCompletion = completion
        present()
    }

    public func forget(_ window: PickedWindow) { filters[window.handle] = nil }

    public func capture(_ window: PickedWindow) async throws -> Shot {
        guard let filter = filters[window.handle] else { throw WindowCaptureError.noSource }
        do {
            return try await Self.shot(filter)
        } catch {
            let mapped = Self.map(error)
            // The window is gone: never fall back to anything else.
            if mapped != .permissionDenied { filters[window.handle] = nil }
            throw mapped
        }
    }

    /// ScreenCaptureKit's errors in Prompt Relay's words.
    nonisolated static func map(_ error: Error) -> WindowCaptureError {
        if let own = error as? WindowCaptureError { return own }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue
            || ns.code == SCStreamError.missingEntitlements.rawValue { return .permissionDenied }
        return .failed
    }

    /// Phase 10: the longest side of a snapshot in pixels. A Retina window
    /// stays sharp; a 6K full-screen window does not cost 80 MB of memory.
    nonisolated public static let maxPixelSide: CGFloat = 3200

    /// Pixel size for a window of `points` at `scale`, capped at `maxPixelSide`.
    nonisolated static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var w = points.width * scale, h = points.height * scale
        let longest = max(w, h)
        if longest > maxPixelSide { w *= maxPixelSide / longest; h *= maxPixelSide / longest }
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    /// Phase 14: nonisolated, so the capture, the PNG encoding (up to
    /// 3200 px) and the thumbnail run off the main thread.
    nonisolated static func shot(_ filter: SCContentFilter) async throws -> Shot {
        let config = SCStreamConfiguration()
        // The window's own scale (an external display's, not this one's).
        let size = pixelSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw WindowCaptureError.noImage
        }
        return Shot(png: png, label: "Window", fingerprint: CaptureStability.fingerprint(image))
    }

    public func captureWindow(completion: @escaping @MainActor (Result<Shot, Error>?) -> Void) {
        guard self.completion == nil, pickCompletion == nil else { return }
        self.completion = completion
        present()
    }

    private func present() {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        config.allowsChangingSelectedContent = false
        // Phase 14: Prompt Relay never captures itself instead of the agent.
        if let own = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [own] }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        picker.present(using: .window)
    }

    private func finish(_ result: Result<Shot, Error>?) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let done = completion
        completion = nil
        done?(result)
    }

    private func finishPick(_ result: Result<PickedWindow, Error>?) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let done = pickCompletion
        pickCompletion = nil
        done?(result)
    }

    /// What macOS says about the picked window (15.2+); never its contents.
    private static func describe(_ filter: SCContentFilter) -> (label: String, id: UInt32?) {
        if #available(macOS 15.2, *), let window = filter.includedWindows.first {
            let app = window.owningApplication?.applicationName ?? ""
            let label = app.isEmpty ? "the window you picked" : "\(app) window"
            return (label, window.windowID)
        }
        return ("the window you picked", nil)
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in if self.pickCompletion != nil { self.finishPick(nil) } else { self.finish(nil) } }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            if self.pickCompletion != nil { self.finishPick(.failure(Self.map(error))) } else { self.finish(.failure(error)) }
        }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                                 for stream: SCStream?) {
        Task { @MainActor in
            if self.pickCompletion != nil {
                let handle = UUID().uuidString
                self.filters[handle] = filter
                let (label, id) = Self.describe(filter)
                self.finishPick(.success(PickedWindow(handle: handle, label: label, windowID: id)))
                return
            }
            do { self.finish(.success(try await Self.shot(filter))) } catch { self.finish(.failure(error)) }
        }
    }
}
