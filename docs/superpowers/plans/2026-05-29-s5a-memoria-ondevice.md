# S5a — Memoria on-device v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dar al agente (S4) memoria persistente on-device — capturar hechos del usuario (tool explícita + consolidación post-turno), almacenarlos en un grafo+vector+keyword unificado con capas y olvido tipo humano, y recuperarlos e inyectarlos relevantemente en cada turno.

**Architecture:** Capa `Memory/` nueva sobre SQLite (GRDB) + `sqlite-vec` (KNN) + FTS5 (keyword), con esquema unificado nodo/arista (cubre L1→L4 + episodios sin migración destructiva, columnas de sync listas para S5c). Embeddings on-device con Apple `NLContextualEmbedding` detrás de un protocolo `Embedder`. El `Agent` (S4) gana un `MemoryServices` opcional: recupera→inyecta en el system prompt→stream del turno→consolida async. Las tools de memoria leen `store`/`embedder` de un singleton `@MainActor` (como `ToolActivityRelay`) porque LiteRT-LM reconstruye los `Tool` vía `init()`.

**Tech Stack:** Swift, SwiftUI, XCTest, LiteRT-LM (runtime/tools), GRDB.swift (SQLite), sqlite-vec (C, vectores), Apple NaturalLanguage (`NLContextualEmbedding`). iOS deployment target 26.2.

---

## Spec

`docs/superpowers/specs/2026-05-29-s5a-memoria-ondevice-design.md` · Roadmap `00-roadmap.md` §3.2.

## Convenciones del proyecto (leer antes de ejecutar)

- Workflow: subagent-driven; commit directo a `main`. Tras tocar código: `graphify update .`.
- **Tests:** `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO` — éxito = aparece "Test Suite … passed" (IGNORAR el `** TEST FAILED **` final = crash de deinit de LiteRT en el simulador). **Nunca** `simctl erase/shutdown`. Ver [[gemma-simulator-destination]].
- **Build device:** `xcodebuild build -scheme Gemma -destination 'id=00008140-000A6216110A801C' -allowProvisioningUpdates`.
- Añadir archivos `.swift` nuevos al target: hay que agregarlos al `project.pbxproj` (vía Xcode o editando el grupo). Cada tarea que crea archivos asume que se agregan al target `Gemma` (tests al target `GemmaTests`).

## Hechos del código actual (verificados)

- **Agente:** `Gemma/Gemma/Agent/Agent.swift` — `@MainActor final class Agent`, `init(runtime: ToolCallingRuntime, registry: ToolRegistry)`, `run(prompt:options:) -> AsyncThrowingStream<AgentEvent, Error>`. `systemPrompt` es un `private var` computado hardcodeado. Mapea `GenerationEvent`→`AgentEvent` 1:1. `AgentEvent`: `.token/.toolCallStarted/.toolCallFinished/.completed/.failed`.
- **Runtime:** `Gemma/Gemma/Runtime/LiteRTLMRuntime.swift` — `@MainActor public final class LiteRTLMRuntime: ModelRuntime` (+ extensión `: ToolCallingRuntime`). Path de tools `streamWithTools` (líneas ~250-343): construye `ConversationConfig(systemMessage: Message?(.system), tools: tools, samplerConfig: SamplerConfig(topK:topP:temperature:))`, `engine.createConversation(with:)` (reset+retry once), `conv.sendMessageStream(Message(prompt))`, enforce `options.maxTokens`. Relay: setea `ToolActivityRelay.shared.sink` durante la generación. Path texto plano: `ModelRuntime.generate(prompt:image:audioURL:options:)` (líneas ~116-231).
- **ModelRuntime** (`Gemma/Gemma/Runtime/ModelRuntime.swift`): `generate(prompt:image:audioURL:options:)` (NO existe overload sin image/audio). `GenerationOptions(maxTokens:temperature:topP:topK:useSpeculativeDecoding:systemPrompt:)` (campo `maxTokens`, default 4000). `GenerationEvent`: `.token/.toolCallStarted/.toolCallFinished/.completed`. `ModelLoadOptions(modelPath:…)`. `RuntimeError`.
- **ToolCallingRuntime** (`Gemma/Gemma/Runtime/ToolCallingRuntime.swift`): `protocol ToolCallingRuntime: AnyObject { func generate(prompt:tools:[Tool]:options:) async -> AsyncThrowingStream<GenerationEvent,Error> }`. `@MainActor ToolActivityRelay` singleton: `.shared`, `var sink: ((ToolActivity)->Void)?`, `started(name:args:)`, `finished(name:result:)`.
- **Tool (LiteRT-LM)** (`vendor/LiteRT-LM/swift/Tool.swift`): `protocol Tool: Decodable { static var name: String; static var description: String; init(); func run() async throws -> Any }`. Params vía `@ToolParam(description:) var x: T` (T ∈ String/Int/Bool/Double/Float/Optionals/Arrays). **Los `Tool` se reconstruyen vía `init()` por el framework** → no reciben deps inyectadas; usan singletons `@MainActor`.
- **ToolRegistry** (`Gemma/Gemma/Agent/ToolRegistry.swift`): `@MainActor final class`, `private(set) var tools: [Tool]`, `register(_:)`, `static withDefaults()` (registra `CurrentTimeTool()`).
- **CurrentTimeTool** (`Gemma/Gemma/Agent/CurrentTimeTool.swift`): `struct …: Tool`, `static name/description`, `init(){}`, `func run() async throws -> Any` que emite por `ToolActivityRelay.shared` vía `await MainActor.run { … }`.
- **HarnessModel** (`Gemma/Gemma/Harness/HarnessModel.swift`): `@Observable @MainActor`. `@ObservationIgnored private var runtime: ModelRuntime`. `runAgentTurn(_ prompt:)` (líneas 192-211) crea el agente **por turno**: `let agent = Agent(runtime: lr, registry: ToolRegistry.withDefaults())` tras `guard let lr = runtime as? ToolCallingRuntime`. `makeGenerationOptions()` mapea `settings.maxOutputTokens/temperature/topP/topK/systemPrompt`. `agentLog: [String]`.
- **Settings:** struct `GenerationSettings` (`Gemma/Gemma/Settings/GenerationSettings.swift`, `Codable,Equatable,Sendable`): `backend, contextLength, useSpeculativeDecoding, systemPrompt, temperature, topP, topK, maxOutputTokens`; `static let default`. `SettingsStore` (`Gemma/Gemma/Settings/SettingsStore.swift`): JSON en UserDefaults key `"gemma.generationSettings.v1"`, `load()/save(_:)`. `SettingsView` usa `@State draft: GenerationSettings`, bindea `$draft.<field>`, guarda con `model.saveSettings(draft)`.
- **Modelos instalados:** `InstalledModels.defaultInDocuments()`, `status(of: descriptor) -> .installed(URL)/.notInstalled/.corrupted`. `ModelCatalog.find(id)`. IDs: `"gemma-4-e2b-it"`, `"gemma-4-e4b-it"`. (NO existe `ModelStore`.)
- **DummyRuntime:** `public actor DummyRuntime: ModelRuntime` — **no** conforma `ToolCallingRuntime`.
- **Tests:** XCTest, `@testable import Gemma`, `@MainActor final class … XCTestCase`. Stub: `final class StubRuntime: ToolCallingRuntime`. Device-gating (`AgentRuntimeTests.swift`): `InstalledModels.defaultInDocuments()` + loop sobre ids + `case .installed(let url)` else `throw XCTSkip(...)`.
- **Deps SPM:** patrón establecido = **local vendored** (`XCLocalSwiftPackageReference` → `vendor/LiteRT-LM`), `OTHER_LDFLAGS = -all_load`. GRDB no usa `unsafeFlags` → puede ir como **remoto**; si Xcode 26.2 lo rechaza, vendorizar igual que LiteRT-LM.

## File Structure

Nuevos (target `Gemma`), todos bajo `Gemma/Gemma/Memory/` salvo nota:
- `MemoryModels.swift` — `Node`, `Edge`, enums.
- `SqliteVec.swift` — registro de la extensión C.
- `CSqliteVec/sqlite-vec.c` + `sqlite-vec.h` + `Gemma/Gemma/Gemma-Bridging-Header.h`.
- `MemoryStore.swift` — GRDB: esquema, migraciones, CRUD, FTS, vec, dedup, sweep.
- `Decay.swift` — math pura.
- `Embedder.swift` — protocolo + `NLContextualEmbedder`.
- `MemoryRetriever.swift` — retrieval híbrido + render.
- `MemoryConsolidator.swift` — extracción post-turno.
- `MemoryToolbox.swift` — singleton `@MainActor` con `store`/`embedder` para las tools.
- `RememberTool.swift`, `ForgetTool.swift` — `Tool`s.
- `Harness/MemoryInspectorView.swift` — inspector UI.

