# Model Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose the chat model provider and the consolidation model provider independently (Local mlx / Gemini / Cerebras / Groq), both configured from the macOS app, with cloud API keys stored in Keychain (app) and encrypted at rest (i3).

**Architecture:** A `ModelProvider` value (`kind`, `baseURL`, `model`, `apiKey?`) parameterizes the existing OpenAI-compatible clients. The app's `ServerRuntime` (chat) derives auth + the mlx-only `chat_template_kwargs` quirk from the provider kind. The consolidation provider is pushed to the i3 (`POST /v1/config/model`), persisted in sqlite with the API key AES-GCM-encrypted (key derived from the bearer token via HKDF), and read per-call by a dynamic `RemoteModelClient`. The local 15 GB mlx server is spawned only when a side uses "local".

**Tech Stack:** Swift 6 — app (SwiftUI, Xcode), server (SwiftPM, Hummingbird, GRDB, **swift-crypto**). Spec: `docs/superpowers/specs/2026-06-04-model-router-design.md`. Build app-first (Tasks 1–7), then server (Tasks 8–11), then manual verify (Task 12).

**Where to run app tests:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -30` in `personal_agent`.
**Where to run server tests:** `swift test --filter <Name>` in `personal_agent/gemma-memory/memory-service` (dev clone, on `main`). Deploy later by pushing + `ssh HomeLab 'cd ~/Projects/gemma-memory && git pull && docker compose build memory && docker compose up -d memory'`.

**Known pre-existing app test failure (ignore):** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081` fails on this machine because UserDefaults points at the i3. Unrelated to this work.

---

## File Structure

**App (`personal_agent/Gemma/Gemma/`):**
- Create `Runtime/ModelProvider.swift` — provider kind enum + presets + quirk/auth rules.
- Modify `Runtime/ServerRuntime.swift` — provider-driven auth/quirk/error-mapping.
- Modify `Runtime/RuntimeFactory.swift` — build from a `ModelProvider`.
- Modify `Harness/HarnessModel.swift` — build chat provider from settings; `rebuildRuntime()`; `needsLocalModel` gating.
- Create `Settings/KeychainStore.swift` — Keychain get/set/delete.
- Modify `Settings/SettingsKeys.swift` — new keys.
- Modify `Settings/SettingsView.swift` — "Models" section.
- Modify `Memory/MemoryClient.swift` — `setModelConfig` / `modelConfig`.

**Server (`gemma-memory/memory-service/Sources/`):**
- Modify `MemoryCore/.../Package.swift` (repo root) — add swift-crypto.
- Create `MemoryCore/ConfigCrypto.swift` — HKDF + AES-GCM seal/open.
- Create `MemoryCore/ModelConfigStore.swift` — persisted provider config (encrypted key).
- Modify `MemoryCore/MemoryStore.swift` — `v6-service-config` migration.
- Create `MemoryService/Handlers/ConfigHandlers.swift` — `POST/GET /v1/config/model`.
- Modify `MemoryService/App.swift` — register ConfigHandlers; wire ModelConfigStore into Services + RemoteModelClient.
- Modify `MemoryService/RemoteModelClient.swift` — read dynamic provider config per call.

---

# PART A — APP (chat router)

## Task 1: `ModelProvider` type + registry

**Files:**
- Create: `Gemma/Gemma/Runtime/ModelProvider.swift`
- Test: `Gemma/GemmaTests/ModelProviderTests.swift` (create)

- [ ] **Step 1: Write the failing test** — `ModelProviderTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ModelProviderTests: XCTestCase {
    func test_presets_haveExpectedBaseURLsAndModels() {
        XCTAssertEqual(ModelProvider.Kind.local.defaultBaseURL.absoluteString, "http://localhost:8080/v1")
        XCTAssertEqual(ModelProvider.Kind.gemini.defaultBaseURL.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(ModelProvider.Kind.cerebras.defaultBaseURL.absoluteString, "https://api.cerebras.ai/v1")
        XCTAssertEqual(ModelProvider.Kind.groq.defaultBaseURL.absoluteString, "https://api.groq.com/openai/v1")
        XCTAssertEqual(ModelProvider.Kind.gemini.defaultModel, "gemini-2.5-flash")
        XCTAssertEqual(ModelProvider.Kind.local.defaultModel, "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit")
    }
    func test_quirks_localOnly() {
        XCTAssertTrue(ModelProvider.Kind.local.isLocalMLX)
        XCTAssertFalse(ModelProvider.Kind.gemini.isLocalMLX)
        XCTAssertFalse(ModelProvider.Kind.groq.isLocalMLX)
    }
}
```

- [ ] **Step 2: Run — verify it FAILS** (`ModelProvider` undefined). Run the app test command (filter not reliable in xcodebuild; run the suite and look for the new test).

- [ ] **Step 3: Create `ModelProvider.swift`:**

