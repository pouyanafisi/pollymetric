import XCTest
@testable import Pollymetric

final class LocalModelsTests: XCTestCase {
    func testOllamaRunnerIsNamedFromItsManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ollama-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifests/registry.ollama.ai/library/llama3.1/8b")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"layers":[{"mediaType":"application/vnd.ollama.image.template","digest":"sha256:aaa"},{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:bbb"}]}"#.utf8).write(to: manifest)

        let runner = LocalModels.match(name: "ollama", arguments: ["ollama", "runner", "--model", "/Users/me/.ollama/models/blobs/sha256-bbb", "--port", "5555"], ollamaRoot: root)
        XCTAssertEqual(runner?.label, "Ollama · llama3.1:8b")
        XCTAssertEqual(LocalModels.match(name: "ollama", arguments: ["ollama", "serve"])?.label, "Ollama")
    }

    func testModelFilesNameTheirEngine() {
        XCTAssertEqual(LocalModels.match(name: "llama-server", arguments: ["llama-server", "-m", "/models/Qwen2.5-Coder-7B-Q4_K_M.gguf"])?.label,
                       "llama.cpp · Qwen2.5-Coder-7B-Q4_K_M")
        XCTAssertEqual(LocalModels.match(name: "python3.12", arguments: ["python3", "-m", "mlx_lm.server", "--model", "mlx-community/Llama-3-8B"])?.label,
                       "MLX · Llama-3-8B")
        XCTAssertEqual(LocalModels.match(name: "vllm", arguments: ["vllm", "serve", "Qwen/Qwen2.5-7B"])?.label, "vLLM · Qwen2.5-7B")
        XCTAssertNil(LocalModels.match(name: "node", arguments: ["node", "server.js", "-m", "x"]))
        XCTAssertNil(LocalModels.match(name: "python3", arguments: ["python3", "-m", "http.server"]))
    }

    func testDescriberUsesTheModelName() {
        let described = ProcessDescriber.describe(name: "llama-server", arguments: ["llama-server", "--model=/m/tiny.gguf"], cwd: nil)
        XCTAssertEqual(described.label, "llama.cpp · tiny")
        XCTAssertNotNil(ProcessDescriber.explain(label: described.label, name: "llama-server", app: nil))
    }
}