Modificados:
- `Agent/Agent.swift` — `MemoryServices?` opcional, retrieve→inject→consolidate.
- `Harness/HarnessModel.swift` — `runAgentTurn` cablea memoria; `memoryStore` lazy.
- `Settings/GenerationSettings.swift` — `memoryEnabled: Bool?`.
- `Harness/SettingsView.swift` — toggle. `Harness/HarnessView.swift` — botón/sheet inspector.

Tests (target `GemmaTests`): `MemoryStoreTests`, `DecayTests`, `MemoryRetrieverTests`, `MemoryConsolidatorTests`, `MemoryToolsTests`, `AgentTests` (extender), `GenerationSettingsTests` (extender), `MemoryE2ETests` (device-gated), `SqliteVecSpikeTests` (Fase 0, temporal).

## What We're NOT Doing

Episodios/clustering, daily summary (#25), compresión (#9), importance scoring profundo (#22), soft-confidence UX (#12), multi-step linking (#15), emotional timelines, meta-grafo narrativo → **S11**. Embeddings premium, Qdrant, graphify-servidor → **S5b**. Sync device↔servidor → **S5c** (columnas creadas, no usadas). Background con app cerrada → **S0**. No se reescribe el tool-calling ni el runtime.

---

## Phase 0 — Spike de integración GRDB + sqlite-vec (de-risk primero)

Riesgo #1: que `sqlite-vec` no se integre en iOS. Validar antes de construir. Fallback documentado: vectores BLOB + coseno en Swift (misma interfaz).

### Task 0.1: Añadir GRDB

- [ ] **Step 1:** En Xcode: File ▸ Add Package Dependencies → `https://github.com/groue/GRDB.swift` → "Up to Next Major" (7.x) → producto **`GRDB`** al target `Gemma`. (Si Xcode 26.2 rechaza remoto, clonar a `vendor/GRDB.swift` y añadir como `XCLocalSwiftPackageReference`.)
- [ ] **Step 2:** Crear `Gemma/GemmaTests/SqliteVecSpikeTests.swift` con `import GRDB` y un test mínimo:
```swift
import XCTest
import GRDB
@testable import Gemma

final class SqliteVecSpikeTests: XCTestCase {
    func testGRDBOpens() throws {
        let q = try DatabaseQueue()
        let n = try q.read { try Int.fetchOne($0, sql: "SELECT 1") }
        XCTAssertEqual(n, 1)
    }
}
```
- [ ] **Step 3:** Build device para confirmar que `import GRDB` enlaza:
Run: `xcodebuild build -scheme Gemma -destination 'id=00008140-000A6216110A801C' -allowProvisioningUpdates`
Expected: BUILD SUCCEEDED.
- [ ] **Step 4:** Commit: `git add -A && git commit -m "build(s5a): add GRDB dependency"`.

### Task 0.2: Integrar sqlite-vec (C + bridging header)

- [ ] **Step 1:** Descargar la amalgamación de `asg017/sqlite-vec` (release: `sqlite-vec.c`, `sqlite-vec.h`) a `Gemma/Gemma/Memory/CSqliteVec/`. Añadir ambos al target `Gemma` (el `.c` a Compile Sources).
- [ ] **Step 2:** Crear `Gemma/Gemma/Gemma-Bridging-Header.h`:
```objc
#ifndef Gemma_Bridging_Header_h
#define Gemma_Bridging_Header_h
#include "sqlite-vec.h"
#endif
```
y setear `SWIFT_OBJC_BRIDGING_HEADER = Gemma/Gemma-Bridging-Header.h` en el target.
- [ ] **Step 3:** Crear `Gemma/Gemma/Memory/SqliteVec.swift`:
```swift
import Foundation
import SQLite3

enum SqliteVec {
    /// Registers sqlite-vec as an auto-extension so every new SQLite connection loads it.
    /// Idempotent-safe to call once at app/store startup.
    static func registerAutoExtension() {
        let fn = unsafeBitCast(sqlite3_vec_init as (@convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafePointer<sqlite3_api_routines>?) -> Int32),
                               to: (@convention(c) () -> Void).self)
        _ = sqlite3_auto_extension(fn)
    }
}
```
> Si la firma exacta de `sqlite3_vec_init` que expone el header difiere, ajustar el `unsafeBitCast` aquí. Este es el punto que la fase valida.
- [ ] **Step 4:** Escribir el test KNN en `SqliteVecSpikeTests.swift`:
```swift
    func testVecKNNRoundTrip() throws {
        SqliteVec.registerAutoExtension()
        let q = try DatabaseQueue()
        try q.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE v USING vec0(id TEXT PRIMARY KEY, e float[4])")
            try db.execute(sql: "INSERT INTO v(id, e) VALUES (?, ?)", arguments: ["a", floatsToBlob([1,0,0,0])])
            try db.execute(sql: "INSERT INTO v(id, e) VALUES (?, ?)", arguments: ["b", floatsToBlob([0,1,0,0])])
        }
        let nearest = try q.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM v WHERE e MATCH ? ORDER BY distance LIMIT 1",
                                arguments: [floatsToBlob([0.9, 0.1, 0, 0])])
        }
        XCTAssertEqual(nearest, "a")
    }
    private func floatsToBlob(_ v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }
```
- [ ] **Step 5:** Run en sim: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -only-testing:GemmaTests/SqliteVecSpikeTests`
Expected: "Test Suite 'SqliteVecSpikeTests' passed".
- [ ] **Step 6:** Build device OK (mismo comando que 0.1/Step 3).
- [ ] **Step 7:** **Decisión registrada** en el plan: ✅ sqlite-vec OK, ó ⚠️ fallback BLOB+coseno (en cuyo caso `MemoryStore.nearest` itera y calcula coseno en Swift; misma firma). Commit: `git add -A && git commit -m "build(s5a): integrate sqlite-vec (KNN smoke test green)"`.

> El spike test queda; `graphify update .`.

---

## Phase 1 — Modelos + MemoryStore (esquema, CRUD, FTS)

### Task 1.1: Modelos de dominio

**Files:** Create `Gemma/Gemma/Memory/MemoryModels.swift`

- [ ] **Step 1:** Crear el archivo:
```swift
import Foundation
import GRDB

enum NodeKind: String, Codable, CaseIterable { case person, place, fact, preference, topic, day, episode, conversation }
enum MemoryLayer: String, Codable, CaseIterable { case live, daily, identity, episodic } // episodic reservado (S11)
enum Confidence: String, Codable, CaseIterable { case sure, probable, maybe }
enum Origin: String, Codable, CaseIterable { case explicit, extracted }
enum Relation: String, Codable, CaseIterable {
    case knows, worksWith, family, likes, dislikes, locatedAt, visited, happenedOn, mentionedIn, partOfEpisode, relatedTo
}

struct Node: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var kind: NodeKind
    var label: String
    var body: String
    var layer: MemoryLayer
    var createdAt: Double
    var updatedAt: Double
    var lastSeenAt: Double
    var salience: Double
    var decayRate: Double
    var confidence: Confidence
    var mentionCount: Int
    var ttlExpiresAt: Double?
    var sourceRef: String?
    var origin: Origin
    var serverId: String?
    var dirty: Bool
    var deleted: Bool
    var extra: String?
    static let databaseTableName = "node"
}

struct Edge: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var srcId: String
    var dstId: String
    var relation: Relation
    var weight: Double
    var confidence: Confidence
    var createdAt: Double
    var updatedAt: Double
    var dirty: Bool
    var deleted: Bool
    var extra: String?
    static let databaseTableName = "edge"
}
```
- [ ] **Step 2:** Build sim para confirmar compilación: `xcodebuild build -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17'`. Expected: BUILD SUCCEEDED.
- [ ] **Step 3:** Commit: `git add -A && git commit -m "feat(s5a): memory domain models (Node/Edge/enums)"`.

### Task 1.2: MemoryStore — esquema + CRUD + FTS (TDD)

**Files:** Create `Gemma/Gemma/Memory/MemoryStore.swift`, Test `Gemma/GemmaTests/MemoryStoreTests.swift`