```swift
import Foundation

/// A model backend the app can talk to via the OpenAI-compatible chat API.
struct ModelProvider: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case local, gemini, cerebras, groq
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .local: return "Gemma local (mlx)"
            case .gemini: return "Gemini"
            case .cerebras: return "Cerebras"
            case .groq: return "Groq"
            }
        }
        /// Cloud providers reject `chat_template_kwargs` and require a bearer key; local mlx is the
        /// inverse. This is the single switch that drives both quirks.
        var isLocalMLX: Bool { self == .local }

        /// Endpoint directory that CONTAINS `chat/completions` (the runtime appends `chat/completions`).
        /// Note each ends at the version segment — Gemini's is `/v1beta/openai` (NOT `/v1`).
        var defaultBaseURL: URL {
            switch self {
            case .local: return URL(string: "http://localhost:8080/v1")!
            case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
            case .cerebras: return URL(string: "https://api.cerebras.ai/v1")!
            case .groq: return URL(string: "https://api.groq.com/openai/v1")!
            }
        }
        var defaultModel: String {
            switch self {
            case .local: return "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit"
            case .gemini: return "gemini-2.5-flash"
            case .cerebras: return "llama-3.3-70b"
            case .groq: return "llama-3.3-70b-versatile"
            }
        }
    }

    var kind: Kind
    var baseURL: URL
    var model: String
    var apiKey: String?

    init(kind: Kind, baseURL: URL? = nil, model: String? = nil, apiKey: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = (model?.isEmpty == false ? model! : kind.defaultModel)
        self.apiKey = apiKey
    }
}
```

