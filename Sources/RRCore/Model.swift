import Foundation

public struct Config: Sendable {
    public enum Provider: String, Sendable { case anthropic, openai }

    public var provider: Provider = .anthropic
    public var model = "claude-sonnet-5-5"
    public var endpoint = "https://api.anthropic.com"
    /// Name of the environment variable holding the API key.
    public var apiKeyEnv = "ANTHROPIC_API_KEY"
    /// Anthropic effort level; empty to leave it out (models before Claude 4.6 reject it).
    public var effort = "low"
    public var defaultTime = TimeOfDay(hour: 9, minute: 0)!
    public var previewCount = 4
    public var path = ""

    public static func defaultPath(env: [String: String]) -> String {
        let base = env["XDG_CONFIG_HOME"] ?? (env["HOME"] ?? NSHomeDirectory()) + "/.config"
        return base + "/rr/config.json"
    }

    /// Reads the config file if there is one, then applies RR_PROVIDER, RR_MODEL and RR_ENDPOINT.
    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        var c = Config()
        c.path = defaultPath(env: env)
        var file: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: c.path) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ModelError("\(c.path) is not a JSON object")
            }
            file = parsed
        }
        func setting(_ key: String, _ envName: String? = nil) -> String? {
            if let envName, let v = env[envName], !v.isEmpty { return v }
            return file[key] as? String
        }

        if let p = setting("provider", "RR_PROVIDER") {
            guard let provider = Provider(rawValue: p) else {
                throw ModelError("provider must be \"anthropic\" or \"openai\", not \"\(p)\"")
            }
            c.provider = provider
        }
        if c.provider == .openai {
            // Ollama's OpenAI-compatible endpoint; there is no sensible default model.
            c.endpoint = "http://localhost:11434/v1"
            c.apiKeyEnv = "OPENAI_API_KEY"
            c.model = ""
        }
        c.model = setting("model", "RR_MODEL") ?? c.model
        c.endpoint = setting("endpoint", "RR_ENDPOINT") ?? c.endpoint
        while c.endpoint.hasSuffix("/") { c.endpoint.removeLast() }
        c.apiKeyEnv = setting("api_key_env") ?? c.apiKeyEnv
        c.effort = setting("effort") ?? c.effort
        if let t = setting("default_time") {
            guard let parsed = TimeOfDay(t) else { throw ModelError("default_time must be HH:MM, not \"\(t)\"") }
            c.defaultTime = parsed
        }
        if let n = file["preview_count"] as? Int, n >= 1 { c.previewCount = n }
        guard !c.model.isEmpty else {
            throw ModelError("no model set for provider \"openai\"; set \"model\" in \(c.path) or RR_MODEL")
        }
        return c
    }
}

public struct ModelError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The only place that talks to a model: sentence in, intent out.
public func extractIntent(sentence: String, lists: [String], today: Day, config: Config,
                          env: [String: String] = ProcessInfo.processInfo.environment) async throws -> Intent {
    let system = Intent.systemPrompt(today: today, lists: lists)
    let key = env[config.apiKeyEnv].flatMap { $0.isEmpty ? nil : $0 }
    let text: String
    switch config.provider {
    case .anthropic:
        guard let key else {
            throw ModelError("\(config.apiKeyEnv) is not set. Export an Anthropic API key, " +
                             "or point rr at another provider in \(config.path).")
        }
        text = try await anthropic(sentence: sentence, system: system, key: key, config: config)
    case .openai:
        text = try await openAICompatible(sentence: sentence, system: system, key: key, config: config)
    }
    guard let data = jsonObjectText(text).data(using: .utf8), let intent = try? Intent.decode(json: data) else {
        throw ModelError("the model's reply was not a valid intent:\n\(text)")
    }
    return intent
}

private func anthropic(sentence: String, system: String, key: String, config: Config) async throws -> String {
    var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": Intent.schema]]
    if !config.effort.isEmpty { outputConfig["effort"] = config.effort }
    var body: [String: Any] = [
        "model": config.model,
        "max_tokens": 8000,
        "system": system,
        "messages": [["role": "user", "content": sentence]],
        "output_config": outputConfig,
    ]
    var headers = ["x-api-key": key, "anthropic-version": "2026-10-21"]
    // These models can decline a request outright; let the API retry on its default
    // fallback model instead of failing. Only Anthropic's own endpoint supports this.
    let declines = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2"]
    if declines.contains(config.model) && config.endpoint == "https://api.anthropic.com" {
        body["fallbacks"] = "default"
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
    }

    let reply = try await post(config.endpoint + "/v1/messages", headers: headers, body: body)
    switch reply["stop_reason"] as? String {
    case "refusal": throw ModelError("the model declined this request")
    case "max_tokens": throw ModelError("the model's reply was cut off")
    default: break
    }
    let blocks = reply["content"] as? [[String: Any]] ?? []
    guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
        throw ModelError("the model returned no text")
    }
    return text
}

private func openAICompatible(sentence: String, system: String, key: String?, config: Config) async throws -> String {
    var body: [String: Any] = [
        "model": config.model,
        "messages": [["role": "system", "content": system], ["role": "user", "content": sentence]],
        "response_format": [
            "type": "json_schema",
            "json_schema": ["name": "reminder", "strict": true, "schema": Intent.schema],
        ],
    ]
    // Local models are steadier at temperature 0; OpenAI's own newer models reject the field.
    if !config.endpoint.contains("api.openai.com") { body["temperature"] = 0 }
    let headers = key.map { ["Authorization": "Bearer \($0)"] } ?? [:]

    let reply = try await post(config.endpoint + "/chat/completions", headers: headers, body: body)
    let choices = reply["choices"] as? [[String: Any]] ?? []
    guard let message = choices.first?["message"] as? [String: Any],
          let text = message["content"] as? String, !text.isEmpty else {
        throw ModelError("the model returned no text")
    }
    return text
}

private func post(_ url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
    guard let target = URL(string: url) else { throw ModelError("bad endpoint: \(url)") }
    var request = URLRequest(url: target, timeoutInterval: 180)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let data: Data, response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw ModelError("could not reach \(url): \(error.localizedDescription)")
    }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let json else {
        let detail = (json?["error"] as? [String: Any])?["message"] as? String
            ?? json?["error"] as? String
            ?? String(data: data.prefix(500), encoding: .utf8) ?? ""
        throw ModelError("\(url) returned HTTP \(status): \(detail)")
    }
    return json
}

/// Some local models wrap JSON in a code fence or add a sentence around it.
private func jsonObjectText(_ text: String) -> String {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return text }
    return String(text[open...close])
}