- [ ] **Step 1: Test que falla.** Crear `MemoryStoreTests.swift`:
```swift
import XCTest
import GRDB
@testable import Gemma

final class MemoryStoreTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    private func sampleNode(id: String = UUID().uuidString, kind: NodeKind = .preference, label: String = "sushi") -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: id, kind: kind, label: label, body: label, layer: .daily,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3,
                    decayRate: 0.001, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                    sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testUpsertAndFetch() throws {
        let store = try makeStore()
        let n = sampleNode()
        try store.upsert(n)
        XCTAssertEqual(try store.node(id: n.id)?.label, "sushi")
    }

    func testAllNodesExcludesDeleted() throws {
        let store = try makeStore()
        let n = sampleNode(); try store.upsert(n)
        try store.softDelete(nodeId: n.id)
        XCTAssertTrue(try store.allNodes().isEmpty)
        XCTAssertEqual(try store.allNodes(includeDeleted: true).count, 1)
    }

    func testFTSFindsByKeyword() throws {
        let store = try makeStore()
        try store.upsert(sampleNode(label: "sushi restaurant downtown"))
        XCTAssertEqual(try store.searchFTS(query: "sushi", limit: 5).count, 1)
    }
}
```
- [ ] **Step 2: Run → falla** (no compila / `MemoryStore` no existe):
Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO -only-testing:GemmaTests/MemoryStoreTests`
Expected: build/compile failure ("cannot find 'MemoryStore'").
- [ ] **Step 3: Implementar** `MemoryStore.swift`:
```swift
import Foundation
import GRDB

final class MemoryStore {
    let dbQueue: DatabaseQueue
    let embeddingDim: Int

    init(url: URL? = nil, inMemory: Bool = false, embeddingDim: Int) throws {
        SqliteVec.registerAutoExtension()
        self.embeddingDim = embeddingDim
        if inMemory {
            self.dbQueue = try DatabaseQueue()
        } else {
            self.dbQueue = try DatabaseQueue(path: (url ?? Self.defaultURL()).path)
        }
        try migrator.migrate(dbQueue)
    }

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.sqlite")
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1-core") { db in
            try db.create(table: "node") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("label", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("layer", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("lastSeenAt", .double).notNull()
                t.column("salience", .double).notNull()
                t.column("decayRate", .double).notNull()
                t.column("confidence", .text).notNull()
                t.column("mentionCount", .integer).notNull().defaults(to: 1)
                t.column("ttlExpiresAt", .double)
                t.column("sourceRef", .text)
                t.column("origin", .text).notNull()
                t.column("serverId", .text)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("extra", .text)
            }
            try db.create(indexOn: "node", columns: ["kind"])
            try db.create(indexOn: "node", columns: ["layer"])
            try db.create(indexOn: "node", columns: ["ttlExpiresAt"])
            try db.create(indexOn: "node", columns: ["lastSeenAt"])

            try db.create(table: "edge") { t in
                t.primaryKey("id", .text)
                t.column("srcId", .text).notNull().indexed()
                t.column("dstId", .text).notNull().indexed()
                t.column("relation", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1)
                t.column("confidence", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("extra", .text)
            }

            try db.create(virtualTable: "node_fts", using: FTS5()) { t in
                t.column("node_id")  // unindexed key
                t.column("label")
                t.column("body")
            }

            try db.execute(sql: "CREATE VIRTUAL TABLE node_vec USING vec0(node_id TEXT PRIMARY KEY, embedding float[\(self.embeddingDim)])")
        }
        return m
    }

    // MARK: CRUD
    func upsert(_ node: Node) throws {
        try dbQueue.write { db in
            try node.save(db)
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id = ?", arguments: [node.id])
            try db.execute(sql: "INSERT INTO node_fts(node_id, label, body) VALUES (?, ?, ?)",
                           arguments: [node.id, node.label, node.body])
        }
    }
    func upsert(_ edge: Edge) throws { try dbQueue.write { try edge.save($0) } }
    func node(id: String) throws -> Node? { try dbQueue.read { try Node.fetchOne($0, key: id) } }
    func allNodes(includeDeleted: Bool = false) throws -> [Node] {
        try dbQueue.read { db in
            includeDeleted ? try Node.fetchAll(db) : try Node.filter(Column("deleted") == false).fetchAll(db)
        }
    }
    func edges(from id: String) throws -> [Edge] {
        try dbQueue.read { try Edge.filter(Column("srcId") == id && Column("deleted") == false).fetchAll($0) }
    }
    func softDelete(nodeId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE node SET deleted=1, dirty=1, updatedAt=? WHERE id=?",
                           arguments: [Date().timeIntervalSince1970, nodeId])
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id=?", arguments: [nodeId])
        }
    }
    func searchFTS(query: String, limit: Int) throws -> [Node] {
        try dbQueue.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)
            guard let p = pattern else { return [] }
            let ids = try String.fetchAll(db, sql: "SELECT node_id FROM node_fts WHERE node_fts MATCH ? LIMIT ?",
                                          arguments: [p.rawPattern, limit])
            return try ids.compactMap { try Node.fetchOne(db, key: $0) }.filter { !$0.deleted }
        }
    }

    static func floatsToBlob(_ v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }
}
```
> Confirmar la API GRDB de la versión instalada (`primaryKey`, `create(indexOn:)`, `FTS5Pattern`, `save(db)`). Si `FTS5Pattern(matchingAnyTokenIn:)` o `rawPattern` difieren, ajustar el `searchFTS` (alternativa: `MATCH ?` con el texto escapado).
- [ ] **Step 4: Run → pasa** (mismo comando que Step 2). Expected: "Test Suite 'MemoryStoreTests' passed".
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): MemoryStore (GRDB schema, CRUD, FTS)"`. `graphify update .`.

---

## Phase 2 — Decay / dedup / sweep

### Task 2.1: Decay (math pura, TDD)

**Files:** Create `Gemma/Gemma/Memory/Decay.swift`, Test `Gemma/GemmaTests/DecayTests.swift`

- [ ] **Step 1: Test que falla.** `DecayTests.swift`:
```swift
import XCTest
@testable import Gemma

final class DecayTests: XCTestCase {
    func testDecaysOverTime() {
        let s0 = Decay.effectiveSalience(base: 10, decayRate: 0.001, elapsedSeconds: 0)
        let s1 = Decay.effectiveSalience(base: 10, decayRate: 0.001, elapsedSeconds: 1000)
        XCTAssertEqual(s0, 10, accuracy: 0.001)
        XCTAssertLessThan(s1, s0)
    }
    func testReinforceCaps() {
        XCTAssertEqual(Decay.reinforce(current: 9.8, bump: 0.5, cap: 10), 10, accuracy: 0.001)
    }
    func testPromote() {
        XCTAssertTrue(Decay.shouldPromote(mentionCount: 3, origin: .extracted, permanent: false))
        XCTAssertTrue(Decay.shouldPromote(mentionCount: 1, origin: .explicit, permanent: false))
        XCTAssertFalse(Decay.shouldPromote(mentionCount: 1, origin: .extracted, permanent: false))
    }
    func testForget() {
        let now = 1000.0
        XCTAssertFalse(Decay.shouldForget(layer: .identity, effectiveSalience: 0, ttlExpiresAt: 1, now: now))
        XCTAssertTrue(Decay.shouldForget(layer: .daily, effectiveSalience: 0.01, ttlExpiresAt: nil, now: now))
        XCTAssertTrue(Decay.shouldForget(layer: .live, effectiveSalience: 5, ttlExpiresAt: 999, now: now))
    }
}
```
- [ ] **Step 2: Run → falla** (`-only-testing:GemmaTests/DecayTests`). Expected: "cannot find 'Decay'".
- [ ] **Step 3: Implementar** `Decay.swift`:
```swift
import Foundation

enum Decay {
    static func effectiveSalience(base: Double, decayRate: Double, elapsedSeconds: Double) -> Double {
        base * exp(-decayRate * max(0, elapsedSeconds))
    }
    static func reinforce(current: Double, bump: Double = 0.5, cap: Double = 10) -> Double {
        min(cap, current + bump)
    }
    static func shouldPromote(mentionCount: Int, origin: Origin, permanent: Bool, threshold: Int = 3) -> Bool {
        permanent || origin == .explicit || mentionCount >= threshold
    }
    static func shouldForget(layer: MemoryLayer, effectiveSalience: Double, ttlExpiresAt: Double?, now: Double, floor: Double = 0.05) -> Bool {
        if layer == .identity { return false }
        if let ttl = ttlExpiresAt, now > ttl { return true }
        return effectiveSalience < floor
    }
    static func defaultDecayRate(for layer: MemoryLayer) -> Double {
        switch layer {
        case .live: return 1.0 / (30 * 60)
        case .daily: return 1.0 / (5 * 24 * 3600)
        case .identity: return 1.0 / (365 * 24 * 3600)
        case .episodic: return 1.0 / (90 * 24 * 3600)
        }
    }
}
```
- [ ] **Step 4: Run → pasa.** Expected: passed.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): Decay (human-like forgetting math)"`.

