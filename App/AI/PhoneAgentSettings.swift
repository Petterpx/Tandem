import Foundation
import Observation
import Security

/// Only non-secret preferences go into UserDefaults. API credentials stay in Keychain.
@MainActor @Observable
final class PhoneAgentSettings {
    private let defaults: UserDefaults
    private static let keychainService = "dev.tandem.phone-agent"
    private static let keychainAccount = "openai-compatible-api-key"

    var provider: PhoneAgentProvider { didSet { defaults.set(provider.rawValue, forKey: "phoneAgent.provider") } }
    var codexModel: String { didSet { defaults.set(codexModel, forKey: "phoneAgent.codexModel") } }
    var apiModel: String { didSet { defaults.set(apiModel, forKey: "phoneAgent.apiModel") } }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "phoneAgent.baseURL") } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "phoneAgent.codexPath") } }
    private(set) var apiKey: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = PhoneAgentProvider(rawValue: defaults.string(forKey: "phoneAgent.provider") ?? "") ?? .codex
        codexModel = defaults.string(forKey: "phoneAgent.codexModel") ?? "gpt-6.1-sol"
        apiModel = defaults.string(forKey: "phoneAgent.apiModel") ?? ""
        baseURL = defaults.string(forKey: "phoneAgent.baseURL") ?? "https://api.openai.com/v1"
        codexPath = defaults.string(forKey: "phoneAgent.codexPath") ?? Self.discoverCodex() ?? ""
        apiKey = Self.loadAPIKey()
    }

    var readinessMessage: String? {
        do { _ = try configuration(); return nil }
        catch { return error.localizedDescription }
    }

    func configuration() throws -> PhoneAgentConfiguration {
        let model = (provider == .codex ? codexModel : apiModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw PhoneAgentPlannerError.configuration("请填写支持图片输入的模型名称") }
        let path = NSString(string: codexPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        if provider == .codex {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw PhoneAgentPlannerError.configuration("请选择可执行的 Codex CLI；先在终端运行 codex login 登录 ChatGPT")
            }
        } else {
            let endpoint = try PhoneAgentPlanner.endpoint(baseURL)
            if !PhoneAgentPlanner.isLocal(endpoint), apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PhoneAgentPlannerError.configuration("请保存自定义模型 API Key")
            }
        }
        return PhoneAgentConfiguration(provider: provider, model: model, baseURL: baseURL, apiKey: apiKey, codexPath: path)
    }

    func saveAPIKey(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PhoneAgentPlanner.validAPIKey(clean) else {
            throw PhoneAgentPlannerError.configuration("API Key 不能包含控制字符")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.keychainService,
                                   kSecAttrAccount as String: Self.keychainAccount]
        if clean.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PhoneAgentPlannerError.configuration("无法从钥匙串删除 API Key（\(status)）")
            }
        } else {
            let attributes: [String: Any] = [kSecValueData as String: Data(clean.utf8)]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query.merging(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let addStatus = SecItemAdd(item as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw PhoneAgentPlannerError.configuration("无法将 API Key 保存到钥匙串（\(addStatus)）")
                }
            } else if status != errSecSuccess {
                throw PhoneAgentPlannerError.configuration("无法更新钥匙串 API Key（\(status)）")
            }
        }
        apiKey = clean
    }

    static func discoverCodex() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func loadAPIKey() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: keychainAccount,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
