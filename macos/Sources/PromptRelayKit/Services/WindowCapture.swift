import AppKit
import ScreenCaptureKit

/// Phase 9.4, Capture Final Window: one still image of one window that the
/// user picks in macOS's own content picker. The system shows the picker and
/// handles screen-capture consent; Prompt Relay never chooses a window, never
/// records, and never captures in the background. Nothing happens unless the
/// user starts it, and a cancelled or failed pick adds nothing.
public protocol WindowCapturing: AnyObject {
    @MainActor func captureWindow(completion: @escaping @MainActor (Result<WindowCapture.Shot, Error>?) -> Void)
    /// Auto-capture: the user picks the source window once (system picker);
    /// it is remembered for this app run only. nil: cancelled.
    @MainActor func chooseSource(completion: @escaping @MainActor (Result<String, Error>?) -> Void)
    /// One still image of the chosen source window; fails if none was chosen
    /// or the window is gone (never another window or the screen).
    @MainActor func captureSource(completion: @escaping @MainActor (Result<WindowCapture.Shot, Error>) -> Void)
    @MainActor func forgetSource()
}

public enum WindowCaptureError: Error, Equatable { case failed, noImage, noSource }

@MainActor
public final class WindowCapture: NSObject, WindowCapturing, SCContentSharingPickerObserver {
    public struct Shot: Equatable, Sendable {
        public let png: Data
        /// The picked window's app and title, for the file name only.
        public let label: String
    }

    private var completion: (@MainActor (Result<Shot, Error>?) -> Void)?
    private var sourceCompletion: (@MainActor (Result<String, Error>?) -> Void)?
    /// The window the user picked for auto-capture (memory only).
    private var source: SCContentFilter?

    public func chooseSource(completion: @escaping @MainActor (Result<String, Error>?) -> Void) {
        guard self.completion == nil, sourceCompletion == nil else { return }
        sourceCompletion = completion
        present()
    }

    public func forgetSource() { source = nil }

    public func captureSource(completion: @escaping @MainActor (Result<Shot, Error>) -> Void) {
        guard let source else { completion(.failure(WindowCaptureError.noSource)); return }
        Task { @MainActor in
            do { completion(.success(try await Self.shot(source))) } catch {
                self.source = nil   // the window is gone: never fall back to anything else
                completion(.failure(error))
            }
        }
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

    static func shot(_ filter: SCContentFilter) async throws -> Shot {
        let config = SCStreamConfiguration()
        let size = pixelSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw WindowCaptureError.noImage
        }
        return Shot(png: png, label: "Window")
    }

    public func captureWindow(completion: @escaping @MainActor (Result<Shot, Error>?) -> Void) {
        guard self.completion == nil, sourceCompletion == nil else { return }
        self.completion = completion
        present()
    }

    private func present() {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        config.allowsChangingSelectedContent = false
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

    private func finishSource(_ result: Result<String, Error>?) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        let done = sourceCompletion
        sourceCompletion = nil
        done?(result)
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in if self.sourceCompletion != nil { self.finishSource(nil) } else { self.finish(nil) } }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            if self.sourceCompletion != nil { self.finishSource(.failure(error)) } else { self.finish(.failure(error)) }
        }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                                 for stream: SCStream?) {
        Task { @MainActor in
            if self.sourceCompletion != nil {
                self.source = filter
                self.finishSource(.success("the window you picked"))
                return
            }
            do { self.finish(.success(try await Self.shot(filter))) } catch { self.finish(.failure(error)) }
        }
    }
}
