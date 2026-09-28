import Foundation

/// Recognizes local AI models (Ollama, llama.cpp, LM Studio, MLX, vLLM) and names them
/// by the model they've loaded, so "ollama 18 GB" reads as "Ollama · llama3.1:8b".
/// A loaded model holds its weights in memory for as long as it runs.
enum LocalModels {
    struct Match: Equatable {
        var engine: String
        var model: String?
        var label: String { model.map { "\(engine) · \($0)" } ?? engine }
    }

    static let engines = ["Ollama", "llama.cpp", "LM Studio", "MLX", "vLLM"]

    static func isLocalModel(label: String) -> Bool {
        engines.contains { label == $0 || label.hasPrefix($0 + " ·") }
    }

    static func match(name: String, arguments: [String], ollamaRoot: URL? = nil) -> Match? {
        let n = name.lowercased()
        let args = Array(arguments.dropFirst())
        // For interpreters, `-m` names the module being run, not a model.
        let flags = ProcessDescriber.isInterpreter(n) ? ["--model", "--model-path"] : ["-m", "--model", "--model-path"]
        let modelPath = value(after: flags, in: args) ?? args.first { $0.hasSuffix(".gguf") }

        if n == "ollama" || n.hasPrefix("ollama_") || n == "ollama-runner" {
            // `ollama serve` is the server; a loaded model runs as `ollama runner --model <blob>`.
            guard args.contains("runner") || modelPath != nil else { return Match(engine: "Ollama", model: nil) }
            return Match(engine: "Ollama", model: modelPath.flatMap { OllamaNames.shared.name(forBlob: $0, root: ollamaRoot) })
        }
        if n.hasPrefix("llama-server") || n.hasPrefix("llama-cli") || n == "llama-run" {
            return Match(engine: "llama.cpp", model: modelPath.map(stem))
        }
        if n.contains("lm studio") || n.hasPrefix("lms") || n.contains("llmworker") {
            return modelPath.map { Match(engine: "LM Studio", model: stem($0)) }
        }
        if n == "vllm" || args.first == "vllm" || (ProcessDescriber.isInterpreter(n) && args.contains("vllm")) {
            let served = args.firstIndex(of: "serve").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            return Match(engine: "vLLM", model: (served ?? modelPath).map(stem))
        }
        if ProcessDescriber.isInterpreter(n), let m = args.firstIndex(of: "-m"), args.indices.contains(m + 1),
           args[m + 1].hasPrefix("mlx_lm") {
            return Match(engine: "MLX", model: modelPath.map(stem))
        }
        return nil
    }

    private static func value(after flags: [String], in args: [String]) -> String? {
        for (i, arg) in args.enumerated() {
            if flags.contains(arg), args.indices.contains(i + 1) { return args[i + 1] }
            for flag in flags where flag.hasPrefix("--") && arg.hasPrefix(flag + "=") {
                return String(arg.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    /// "…/Qwen2.5-Coder-7B-Q4_K_M.gguf" → "Qwen2.5-Coder-7B-Q4_K_M"; "mlx-community/Llama-3-8B" → "Llama-3-8B".
    static func stem(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".gguf") || last.hasSuffix(".safetensors") ? (last as NSString).deletingPathExtension : last
    }
}

/// Maps an Ollama weights file (`…/blobs/sha256-<hex>`) to the model name you pulled
/// (`llama3.1:8b`), from Ollama's own manifests. Rebuilt at most once a minute, and only
/// when a file isn't found, so a model pulled later still gets its name.
final class OllamaNames: @unchecked Sendable {
    static let shared = OllamaNames()
    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var builtAt = Date.distantPast

    func name(forBlob path: String, root: URL? = nil) -> String? {
        let digest = (path as NSString).lastPathComponent.replacingOccurrences(of: "sha256-", with: "sha256:")
        return lock.withLock {
            if let hit = names[digest] { return hit }
            guard root != nil || Date().timeIntervalSince(builtAt) > 60 else { return nil }
            names = Self.index(root: root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models"))
            builtAt = Date()
            return names[digest]
        }
    }

    static func index(root: URL) -> [String: String] {
        let manifests = root.appendingPathComponent("manifests", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: String] = [:]
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = json["layers"] as? [[String: Any]],
                  let digest = layers.first(where: { ($0["mediaType"] as? String) == "application/vnd.ollama.image.model" })?["digest"] as? String
            else { continue }
            // …/manifests/<registry>/<namespace>/<model>/<tag>; the "library" namespace is implied.
            let parts = file.pathComponents.suffix(3)
            guard parts.count == 3 else { continue }
            let (namespace, model, tag) = (parts[parts.startIndex], parts[parts.startIndex + 1], parts[parts.startIndex + 2])
            let name = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
            result[digest] = result[digest] ?? name
        }
        return result
    }
}
