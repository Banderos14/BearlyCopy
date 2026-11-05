import AppKit
import ScreenCaptureKit

/// Phase 9.4, Capture Final Window: one still image of one window that the
/// user picks in macOS's own content picker. The system shows the picker and
/// handles screen-capture consent; Prompt Relay never chooses a window, never
/// records, and never captures in the background. Nothing happens unless the
/// user starts it, and a cancelled or failed pick adds nothing.
public protocol WindowCapturing: AnyObject {
    @MainActor func captureWindow(completion: @escaping @MainActor (Result<WindowCapture.Shot, Error>?) -> Void)
}

public enum WindowCaptureError: Error, Equatable { case failed, noImage }

@MainActor
public final class WindowCapture: NSObject, WindowCapturing, SCContentSharingPickerObserver {
    public struct Shot: Equatable, Sendable {
        public let png: Data
        /// The picked window's app and title, for the file name only.
        public let label: String
    }

    private var completion: (@MainActor (Result<Shot, Error>?) -> Void)?

    public func captureWindow(completion: @escaping @MainActor (Result<Shot, Error>?) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
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

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                                 for stream: SCStream?) {
        Task { @MainActor in
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = max(1, Int(filter.contentRect.width * scale))
            config.height = max(1, Int(filter.contentRect.height * scale))
            config.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let rep = NSBitmapImageRep(cgImage: image)
                guard let png = rep.representation(using: .png, properties: [:]) else { throw WindowCaptureError.noImage }
                self.finish(.success(Shot(png: png, label: "Window")))
            } catch {
                self.finish(.failure(error))
            }
        }
    }
}
