import Foundation
import Testing
@testable import WinnieCore

@Suite struct CustomAPITests {
    let reader = ResolvedAPI(api: CustomAPI(name: "Bridge API", baseURL: "https://api.example.com/v1/"), key: "secret")
    let writer = ResolvedAPI(api: CustomAPI(name: "CRM", baseURL: "https://crm.example.com", authHeader: "X-API-Key",
                                            authScheme: "", allowsWrites: true), key: "k2")

    func build(_ arguments: [String: Any]) -> CustomAPITools.RequestResult {
        CustomAPITools.request(from: arguments, apis: [reader, writer])
    }

    func url(_ result: CustomAPITools.RequestResult) -> String? {
        if case .success(let request) = result { return request.url?.absoluteString }
        return nil
    }

    @Test func buildsAnAuthorisedGetUnderTheBaseURL() throws {
        guard case .success(let request) = build(["api": "bridge-api", "path": "/tasks", "query": ["limit": 5, "q": "отчёт"]])
        else { Issue.record("expected a request"); return }
        #expect(request.url?.absoluteString == "https://api.example.com/v1/tasks?limit=5&q=%D0%BE%D1%82%D1%87%D1%91%D1%82")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func bareKeyHeadersAreSupported() {
        guard case .success(let request) = build(["api": "crm", "method": "post", "path": "/leads", "body": ["name": "Лёва"]])
        else { Issue.record("expected a request"); return }
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "k2")
        #expect(request.httpMethod == "POST" && request.httpBody != nil)
    }

    @Test func writesAreRefusedUnlessTheUserAllowedThem() {
        guard case .failure(let outcome) = build(["api": "bridge-api", "method": "DELETE", "path": "/tasks/1"])
        else { Issue.record("expected a refusal"); return }
        #expect(outcome.isError && outcome.content.contains("read only"))
    }

    @Test func theKeyCanNeverBeSentToAnotherHost() {
        // Every one of these tries to leave the configured host.
        for path in ["//evil.example/x", "/x/../../..//evil.example", "https://evil.example/x", "/@evil.example/x",
                     "/\\evil.example", "evil.example/x"] {
            #expect(url(build(["api": "bridge-api", "path": path])) == nil, "\(path) must be refused")
        }
        #expect(url(build(["api": "nope", "path": "/x"])) == nil)
        #expect(url(build(["api": "bridge-api", "method": "TRACE", "path": "/x"])) == nil)
    }

    @Test func onlyHttpsAPIsAreUsableAndTheyAppearInThePrompt() {
        #expect(!CustomAPI(name: "A", baseURL: "http://a.example").isUsable)
        #expect(!CustomAPI(name: "A", baseURL: "https://a.example", isEnabled: false).isUsable)
        let api = CustomAPI(name: "Bridge API", baseURL: "https://api.example.com", notes: "GET /tasks — мои задачи")
        let prompt = ClaudeClient.systemPrompt(master: "x", apis: [api])
        #expect(prompt.contains("bridge-api: https://api.example.com (read only: GET)"))
        #expect(prompt.contains("GET /tasks — мои задачи"))
        #expect(!ClaudeClient.systemPrompt(master: "x").contains("call_api"))
    }

    @Test func toolIsOfferedOnlyForConfiguredAPIs() {
        let definition = CustomAPIToolSchema.definition(for: [reader.api, writer.api])
        let schema = definition["input_schema"] as? [String: Any]
        let apiProperty = (schema?["properties"] as? [String: Any])?["api"] as? [String: Any]
        #expect(apiProperty?["enum"] as? [String] == ["bridge-api", "crm"])
    }
}
