import Foundation

/// Reads the chat endpoint Raphael (the Hermes agent) already uses, so the
/// Raphael chat provider works with zero setup. Source: the top-level `model:`
/// block of `~/.hermes/config.yaml`; `${VAR}` values resolve from `~/.hermes/.env`.
/// Nothing is cached on disk or copied into the Keychain: Hermes stays the owner.
enum HermesConfig {
    struct Endpoint: Equatable {
        var baseURL: String      // normalised, without /v1
        var apiKey: String
        var model: String
    }

    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    }

    /// The `model:` endpoint, or nil when Hermes is not set up on this Mac.
    static func endpoint() -> Endpoint? {
        guard let yaml = try? String(contentsOf: home.appendingPathComponent("config.yaml"), encoding: .utf8) else {
            return nil
        }
        let block = topLevelBlock(named: "model", in: yaml)
        guard let base = block["base_url"], !base.isEmpty else { return nil }
        let env = loadEnv()
        return Endpoint(
            baseURL: LocalChat.normaliseURL(base),
            apiKey: resolve(block["api_key"] ?? "", env: env),
            model: block["default"] ?? "default"
        )
    }

    /// Scalar `key: value` pairs directly under a top-level `name:` key.
    static func topLevelBlock(named name: String, in yaml: String) -> [String: String] {
        var out: [String: String] = [:]
        var inside = false
        for raw in yaml.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty || raw.hasPrefix("#") { continue }
            let indented = raw.hasPrefix(" ") || raw.hasPrefix("\t")
            if !indented {
                inside = raw.trimmingCharacters(in: .whitespaces) == "\(name):"
                continue
            }
            guard inside else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Only direct children (two-space indent), skip nested lists/maps.
            guard raw.hasPrefix("  "), !raw.hasPrefix("   "), !line.hasPrefix("-"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// `${VAR}` / `$VAR` → value from ~/.hermes/.env, then the process environment.
    static func resolve(_ value: String, env: [String: String]) -> String {
        var name = value
        if name.hasPrefix("${"), name.hasSuffix("}") { name = String(name.dropFirst(2).dropLast()) }
        else if name.hasPrefix("$") { name = String(name.dropFirst()) }
        else { return value }
        return env[name] ?? ProcessInfo.processInfo.environment[name] ?? ""
    }

    static func loadEnv() -> [String: String] {
        guard let text = try? String(contentsOf: home.appendingPathComponent(".env"), encoding: .utf8) else { return [:] }
        return parseEnv(text)
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            out[String(line[..<eq])] = v
        }
        return out
    }
}