### Task 2.2: dedup/merge + sweep en MemoryStore (TDD)

**Files:** Modify `Gemma/Gemma/Memory/MemoryStore.swift`, Test extend `MemoryStoreTests.swift`

- [ ] **Step 1: Test que falla.** Añadir a `MemoryStoreTests`:
```swift
    func testUpsertMergingReinforces() throws {
        let store = try makeStore()
        _ = try store.upsertMerging(sampleNode(label: "sushi"))
        _ = try store.upsertMerging(sampleNode(label: "sushi"))
        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].mentionCount, 2)
    }
    func testPromotesToIdentityAtThreshold() throws {
        let store = try makeStore()
        for _ in 0..<3 { _ = try store.upsertMerging(sampleNode(label: "Juan", kind: .person)) }
        XCTAssertEqual(try store.allNodes().first?.layer, .identity)
    }
    func testSweepForgetsExpiredDailyKeepsIdentity() throws {
        let store = try makeStore()
        var daily = sampleNode(label: "tmp"); daily.ttlExpiresAt = 1; daily.lastSeenAt = 1
        var ident = sampleNode(label: "name"); ident.layer = .identity; ident.ttlExpiresAt = nil
        try store.upsert(daily); try store.upsert(ident)
        try store.sweep(now: Date().timeIntervalSince1970)
        let labels = Set(try store.allNodes().map { $0.label })
        XCTAssertFalse(labels.contains("tmp"))
        XCTAssertTrue(labels.contains("name"))
    }
```
- [ ] **Step 2: Run → falla** (`upsertMerging`/`sweep` no existen).
- [ ] **Step 3: Implementar** — añadir a `MemoryStore.swift`:
```swift
extension MemoryStore {
    func findDuplicate(kind: NodeKind, label: String) throws -> Node? {
        try dbQueue.read { db in
            try Node.filter(Column("kind") == kind.rawValue && Column("label") == label && Column("deleted") == false).fetchOne(db)
        }
    }
    @discardableResult
    func upsertMerging(_ candidate: Node) throws -> String {
        if let existing = try findDuplicate(kind: candidate.kind, label: candidate.label) {
            var merged = existing
            merged.salience = Decay.reinforce(current: existing.salience)
            merged.mentionCount = existing.mentionCount + 1
            merged.lastSeenAt = candidate.lastSeenAt
            merged.updatedAt = candidate.updatedAt
            if merged.body.isEmpty { merged.body = candidate.body }
            if Decay.shouldPromote(mentionCount: merged.mentionCount, origin: merged.origin, permanent: merged.layer == .identity) {
                merged.layer = .identity
                merged.ttlExpiresAt = nil
                merged.decayRate = Decay.defaultDecayRate(for: .identity)
            }
            merged.dirty = true
            try upsert(merged)
            return merged.id
        } else {
            try upsert(candidate)
            return candidate.id
        }
    }
    func sweep(now: Double = Date().timeIntervalSince1970) throws {
        for n in try allNodes() {
            let eff = Decay.effectiveSalience(base: n.salience, decayRate: n.decayRate, elapsedSeconds: now - n.lastSeenAt)
            if Decay.shouldForget(layer: n.layer, effectiveSalience: eff, ttlExpiresAt: n.ttlExpiresAt, now: now) {
                try softDelete(nodeId: n.id)
            }
        }
    }
}
```
- [ ] **Step 4: Run → pasa.**
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): dedup/merge + forgetting sweep"`. `graphify update .`.

---

## Phase 3 — Embedder + indexado vectorial + retriever

### Task 3.1: Embedder (protocolo + Apple + fake)

**Files:** Create `Gemma/Gemma/Memory/Embedder.swift`

- [ ] **Step 1:** Crear `Embedder.swift`:
```swift
import Foundation
import NaturalLanguage

protocol Embedder {
    var dimension: Int { get }
    func embed(_ text: String) throws -> [Float]
}

enum MemoryError: Error { case embedderUnavailable }

final class NLContextualEmbedder: Embedder {
    private let model: NLContextualEmbedding
    let dimension: Int
    init(language: NLLanguage = .spanish) throws {
        guard let m = NLContextualEmbedding(language: language) else { throw MemoryError.embedderUnavailable }
        if !m.hasAvailableAssets {
            try? m.requestAssets { _, _ in } as Void   // best-effort; see note
        }
        try m.load()
        self.model = m
        self.dimension = m.dimension
    }
    func embed(_ text: String) throws -> [Float] {
        let result = try model.embeddingResult(for: text, language: nil)
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            for i in 0..<min(dimension, vec.count) { sum[i] += vec[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [Float](repeating: 0, count: dimension) }
        return sum.map { Float($0 / Double(count)) }
    }
}

/// Deterministic fake for Mac/sim tests (no assets needed).
final class FakeEmbedder: Embedder {
    let dimension: Int
    init(dimension: Int = 4) { self.dimension = dimension }
    func embed(_ text: String) throws -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for (i, ch) in text.unicodeScalars.enumerated() { v[i % dimension] += Float(ch.value % 17) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
```
> **Confirmar en device la API real de `NLContextualEmbedding`** (`init(language:)`, `requestAssets`, `load()`, `embeddingResult(for:language:)`, `enumerateTokenVectors(in:)`, `dimension`, `hasAvailableAssets`). El `requestAssets` es async/callback — ajustar a un `prepare() async` si hace falta; si no hay assets, la app debe degradar a `embedder == nil` (retrieval no-vectorial). El `FakeEmbedder` cubre los tests Mac.
- [ ] **Step 2:** Build sim. Expected: BUILD SUCCEEDED (puede requerir ajustar el `requestAssets`; si no compila, dejar solo `try m.load()` y manejar el throw).
- [ ] **Step 3:** Commit: `git add -A && git commit -m "feat(s5a): Embedder protocol + NLContextualEmbedder + FakeEmbedder"`.

### Task 3.2: Indexado vectorial en el store (TDD)

**Files:** Modify `MemoryStore.swift`, Test extend `MemoryStoreTests.swift`

- [ ] **Step 1: Test que falla:**
```swift
    func testEmbeddingNearest() throws {
        let store = try makeStore()  // embeddingDim 4
        let a = sampleNode(label: "a"); let b = sampleNode(label: "b")
        try store.upsert(a); try store.upsert(b)
        try store.setEmbedding(nodeId: a.id, [1,0,0,0])
        try store.setEmbedding(nodeId: b.id, [0,1,0,0])
        let near = try store.nearest(to: [0.9,0.1,0,0], k: 1)
        XCTAssertEqual(near.first?.id, a.id)
    }
```
- [ ] **Step 2: Run → falla** (`setEmbedding`/`nearest` no existen).
- [ ] **Step 3: Implementar** en `MemoryStore.swift`:
```swift
extension MemoryStore {
    func setEmbedding(nodeId: String, _ vector: [Float]) throws {
        precondition(vector.count == embeddingDim, "embedding dim mismatch")
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO node_vec(node_id, embedding) VALUES (?, ?)",
                           arguments: [nodeId, Self.floatsToBlob(vector)])
        }
    }
    func nearest(to vector: [Float], k: Int) throws -> [(id: String, distance: Double)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT node_id, distance FROM node_vec WHERE embedding MATCH ? ORDER BY distance LIMIT ?",
                             arguments: [Self.floatsToBlob(vector), k])
                .map { (id: $0["node_id"] as String, distance: $0["distance"] as Double) }
        }
    }
}
```
> Si Fase 0 eligió fallback: `nearest` itera nodos con embedding y calcula coseno en Swift (misma firma). `setEmbedding` guarda el blob en una columna `node.extra`/tabla aparte.
- [ ] **Step 4: Run → pasa.**
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): vector index (sqlite-vec setEmbedding/nearest)"`.

### Task 3.3: MemoryRetriever (TDD)

**Files:** Create `Gemma/Gemma/Memory/MemoryRetriever.swift`, Test `Gemma/GemmaTests/MemoryRetrieverTests.swift`