- [ ] **Step 4: Run — verify it PASSES.**

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Runtime/ModelProvider.swift Gemma/GemmaTests/ModelProviderTests.swift
git commit -m "feat(router): ModelProvider kind + presets + mlx-quirk rule"
```

---

## Task 2: `ServerRuntime` provider-aware (auth + quirk + error mapping)

**Files:**
- Modify: `Gemma/Gemma/Runtime/ServerRuntime.swift`
- Test: `Gemma/GemmaTests/` — find the existing `ServerRuntime` URLProtocol-mock test (e.g. `ServerRuntimeTests.swift`); APPEND. If none exists, create `ServerRuntimeProviderTests.swift` with a `URLProtocol` stub (see Step 1).

- [ ] **Step 1: Write the failing tests.** Use a `URLProtocol` stub that captures the outgoing `URLRequest` and returns a canned non-streamed JSON (set `stream:false` is not needed — assert on the request only). Append:

```swift
func test_cloudRequest_hasBearerAuth_andNoThinkingKwargs() async throws {
    let captured = try await captureRequest(provider: ModelProvider(kind: .gemini, apiKey: "KEY123"))
    XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer KEY123")
    let body = try JSONSerialization.jsonObject(with: captured.httpBodyData) as! [String: Any]
    XCTAssertNil(body["chat_template_kwargs"])
    XCTAssertEqual(body["model"] as? String, "gemini-2.5-flash")
    XCTAssertEqual(captured.url?.absoluteString,
                   "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
}

func test_localRequest_hasThinkingKwargs_andNoAuth() async throws {
    let captured = try await captureRequest(provider: ModelProvider(kind: .local))
    XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"))
    let body = try JSONSerialization.jsonObject(with: captured.httpBodyData) as! [String: Any]
    XCTAssertNotNil(body["chat_template_kwargs"])
}

func test_http401_mapsToInvalidKeyMessage() async {
    let msg = await errorMessage(status: 401, provider: ModelProvider(kind: .groq, apiKey: "bad"))
    XCTAssertTrue(msg.contains("API key"), msg)
}
```

> Implement `captureRequest(provider:)`, `errorMessage(status:provider:)`, and `httpBodyData` helpers in the test file using a `URLProtocol` subclass that records `URLProtocol.request` and returns a stubbed `HTTPURLResponse`. Mirror any existing URLProtocol mock already in the app test target (search `GemmaTests` for `URLProtocol`). `URLSession` for the runtime must be built from a `URLSessionConfiguration` with `protocolClasses = [Stub.self]`; pass it into `ServerRuntime(session:)`.

**URL convention (matches Task 1 presets):** each preset `baseURL` ends at the version directory that contains `chat/completions` (`http://localhost:8080/v1`, `https://generativelanguage.googleapis.com/v1beta/openai`, `https://api.cerebras.ai/v1`, `https://api.groq.com/openai/v1`). The runtime appends **`chat/completions`** (NOT `v1/chat/completions`) — this is the only way Gemini's `/v1beta/openai/chat/completions` and the `/v1/...` providers both come out right. Step 3 changes the existing `appendingPathComponent("v1/chat/completions")` to `appendingPathComponent("chat/completions")`.

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Modify `ServerRuntime`.** Change the initializer to accept a `ModelProvider` (keep a convenience default that builds `.local`):

```swift
let provider: ModelProvider
// derived:
var baseURL: URL { provider.baseURL }
var model: String { provider.model }

init(provider: ModelProvider = ModelProvider(kind: .local),
     session: URLSession = .shared,
     enableThinking: Bool = false,
     generationTimeout: Duration = .seconds(120)) {
    self.provider = provider
    self.session = session
    self.enableThinking = enableThinking
    self.generationTimeout = generationTimeout
}
```
(Remove the old `baseURL`/`model` stored properties; replace their uses with the computed ones.)

In `generate(prompt:tools:options:)`, where `body` is built, gate the quirk and add auth:

```swift
var body: [String: Any] = [
    "model": model,
    "messages": messages,
    "max_tokens": options.maxTokens,
    "temperature": options.temperature,
    "stream": true,
]
if provider.kind.isLocalMLX {
    body["chat_template_kwargs"] = ["enable_thinking": enableThinking]
}
if !tools.isEmpty { body["tools"] = tools.map { type(of: $0).functionSpec } }

var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
if let key = provider.apiKey, !key.isEmpty {
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
}
```

Replace the non-2xx error throw with a mapped message:

```swift
if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
    throw RuntimeError.generationFailed(Self.errorMessage(status: http.statusCode, provider: provider))
}
```

Add a static mapper:

```swift
static func errorMessage(status: Int, provider: ModelProvider) -> String {
    let p = provider.kind.displayName
    switch status {
    case 401: return "\(p): API key inválida o ausente."
    case 403: return "\(p): acceso denegado (revisa la API key/permisos)."
    case 429: return "\(p): rate limit — intenta de nuevo en un momento."
    default:  return "\(p): error HTTP \(status)."
    }
}
```

And in the `catch` that wraps URL/transport errors, map offline to a clear message:

```swift
} catch {
    let p = provider.kind.displayName
    let msg = (error is URLError) ? "\(p): sin conexión." : "\(p): \(error.localizedDescription)"
    continuation.finish(throwing: RuntimeError.generationFailed(msg))
}
```

- [ ] **Step 4: Run — verify PASS** (and the rest of the suite still builds; other `ServerRuntime()` call sites now use the default `.local` provider).

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Runtime/ServerRuntime.swift Gemma/Gemma/Runtime/ModelProvider.swift Gemma/GemmaTests/
git commit -m "feat(router): ServerRuntime derives auth + mlx quirk from provider; clear error mapping"
```

---

## Task 3: `RuntimeFactory(provider:)` + HarnessModel chat-provider building + rebuild

**Files:**
- Modify: `Gemma/Gemma/Runtime/RuntimeFactory.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Modify: `Gemma/Gemma/Settings/SettingsKeys.swift`
- Test: `Gemma/GemmaTests/` — add a HarnessModel test (or extend existing) asserting `chatProvider()` reads settings.

- [ ] **Step 1: Add settings keys** to `SettingsKeys.swift`:

```swift
static let chatProvider = "chatProvider"            // ModelProvider.Kind.rawValue
static let chatModel = "chatModel"
static let consolidationProvider = "consolidationProvider"
static let consolidationModel = "consolidationModel"
```

- [ ] **Step 2: Write the failing test** — assert HarnessModel builds the chat provider from UserDefaults + Keychain:

```swift
func test_chatProvider_readsSettings() {
    UserDefaults.standard.set("gemini", forKey: SettingsKeys.chatProvider)
    UserDefaults.standard.set("gemini-2.0-pro", forKey: SettingsKeys.chatModel)
    let p = HarnessModel.chatProvider(keyLookup: { _ in "K" })
    XCTAssertEqual(p.kind, .gemini)
    XCTAssertEqual(p.model, "gemini-2.0-pro")
    XCTAssertEqual(p.apiKey, "K")
    UserDefaults.standard.removeObject(forKey: SettingsKeys.chatProvider)
    UserDefaults.standard.removeObject(forKey: SettingsKeys.chatModel)
}
```

- [ ] **Step 3a: `RuntimeFactory`** — make it build from a provider:

```swift
@MainActor
public enum RuntimeFactory {
    public static func make(_ provider: ModelProvider) -> ModelRuntime & ToolCallingRuntime {
        ServerRuntime(provider: provider)
    }
    public static func dummy() -> ModelRuntime & ToolCallingRuntime { DummyRuntime() }
}
```
Update any `RuntimeFactory.make(.server)` / `.dummy` call sites accordingly (search the app).

- [ ] **Step 3b: HarnessModel** — add a static provider builder + a rebuild method. Add:

```swift
/// Build the chat provider from settings. `keyLookup` returns the stored API key for a kind
/// (injected for tests; production passes `KeychainStore.shared.get`).
static func chatProvider(keyLookup: (ModelProvider.Kind) -> String?) -> ModelProvider {
    let kindRaw = UserDefaults.standard.string(forKey: SettingsKeys.chatProvider) ?? "local"
    let kind = ModelProvider.Kind(rawValue: kindRaw) ?? .local
    let model = UserDefaults.standard.string(forKey: SettingsKeys.chatModel)
    let key = kind.isLocalMLX ? nil : keyLookup(kind)
    return ModelProvider(kind: kind, model: model, apiKey: key)
}

/// Rebuild the chat runtime from current settings (called when chat settings change).
func rebuildRuntime() {
    let provider = Self.chatProvider(keyLookup: { KeychainStore.shared.get(account: "apiKey.\($0.rawValue)") })
    self.runtime = RuntimeFactory.make(provider)
}
```
In `init()`, replace `self.runtime = ServerRuntime()` with `self.runtime = RuntimeFactory.make(Self.chatProvider(keyLookup: { KeychainStore.shared.get(account: "apiKey.\($0.rawValue)") }))`.

> `KeychainStore` is created in Task 4. If implementing strictly in order, temporarily stub `keyLookup` with `{ _ in nil }` here and switch to `KeychainStore.shared.get` after Task 4 (note it in your commit). Or implement Task 4 first — both orders are fine; just keep them consistent.

- [ ] **Step 4: Run — verify PASS** + suite builds.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Runtime/RuntimeFactory.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Settings/SettingsKeys.swift Gemma/GemmaTests/
git commit -m "feat(router): build chat runtime from settings provider; rebuildRuntime()"
```

---

## Task 4: `KeychainStore`

**Files:**
- Create: `Gemma/Gemma/Settings/KeychainStore.swift`
- Test: `Gemma/GemmaTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import Gemma

final class KeychainStoreTests: XCTestCase {
    func test_set_get_delete_roundTrip() {
        let acct = "apiKey.test.\(UUID().uuidString)"
        KeychainStore.shared.set("secret-123", account: acct)
        XCTAssertEqual(KeychainStore.shared.get(account: acct), "secret-123")
        KeychainStore.shared.set("secret-456", account: acct) // overwrite
        XCTAssertEqual(KeychainStore.shared.get(account: acct), "secret-456")
        KeychainStore.shared.delete(account: acct)
        XCTAssertNil(KeychainStore.shared.get(account: acct))
    }
}
```

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Create `KeychainStore.swift`:**

```swift
import Foundation
import Security

/// Minimal Keychain wrapper for API keys (generic password items, one per account).
struct KeychainStore {
    static let shared = KeychainStore()
    private let service = "lambert-dev-group.Gemma.apiKeys"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func get(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        SecItemDelete(query(account) as CFDictionary)   // overwrite-safe
        var q = query(account)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
```

- [ ] **Step 4: Run — verify PASS.** (macOS unit tests can use the login keychain. If the test target lacks keychain access, the round-trip still works against the data-protection keychain for generic passwords; if `errSecMissingEntitlement` appears, add the test host app's existing entitlements — do not add new ones beyond what the app already has.)

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Settings/KeychainStore.swift Gemma/GemmaTests/KeychainStoreTests.swift
git commit -m "feat(router): KeychainStore for API keys"
```

---

## Task 5: Settings "Models" UI

**Files:**
- Modify: `Gemma/Gemma/Settings/SettingsView.swift`
- Test: none (SwiftUI view; logic is covered by Tasks 1–4 + 6–7). Manual visual check via ⌘R is owed.

- [ ] **Step 1: Add a "Models" section** to `SettingsView`'s `Form`, above "Servidor". Two provider blocks via a small reusable subview. Add to `SettingsView`:

```swift
@AppStorage(SettingsKeys.chatProvider) private var chatProvider = "local"
@AppStorage(SettingsKeys.chatModel) private var chatModel = ""
@AppStorage(SettingsKeys.consolidationProvider) private var consolidationProvider = "local"
@AppStorage(SettingsKeys.consolidationModel) private var consolidationModel = ""
```

Insert this Section at the top of the `Form`:

```swift
Section("Modelos") {
    ProviderPicker(title: "Chat", providerRaw: $chatProvider, model: $chatModel,
                   onChange: { model.rebuildRuntime(); model.refreshLocalModelLifecycle() })
    ProviderPicker(title: "Consolidación", providerRaw: $consolidationProvider, model: $consolidationModel,
                   onChange: { model.pushConsolidationConfig(); model.refreshLocalModelLifecycle() })
    Text("El chat usa el modelo elegido en este Mac. La consolidación corre en el i3 con su propio modelo. Las API keys se guardan cifradas.")
        .font(.footnote).foregroundStyle(.secondary)
}
```

Add the reusable subview in the same file:

```swift
private struct ProviderPicker: View {
    let title: String
    @Binding var providerRaw: String
    @Binding var model: String
    let onChange: () -> Void
    @State private var apiKey: String = ""

    private var kind: ModelProvider.Kind { ModelProvider.Kind(rawValue: providerRaw) ?? .local }
    private var keyAccount: String { "apiKey.\(kind.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: $providerRaw) {
                ForEach(ModelProvider.Kind.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .onChange(of: providerRaw) { _, _ in apiKey = ""; onChange() }
            TextField("Modelo (\(kind.defaultModel))", text: $model)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onChange)
            if !kind.isLocalMLX {
                SecureField(KeychainStore.shared.get(account: keyAccount) == nil ? "API key" : "•••• guardada",
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !apiKey.isEmpty { KeychainStore.shared.set(apiKey, account: keyAccount); apiKey = "" }
                        onChange()
                    }
            }
        }
    }
}
```

> `model.refreshLocalModelLifecycle()`, `model.pushConsolidationConfig()` are added in Tasks 6 and 7. If implementing strictly in order, comment those two calls out with a `// TODO(Task 6/7)` and wire them when those tasks land. `rebuildRuntime()` exists from Task 3.

- [ ] **Step 2: Build the app** (`xcodebuild build ...`) — compiles. Visual check owed (manual ⌘R).

- [ ] **Step 3: Commit**

```bash
git add Gemma/Gemma/Settings/SettingsView.swift
git commit -m "feat(router): Settings Models section — chat + consolidation provider pickers"
```

---

## Task 6: `needsLocalModel` spawn gating

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Test: `Gemma/GemmaTests/` — add a pure-logic test for `needsLocalModel`.

- [ ] **Step 1: Write the failing test:**

```swift
func test_needsLocalModel_trueIfEitherSideLocal() {
    XCTAssertTrue(HarnessModel.needsLocalModel(chat: "local", consolidation: "gemini"))
    XCTAssertTrue(HarnessModel.needsLocalModel(chat: "groq", consolidation: "local"))
    XCTAssertTrue(HarnessModel.needsLocalModel(chat: "local", consolidation: "local"))
    XCTAssertFalse(HarnessModel.needsLocalModel(chat: "gemini", consolidation: "groq"))
}
```

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Implement** in `HarnessModel`:

```swift
static func needsLocalModel(chat: String, consolidation: String) -> Bool {
    chat == ModelProvider.Kind.local.rawValue || consolidation == ModelProvider.Kind.local.rawValue
}

/// Spawn/keep-warm the local mlx server only when a side uses local; otherwise stop it.
/// No-op under XCTest (mirrors startServer()).
func refreshLocalModelLifecycle() {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    let chat = UserDefaults.standard.string(forKey: SettingsKeys.chatProvider) ?? "local"
    let cons = UserDefaults.standard.string(forKey: SettingsKeys.consolidationProvider) ?? "local"
    if Self.needsLocalModel(chat: chat, consolidation: cons) {
        Task { await serverManager.start() }
    } else {
        serverManager.stop()
    }
}
```
In `startServer()` (the app's launch entry), replace the unconditional start with a call to `refreshLocalModelLifecycle()` so launch respects the setting. (Keep the existing XCTest guard.)

- [ ] **Step 4: Run — verify PASS** + suite builds.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/
git commit -m "feat(router): spawn local mlx only when chat or consolidation uses local"
```

---

## Task 7: `MemoryClient` push consolidation config

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryClient.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (add `pushConsolidationConfig()`)
- Test: `Gemma/GemmaTests/` — encode test for the request body (mirror existing MemoryClient tests if any; otherwise assert via URLProtocol capture).

- [ ] **Step 1: Add client methods** to `MemoryClient.swift` (mirror the existing `post`/`get` helper usage):

```swift
// MARK: model config (consolidation provider, pushed to the i3)
func setModelConfig(provider: String, baseURL: String, model: String, apiKey: String?) async throws {
    struct B: Encodable { let provider: String; let baseURL: String; let model: String; let apiKey: String? }
    let _: EmptyOK = try await post("/v1/config/model",
                                    B(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey))
}
struct ModelConfigInfo: Decodable, Sendable { let provider: String; let baseURL: String; let model: String; let hasKey: Bool }
func modelConfig() async throws -> ModelConfigInfo { try await get("/v1/config/model") }
```

- [ ] **Step 2: Add `pushConsolidationConfig()`** to `HarnessModel`:

```swift
/// Push the consolidation provider config to the i3 (key included, over the authed channel).
func pushConsolidationConfig() {
    ensureMemory()
    guard let client = memory else { return }
    let kindRaw = UserDefaults.standard.string(forKey: SettingsKeys.consolidationProvider) ?? "local"
    let kind = ModelProvider.Kind(rawValue: kindRaw) ?? .local
    let model = UserDefaults.standard.string(forKey: SettingsKeys.consolidationModel)
    let provider = ModelProvider(kind: kind, model: model,
                                 apiKey: kind.isLocalMLX ? nil : KeychainStore.shared.get(account: "apiKey.\(kind.rawValue)"))
    Task {
        try? await client.setModelConfig(provider: kind.rawValue,
                                          baseURL: provider.baseURL.absoluteString,
                                          model: provider.model, apiKey: provider.apiKey)
    }
}
```
Call `pushConsolidationConfig()` once on app launch (next to `startServer()`), so the i3 is synced. Guard under XCTest like the others.

- [ ] **Step 3: Write a test** asserting the push body via a URLProtocol-capturing `MemoryClient` (mirror the app's existing URLProtocol mock). Assert the POST path is `/v1/config/model` and the JSON has `provider`/`baseURL`/`model`/`apiKey`. Run — FAIL then PASS.

- [ ] **Step 4: Run — verify PASS** + suite builds.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/
git commit -m "feat(router): push consolidation provider config to the i3 on change/launch"
```

---

# PART B — SERVER (consolidation router, on `gemma-memory/memory-service`)

## Task 8: swift-crypto dependency + `ConfigCrypto` (HKDF + AES-GCM)

**Files:**
- Modify: `Package.swift` (repo root of `gemma-memory`)
- Create: `Sources/MemoryCore/ConfigCrypto.swift`
- Test: `Tests/MemoryCoreTests/ConfigCryptoTests.swift`

- [ ] **Step 1: Add swift-crypto** to `Package.swift` — add the dependency and attach the `Crypto` product to the `MemoryCore` target:

```swift
// in dependencies:
.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
// in the MemoryCore target's dependencies array:
.product(name: "Crypto", package: "swift-crypto"),
```

- [ ] **Step 2: Write the failing test** — `ConfigCryptoTests.swift`:

```swift
import XCTest
@testable import MemoryCore

final class ConfigCryptoTests: XCTestCase {
    func test_roundTrip_sameToken() throws {
        let c = ConfigCrypto(bearerToken: "tok-abc")
        let blob = try c.seal("my-api-key")
        XCTAssertNotEqual(blob, Data("my-api-key".utf8))     // ciphertext, not plaintext
        XCTAssertEqual(try c.open(blob), "my-api-key")
    }
    func test_wrongToken_failsToOpen() throws {
        let blob = try ConfigCrypto(bearerToken: "tok-abc").seal("k")
        XCTAssertThrowsError(try ConfigCrypto(bearerToken: "different").open(blob))
    }
}
```

- [ ] **Step 3: Create `ConfigCrypto.swift`:**

```swift
import Foundation
import Crypto

/// AES-GCM encryption for the consolidation API key at rest. The symmetric key is derived from
/// the server's bearer token via HKDF, so the key never lives in the DB — copying the sqlite file
/// cannot reveal the API key without the bearer token.
public struct ConfigCrypto {
    private let key: SymmetricKey

    public init(bearerToken: String) {
        let ikm = SymmetricKey(data: Data(bearerToken.utf8))
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("model-config-key".utf8),
            info: Data("apiKey".utf8),
            outputByteCount: 32)
    }

    /// Returns the AES-GCM `combined` blob (nonce + ciphertext + tag).
    public func seal(_ plaintext: String) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw CryptoError.sealFailed }
        return combined
    }

    public func open(_ blob: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: blob)
        let data = try AES.GCM.open(box, using: key)
        return String(decoding: data, as: UTF8.self)
    }

    public enum CryptoError: Error { case sealFailed }
}
```

- [ ] **Step 4: Run — verify PASS:** `swift test --filter ConfigCryptoTests` (first run rebuilds with swift-crypto).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Sources/MemoryCore/ConfigCrypto.swift Tests/MemoryCoreTests/ConfigCryptoTests.swift
git commit -m "feat(router): ConfigCrypto — AES-GCM key encryption, HKDF-from-bearer"
```

---

## Task 9: `service_config` migration + `ModelConfigStore`

**Files:**
- Modify: `Sources/MemoryCore/MemoryStore.swift` (add `v6-service-config` migration)
- Create: `Sources/MemoryCore/ModelConfigStore.swift`
- Test: `Tests/MemoryCoreTests/ModelConfigStoreTests.swift`

- [ ] **Step 1: Add the migration** in `MemoryStore.migrator` (after `v5-purge-conversation-nodes`):

```swift
m.registerMigration("v6-service-config") { db in
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS service_config (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            baseURL TEXT NOT NULL,
            model TEXT NOT NULL,
            apiKeyCipher BLOB
        )
        """)
}
```

- [ ] **Step 2: Write the failing test** — `ModelConfigStoreTests.swift`:

```swift
import XCTest
import GRDB
@testable import MemoryCore

final class ModelConfigStoreTests: XCTestCase {
    func test_empty_returnsNil() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        XCTAssertNil(try cfg.load())
    }
    func test_save_then_load_decryptsKey() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        try cfg.save(provider: "gemini", baseURL: "https://x", model: "gemini-2.5-flash", apiKey: "K")
        let loaded = try cfg.load()
        XCTAssertEqual(loaded?.provider, "gemini")
        XCTAssertEqual(loaded?.model, "gemini-2.5-flash")
        XCTAssertEqual(loaded?.apiKey, "K")
        // stored ciphertext is not the plaintext key
        let raw: Data? = try store.dbQueue.read { try Data.fetchOne($0, sql: "SELECT apiKeyCipher FROM service_config") }
        XCTAssertNotNil(raw); XCTAssertNotEqual(raw, Data("K".utf8))
    }
    func test_save_localNoKey() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let cfg = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: "t"))
        try cfg.save(provider: "local", baseURL: "http://localhost:8080", model: "gemma", apiKey: nil)
        XCTAssertNil(try cfg.load()?.apiKey)
    }
}
```

- [ ] **Step 3: Create `ModelConfigStore.swift`:**

```swift
import Foundation
import GRDB

/// Persisted consolidation provider config (single row). The API key is stored AES-GCM-encrypted.
/// Reuses the MemoryStore DatabaseQueue; never touches `node`/`transcript`.
public final class ModelConfigStore: @unchecked Sendable {
    public struct Resolved: Sendable, Equatable {
        public let provider: String
        public let baseURL: String
        public let model: String
        public let apiKey: String?
    }

    private let dbQueue: DatabaseQueue
    private let crypto: ConfigCrypto
    private static let rowID = "default"

    public init(dbQueue: DatabaseQueue, crypto: ConfigCrypto) {
        self.dbQueue = dbQueue; self.crypto = crypto
    }

    public func save(provider: String, baseURL: String, model: String, apiKey: String?) throws {
        let cipher = try apiKey.flatMap { $0.isEmpty ? nil : try crypto.seal($0) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO service_config (id, provider, baseURL, model, apiKeyCipher)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, baseURL=excluded.baseURL,
                                              model=excluded.model, apiKeyCipher=excluded.apiKeyCipher
                """, arguments: [Self.rowID, provider, baseURL, model, cipher])
        }
    }

    /// Current config, or nil if nothing persisted. Throws if a stored key fails to decrypt.
    public func load() throws -> Resolved? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT provider, baseURL, model, apiKeyCipher FROM service_config WHERE id = ?",
                arguments: [Self.rowID]) else { return nil }
            let cipher = row["apiKeyCipher"] as Data?
            let key = try cipher.map { try crypto.open($0) }
            return Resolved(provider: row["provider"], baseURL: row["baseURL"], model: row["model"], apiKey: key)
        }
    }
}
```

- [ ] **Step 4: Run — verify PASS:** `swift test --filter ModelConfigStoreTests` then `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/MemoryStore.swift Sources/MemoryCore/ModelConfigStore.swift Tests/MemoryCoreTests/ModelConfigStoreTests.swift
git commit -m "feat(router): ModelConfigStore + v6 migration (encrypted key at rest)"
```

---

## Task 10: `POST/GET /v1/config/model` endpoints

**Files:**
- Create: `Sources/MemoryService/Handlers/ConfigHandlers.swift`
- Modify: `Sources/MemoryService/App.swift` (build `ModelConfigStore` into `Services`; register `ConfigHandlers`)
- Test: `Tests/MemoryServiceTests/ConfigEndpointsTests.swift`

- [ ] **Step 1: Wire `ModelConfigStore` into `Services`.** In `App.swift`, add `public let modelConfig: ModelConfigStore` to `Services`, and in BOTH inits build it: `self.modelConfig = ModelConfigStore(dbQueue: store.dbQueue, crypto: ConfigCrypto(bearerToken: <bearerToken>))` (the production init uses `config.bearerToken`; the test init uses `bearerToken`). Register the handler next to the others: `ConfigHandlers(services: services).register(on: v1)`.

- [ ] **Step 2: Write the failing test** — `ConfigEndpointsTests.swift` (mirror `ScheduleEndpointsTests` / `ConsolidationEndpointsTests` for app construction + auth headers + request execution):

```swift
// POST /v1/config/model {provider:"gemini",baseURL:"https://x",model:"m",apiKey:"K"} → 200
// then GET /v1/config/model → {provider:"gemini",baseURL:"https://x",model:"m",hasKey:true} (NO apiKey field)
// POST with provider:"gemini" and no apiKey → 400 (cloud requires a key)
// POST without auth → 401
```
Fill in using the existing test helpers in the sibling endpoint test files.

- [ ] **Step 3: Create `ConfigHandlers.swift`:**

```swift
import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import MemoryCore

