import ControlProtocol
import Foundation

enum PhoneAgentProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, openAICompatible
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex 登录" : "自定义模型 API" }
}

struct PhoneAgentConfiguration: Sendable {
    let provider: PhoneAgentProvider
    let model: String
    let baseURL: String
    let apiKey: String
    let codexPath: String
}

struct PhoneAgentHistory: Sendable {
    let summary: String
    let tool: String
    let arguments: [String: JSONValue]
    let result: String
}

struct PhoneAgentInput: Sendable {
    let goal: String
    let deviceName: String
    let platform: String
    let tools: [ToolDescriptor]
    let image: Data
    let mimeType: String
    let screenDescription: String
    let history: [PhoneAgentHistory]
    let step: Int
    var userReplies: [String] = []
    var applicationCatalog: String? = nil
}

/// One decision per fresh screen. A string holds the tool arguments so both
/// providers can use the same closed JSON schema without arbitrary properties.
struct PhoneAgentDecision: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case act, done, ask }
    let kind: Kind
    let summary: String
    let tool: String
    let argumentsJSON: String

    static let responseSchema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "properties": [
            "kind": ["type": "string", "enum": ["act", "done", "ask"]],
            "summary": ["type": "string"],
            "tool": ["type": "string"],
            "argumentsJSON": ["type": "string"],
        ],
        "required": ["kind", "summary", "tool", "argumentsJSON"],
    ]
}

protocol PhoneAgentPlanning: Sendable {
    func decide(_ input: PhoneAgentInput, configuration: PhoneAgentConfiguration) async throws -> PhoneAgentDecision
}

enum PhoneAgentStatus: String, Sendable {
    case idle, thinking, acting, completed, needsUser, stopping, stopped, failed
    var isRunning: Bool { [.thinking, .acting, .stopping].contains(self) }
    var title: String {
        switch self {
        case .idle: "就绪"
        case .thinking: "正在观察和思考"
        case .acting: "正在操作"
        case .completed: "已完成"
        case .needsUser: "等待补充或处理"
        case .stopping: "正在停止"
        case .stopped: "已停止"
        case .failed: "执行失败"
        }
    }
}

struct PhoneAgentStep: Identifiable, Sendable {
    let id: UUID
    let number: Int
    let summary: String
    let tool: String
    var result: String
    var planningSeconds: Double? = nil
    var executionSeconds: Double? = nil
}

struct PhoneAgentRun: Sendable {
    let goal: String
    var status: PhoneAgentStatus
    var steps: [PhoneAgentStep]
    var message: String
}