- [ ] **Step 1: Test que falla.** `MemoryRetrieverTests.swift`:
```swift
import XCTest
@testable import Gemma

final class MemoryRetrieverTests: XCTestCase {
    private func store() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }
    private func node(_ label: String, _ kind: NodeKind) -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: UUID().uuidString, kind: kind, label: label, body: label, layer: .daily,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 5, decayRate: 0.0001,
                    confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                    origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testRetrievesByKeywordWithoutEmbedder() throws {
        let s = try store()
        try s.upsert(node("sushi", .preference))
        try s.upsert(node("pizza", .preference))
        let r = MemoryRetriever(store: s, embedder: nil)
        let got = try r.retrieve(query: "sushi", k: 5)
        XCTAssertTrue(got.contains { $0.label == "sushi" })
    }

    func testSpreadingActivationPullsNeighbors() throws {
        let s = try store()
        let juan = node("Juan", .person); let place = node("Tradzzy", .place)
        try s.upsert(juan); try s.upsert(place)
        try s.upsert(Edge(id: UUID().uuidString, srcId: juan.id, dstId: place.id, relation: .worksWith,
                          weight: 1, confidence: .probable, createdAt: 0, updatedAt: 0, dirty: true, deleted: false, extra: nil))
        let r = MemoryRetriever(store: s, embedder: nil)
        let got = try r.retrieve(query: "Juan", k: 5)
        XCTAssertTrue(got.contains { $0.label == "Tradzzy" })
    }

    func testInjectionBlockFormats() throws {
        let s = try store(); let r = MemoryRetriever(store: s, embedder: nil)
        let block = r.injectionBlock(for: [node("sushi", .preference)])
        XCTAssertTrue(block.contains("sushi"))
    }
}
```
- [ ] **Step 2: Run → falla.**
- [ ] **Step 3: Implementar** `MemoryRetriever.swift`:
```swift
import Foundation

final class MemoryRetriever {
    private let store: MemoryStore
    private let embedder: Embedder?
    init(store: MemoryStore, embedder: Embedder?) { self.store = store; self.embedder = embedder }

    func retrieve(query: String, k: Int = 8, now: Double = Date().timeIntervalSince1970) throws -> [Node] {
        var pool: [String: Node] = [:]
        var sim: [String: Double] = [:]

        if let embedder, let qv = try? embedder.embed(query) {
            for hit in (try? store.nearest(to: qv, k: k * 2)) ?? [] {
                if let n = try store.node(id: hit.id), !n.deleted {
                    pool[n.id] = n; sim[n.id] = 1.0 / (1.0 + hit.distance)
                }
            }
        }
        for n in (try? store.searchFTS(query: query, limit: k * 2)) ?? [] {
            pool[n.id] = n; sim[n.id] = max(sim[n.id] ?? 0, 0.6)
        }
        for id in Array(pool.keys) {
            for e in (try? store.edges(from: id)) ?? [] {
                if pool[e.dstId] == nil, let n = try store.node(id: e.dstId), !n.deleted {
                    pool[n.id] = n; sim[n.id] = 0.3 * (sim[id] ?? 0.5)
                }
            }
        }
        let scored = pool.values.map { n -> (Node, Double) in
            let eff = Decay.effectiveSalience(base: n.salience, decayRate: n.decayRate, elapsedSeconds: now - n.lastSeenAt)
            let recency = 1.0 / (1.0 + (now - n.lastSeenAt) / 86400.0)
            let s = (sim[n.id] ?? 0.1) * 0.6 + (eff / 10.0) * 0.25 + recency * 0.15
            return (n, s)
        }.sorted { $0.1 > $1.1 }
        return Array(scored.prefix(k).map { $0.0 })
    }

    func injectionBlock(for nodes: [Node]) -> String {
        guard !nodes.isEmpty else { return "" }
        let lines = nodes.map { "- [\($0.kind.rawValue)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }
        return "What you remember about the user (use if relevant):\n" + lines.joined(separator: "\n")
    }
}
```
- [ ] **Step 4: Run → pasa.**
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): MemoryRetriever (hybrid vector+FTS+graph+recency)"`. `graphify update .`.

---

## Phase 4 — Captura: toolbox singleton + tools + consolidador

### Task 4.1: MemoryToolbox (singleton para tools)

**Files:** Create `Gemma/Gemma/Memory/MemoryToolbox.swift`

- [ ] **Step 1:** Crear `MemoryToolbox.swift`:
```swift
import Foundation

/// Tools are reconstructed via init() by LiteRT-LM, so they can't hold injected deps.
/// They read the active store/embedder from this @MainActor singleton (like ToolActivityRelay).
/// HarnessModel/Agent sets it for the duration of a turn.
@MainActor
final class MemoryToolbox {
    static let shared = MemoryToolbox()
    var store: MemoryStore?
    var embedder: Embedder?
    private init() {}
}
```
- [ ] **Step 2:** Build sim. Expected: SUCCEEDED.
- [ ] **Step 3:** Commit: `git add -A && git commit -m "feat(s5a): MemoryToolbox shared context for tools"`.

### Task 4.2: RememberTool + ForgetTool (TDD)

**Files:** Create `RememberTool.swift`, `ForgetTool.swift`; Test `Gemma/GemmaTests/MemoryToolsTests.swift`

- [ ] **Step 1: Test que falla.** `MemoryToolsTests.swift`:
```swift
import XCTest
import LiteRTLM
@testable import Gemma

@MainActor
final class MemoryToolsTests: XCTestCase {
    func testRememberCreatesIdentityNodeWhenPermanent() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = FakeEmbedder(dimension: 4)
        defer { MemoryToolbox.shared.store = nil; MemoryToolbox.shared.embedder = nil }

        var tool = RememberTool()
        tool._content = ToolParam(wrappedValue: "user likes sushi", description: "")
        tool._kind = ToolParam(wrappedValue: "preference", description: "")
        tool._permanent = ToolParam(wrappedValue: true, description: "")
        _ = try await tool.run()

        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].layer, .identity)
        XCTAssertEqual(nodes[0].origin, .explicit)
    }

    func testForgetSoftDeletes() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        defer { MemoryToolbox.shared.store = nil }
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "x", kind: .fact, label: "sushi", body: "sushi", layer: .daily,
                              createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001,
                              confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                              origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        var tool = ForgetTool()
        tool._query = ToolParam(wrappedValue: "sushi", description: "")
        _ = try await tool.run()
        XCTAssertTrue(try store.allNodes().isEmpty)
    }
}
```
> Nota: el acceso a los backing-fields `_content`/`_kind`/etc. del `@ToolParam` para tests asume que son `internal`. Si no son accesibles, añadir a la tool un `init(content:kind:permanent:)` de conveniencia `internal` solo para tests (el framework usa el `init()` Decodable; un init extra no rompe la conformance).
- [ ] **Step 2: Run → falla.**
- [ ] **Step 3: Implementar** `RememberTool.swift`:
```swift
import Foundation
import LiteRTLM

struct RememberTool: Tool {
    static let name = "remember"
    static let description = "Save a durable fact about the user (preference, person, place, etc.) to long-term memory."

    @ToolParam(description: "The fact to remember, as a short canonical phrase.") var content: String
    @ToolParam(description: "One of: person, place, fact, preference, topic.") var kind: String?
    @ToolParam(description: "true to remember permanently (identity).") var permanent: Bool?

    init() {}

    func run() async throws -> Any {
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: content) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            let now = Date().timeIntervalSince1970
            let perm = permanent ?? false
            let layer: MemoryLayer = perm ? .identity : .daily
            let k = NodeKind(rawValue: kind ?? "fact") ?? .fact
            let node = Node(id: UUID().uuidString, kind: k, label: content, body: content, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: perm ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .sure, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                            dirty: true, deleted: false, extra: nil)
            do {
                let id = try store.upsertMerging(node)
                if let emb = MemoryToolbox.shared.embedder, let v = try? emb.embed(content) { try? store.setEmbedding(nodeId: id, v) }
                return "Saved to memory: \(content)"
            } catch { return "memory error: \(error)" }
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```
- [ ] **Step 4: Implementar** `ForgetTool.swift`:
```swift
import Foundation
import LiteRTLM

struct ForgetTool: Tool {
    static let name = "forget"
    static let description = "Forget previously remembered facts that match a query."

    @ToolParam(description: "What to forget (keywords).") var query: String

    init() {}

    func run() async throws -> Any {
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: query) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            do {
                let matches = try store.searchFTS(query: query, limit: 20)
                for m in matches { try store.softDelete(nodeId: m.id) }
                return "Forgot \(matches.count) item(s)."
            } catch { return "memory error: \(error)" }
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```
- [ ] **Step 5: Run → pasa.** (Ajustar el acceso a `@ToolParam` según la nota del Step 1 si hace falta.)
- [ ] **Step 6: Commit:** `git add -A && git commit -m "feat(s5a): remember/forget tools (via MemoryToolbox)"`.