/// `POST/GET /v1/config/model` — the macOS app configures the consolidation provider here.
struct ConfigHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/config/model", use: set)
        group.get ("/config/model", use: get)
    }

    private func json(_ obj: Any, _ status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    struct SetBody: Decodable, Sendable {
        let provider: String; let baseURL: String; let model: String; let apiKey: String?
    }

    @Sendable func set(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let buf = try? await req.body.collect(upTo: 16_000),
              let b = try? JSONDecoder().decode(SetBody.self, from: Data(buf.readableBytesView)) else {
            return jsonError(.badRequest, "bad_request", "provider/baseURL/model required")
        }
        if b.provider != "local", (b.apiKey ?? "").isEmpty {
            return jsonError(.badRequest, "key_required", "cloud provider requires an apiKey")
        }
        do { try services.modelConfig.save(provider: b.provider, baseURL: b.baseURL, model: b.model, apiKey: b.apiKey) }
        catch { return jsonError(.internalServerError, "store_error", "\(error)") }
        return json(["ok": true])
    }

    @Sendable func get(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let cfg = (try? services.modelConfig.load()) ?? nil
        // Default view when nothing persisted = local mlx (matches RemoteModelClient fallback).
        let provider = cfg?.provider ?? "local"
        let baseURL = cfg?.baseURL ?? ""
        let model = cfg?.model ?? ""
        let hasKey = (cfg?.apiKey?.isEmpty == false)
        return json(["provider": provider, "baseURL": baseURL, "model": model, "hasKey": hasKey])
    }
}
```

- [ ] **Step 4: Run — verify PASS:** `swift test --filter ConfigEndpointsTests` then `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryService/Handlers/ConfigHandlers.swift Sources/MemoryService/App.swift Tests/MemoryServiceTests/ConfigEndpointsTests.swift
git commit -m "feat(router): POST/GET /v1/config/model (key never returned; cloud requires key)"
```

---

## Task 11: `RemoteModelClient` reads dynamic provider config

**Files:**
- Modify: `Sources/MemoryService/RemoteModelClient.swift`
- Modify: `Sources/MemoryService/App.swift` (construct `RemoteModelClient` with the `ModelConfigStore` + defaults)
- Test: `Tests/MemoryServiceTests/` or `Tests/MemoryCoreTests/` — URLProtocol-capture test (mirror any existing; else add a stub).

- [ ] **Step 1: Make `RemoteModelClient` resolve config per call.** Replace its stored `baseURL`/`model` with a `ModelConfigStore?` + defaults:

```swift
public struct RemoteModelClient: ModelTextClient {
    let configStore: ModelConfigStore?
    let defaultBaseURL: URL
    let defaultModel: String
    public let session: URLSession
    public let timeout: TimeInterval

