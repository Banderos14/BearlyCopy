import AppKit
import XCTest
@testable import PromptRelayKit

/// Phase 14 with the real Core (Phase 13 fixtures): an auto screenshot goes
/// into a Context Pack only when it is checked; it is image data held in
/// memory, labelled as BearlyCopy's screenshot, never as the agent's file.
extension Phase13Tests {
    func testContextPackTakesOnlyCheckedAutoScreenshots() async throws {
        try claude("s1", "p1", "Make the report", "Report done.")
        let model = await makeModel()
        let ref = try XCTUnwrap(refs(model).first)
        model.addToPack(ref)
        let unchecked = try store.addEphemeralImage(TypedAttachmentTests.png(.systemRed), name: "Auto screenshot Claude Desktop 1.png",
                                                    to: ref, source: .windowCapture, sourceProvider: .claudeCode, selected: false)
        model.attachmentsVersion += 1
        await model.prepareContextPack()
        var pack = try XCTUnwrap(model.contextPack.pack)
        XCTAssertTrue(pack.attachments.isEmpty, "unchecked: not in the pack")
        XCTAssertFalse(pack.text.contains("Auto screenshot"))

        model.setSelected(unchecked, true)
        await model.prepareContextPack()
        pack = try XCTUnwrap(model.contextPack.pack)
        XCTAssertEqual(pack.attachments.map(\.availability), [.memoryOnly])
        XCTAssertTrue(pack.text.contains("Auto screenshot Claude Desktop 1.png"))
        XCTAssertFalse(pack.manifest.json().contains("/Users/"), "no paths in the manifest")
        guard case .image(let img)? = model.contextPackDragPayloads().last else { return XCTFail("image data, not a file") }
        XCTAssertNil(img.file)
        XCTAssertTrue(ReviewPack.origin(unchecked).hasPrefix("auto screenshot of the window the user linked"))
        XCTAssertFalse(ReviewPack.origin(unchecked).contains("written by"), "never presented as the agent's file")
    }
}