### Task 4.3: MemoryConsolidator (TDD)

**Files:** Create `Gemma/Gemma/Memory/MemoryConsolidator.swift`, Test `Gemma/GemmaTests/MemoryConsolidatorTests.swift`

- [ ] **Step 1: Test que falla.** `MemoryConsolidatorTests.swift`:
```swift
import XCTest
import UIKit
@testable import Gemma

@MainActor
final class MemoryConsolidatorTests: XCTestCase {
    /// Emits a fixed JSON as tokens through the plain-text generate path.
    final class StubTextRuntime: ModelRuntime {
        nonisolated let identifier = "stub"
        let json: String
        init(json: String) { self.json = json }
        func isLoaded() async -> Bool { true }
        func load(options: ModelLoadOptions) async throws {}
        func unload() async {}
        func currentMetrics() async -> RuntimeMetrics? { nil }
        func generate(prompt: String, image: UIImage?, audioURL: URL?, options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            let j = json
            return AsyncThrowingStream { c in
                c.yield(.token(j))
                c.yield(.completed(GenerationResult(text: j, metrics: RuntimeMetrics(tokensGenerated: 1, elapsedSeconds: 0.01, timeToFirstTokenSeconds: 0.01, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func testConsolidatesMemoriesAndRelations() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let json = """
        noise {"memories":[{"kind":"preference","label":"sushi","body":"likes sushi","confidence":"probable","ttlHours":null},
        {"kind":"person","label":"Juan","body":"friend","confidence":"sure","ttlHours":null}],
        "relations":[{"from":"Juan","relation":"worksWith","to":"sushi"}]} trailing
        """
        let c = MemoryConsolidator(runtime: StubTextRuntime(json: json), store: store, embedder: FakeEmbedder(dimension: 4))
        await c.consolidate(user: "me gusta el sushi y Juan trabaja conmigo", assistant: "ok")
        let labels = Set(try store.allNodes().map { $0.label })
        XCTAssertTrue(labels.contains("sushi"))
        XCTAssertTrue(labels.contains("Juan"))
    }

    func testInvalidJSONIsNoOp() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let c = MemoryConsolidator(runtime: StubTextRuntime(json: "sorry, no json here"), store: store, embedder: nil)
        await c.consolidate(user: "hi", assistant: "hello")
        XCTAssertTrue(try store.allNodes().isEmpty)
    }

    func testExtractJSON() {
        XCTAssertEqual(MemoryConsolidator.extractJSON("a {\"x\":1} b"), "{\"x\":1}")
        XCTAssertNil(MemoryConsolidator.extractJSON("no braces"))
    }
}
```
- [ ] **Step 2: Run → falla.**
- [ ] **Step 3: Implementar** `MemoryConsolidator.swift`:
```swift
import Foundation

@MainActor
final class MemoryConsolidator {
    private let runtime: ModelRuntime
    private let store: MemoryStore
    private let embedder: Embedder?
    init(runtime: ModelRuntime, store: MemoryStore, embedder: Embedder?) {
        self.runtime = runtime; self.store = store; self.embedder = embedder
    }

    struct Extracted: Codable {
        struct Item: Codable { let kind: String; let label: String; let body: String?; let confidence: String?; let ttlHours: Double? }
        struct Rel: Codable { let from: String; let relation: String; let to: String }
        let memories: [Item]
        let relations: [Rel]?
    }

    private func prompt(user: String, assistant: String) -> String {
        """
        Extract durable facts about the user from this exchange as JSON only.
        Include real, useful facts (preferences, people, places, routines). If none, use empty arrays.
        Schema: {"memories":[{"kind":"person|place|fact|preference|topic","label":"short canonical","body":"detail","confidence":"sure|probable|maybe","ttlHours":null}],"relations":[{"from":"label","relation":"knows|worksWith|family|likes|locatedAt","to":"label"}]}
        Exchange:
        User: \(user)
        Assistant: \(assistant)
        JSON:
        """
    }

    func consolidate(user: String, assistant: String) async {
        let p = prompt(user: user, assistant: assistant)
        var raw = ""
        let stream = await runtime.generate(prompt: p, image: nil, audioURL: nil,
                                            options: GenerationOptions(maxTokens: 256, temperature: 0.2))
        do { for try await e in stream { if case .token(let t) = e { raw += t } } } catch { return }
        guard let json = Self.extractJSON(raw), let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Extracted.self, from: data) else { return }

        let now = Date().timeIntervalSince1970
        var labelToId: [String: String] = [:]
        for item in parsed.memories {
            let k = NodeKind(rawValue: item.kind) ?? .fact
            let ttl = item.ttlHours.map { now + $0 * 3600 }
            let layer: MemoryLayer = ttl != nil ? .live : .daily
            let node = Node(id: UUID().uuidString, kind: k, label: item.label, body: item.body ?? item.label, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: layer),
                            confidence: Confidence(rawValue: item.confidence ?? "probable") ?? .probable,
                            mentionCount: 1, ttlExpiresAt: ttl, sourceRef: nil, origin: .extracted,
                            serverId: nil, dirty: true, deleted: false, extra: nil)
            if let id = try? store.upsertMerging(node) {
                labelToId[item.label] = id
                if let embedder, let v = try? embedder.embed(node.body) { try? store.setEmbedding(nodeId: id, v) }
            }
        }
        for rel in parsed.relations ?? [] {
            guard let s = labelToId[rel.from], let d = labelToId[rel.to], let r = Relation(rawValue: rel.relation) else { continue }
            let edge = Edge(id: UUID().uuidString, srcId: s, dstId: d, relation: r, weight: 1, confidence: .probable,
                            createdAt: now, updatedAt: now, dirty: true, deleted: false, extra: nil)
            try? store.upsert(edge)
        }
        try? store.sweep()
    }

    static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        return String(s[start...end])
    }
}
```
- [ ] **Step 4: Run → pasa.**
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): MemoryConsolidator (post-turn extraction)"`. `graphify update .`.

---

## Phase 5 — Integración en el Agente y el Harness

### Task 5.1: Agent gana MemoryServices opcional (TDD)

**Files:** Modify `Gemma/Gemma/Agent/Agent.swift`, Test extend `Gemma/GemmaTests/AgentTests.swift`

- [ ] **Step 1: Test que falla.** Añadir a `AgentTests.swift` (el archivo ya tiene un `StubRuntime: ToolCallingRuntime` y patrón; añadir un stub que capture el systemPrompt):
```swift
    func testInjectsMemoryIntoSystemPrompt() async throws {
        final class CapturingRuntime: ToolCallingRuntime {
            var capturedSystemPrompt: String?
            func generate(prompt: String, tools: [Tool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
                capturedSystemPrompt = options.systemPrompt
                return AsyncThrowingStream { c in
                    c.yield(.completed(GenerationResult(text: "ok", metrics: RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    c.finish()
                }
            }
        }
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "1", kind: .preference, label: "sushi", body: "likes sushi", layer: .daily,
                              createdAt: now, updatedAt: now, lastSeenAt: now, salience: 5, decayRate: 0.0001,
                              confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                              origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        let retriever = MemoryRetriever(store: store, embedder: nil)
        let consolidator = MemoryConsolidator(runtime: DummyRuntime(), store: store, embedder: nil)
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(),
                          memory: MemoryServices(retriever: retriever, consolidator: consolidator))
        for try await _ in agent.run(prompt: "¿qué me gusta comer?", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystemPrompt?.contains("sushi") ?? false)
    }
```
> `DummyRuntime` es un `actor: ModelRuntime` (sirve como runtime de texto para el consolidador en este test; no se ejercita su salida).
- [ ] **Step 2: Run → falla** (`MemoryServices`/`memory:` no existen).
- [ ] **Step 3: Implementar** — reemplazar el contenido de `Agent.swift` por:
```swift
import Foundation
import LiteRTLM

public enum AgentEvent: Sendable {
    case token(String)
    case toolCallStarted(name: String, args: String)
    case toolCallFinished(name: String, result: String)
    case completed(GenerationResult)
    case failed(String)
}

/// Memory services injected into the Agent (nil → S4 behavior, no memory).
@MainActor
struct MemoryServices {
    let retriever: MemoryRetriever
    let consolidator: MemoryConsolidator
}

@MainActor
final class Agent {
    private let runtime: ToolCallingRuntime
    private let registry: ToolRegistry
    private let memory: MemoryServices?

    init(runtime: ToolCallingRuntime, registry: ToolRegistry, memory: MemoryServices? = nil) {
        self.runtime = runtime
        self.registry = registry
        self.memory = memory
    }

    private func systemPrompt(memoryBlock: String) -> String {
        let base = "You are Gemma, a helpful on-device assistant. You can call tools to get real information. When a tool is relevant (e.g. the user asks the time), call it instead of guessing. Use the remember tool to save durable facts the user shares."
        return memoryBlock.isEmpty ? base : base + "\n\n" + memoryBlock
    }

    func run(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = registry.tools
        var memoryBlock = ""
        if let memory, let nodes = try? memory.retriever.retrieve(query: prompt) {
            memoryBlock = memory.retriever.injectionBlock(for: nodes)
        }
        var opts = options
        opts.systemPrompt = systemPrompt(memoryBlock: memoryBlock)
        let memory = self.memory
        return AsyncThrowingStream { continuation in
            let task = Task {
                let stream = await runtime.generate(prompt: prompt, tools: tools, options: opts)
                var answer = ""
                do {
                    for try await event in stream {
                        switch event {
                        case .token(let t): answer += t; continuation.yield(.token(t))
                        case .toolCallStarted(let n, let a): continuation.yield(.toolCallStarted(name: n, args: a))
                        case .toolCallFinished(let n, let r): continuation.yield(.toolCallFinished(name: n, result: r))
                        case .completed(let res): continuation.yield(.completed(res))
                        }
                    }
                    continuation.finish()
                    if let memory {
                        let finalAnswer = answer
                        Task { await memory.consolidator.consolidate(user: prompt, assistant: finalAnswer) }
                    }
                } catch {
                    continuation.yield(.failed("\(error)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```