    public init(configStore: ModelConfigStore?, defaultBaseURL: URL,
                defaultModel: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
                session: URLSession = .shared, timeout: TimeInterval = 120) {
        self.configStore = configStore; self.defaultBaseURL = defaultBaseURL
        self.defaultModel = defaultModel; self.session = session; self.timeout = timeout
    }

    private func resolve() -> (baseURL: URL, model: String, apiKey: String?, isLocal: Bool) {
        if let c = try? configStore?.load() ?? nil, let url = URL(string: c.baseURL) {
            return (url, c.model, c.apiKey, c.provider == "local")
        }
        return (defaultBaseURL, defaultModel, nil, true)   // pre-push default = local mlx
    }

    public func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        let r = resolve()
        struct Msg: Encodable { let role: String; let content: String }
        var body: [String: Any] = [
            "model": r.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": options.maxTokens,
            "temperature": options.temperature,
        ]
        if r.isLocal { body["chat_template_kwargs"] = ["enable_thinking": false] }

        // baseURL ends at the version dir (e.g. .../v1, .../v1beta/openai) — append chat/completions.
        var urlReq = URLRequest(url: r.baseURL.appendingPathComponent("chat/completions"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = r.apiKey, !key.isEmpty { urlReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        urlReq.timeoutInterval = timeout
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: urlReq)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelClientError.remoteFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
        struct OpenAIResp: Decodable { let choices: [Choice] }
        let parsed = try JSONDecoder().decode(OpenAIResp.self, from: data)
        return parsed.choices.first?.message.content ?? ""
    }

    public enum ModelClientError: Error, Equatable { case remoteFailed(status: Int) }
}
```

> Note the body is now `[String: Any]` (JSONSerialization) instead of a typed `Req`, because the quirk key is conditional. This matches the app's `ServerRuntime` approach.

- [ ] **Step 2: Update `App.swift`** to construct the client with the store. The default-local baseURL must end at the version dir, so append `v1` to `config.modelURL` (which is e.g. `http://host.docker.internal:8080`): `let modelClient = RemoteModelClient(configStore: modelConfig, defaultBaseURL: URL(string: config.modelURL)!.appendingPathComponent("v1"), defaultModel: config.modelName)`. (Build `modelConfig` before `modelClient`.) Keep the test `Services` init working (pass `configStore: nil` for the NoOp path, or build a `ModelConfigStore` there too — prefer building it so consolidation can be exercised). The app sends `provider.baseURL` already ending at the version dir (Task 7), so stored cloud configs need no adjustment.

- [ ] **Step 3: Write a URLProtocol-capture test:** with a `ModelConfigStore` seeded `provider:"gemini",apiKey:"K"`, calling `generate` produces a request to the gemini baseURL with `Authorization: Bearer K` and NO `chat_template_kwargs`; with an empty store, it targets `defaultBaseURL` WITH the quirk and no auth. Run — FAIL then PASS.

- [ ] **Step 4: Run — verify PASS:** `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryService/RemoteModelClient.swift Sources/MemoryService/App.swift Tests/
git commit -m "feat(router): RemoteModelClient resolves provider config per call (cloud auth + quirk)"
```

---

## Task 12: Deploy server + manual gated cloud verification

**Files:** none (deploy + manual).

- [ ] **Step 1: Deploy the server** (after server tasks merged to `gemma-memory` main):
```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && git pull && docker compose build memory && docker compose up -d memory'
```

- [ ] **Step 2: App manual check (⌘R):** Settings → Modelos → set Chat = Gemini, paste a real key, type a chat message → response comes from Gemini; set Chat back to Local → app spawns mlx and responds locally. Set Consolidation = Groq + key → confirm `GET /v1/config/model` on the i3 returns `{provider:"groq", hasKey:true}` (no key) via `curl` with the bearer token.

- [ ] **Step 3: Verify both-cloud saves RAM:** set both Chat and Consolidation to cloud → confirm the local mlx server is NOT running (no `mlx_vlm.server` process; `ServerManager` stopped).

- [ ] **Step 4: Record** the verification result in the session/memory. No code commit.

---

## Self-Review

**Spec coverage:**
- §5 provider registry → Task 1. ✓
- §6.1 ServerRuntime auth/quirk/error map → Task 2. ✓
- §6.1 RuntimeFactory/HarnessModel rebuild → Task 3. ✓
- §6.2 Settings UI + Keychain → Tasks 4, 5. ✓
- §6.3 needsLocalModel spawn → Task 6. ✓
- §6.4 push endpoint + ModelConfigStore + migration → Tasks 7 (app push), 9 (store+migration), 10 (endpoints). ✓
- §6.5 RemoteModelClient dynamic → Task 11. ✓
- §6.6 encryption (swift-crypto, HKDF, AES-GCM) → Task 8. ✓
- §7 data flow / §8 error handling → Tasks 2 (chat errors), 10 (cloud-requires-key 400), 11 (default fallback). ✓
- §9 testing → unit tests in Tasks 1–4, 6, 8–11; manual gated in Task 12. ✓
- §10 order app-first → Tasks 1–7 (app) then 8–11 (server) then 12. ✓
- §11 security (Keychain, encrypted at rest, key never returned) → Tasks 4, 8, 10. ✓

**Placeholder scan:** No TBD/TODO. Two forward-reference notes (Task 3 keyLookup before Task 4; Task 5 calls before Tasks 6/7) are explicit ordering instructions with a concrete temporary stub, not placeholders.

**Type consistency:** `ModelProvider`/`ModelProvider.Kind` consistent across Tasks 1–7. `ServerRuntime(provider:)` consistent in Tasks 2, 3. `KeychainStore.shared.get/set/delete(account:)` consistent in Tasks 3, 4, 5, 7. `ConfigCrypto(bearerToken:).seal/open` consistent in Tasks 8, 9, 10. `ModelConfigStore(dbQueue:crypto:).save/load` + `Resolved` consistent in Tasks 9, 10, 11. `RemoteModelClient(configStore:defaultBaseURL:defaultModel:)` consistent in Tasks 11, and App.swift wiring in 10/11. Endpoint `/v1/config/model` body `{provider,baseURL,model,apiKey?}` consistent in Tasks 7, 10. **URL convention (consistent across Tasks 1, 2, 7, 11):** every `baseURL` ends at the version directory (`.../v1`, or Gemini's `.../v1beta/openai`); the chat code appends `chat/completions`. App `ServerRuntime` and server `RemoteModelClient` both append `chat/completions`; the server's pre-push default appends `v1` to `MODEL_URL` first.
