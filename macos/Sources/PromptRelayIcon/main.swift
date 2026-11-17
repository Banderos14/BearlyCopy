import AppKit
import PromptRelayKit

// Phase 16: writes the application icon's .iconset from Bearly's vector
// drawing (`AppIcon`). Used by scripts/make-app-icon.sh; not part of the app.
//
//   swift run --package-path macos PromptRelayIcon <out.iconset> [preview.png]
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: PromptRelayIcon <out.iconset> [preview-1024.png]\n".utf8))
    exit(2)
}
MainActor.assumeIsolated {
    do {
        try AppIcon.writeIconset(to: URL(fileURLWithPath: args[1], isDirectory: true))
        if args.count >= 3, let png = AppIcon.pngData(pixels: 1024) {
            try png.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        }
    } catch {
        FileHandle.standardError.write(Data("PromptRelayIcon: \(error)\n".utf8))
        exit(1)
    }
}