- [ ] **Step 4: Run → pasa.** Verificar también que los tests S4 existentes (`AgentTests` original, `ToolRegistryTests`) siguen verdes: `xcodebuild test … -only-testing:GemmaTests/AgentTests -only-testing:GemmaTests/ToolRegistryTests -parallel-testing-enabled NO`.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): Agent gains optional MemoryServices (retrieve→inject→consolidate)"`.

### Task 5.2: HarnessModel cablea memoria en runAgentTurn

**Files:** Modify `Gemma/Gemma/Harness/HarnessModel.swift`

- [ ] **Step 1:** Añadir propiedades a `HarnessModel` (junto a los demás `@ObservationIgnored` / estado):
```swift
    @ObservationIgnored private var memoryStore: MemoryStore?
    @ObservationIgnored private var embedder: Embedder?

    /// Accessor for the inspector view (Task 6.3).
    public func inspectorStore() -> MemoryStore? { memoryStore }
```
- [ ] **Step 2:** Añadir un helper lazy:
```swift
    private func ensureMemory() -> MemoryServices? {
        guard (settings.memoryEnabled ?? true) else { return nil }
        if memoryStore == nil {
            embedder = try? NLContextualEmbedder()
            let dim = embedder?.dimension ?? 512
            memoryStore = try? MemoryStore(url: try? MemoryStore.defaultURL(), embeddingDim: dim)
        }
        guard let store = memoryStore else { return nil }
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = embedder
        let retriever = MemoryRetriever(store: store, embedder: embedder)
        let consolidator = MemoryConsolidator(runtime: runtime, store: store, embedder: embedder)
        return MemoryServices(retriever: retriever, consolidator: consolidator)
    }
```
> El `embeddingDim` debe ser estable entre lanzamientos. Si el asset de NLContextualEmbedding no estaba en el primer arranque (dim 512) y luego sí (dim real), `node_vec` quedaría con dim incorrecta. Mitigación v1: persistir la dim usada al crear la DB en UserDefaults (`"gemma.memory.embeddingDim"`) y reusarla; si difiere de la del embedder actual, no setear embeddings (degradar) hasta una migración futura. Implementar esta persistencia aquí.
- [ ] **Step 3:** Modificar `runAgentTurn` para construir el registry con las tools de memoria y pasar `memory`:
```swift
    public func runAgentTurn(_ prompt: String) async {
        guard let lr = runtime as? ToolCallingRuntime else {
            agentLog.append("[agent needs the LiteRT-LM runtime loaded]"); return
        }
        agentRunning = true; defer { agentRunning = false }
        agentLog.append("you: \(prompt)")
        let memory = ensureMemory()
        let registry = ToolRegistry()
        registry.register(CurrentTimeTool())
        if memory != nil { registry.register(RememberTool()); registry.register(ForgetTool()) }
        let agent = Agent(runtime: lr, registry: registry, memory: memory)
        var answer = ""
        do {
            for try await event in agent.run(prompt: prompt, options: makeGenerationOptions()) {
                switch event {
                case .token(let t): answer += t
                case .toolCallStarted(let n, _): agentLog.append("🔧 \(n)…")
                case .toolCallFinished(let n, let r): agentLog.append("🔧 \(n) ✓ \(r)")
                case .completed: agentLog.append("gemma: \(answer)")
                case .failed(let m): agentLog.append("[error: \(m)]")
                }
            }
        } catch { agentLog.append("[error: \(error)]") }
    }
```
- [ ] **Step 4:** Build sim + device. Expected: SUCCEEDED.
- [ ] **Step 5:** Commit: `git add -A && git commit -m "feat(s5a): HarnessModel wires memory into runAgentTurn"`. `graphify update .`.

---

## Phase 6 — Settings toggle + inspector

### Task 6.1: memoryEnabled en GenerationSettings (TDD)

**Files:** Modify `Gemma/Gemma/Settings/GenerationSettings.swift`, Test extend `Gemma/GemmaTests/GenerationSettingsTests.swift`

- [ ] **Step 1: Test que falla.** Añadir:
```swift
    func testMemoryEnabledDefaultsNilDecodesOldJSON() throws {
        // Old persisted JSON without memoryEnabled must still decode.
        let oldJSON = """
        {"backend":{"gpu":{}},"contextLength":4096,"useSpeculativeDecoding":false,"systemPrompt":"","temperature":1.0,"topP":0.95,"topK":64,"maxOutputTokens":256}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(GenerationSettings.self, from: oldJSON)
        XCTAssertNil(s.memoryEnabled)   // effective default handled by caller (?? true)
    }
```
> Ajustar el encoding de `backend` (ComputeBackend es `Codable` enum) al formato real; si el decode del JSON literal es frágil, en su lugar: codificar `GenerationSettings.default` a JSON, parsear a diccionario, remover `memoryEnabled`, re-decodificar y aseverar `nil`.
- [ ] **Step 2: Run → falla** (`memoryEnabled` no existe).
- [ ] **Step 3: Implementar** — añadir el campo **opcional** a `GenerationSettings` (struct + cualquier init explícito; al ser opcional, el decode de JSON viejo lo deja `nil`):
```swift
    public var memoryEnabled: Bool?
```
(añadirlo después de `maxOutputTokens`; si hay un `init` con parámetros, darle `memoryEnabled: Bool? = nil`).
- [ ] **Step 4: Run → pasa.**
- [ ] **Step 5: Commit:** `git add -A && git commit -m "feat(s5a): memoryEnabled setting (back-compat optional)"`.

### Task 6.2: Toggle en SettingsView

**Files:** Modify `Gemma/Gemma/Harness/SettingsView.swift`

- [ ] **Step 1:** Añadir una fila/Section donde estén los demás `$draft.*` (p.ej. en `parametersTab`):
```swift
            Section("Memory") {
                Toggle("Enable memory (S5a)", isOn: Binding(
                    get: { draft.memoryEnabled ?? true },
                    set: { draft.memoryEnabled = $0 }
                ))
            }
```
- [ ] **Step 2:** Build sim. Expected: SUCCEEDED.
- [ ] **Step 3:** Commit: `git add -A && git commit -m "feat(s5a): memory toggle in SettingsView"`.

### Task 6.3: Inspector de memoria

**Files:** Create `Gemma/Gemma/Harness/MemoryInspectorView.swift`, Modify `Gemma/Gemma/Harness/HarnessView.swift`

