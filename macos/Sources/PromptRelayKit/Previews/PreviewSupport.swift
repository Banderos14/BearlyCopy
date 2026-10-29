#if DEBUG
import AppKit
import SwiftUI

/// Sample data for SwiftUI Previews in Xcode. Debug builds only; it never
/// runs the Core and never touches the user's history or clipboard.
public final class PreviewCore: CoreProviding, @unchecked Sendable {
    public static let answer = """
    Готово. Я добавил компактный островок в чёлку и оставил полный ответ в окне.

    ```swift
    try clipboard.copy(text)
    ```

    Claude сообщает: тесты прошли — это не проверено Prompt Relay.
    """

    public init() {}

    private func decode<T: Decodable>(_ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private var session: String {
        """
        {"session_id":"1aac4f95-88cc-4017-aef3-8b6e268c9cb7","session_key":"1aac4f95-88cc-4017-aef3-8b6e268c9cb7",
         "project":{"path":"/Users/me/code/prompt-relay","name":"prompt-relay"},"first_event_at":"2026-10-29T16:00:00.000000Z",
         "last_event_at":"2026-10-29T16:13:51.000000Z","event_count":6,"turn_count":3,"cwds":[],
         "last_turn":{"index":3,"status":"stop_received"},"integrity":{"corrupt_lines":0,"unsupported_lines":0,"foreign_lines":0}}
        """
    }

    private func turn(_ i: Int, text: String?, full: Bool) -> String {
        let response = text.map { t -> String in
            let enc = String(data: try! JSONEncoder().encode(t), encoding: .utf8)!
            let preview = String(data: try! JSONEncoder().encode(String(t.prefix(200))), encoding: .utf8)!
            return "{\"preview\":\(preview),\"truncated\":\(t.count > 200),\"char_count\":\(t.unicodeScalars.count),\"utf8_bytes\":\(t.utf8.count),\"prompt_id\":\"p\(i)\",\"received_at\":\"2026-10-29T16:1\(i):00.000000Z\"\(full ? ",\"text\":\(enc)" : "")}"
        } ?? "null"
        let status = text == nil ? "api_error" : "stop_received"
        let error = text == nil ? #"{"type":"rate_limit","details":null,"message":"API Error: Rate limit reached"}"# : "null"
        return """
        {"index":\(i),"status":"\(status)","link":"prompt_id","request":null,"final_response":\(response),
         "response_event_count":1,"background_tasks":{"reported":true,"count":0},"error":\(error),"candidate_request_turns":[]}
        """
    }

    private func text(for index: Int) -> String? {
        switch index {
        case 1: return "Привет из плагина 🚀"
        case 2: return nil
        default: return Self.answer
        }
    }

    public func projects() async throws -> CoreResult<ProjectsData> {
        CoreResult(data: decode("""
        {"projects":[{"path":"/Users/me/code/prompt-relay","name":"prompt-relay","capture_enabled":true,"explicitly_enabled":true,
          "session_count":1,"last_event_at":"2026-10-29T16:13:51.000000Z"}],
         "settings":{"retention_days":null,"automatic_deletion":false}}
        """), warnings: [])
    }

    public func sessions(project: String?) async throws -> CoreResult<SessionsData> {
        CoreResult(data: decode("{\"project_filter\":null,\"sessions\":[\(session)]}"), warnings: [])
    }

    public func turns(sessionKey: String) async throws -> CoreResult<TurnsData> {
        let turns = (1...3).map { turn($0, text: text(for: $0), full: false) }.joined(separator: ",")
        return CoreResult(data: decode("{\"session\":\(session),\"turns\":[\(turns)]}"), warnings: [])
    }

    public func show(sessionKey: String, turn index: Int) async throws -> CoreResult<ShowData> {
        CoreResult(data: decode("{\"session\":\(session),\"turn\":\(turn(index, text: text(for: index), full: true))}"), warnings: [])
    }

    public func context(sessionKey: String, turn: Int) async throws -> CoreResult<ContextData> {
        throw CoreError.api(code: "not_found", message: "Previews do not build context packets")
    }

    public func doctor() async throws -> CoreResult<DoctorData> {
        throw CoreError.api(code: "internal_error", message: "Previews do not run doctor")
    }
}

@MainActor
public enum PreviewFixtures {
    public static func model() -> AppModel {
        let model = AppModel(core: PreviewCore(),
                             clipboard: ClipboardService(pasteboard: NSPasteboard(name: NSPasteboard.Name("PromptRelayPreview"))),
                             dataDirectory: nil)
        Task { await model.refreshNow() }
        return model
    }

    public static let actions = SurfaceActions(openWindow: {}, openStatus: {}, quit: {})

    public static func notch(expanded: Bool, indicator: Bool = false) -> NotchPresentation {
        let p = NotchPresentation()
        p.notchSize = CGSize(width: 185, height: 32)
        p.isExpanded = expanded
        p.showsIndicator = indicator
        p.contentHeight = 190
        return p
    }
}

#Preview("Notch · expanded") {
    NotchRootView(model: PreviewFixtures.model(), presentation: PreviewFixtures.notch(expanded: true),
                  interaction: NotchInteraction(scheduler: MainQueueScheduler()), actions: PreviewFixtures.actions)
        .frame(width: 428, height: 260)
        .background(Color.gray.opacity(0.4))
}

#Preview("Notch · compact, answer ready") {
    NotchRootView(model: PreviewFixtures.model(), presentation: PreviewFixtures.notch(expanded: false, indicator: true),
                  interaction: NotchInteraction(scheduler: MainQueueScheduler()), actions: PreviewFixtures.actions)
        .frame(width: 237, height: 32)
        .background(Color.gray.opacity(0.4))
}

#Preview("Menu-bar panel") {
    MenuPanelView(model: PreviewFixtures.model(), actions: PreviewFixtures.actions)
}

#Preview("Main window") {
    MainWindowView(model: PreviewFixtures.model(), actions: PreviewFixtures.actions)
}
#endif