- [ ] **Step 1:** Crear `MemoryInspectorView.swift`:
```swift
import SwiftUI

struct MemoryInspectorView: View {
    let store: MemoryStore?
    @State private var nodes: [Node] = []
    var body: some View {
        List(nodes) { n in
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(n.kind.rawValue)/\(n.layer.rawValue)] \(n.label)").font(.subheadline).bold()
                if !n.body.isEmpty, n.body != n.label { Text(n.body).font(.caption) }
                Text("salience \(String(format: "%.2f", n.salience)) · ×\(n.mentionCount) · \(n.confidence.rawValue)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Memory")
        .task { reload() }
        .toolbar { Button("Reload") { reload() } }
    }
    private func reload() { nodes = (try? store?.allNodes()) ?? [] }
}
```
- [ ] **Step 2:** En `HarnessView.swift`, añadir un botón (junto al de "Agent") y un `.sheet` que presente `NavigationStack { MemoryInspectorView(store: model.inspectorStore()) }` (usar el accessor expuesto en Task 5.2; añadir un `@State showMemory` o reusar el patrón de `showAgent`). Incluir el botón en la misma barra que abre Agent/Settings.
- [ ] **Step 3:** Build sim + device. Expected: SUCCEEDED.
- [ ] **Step 4:** Commit: `git add -A && git commit -m "feat(s5a): memory inspector view"`. `graphify update .`.

---

## Phase 7 — E2E en device + cierre

### Task 7.1: Test E2E device-gated

**Files:** Create `Gemma/GemmaTests/MemoryE2ETests.swift`

- [ ] **Step 1:** Crear el test (patrón de `AgentRuntimeTests`):
```swift
import XCTest
@testable import Gemma
import LiteRTLM

@MainActor
final class MemoryE2ETests: XCTestCase {
    private func installedModelURL() throws -> URL {
        let store = InstalledModels.defaultInDocuments()
        for id in ["gemma-4-e2b-it", "gemma-4-e4b-it"] {
            if let d = ModelCatalog.find(id), case .installed(let url) = store.status(of: d) { return url }
        }
        throw XCTSkip("No Gemma 4 .litertlm installed — device-only E2E.")
    }

    func testRemembersAcrossTurns() async throws {
        let url = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        defer { Task { await runtime.unload() } }

        let embedder = try? NLContextualEmbedder()
        let dim = embedder?.dimension ?? 512
        let store = try MemoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).sqlite"), embeddingDim: dim)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = embedder
        defer { MemoryToolbox.shared.store = nil; MemoryToolbox.shared.embedder = nil }

        let registry = ToolRegistry()
        registry.register(RememberTool()); registry.register(ForgetTool())
        let retriever = MemoryRetriever(store: store, embedder: embedder)
        let consolidator = MemoryConsolidator(runtime: runtime, store: store, embedder: embedder)
        let agent = Agent(runtime: runtime, registry: registry,
                          memory: MemoryServices(retriever: retriever, consolidator: consolidator))

        for try await _ in agent.run(prompt: "Me llamo Roilan, me gusta el sushi y mi amigo Juan trabaja conmigo.", options: GenerationOptions(maxTokens: 200)) {}
        try await Task.sleep(nanoseconds: 8_000_000_000)  // let async consolidation finish
        XCTAssertFalse(try store.allNodes().isEmpty, "consolidation should have stored memories")

        var answer = ""
        for try await e in agent.run(prompt: "¿Qué me gusta comer?", options: GenerationOptions(maxTokens: 128)) {
            if case .token(let t) = e { answer += t }
        }
        XCTAssertTrue(answer.lowercased().contains("sushi"), "should recall sushi; got: \(answer)")
    }
}
```
> Device-only; depende del E4B (puede ser flaky). Valor principal = run manual. Documentar tasa de acierto.
- [ ] **Step 2:** Build device OK; el test se salta en sim sin modelo. Commit: `git add -A && git commit -m "test(s5a): device-gated memory E2E"`.

### Task 7.2: Verificación manual en device

- [ ] **Step 1:** Build+run en iPhone 16 (Xcode o `xcodebuild build -destination 'id=00008140-000A6216110A801C' -allowProvisioningUpdates`). Cargar Gemma 4, abrir sheet **Agent**.
- [ ] **Step 2:** Turno: "Me llamo Roilan, me gusta el sushi, mi amigo Juan trabaja conmigo." → respuesta normal (posible `remember`).
- [ ] **Step 3:** Abrir **Memory** inspector → confirmar nodos `person:Juan`, `preference:sushi`, nodo `day`, aristas.
- [ ] **Step 4:** Nuevo turno: "¿Qué me gusta comer?" → usa la memoria (sushi). "¿Quién es Juan?" → recall por grafo.
- [ ] **Step 5:** Matar y relanzar la app → repetir Step 4 → la memoria persiste.

### Task 7.3: Cierre

- [ ] **Step 1:** Suite completa en sim: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO`. Expected: "Test Suite … passed" (ignorar el `** TEST FAILED **` de deinit del sim).
- [ ] **Step 2:** Registrar resultado (tasa de acierto del recall; tuning de pesos/threshold si hizo falta) en `docs/superpowers/specs/01-s1-runtime-report.md` (nueva §9 — Memoria S5a).
- [ ] **Step 3:** `00-roadmap.md` §3.2: marcar S5a hecho/verificado.
- [ ] **Step 4:** `graphify update .`; actualizar [[gemma-project-state]].
- [ ] **Step 5:** Commit: `git add -A && git commit -m "docs(s5a): record memory E2E result; mark S5a done"`.

---

## Testing Strategy

- **Unit (Mac/sim):** store (migración/CRUD/FTS/dedup/sweep/vector), `Decay` (pura), retriever (FakeEmbedder + fixtures, spreading-activation, degradación sin embedder), consolidador (StubTextRuntime + JSON canónico/ruidoso/inválido), tools (MemoryToolbox), Agent (inyección + back-compat sin memoria), settings (back-compat decode). Stores in-memory, deps tras protocolo.
- **Device-gated:** paths reales de `NLContextualEmbedder`/`sqlite-vec` y el E2E (`MemoryE2ETests`) — `XCTSkip` sin modelo.
- **Edge cases:** JSON inválido (no corromper DB), embedder ausente (degradar a FTS+grafo), dim de embedding cambiante (persistir dim), identity nunca olvidado, TTL vencido olvidado, dedup refuerza vs duplica.

## Performance Considerations

- 2ª pasada del E4B (consolidación) async post-respuesta (no bloquea el stream); v1 solo app activa (background = S0). **Riesgo de solape:** si el usuario lanza otro turno mientras consolida, dos generaciones compiten por la única sesión del engine. Mitigación v1: serializar (un flag/`Task` guardado en HarnessModel que espere la consolidación previa) — anotar; si causa errores `FAILED_PRECONDITION`, implementar la serialización.
- `sqlite-vec` KNN + FTS5 rápidos a escala personal; índices en `kind/layer/ttl/lastSeen/edge.src/dst`.
- Spreading-activation a 1 hop; `k≈8`; bloque de inyección acotado para no inflar el prompt.

## Self-Review (cobertura del spec)

- Esquema unificado nodo/arista + sync cols → Task 1.1/1.2. Capas + olvido humano → Phase 2. Captura híbrida (tools + consolidación) → Phase 4. Retrieval híbrido + inyección #18 → Task 3.3 + 5.1. Integración Agente → Phase 5. Settings + inspector → Phase 6. Embeddings Apple tras protocolo → Task 3.1. Device E2E + persistencia → Phase 7. sqlite-vec/GRDB de-risk → Phase 0. ✅ sin huecos.

## References

- Spec: `docs/superpowers/specs/2026-05-29-s5a-memoria-ondevice-design.md`
- Tool API real: `Gemma/Gemma/Runtime/LiteRTLMRuntime.swift` (`streamWithTools`, `ConversationConfig`); `vendor/LiteRT-LM/swift/Tool.swift`, `Config.swift`
- Patrón tool/registro: `Gemma/Gemma/Agent/CurrentTimeTool.swift`, `ToolRegistry.swift`; relay: `Gemma/Gemma/Runtime/ToolCallingRuntime.swift`
- Test + device-gating: `Gemma/GemmaTests/AgentRuntimeTests.swift`, `AgentTests.swift`
- Settings: `Gemma/Gemma/Settings/GenerationSettings.swift`, `SettingsStore.swift`, `Gemma/Gemma/Harness/SettingsView.swift`
- GRDB: https://github.com/groue/GRDB.swift · sqlite-vec: https://github.com/asg017/sqlite-vec · NaturalLanguage `NLContextualEmbedding` (iOS 17+)
- Gotchas: [[litertlm-spm-workaround]], [[gemma-simulator-destination]], [[gemma-project-state]]
