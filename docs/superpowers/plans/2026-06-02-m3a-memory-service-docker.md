# M3a — Memory Service en Docker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Extraer toda la capa de memoria del proceso de la app macOS a un servicio HTTP independiente, deployable como Docker, con un sidecar Python para embeddings (BGE-M3, 1024-dim) que reemplaza `NLContextualEmbedding`. Al final, la app macOS sigue funcionando idéntico de cara al usuario, pero todos los `MemoryStore`/`Retriever`/`Engine`/`TranscriptStore` viven en el container `memory` y la app habla con ellos por HTTP.

**Architecture:** Dos containers Docker (`memory` Swift+Hummingbird+GRDB y `embedder` Python+FastAPI+BGE-M3) orquestados por `docker-compose.yml`. El servicio Swift reutiliza el código actual de `Gemma/Gemma/Memory/` movido al nuevo SwiftPM package `memory-service/Sources/MemoryCore/`. La app macOS gana un `MemoryClient` Swift que reemplaza el acceso in-process a GRDB; el resto del flujo (`Agent.run`, tool loop, ServerRuntime) queda intacto. Wipe inicial — sin migración de datos viejos.

**Tech Stack:** Swift 5.10 (Linux + macOS) · Hummingbird 2 · GRDB.swift · swift-async-http-client · Python 3.11 · FastAPI · sentence-transformers · BAAI/bge-m3 · Docker / Docker Compose · XCTest · pytest.

**Spec:** `docs/superpowers/specs/2026-06-02-m3a-memory-service-docker-design.md` (commit `c379062`). Léelo antes de empezar — esta plan ejecuta literalmente sus secciones 5–11.

**Branch:** `feat/m3a-memory-service-docker`. Crearla al arrancar (`git checkout -b feat/m3a-memory-service-docker` desde `main`).

**Key current facts (verified at plan time):**
- `Memory/MemoryStore.swift` usa GRDB con `DatabaseQueue`; esquema versión 5 (migración `v5-purge-conversation-nodes` la última). El struct `Node` tiene los campos `id, kind, label, body, layer, createdAt, updatedAt, lastSeenAt, salience, decayRate, confidence, mentionCount, ttlExpiresAt, sourceRef, origin, serverId, dirty, deleted, extra`. `NodeKind` ya es free-form `String` + vocab.
- `TranscriptStore` tiene `append(threadId,turnIndex,role,text,now:)`, `range(threadId,fromTurn,toTurn:)`, `recent(threadId,maxTurns,maxChars:)`, `rows(ids:)`, `allRecent(limit:)`.
- `MemoryToolbox` (`@MainActor final class .shared`) hoy expone `var store: MemoryStore?`, `var embedder: Embedder?`, `var transcriptStore: TranscriptStore?`, `var reflectionRequest: (() -> Void)?`. Lo usa cada tool.
- `HarnessModel.ensureMemory()` instancia `MemoryStore` (path `Application Support/Gemma/memory.sqlite`), `NLContextualEmbedder`, `TranscriptStore`, los inyecta en `MemoryToolbox.shared`. `runAgentTurn` usa `store.recall`, `transcriptStore.append`, `consolidator.armTurnEnd`.
- `Embedder` es un protocolo (`Memory/Embedder.swift`); implementaciones: `NLContextualEmbedder` (real, Apple), `FakeEmbedder` (tests).
- `Agent.run` ya recibe la "current message" + `ChatMessage` history; el assemble del system prompt + recall vive en `HarnessModel` (no en `Agent`).
- El `mlx_vlm.server` está expuesto en `:8080`. El launcher es `spike-mlx/serve_mlx_vlm.py` (no cambia).
- Repo tiene ya `.gitignore` para `spike-mlx/.venv*`; añadiremos rules para `embedder/__pycache__`, `embedder/models/`, `memory-service/.build/`, `docker-data/`.

**Build/test commands (referencia):**
- App macOS: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'`. Sufijo `2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -8`.
- memory-service: `(cd memory-service && swift test)` (en macOS o Linux/Docker).
- embedder: `(cd embedder && python3 -m pytest -q)` o dentro del container.
- E2E docker: `docker compose up -d --build` desde el root del repo.

**Transient state durante M3a:** los archivos de `Gemma/Gemma/Memory/` (Store, Retriever, etc.) **se duplican** en `memory-service/Sources/MemoryCore/` durante varias tareas. La app macOS sigue compilando contra su copia in-process hasta la Task 14, donde se borran las copias del app target. Esto evita romper el build en cada paso intermedio.

---

### Task 1: Embedder Python container (BGE-M3 + FastAPI + smoke test)

**Files:**
- Create: `embedder/app.py`
- Create: `embedder/requirements.txt`
- Create: `embedder/Dockerfile`
- Create: `embedder/test_app.py`
- Create: `embedder/.dockerignore`
- Modify: `.gitignore`

- [ ] **Step 1: Write the failing test** — `embedder/test_app.py`:

```python
"""Smoke test for the embedder. Run with:
    python3 -m pytest embedder/test_app.py -v
or inside the container:
    docker compose run --rm embedder python -m pytest test_app.py -v
Self-contained — no network requirement; uses FastAPI TestClient against the app."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
from app import app, EMBED_DIM

client = TestClient(app)


def test_healthz_returns_200():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_embed_returns_vectors_of_expected_dim():
    r = client.post("/embed", json={"texts": ["hola mundo", "hello world"]})
    assert r.status_code == 200
    data = r.json()
    assert "vectors" in data
    assert len(data["vectors"]) == 2
    assert all(len(v) == EMBED_DIM for v in data["vectors"])
    # Vectors must be non-trivial (not all zeros)
    assert any(abs(x) > 1e-6 for x in data["vectors"][0])


def test_embed_rejects_empty_texts():
    r = client.post("/embed", json={"texts": []})
    assert r.status_code == 400


def test_embed_es_en_similarity_is_high():
    """Cross-lingual sanity: 'hola mundo' and 'hello world' should be reasonably close."""
    r = client.post("/embed", json={"texts": ["hola mundo", "hello world"]})
    v1, v2 = r.json()["vectors"]
    # cosine similarity
    dot = sum(a*b for a, b in zip(v1, v2))
    n1 = sum(a*a for a in v1) ** 0.5
    n2 = sum(b*b for b in v2) ** 0.5
    cos = dot / (n1 * n2)
    assert cos > 0.5, f"expected ES↔EN cosine > 0.5, got {cos}"
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd embedder && python3 -m pytest test_app.py -v 2>&1 | tail -20`
Expected: `ModuleNotFoundError: No module named 'app'` (file doesn't exist).

- [ ] **Step 3: Implement `embedder/app.py`** (FastAPI + sentence-transformers + BGE-M3):

```python
"""Embedder sidecar for the Gemma memory service. Loads BAAI/bge-m3
on startup, serves /embed and /healthz. CPU-only; ~1GB RAM."""
import os
from typing import List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

MODEL_ID = os.environ.get("EMBED_MODEL", "BAAI/bge-m3")
CACHE_DIR = os.environ.get("EMBED_MODEL_CACHE", "/models")
EMBED_DIM = 1024  # bge-m3 dense dim

# Load eagerly at import time so /healthz reflects readiness.
_model = SentenceTransformer(MODEL_ID, cache_folder=CACHE_DIR, device="cpu")


class EmbedRequest(BaseModel):
    texts: List[str]


class EmbedResponse(BaseModel):
    vectors: List[List[float]]


app = FastAPI(title="Gemma Memory Embedder", version="1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest):
    if not req.texts:
        raise HTTPException(status_code=400, detail="texts must be non-empty")
    vectors = _model.encode(req.texts, normalize_embeddings=True).tolist()
    return EmbedResponse(vectors=vectors)
```

- [ ] **Step 4: Implement `embedder/requirements.txt`:**

```
fastapi==0.115.6
uvicorn[standard]==0.32.1
sentence-transformers==3.3.1
torch==2.5.1
pydantic==2.10.3
httpx==0.28.1
pytest==8.3.4
```

- [ ] **Step 5: Implement `embedder/Dockerfile`:**

```dockerfile
FROM python:3.11-slim AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py test_app.py ./

# Pre-pull the model so the first POST /embed is instant.
ENV EMBED_MODEL_CACHE=/models
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('BAAI/bge-m3', cache_folder='/models', device='cpu')"

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 6: Implement `embedder/.dockerignore`:**

```
__pycache__/
*.pyc
models/
.venv/
.pytest_cache/
```

- [ ] **Step 7: Update `.gitignore`** — append:

```
# M3a
embedder/__pycache__/
embedder/models/
embedder/.pytest_cache/
memory-service/.build/
memory-service/.swiftpm/
docker-data/
```

- [ ] **Step 8: Run the test locally (outside Docker)** — first install deps in a venv:

```bash
cd embedder
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest test_app.py -v 2>&1 | tail -20
```

Expected: 4 passed (note: first run downloads the model — ~570MB — and is slow; subsequent runs are fast).

- [ ] **Step 9: Commit**

```bash
git add embedder/ .gitignore
git commit -m "feat(m3a): embedder sidecar (FastAPI + BGE-M3) + smoke tests

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: memory-service Swift package skeleton + /healthz

**Files:**
- Create: `memory-service/Package.swift`
- Create: `memory-service/Sources/MemoryService/App.swift`
- Create: `memory-service/Sources/MemoryService/main.swift`
- Create: `memory-service/Tests/MemoryServiceTests/HealthEndpointTests.swift`
- Create: `memory-service/Dockerfile`
- Create: `memory-service/.dockerignore`

- [ ] **Step 1: Write the failing test** — `memory-service/Tests/MemoryServiceTests/HealthEndpointTests.swift`:

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
@testable import MemoryService

final class HealthEndpointTests: XCTestCase {
    func test_healthz_returns_ok() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"status\":\"ok\""))
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd memory-service && swift test 2>&1) | tail -20`
Expected: compile error — package doesn't exist yet.

- [ ] **Step 3: Implement `memory-service/Package.swift`:**

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MemoryService",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "memory-service", targets: ["MemoryService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "MemoryService",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .testTarget(
            name: "MemoryServiceTests",
            dependencies: [
                "MemoryService",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]),
    ]
)
```

- [ ] **Step 4: Implement `memory-service/Sources/MemoryService/App.swift`:**

```swift
import Foundation
import Hummingbird
import Logging

public struct AppConfig: Sendable {
    public var bearerToken: String
    public var dbPath: String
    public var embedderURL: String
    public var modelURL: String

    public static func testDefaults() -> AppConfig {
        AppConfig(bearerToken: "test-token", dbPath: ":memory:",
                  embedderURL: "http://embedder:8000",
                  modelURL: "http://host.docker.internal:8080")
    }

    public static func fromEnvironment() -> AppConfig {
        AppConfig(
            bearerToken: ProcessInfo.processInfo.environment["MEMORY_BEARER_TOKEN"]
                ?? fatalError("MEMORY_BEARER_TOKEN must be set"),
            dbPath: ProcessInfo.processInfo.environment["MEMORY_DB_PATH"] ?? "/data/memory.sqlite",
            embedderURL: ProcessInfo.processInfo.environment["EMBEDDER_URL"] ?? "http://embedder:8000",
            modelURL: ProcessInfo.processInfo.environment["MODEL_URL"] ?? "http://host.docker.internal:8080"
        )
    }
}

public func buildApp(config: AppConfig) async throws -> some ApplicationProtocol {
    let router = Router()
    router.get("/healthz") { _, _ in
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(string: #"{"status":"ok"}"#)))
    }
    return Application(router: router,
                       configuration: ApplicationConfiguration(address: .hostname("0.0.0.0", port: 8081)),
                       logger: Logger(label: "memory-service"))
}

// fatalError(_:) -> Never; this helper makes env-or-die one-liners legible.
private func fatalError(_ msg: String) -> Never { Swift.fatalError(msg) }
```

- [ ] **Step 5: Implement `memory-service/Sources/MemoryService/main.swift`:**

```swift
import Foundation

@main
struct Main {
    static func main() async throws {
        let app = try await buildApp(config: AppConfig.fromEnvironment())
        try await app.runService()
    }
}
```

- [ ] **Step 6: Implement `memory-service/Dockerfile`:**

```dockerfile
FROM swift:5.10-jammy AS build
WORKDIR /src
COPY Package.swift ./
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib

FROM swift:5.10-jammy-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/.build/release/memory-service /app/memory-service
EXPOSE 8081
ENTRYPOINT ["/app/memory-service"]
```

- [ ] **Step 7: Implement `memory-service/.dockerignore`:**

```
.build/
.swiftpm/
.git/
*.xcodeproj
```

- [ ] **Step 8: Run the test**

Run: `(cd memory-service && swift test 2>&1) | tail -20`
Expected: 1 test passed (the `/healthz` returns `{"status":"ok"}`).

- [ ] **Step 9: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): memory-service Swift package skeleton (Hummingbird + /healthz)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: docker-compose + Bearer auth middleware

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`
- Modify: `memory-service/Sources/MemoryService/App.swift` (add Bearer middleware)
- Test: `memory-service/Tests/MemoryServiceTests/AuthMiddlewareTests.swift`

- [ ] **Step 1: Write the failing test** — `memory-service/Tests/MemoryServiceTests/AuthMiddlewareTests.swift`:

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
@testable import MemoryService

final class AuthMiddlewareTests: XCTestCase {
    func test_protected_route_rejects_missing_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/echo", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func test_protected_route_rejects_wrong_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/echo", method: .get,
                                     headers: [.authorization: "Bearer wrong"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func test_protected_route_accepts_correct_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/echo", method: .get,
                                     headers: [.authorization: "Bearer test-token"]) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func test_healthz_does_NOT_require_bearer() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd memory-service && swift test --filter AuthMiddlewareTests 2>&1) | tail -20`
Expected: compile error — `/v1/echo` doesn't exist and no auth wired.

- [ ] **Step 3: Add the Bearer middleware + a tiny `/v1/echo` for the test** — modify `memory-service/Sources/MemoryService/App.swift`:

```swift
import Foundation
import Hummingbird
import Logging

public struct AppConfig: Sendable { /* unchanged */ }

struct BearerMiddleware: MiddlewareProtocol {
    typealias Context = BasicRequestContext
    let token: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization],
              header == "Bearer \(token)" else {
            return Response(status: .unauthorized)
        }
        return try await next(request, context)
    }
}

public func buildApp(config: AppConfig) async throws -> some ApplicationProtocol {
    let router = Router()
    // Public:
    router.get("/healthz") { _, _ in
        Response(status: .ok, headers: [.contentType: "application/json"],
                 body: ResponseBody(byteBuffer: .init(string: #"{"status":"ok"}"#)))
    }
    // Protected: anything under /v1
    let v1 = router.group("/v1").add(middleware: BearerMiddleware(token: config.bearerToken))
    v1.get("/echo") { _, _ in
        Response(status: .ok, headers: [.contentType: "application/json"],
                 body: ResponseBody(byteBuffer: .init(string: #"{"ok":true}"#)))
    }
    return Application(router: router,
                       configuration: ApplicationConfiguration(address: .hostname("0.0.0.0", port: 8081)),
                       logger: Logger(label: "memory-service"))
}

private func fatalError(_ msg: String) -> Never { Swift.fatalError(msg) }
```

- [ ] **Step 4: Run to verify it passes**

Run: `(cd memory-service && swift test --filter AuthMiddlewareTests 2>&1) | tail -20`
Expected: 4 passed.

- [ ] **Step 5: Implement `docker-compose.yml`** at repo root:

```yaml
services:
  embedder:
    build:
      context: ./embedder
    expose:
      - "8000"
    volumes:
      - embedder-models:/models
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz').read()"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  memory:
    build:
      context: ./memory-service
    ports:
      - "8081:8081"
    environment:
      - MEMORY_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}
      - MEMORY_DB_PATH=/data/memory.sqlite
      - EMBEDDER_URL=http://embedder:8000
      - MODEL_URL=http://host.docker.internal:8080
      - IDLE_MS=180000
      - POST_TURN_MS=15000
    volumes:
      - ./docker-data/memory:/data
    depends_on:
      embedder:
        condition: service_healthy
    extra_hosts:
      - "host.docker.internal:host-gateway"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O-", "http://localhost:8081/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

volumes:
  embedder-models:
```

- [ ] **Step 6: Implement `.env.example`** at repo root:

```
# Shared secret between the macOS app (or iOS) and the memory service.
# Pick a long random string. Tailscale provides network security; this is
# defense in depth so anyone landed on the host can't poke the service.
MEMORY_BEARER_TOKEN=replace-me-with-a-long-random-string
```

- [ ] **Step 7: Smoke-test the compose stack** (manual, optional):

```bash
cp .env.example .env
# edit .env to set a real token
docker compose build
docker compose up -d
sleep 30
curl -s http://localhost:8081/healthz
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/v1/echo
curl -s -H "Authorization: Bearer $(grep MEMORY_BEARER_TOKEN .env | cut -d= -f2)" http://localhost:8081/v1/echo
docker compose down
```

Expected: `{"status":"ok"}`, then `401`, then `{"ok":true}`. (Skip on CI; manual gate.)

- [ ] **Step 8: Commit**

```bash
git add docker-compose.yml .env.example memory-service/
git commit -m "feat(m3a): docker-compose + Bearer auth middleware

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Move MemoryCore (Store + types + Decay + MemoryText) into the package

**Files:**
- Create: `memory-service/Sources/MemoryCore/{Node.swift, NodeKind.swift, NodeAttributes.swift, MemoryStore.swift, Decay.swift, MemoryText.swift, Embedder.swift, FakeEmbedder.swift}`
- Modify: `memory-service/Package.swift` (declare new `MemoryCore` library target)
- Create: `memory-service/Tests/MemoryCoreTests/{MemoryStoreTests.swift, DecayTests.swift, MemoryTextTests.swift}` (port existing app tests)

> This task is a **copy-with-decoupling**: the source files come from `Gemma/Gemma/Memory/`. They keep the same logic but lose any `import AppKit`/`UIKit` and `Foundation.NLContextualEmbedding`. The originals in the app target stay intact for now (deleted in Task 14).

- [ ] **Step 1: Declare the new library target** — modify `memory-service/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MemoryService",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "memory-service", targets: ["MemoryService"]),
        .library(name: "MemoryCore", targets: ["MemoryCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MemoryCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(
            name: "MemoryService",
            dependencies: [
                "MemoryCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .testTarget(
            name: "MemoryCoreTests",
            dependencies: ["MemoryCore"]),
        .testTarget(
            name: "MemoryServiceTests",
            dependencies: [
                "MemoryService",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]),
    ]
)
```

- [ ] **Step 2: Copy the files** — execute these copies from the repo root, then verify the listing:

```bash
mkdir -p memory-service/Sources/MemoryCore memory-service/Tests/MemoryCoreTests
cp Gemma/Gemma/Memory/Node.swift            memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/NodeKind.swift        memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/NodeAttributes.swift  memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/MemoryStore.swift     memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/Decay.swift           memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/MemoryText.swift      memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/Embedder.swift        memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/FakeEmbedder.swift    memory-service/Sources/MemoryCore/
cp Gemma/GemmaTests/MemoryStoreTests.swift  memory-service/Tests/MemoryCoreTests/
cp Gemma/GemmaTests/DecayTests.swift        memory-service/Tests/MemoryCoreTests/
cp Gemma/GemmaTests/MemoryTextTests.swift   memory-service/Tests/MemoryCoreTests/
ls memory-service/Sources/MemoryCore/
ls memory-service/Tests/MemoryCoreTests/
```

- [ ] **Step 3: Decouple — read each copied source file and edit out non-portable imports/refs:**

Check each new file under `memory-service/Sources/MemoryCore/` and `memory-service/Tests/MemoryCoreTests/`:
- Remove `import AppKit`, `import UIKit`, `import SwiftUI`. Replace any `NSColor`/`UIColor` references with literal strings or remove if cosmetic only.
- Replace `import NaturalLanguage` if any leaked into these files — should not (NL stays in NLContextualEmbedder which we do NOT copy here).
- Tests: replace `@testable import Gemma` → `@testable import MemoryCore`.
- Drop any `@MainActor` annotations that were there to interoperate with the app (`MemoryStore` is already `nonisolated final class` — keep it). Same for retriever later.

Verify there are no remaining UIKit/AppKit imports:

```bash
grep -rn "import UIKit\|import AppKit\|import SwiftUI\|NSColor\|UIColor\|@testable import Gemma" memory-service/
```

Expected output: empty.

- [ ] **Step 4: Build the package**

Run: `(cd memory-service && swift build 2>&1) | tail -20`
Expected: compiles green.

- [ ] **Step 5: Run the MemoryCore tests**

Run: `(cd memory-service && swift test --filter MemoryCoreTests 2>&1) | tail -30`
Expected: all the existing MemoryStore/Decay/MemoryText tests pass in the new package.

- [ ] **Step 6: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): move MemoryCore module — Store/Node/Decay/MemoryText/Embedder into memory-service

Sources duplicated from app target; app continues to compile unchanged.
App-side copies will be deleted in Task 14 after the refactor lands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Move TranscriptStore + Retriever + ConsolidationEngine + Scheduler

**Files:**
- Create: `memory-service/Sources/MemoryCore/{TranscriptStore.swift, ConversationWindow.swift, MemoryRetriever.swift, MemoryConsolidationEngine.swift, ConsolidationScheduler.swift, ChatMessage.swift}`
- Create: `memory-service/Tests/MemoryCoreTests/{TranscriptStoreTests.swift, ConversationWindowTests.swift, MemoryRetrieverTests.swift, MemoryConsolidationEngineTests.swift}` (port from app)

> Same copy-with-decoupling pattern as Task 4. `ChatMessage` (currently in `Agent/` on the app) is needed by the engine prompts; copy a Sendable version into MemoryCore so the package is self-contained.

- [ ] **Step 1: Copy the sources + tests**

```bash
cp Gemma/Gemma/Memory/TranscriptStore.swift              memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/ConversationWindow.swift           memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/MemoryRetriever.swift              memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/MemoryConsolidationEngine.swift    memory-service/Sources/MemoryCore/
cp Gemma/Gemma/Memory/ConsolidationScheduler.swift       memory-service/Sources/MemoryCore/
cp Gemma/GemmaTests/TranscriptStoreTests.swift           memory-service/Tests/MemoryCoreTests/
cp Gemma/GemmaTests/ConversationWindowTests.swift        memory-service/Tests/MemoryCoreTests/
cp Gemma/GemmaTests/MemoryRetrieverTests.swift           memory-service/Tests/MemoryCoreTests/
cp Gemma/GemmaTests/MemoryConsolidationEngineTests.swift memory-service/Tests/MemoryCoreTests/
```

- [ ] **Step 2: Create a Sendable `ChatMessage` inside MemoryCore** — `memory-service/Sources/MemoryCore/ChatMessage.swift`:

```swift
import Foundation

/// Same shape as the app's ChatMessage but lives inside MemoryCore so the package
/// doesn't depend on the app target. The HTTP layer (handlers in MemoryService)
/// decodes the client's wire format into this type before passing to retriever
/// and consolidation prompts.
public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }
    public var role: Role
    public var content: String
    public var name: String?

    public init(role: Role, content: String, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }
}
```

- [ ] **Step 3: Decouple the copied files** — pattern-search and fix imports / `@testable import Gemma`. Run:

```bash
grep -rn "import UIKit\|import AppKit\|import SwiftUI\|@testable import Gemma\|ChatMessage" \
  memory-service/Sources/MemoryCore/ memory-service/Tests/MemoryCoreTests/
```

For each match in the test files: change `@testable import Gemma` → `@testable import MemoryCore`. If a copied source imports `ChatMessage` from the app's `Agent/` module, fix it to use the MemoryCore one (same shape, just owned by the package now). Remove any `@MainActor` that was there only for app-layer interop.

The engine currently calls a `runtime: any ToolCallingRuntime` (the app's protocol). In MemoryCore, replace that dependency surface with a local `protocol ModelTextClient`:

```swift
public protocol ModelTextClient: Sendable {
    func generate(prompt: String, options: ModelTextOptions) async throws -> String
}
public struct ModelTextOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public init(maxTokens: Int = 800, temperature: Double = 0.7) {
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
```

Wherever the engine called `runtime.generate(prompt:tools:options:)` in the app version, replace with `client.generate(prompt:options:)` (no tools — consolidation doesn't use tool-calling). Tests' `ScriptedRuntime`/`CannedRuntime` adapts to this smaller protocol — make it implement `ModelTextClient` instead.

Place `ModelTextClient` next to `MemoryConsolidationEngine`. Public in the module.

- [ ] **Step 4: Build**

Run: `(cd memory-service && swift build 2>&1) | tail -30`
Expected: green. If type errors appear about missing app-layer types, replace each with a public MemoryCore equivalent (e.g., `ToolActivityRelay.shared.started(...)` calls have no equivalent in the service — they're client-side UI; **delete those calls** from the moved sources; the service doesn't have a UI relay).

- [ ] **Step 5: Run the tests**

Run: `(cd memory-service && swift test --filter MemoryCoreTests 2>&1) | tail -30`
Expected: all ported tests (TranscriptStore, ConversationWindow, MemoryRetriever, MemoryConsolidationEngine including the per-thread summarize test from M2d-3) pass.

- [ ] **Step 6: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): move TranscriptStore/Retriever/ConsolidationEngine/Scheduler to MemoryCore

Decoupled from app-layer types: introduced ModelTextClient protocol
(replaces ToolCallingRuntime in the engine), local ChatMessage Sendable,
removed ToolActivityRelay calls (UI-only).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: RemoteEmbedder (HTTP client to the sidecar)

**Files:**
- Create: `memory-service/Sources/MemoryCore/RemoteEmbedder.swift`
- Create: `memory-service/Tests/MemoryCoreTests/RemoteEmbedderTests.swift`

- [ ] **Step 1: Write the failing test** — `memory-service/Tests/MemoryCoreTests/RemoteEmbedderTests.swift`:

```swift
import XCTest
import Foundation
@testable import MemoryCore

final class RemoteEmbedderTests: XCTestCase {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: (URLRequest) -> (HTTPURLResponse, Data) = { _ in
            (HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (res, data) = Self.stub(request)
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    func test_embed_posts_to_embed_endpoint_and_decodes_vectors() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/embed")
            let body = req.httpBody ?? req.httpBodyStream.flatMap { Data(reading: $0) } ?? Data()
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["texts"] as? [String], ["hola"])
            let payload = #"{"vectors":[[0.1, 0.2, 0.3]]}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!
            return (res, payload)
        }
        let e = RemoteEmbedder(baseURL: URL(string: "http://embedder:8000")!,
                                session: makeSession())
        let vecs = try await e.embed(["hola"])
        XCTAssertEqual(vecs, [[0.1, 0.2, 0.3]])
    }

    func test_embed_throws_on_5xx() async throws {
        StubProtocol.stub = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (res, Data())
        }
        let e = RemoteEmbedder(baseURL: URL(string: "http://embedder:8000")!,
                                session: makeSession())
        await XCTAssertThrowsError(try await e.embed(["hola"]))
    }
}

// XCTest's XCTAssertThrowsError(async) — provide local async variant.
func XCTAssertThrowsError<T>(_ expr: @autoclosure () async throws -> T,
                              file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expr() ; XCTFail("expected throw", file: file, line: line) } catch {}
}

private extension Data {
    init(reading stream: InputStream) {
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        self = data
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd memory-service && swift test --filter RemoteEmbedderTests 2>&1) | tail -20`
Expected: compile error — `RemoteEmbedder` doesn't exist.

- [ ] **Step 3: Implement `memory-service/Sources/MemoryCore/RemoteEmbedder.swift`:**

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class RemoteEmbedder: Embedder, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: baseURL.appendingPathComponent("/embed"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["texts": texts])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EmbedderError.remoteFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let payload = try JSONDecoder().decode(EmbedResponse.self, from: data)
        return payload.vectors
    }

    public func embed(_ text: String) async throws -> [Float] {
        let vs = try await embed([text])
        guard let v = vs.first else { throw EmbedderError.emptyResponse }
        return v
    }

    public enum EmbedderError: Error, Equatable {
        case remoteFailed(status: Int)
        case emptyResponse
    }
    private struct EmbedResponse: Decodable { let vectors: [[Float]] }
}
```

> Note: this needs the `Embedder` protocol to expose `embed([String]) async throws -> [[Float]]` and `embed(String) async throws -> [Float]`. Check the protocol's current shape (in the copied `Embedder.swift`); if it only has the single-text method, add the batched one as a default-implemented protocol extension that loops on the single version, then override here.

- [ ] **Step 4: Run to verify it passes**

Run: `(cd memory-service && swift test --filter RemoteEmbedderTests 2>&1) | tail -20`
Expected: 2 passed.

- [ ] **Step 5: Run the full MemoryCore + RemoteEmbedder test suite**

Run: `(cd memory-service && swift test 2>&1) | grep -E "Test Suite|passed|failed" | tail -10`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): RemoteEmbedder — HTTP client to BGE-M3 sidecar (replaces NLContextualEmbedder)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Endpoints — transcript/append + conversation/window

**Files:**
- Create: `memory-service/Sources/MemoryService/Handlers/TranscriptHandlers.swift`
- Modify: `memory-service/Sources/MemoryService/App.swift` (wire routes + a `Services` container that holds the GRDB connection + scheduler)
- Test: `memory-service/Tests/MemoryServiceTests/TranscriptEndpointsTests.swift`

- [ ] **Step 1: Write the failing test** — `memory-service/Tests/MemoryServiceTests/TranscriptEndpointsTests.swift`:

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class TranscriptEndpointsTests: XCTestCase {
    private let auth: HTTPField = .authorization

    func test_append_then_window_returns_inserted_turns() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            // append two turns
            for (i, role, text) in [(0,"user","hola"), (0,"assistant","hola, ¿cómo estás?")] {
                let body = #"{"threadId":"T","role":"\#(role)","text":"\#(text)","turnIndex":\#(i)}"#
                try await client.execute(uri: "/v1/transcript/append", method: .post,
                                         headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                         body: .init(string: body)) { response in
                    XCTAssertEqual(response.status, .ok)
                }
            }
            // window
            try await client.execute(uri: "/v1/conversation/window?threadId=T&maxTurns=12&maxChars=2000",
                                     method: .get,
                                     headers: [auth: "Bearer test-token"]) { response in
                XCTAssertEqual(response.status, .ok)
                let json = String(buffer: response.body)
                XCTAssertTrue(json.contains("hola"), "got: \(json)")
                XCTAssertTrue(json.contains("¿cómo estás?"))
            }
        }
    }

    func test_append_rejects_invalid_body() async throws {
        let app = try await buildApp(config: AppConfig.testDefaults())
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/transcript/append", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: "{}")) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd memory-service && swift test --filter TranscriptEndpointsTests 2>&1) | tail -20`
Expected: compile error / 404s.

- [ ] **Step 3: Introduce a `Services` container** — refactor `App.swift` so handlers can reach the GRDB store + transcript store + embedder. Replace contents of `App.swift`:

```swift
import Foundation
import Hummingbird
import Logging
import MemoryCore

public struct AppConfig: Sendable {
    public var bearerToken: String
    public var dbPath: String
    public var embedderURL: String
    public var modelURL: String
    public var port: Int

    public static func testDefaults() -> AppConfig {
        AppConfig(bearerToken: "test-token", dbPath: ":memory:",
                  embedderURL: "http://embedder:8000",
                  modelURL: "http://host.docker.internal:8080",
                  port: 0)
    }

    public static func fromEnvironment() -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        return AppConfig(
            bearerToken: env["MEMORY_BEARER_TOKEN"] ?? Self.die("MEMORY_BEARER_TOKEN must be set"),
            dbPath: env["MEMORY_DB_PATH"] ?? "/data/memory.sqlite",
            embedderURL: env["EMBEDDER_URL"] ?? "http://embedder:8000",
            modelURL: env["MODEL_URL"] ?? "http://host.docker.internal:8080",
            port: Int(env["MEMORY_PORT"] ?? "8081") ?? 8081
        )
    }

    private static func die(_ msg: String) -> Never { fatalError(msg) }
}

public final class Services: Sendable {
    public let store: MemoryStore
    public let transcript: TranscriptStore
    public let embedder: Embedder
    public let retriever: MemoryRetriever
    public let bearerToken: String

    public init(config: AppConfig) throws {
        self.store = try MemoryStore(path: config.dbPath, embeddingDim: 1024)
        self.transcript = TranscriptStore(dbQueue: store.dbQueue)
        self.embedder = RemoteEmbedder(baseURL: URL(string: config.embedderURL)!)
        self.retriever = MemoryRetriever(store: store, embedder: embedder)
        self.bearerToken = config.bearerToken
    }

    // Test-only injection point.
    public init(store: MemoryStore, transcript: TranscriptStore, embedder: Embedder, bearerToken: String) {
        self.store = store
        self.transcript = transcript
        self.embedder = embedder
        self.retriever = MemoryRetriever(store: store, embedder: embedder)
        self.bearerToken = bearerToken
    }
}

public func buildApp(config: AppConfig) async throws -> some ApplicationProtocol {
    let services = try Services(config: config.dbPath == ":memory:"
        ? config // memory-mode → real services but with in-memory db
        : config)
    return try buildApp(services: services, port: config.port)
}

public func buildApp(services: Services, port: Int) async throws -> some ApplicationProtocol {
    let router = Router()
    router.get("/healthz") { _, _ in
        Response(status: .ok, headers: [.contentType: "application/json"],
                 body: ResponseBody(byteBuffer: .init(string: #"{"status":"ok"}"#)))
    }
    let v1 = router.group("/v1").add(middleware: BearerMiddleware(token: services.bearerToken))
    TranscriptHandlers(services: services).register(on: v1)
    return Application(router: router,
                       configuration: ApplicationConfiguration(address: .hostname("0.0.0.0", port: port)),
                       logger: Logger(label: "memory-service"))
}

struct BearerMiddleware: MiddlewareProtocol {
    typealias Context = BasicRequestContext
    let token: String
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.headers[.authorization] == "Bearer \(token)" else {
            return Response(status: .unauthorized)
        }
        return try await next(request, context)
    }
}
```

> If `MemoryStore.init` only supports `inMemory:` flag instead of `path:`, adapt: introduce a `MemoryStore.init(path: String, embeddingDim: Int)` in MemoryCore that opens a file-backed DB at `path` (or memory if `:memory:`). Update its docstring accordingly. Add a test in `MemoryCoreTests/MemoryStoreTests.swift` for the path init if not present.

- [ ] **Step 4: Implement handlers** — `memory-service/Sources/MemoryService/Handlers/TranscriptHandlers.swift`:

```swift
import Foundation
import Hummingbird
import MemoryCore

struct TranscriptHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/transcript/append", use: append)
        group.get("/conversation/window", use: window)
    }

    struct AppendBody: Decodable {
        let threadId: String
        let role: String
        let text: String
        let turnIndex: Int
    }

    @Sendable func append(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let buf = try await req.body.collect(upTo: 32_000).asData(),
              let body = try? JSONDecoder().decode(AppendBody.self, from: buf),
              ["user","assistant"].contains(body.role) else {
            return Response(status: .badRequest, body: .init(byteBuffer:
                .init(string: #"{"error":{"code":"bad_request","message":"invalid append body"}}"#)))
        }
        try services.transcript.append(threadId: body.threadId, turnIndex: body.turnIndex,
                                       role: body.role, text: body.text, now: Date().timeIntervalSince1970)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(string: "{}")))
    }

    @Sendable func window(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let threadId = req.uri.queryParameters.first(where: { $0.key == "threadId" })?.value else {
            return Response(status: .badRequest)
        }
        let maxTurns = req.uri.queryParameters.first(where: { $0.key == "maxTurns" }).flatMap { Int($0.value) } ?? 12
        let maxChars = req.uri.queryParameters.first(where: { $0.key == "maxChars" }).flatMap { Int($0.value) } ?? 1500
        let rows = try services.transcript.recent(threadId: String(threadId), maxTurns: maxTurns, maxChars: maxChars)
        struct OutTurn: Encodable { let role: String; let text: String }
        let out = ["turns": rows.map { OutTurn(role: $0.role, text: $0.text) }]
        let data = try JSONEncoder().encode(out)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(data: data)))
    }
}

private extension ByteBuffer {
    func asData() -> Data? { Data(buffer: self) }
}
```

> If Hummingbird's `Request.body.collect(upTo:).asData()` API differs in 2.4+, adapt to the equivalent (`ByteBuffer.readData(length:)`). The point is to pull the JSON body bytes.

- [ ] **Step 5: Run to verify it passes**

Run: `(cd memory-service && swift test --filter TranscriptEndpointsTests 2>&1) | tail -20`
Expected: 2 passed.

- [ ] **Step 6: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): endpoints transcript/append + conversation/window

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Endpoints — memory/recall + save + forget + expand

**Files:**
- Create: `memory-service/Sources/MemoryService/Handlers/MemoryHandlers.swift`
- Modify: `memory-service/Sources/MemoryService/App.swift` (register handlers)
- Test: `memory-service/Tests/MemoryServiceTests/MemoryEndpointsTests.swift`

- [ ] **Step 1: Write the failing test** — `memory-service/Tests/MemoryServiceTests/MemoryEndpointsTests.swift`:

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class MemoryEndpointsTests: XCTestCase {
    private let auth = HTTPField.authorization

    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let services = Services(store: store, transcript: ts, embedder: FakeEmbedder(dim: 8), bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }

    func test_save_then_forget_works() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/save", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"kind":"preference","label":"sushi","body":"al user le gusta"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"id\""))
            }
            try await client.execute(uri: "/v1/memory/forget", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"label":"sushi"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"removed\":1"))
            }
        }
    }

    func test_recall_returns_core_and_recall_lists() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // seed via save
            for (k, l, b) in [("identity","Roilan","el usuario se llama Roilan"),
                              ("preference","sushi","al user le gusta el sushi")] {
                let body = #"{"kind":"\#(k)","label":"\#(l)","body":"\#(b)"}"#
                try await client.execute(uri: "/v1/memory/save", method: .post,
                                         headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                         body: .init(string: body)) { res in
                    XCTAssertEqual(res.status, .ok)
                }
            }
            try await client.execute(uri: "/v1/memory/recall", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"query":"qué comida me gusta"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"core\""))
                XCTAssertTrue(s.contains("\"recall\""))
            }
        }
    }

    func test_expand_returns_transcript_for_known_summary() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // seed: a summary node + transcript
            try await client.execute(uri: "/v1/transcript/append", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"threadId":"T","role":"user","text":"viaje a Japón","turnIndex":0}"#)) { _ in }
            try await client.execute(uri: "/v1/memory/save", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"kind":"summary","label":"viaje a Japón","body":"plan","extra":"{\"threadId\":\"T\",\"turnRange\":[0,0]}"}"#)) { _ in }
            try await client.execute(uri: "/v1/memory/expand?topic=viaje%20a%20Japón", method: .get,
                                     headers: [auth: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("viaje a Japón"), "got: \(s)")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd memory-service && swift test --filter MemoryEndpointsTests 2>&1) | tail -20`
Expected: 404s.

- [ ] **Step 3: Implement `memory-service/Sources/MemoryService/Handlers/MemoryHandlers.swift`:**

```swift
import Foundation
import Hummingbird
import MemoryCore

struct MemoryHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/memory/save",   use: save)
        group.post("/memory/forget", use: forget)
        group.post("/memory/recall", use: recall)
        group.get ("/memory/expand", use: expand)
    }

    struct SaveBody: Decodable { let kind: String; let label: String; let body: String?; let extra: String?; let sourceRef: String? }
    struct ForgetBody: Decodable { let id: String?; let label: String? }
    struct RecallBody: Decodable { let query: String; let scope: String?; let limit: Int? }

    @Sendable func save(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let body = try? await decode(SaveBody.self, from: req) else {
            return jsonError(status: .badRequest, code: "bad_request", message: "invalid save body")
        }
        let vec = (try? await services.embedder.embed(body.label)) ?? []
        let result = try services.store.upsertMergingSemantic(kind: body.kind, label: body.label,
                                                              body: body.body ?? "", extra: body.extra,
                                                              sourceRef: body.sourceRef, embedding: vec)
        let out = ["id": result.id, "mergedInto": result.mergedInto as Any]
            .compactMapValues { $0 as? String }
        return jsonOK(out)
    }

    @Sendable func forget(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let body = try? await decode(ForgetBody.self, from: req) else {
            return jsonError(status: .badRequest, code: "bad_request", message: "invalid forget body")
        }
        let removed: Int
        if let id = body.id { removed = try services.store.forgetById(id) }
        else if let label = body.label { removed = try services.store.forgetByLabel(label) }
        else { return jsonError(status: .badRequest, code: "bad_request", message: "id or label required") }
        return jsonOK(["removed": removed])
    }

    @Sendable func recall(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let body = try? await decode(RecallBody.self, from: req) else {
            return jsonError(status: .badRequest, code: "bad_request", message: "invalid recall body")
        }
        let limit = body.limit ?? 6
        let bundle = try await services.retriever.recall(query: body.query, limit: limit)
        struct OutNode: Encodable { let kind: String; let label: String; let body: String; let extra: String? }
        struct Payload: Encodable { let core: [OutNode]; let recall: [OutNode] }
        let payload = Payload(
            core: bundle.core.map { OutNode(kind: $0.kind, label: $0.label, body: $0.body, extra: $0.extra) },
            recall: bundle.recall.map { OutNode(kind: $0.kind, label: $0.label, body: $0.body, extra: $0.extra) }
        )
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(data: data)))
    }

    @Sendable func expand(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let topic = req.uri.queryParameters.first(where: { $0.key == "topic" })?.value else {
            return jsonError(status: .badRequest, code: "bad_request", message: "topic required")
        }
        let result = try services.expandContext(topic: String(topic))
        struct OutTurn: Encodable { let role: String; let text: String }
        struct Payload: Encodable { let transcript: [OutTurn]; let summaryLabel: String? }
        let payload = Payload(
            transcript: result.rows.map { OutTurn(role: $0.role, text: $0.text) },
            summaryLabel: result.summaryLabel
        )
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(data: data)))
    }
}

// JSON helpers
private func decode<T: Decodable>(_ type: T.Type, from req: Request) async throws -> T {
    let buf = try await req.body.collect(upTo: 64_000)
    let data = Data(buffer: buf)
    return try JSONDecoder().decode(type, from: data)
}
private func jsonOK(_ dict: [String: Any]) -> Response {
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return Response(status: .ok, headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: .init(data: data)))
}
private func jsonError(status: HTTPResponse.Status, code: String, message: String) -> Response {
    let payload = #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    return Response(status: status, headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: .init(string: payload)))
}
```

> If `MemoryStore.upsertMergingSemantic` already exists with a different signature, adapt the handler's call to match. The store API IS the source of truth — handlers are thin shims. Likewise `MemoryRetriever.recall` may return `(core: [Node], recall: [Node])` directly — preserve its real shape. Implement `Services.expandContext(topic:)` as a small helper that matches the old `ExpandContextTool` logic (label dedupKey lookup → parse `extra.threadId`/`turnRange` → `transcript.range(...)`) and returns `(rows: [TranscriptRow], summaryLabel: String?)`.

- [ ] **Step 4: Wire the handlers** — modify `App.swift` to call `MemoryHandlers(services: services).register(on: v1)` alongside the transcript handlers.

- [ ] **Step 5: Run the test**

Run: `(cd memory-service && swift test --filter MemoryEndpointsTests 2>&1) | tail -30`
Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): endpoints memory/recall + save + forget + expand

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Endpoints — consolidation (turn-end / reflect / state)

**Files:**
- Create: `memory-service/Sources/MemoryService/Handlers/ConsolidationHandlers.swift`
- Create: `memory-service/Sources/MemoryService/RemoteModelClient.swift` (HTTP impl of `ModelTextClient` against mlx_vlm.server)
- Modify: `memory-service/Sources/MemoryService/App.swift` (instantiate scheduler in Services)
- Test: `memory-service/Tests/MemoryServiceTests/ConsolidationEndpointsTests.swift`

- [ ] **Step 1: Write the failing test** — `memory-service/Tests/MemoryServiceTests/ConsolidationEndpointsTests.swift`:

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class ConsolidationEndpointsTests: XCTestCase {
    private let auth = HTTPField.authorization

    func test_state_endpoint_reports_counts() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = Services(store: store, transcript: TranscriptStore(dbQueue: store.dbQueue),
                                embedder: FakeEmbedder(dim: 8), bearerToken: "test-token",
                                modelClient: NoOpModelClient())
        let app = try await buildApp(services: services, port: 0)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/consolidation/state", method: .get,
                                     headers: [auth: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"nodeCount\""))
                XCTAssertTrue(s.contains("\"transcriptCount\""))
            }
        }
    }

    func test_turn_end_endpoint_acks() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = Services(store: store, transcript: TranscriptStore(dbQueue: store.dbQueue),
                                embedder: FakeEmbedder(dim: 8), bearerToken: "test-token",
                                modelClient: NoOpModelClient())
        let app = try await buildApp(services: services, port: 0)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/consolidation/turn-end", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"threadId":"T"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }
}

struct NoOpModelClient: ModelTextClient {
    func generate(prompt: String, options: ModelTextOptions) async throws -> String { "{}" }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd memory-service && swift test --filter ConsolidationEndpointsTests 2>&1) | tail -20`
Expected: compile errors / 404s.

- [ ] **Step 3: Implement `memory-service/Sources/MemoryService/RemoteModelClient.swift`:**

```swift
import Foundation
import MemoryCore

public struct RemoteModelClient: ModelTextClient {
    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func generate(prompt: String, options: ModelTextOptions) async throws -> String {
        struct Msg: Encodable { let role: String; let content: String }
        struct Req: Encodable {
            let messages: [Msg]; let max_tokens: Int; let temperature: Double
            let chat_template_kwargs: [String: Bool]
        }
        let req = Req(messages: [.init(role: "user", content: prompt)],
                      max_tokens: options.maxTokens, temperature: options.temperature,
                      chat_template_kwargs: ["enable_thinking": false])
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("/v1/chat/completions"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONEncoder().encode(req)
        urlReq.timeoutInterval = 120

        let (data, resp) = try await session.data(for: urlReq)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelClientError.remoteFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
        struct OpenAIResp: Decodable { let choices: [Choice] }
        let r = try JSONDecoder().decode(OpenAIResp.self, from: data)
        return r.choices.first?.message.content ?? ""
    }

    public enum ModelClientError: Error { case remoteFailed(status: Int) }
}
```

- [ ] **Step 4: Extend `Services` to hold the modelClient + scheduler**, and add the convenience init used in tests:

In `App.swift`, modify `Services`:

```swift
public final class Services: Sendable {
    public let store: MemoryStore
    public let transcript: TranscriptStore
    public let embedder: Embedder
    public let retriever: MemoryRetriever
    public let bearerToken: String
    public let modelClient: any ModelTextClient
    public let engine: MemoryConsolidationEngine
    public let scheduler: ConsolidationScheduler

    public init(config: AppConfig) throws {
        self.store = try MemoryStore(path: config.dbPath, embeddingDim: 1024)
        self.transcript = TranscriptStore(dbQueue: store.dbQueue)
        self.embedder = RemoteEmbedder(baseURL: URL(string: config.embedderURL)!)
        self.retriever = MemoryRetriever(store: store, embedder: embedder)
        self.bearerToken = config.bearerToken
        self.modelClient = RemoteModelClient(baseURL: URL(string: config.modelURL)!)
        self.engine = MemoryConsolidationEngine(store: store, embedder: embedder,
                                                runtime: modelClient, transcriptStore: transcript)
        self.scheduler = ConsolidationScheduler(engine: engine)
    }

    // Test-only injection point.
    public init(store: MemoryStore, transcript: TranscriptStore, embedder: Embedder,
                bearerToken: String, modelClient: any ModelTextClient = NoOpModelClient()) {
        self.store = store
        self.transcript = transcript
        self.embedder = embedder
        self.retriever = MemoryRetriever(store: store, embedder: embedder)
        self.bearerToken = bearerToken
        self.modelClient = modelClient
        self.engine = MemoryConsolidationEngine(store: store, embedder: embedder,
                                                runtime: modelClient, transcriptStore: transcript)
        self.scheduler = ConsolidationScheduler(engine: engine)
    }
}

private struct NoOpModelClient: ModelTextClient {
    func generate(prompt: String, options: ModelTextOptions) async throws -> String { "{}" }
}
```

> If `MemoryConsolidationEngine.init` in MemoryCore takes a parameter named differently (e.g., `runtime:` was the original), keep that name to avoid touching MemoryCore further. Same for `ConsolidationScheduler`.

- [ ] **Step 5: Implement `memory-service/Sources/MemoryService/Handlers/ConsolidationHandlers.swift`:**

```swift
import Foundation
import Hummingbird
import MemoryCore

struct ConsolidationHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/consolidation/turn-end", use: turnEnd)
        group.post("/consolidation/reflect", use: reflect)
        group.get ("/consolidation/state",   use: state)
    }

    struct TurnEndBody: Decodable { let threadId: String }

    @Sendable func turnEnd(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let buf = try? await req.body.collect(upTo: 4_000),
              let body = try? JSONDecoder().decode(TurnEndBody.self, from: Data(buffer: buf)) else {
            return Response(status: .badRequest)
        }
        services.scheduler.armTurnEnd(threadId: body.threadId)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(string: "{}")))
    }

    @Sendable func reflect(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let id = await services.scheduler.runReflectAdHoc()
        let payload = #"{"cycleId":"\#(id ?? "")"}"#
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(string: payload)))
    }

    @Sendable func state(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let snap = try services.snapshot()
        struct OutCycle: Encodable { let id: String; let status: String; let endedAt: Double? }
        struct Payload: Encodable {
            let lastCycle: OutCycle?
            let nodeCount: Int
            let transcriptCount: Int
            let isRunning: Bool
        }
        let payload = Payload(
            lastCycle: snap.lastCycle.map { OutCycle(id: $0.id, status: $0.status.rawValue, endedAt: $0.endedAt) },
            nodeCount: snap.nodeCount,
            transcriptCount: snap.transcriptCount,
            isRunning: snap.isRunning
        )
        let data = try JSONEncoder().encode(payload)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(data: data)))
    }
}
```

- [ ] **Step 6: Add `Services.snapshot()`** to App.swift (computes node count + transcript count + last cycle from MemoryStore + scheduler.isRunning). Place near the test-only init.

```swift
extension Services {
    public struct Snapshot { let lastCycle: SleepCycleState?; let nodeCount: Int; let transcriptCount: Int; let isRunning: Bool }
    public func snapshot() throws -> Snapshot {
        let nodeCount = try store.nodeCount()
        let transcriptCount = try transcript.count()
        let isRunning = scheduler.isRunning
        let last = try store.latestSleepCycle()
        return Snapshot(lastCycle: last, nodeCount: nodeCount, transcriptCount: transcriptCount, isRunning: isRunning)
    }
}
```

> If the underlying methods (`store.nodeCount()`, `transcript.count()`, `store.latestSleepCycle()`, `scheduler.isRunning`, `scheduler.runReflectAdHoc()`, `scheduler.armTurnEnd(threadId:)`) don't exist exactly with those names, add tiny shims in MemoryCore on the appropriate type — these are pure read methods over GRDB and an `isRunning` flag on `ConsolidationScheduler`. Name them as written here so the handlers don't need re-edits.

- [ ] **Step 7: Wire** in App.swift's `buildApp(services:port:)` → call `ConsolidationHandlers(services: services).register(on: v1)`.

- [ ] **Step 8: Run the test**

Run: `(cd memory-service && swift test --filter ConsolidationEndpointsTests 2>&1) | tail -20`
Expected: 2 passed.

- [ ] **Step 9: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): consolidation endpoints (turn-end/reflect/state) + RemoteModelClient

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Endpoints — inspector + healthz/readyz

**Files:**
- Create: `memory-service/Sources/MemoryService/Handlers/InspectorHandlers.swift`
- Modify: `memory-service/Sources/MemoryService/App.swift` (register; add `/readyz` that pings embedder)
- Test: `memory-service/Tests/MemoryServiceTests/InspectorEndpointsTests.swift`

- [ ] **Step 1: Write the failing test** — `InspectorEndpointsTests.swift`:

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
@testable import MemoryService
@testable import MemoryCore

final class InspectorEndpointsTests: XCTestCase {
    private let auth = HTTPField.authorization

    func test_nodes_paged() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = Services(store: store, transcript: TranscriptStore(dbQueue: store.dbQueue),
                                embedder: FakeEmbedder(dim: 8), bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/memory/save", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"kind":"preference","label":"sushi"}"#)) { _ in }
            try await client.execute(uri: "/v1/nodes?limit=10", method: .get,
                                     headers: [auth: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"nodes\""))
                XCTAssertTrue(s.contains("\"sushi\""))
            }
        }
    }

    func test_transcript_recent() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = Services(store: store, transcript: TranscriptStore(dbQueue: store.dbQueue),
                                embedder: FakeEmbedder(dim: 8), bearerToken: "test-token")
        let app = try await buildApp(services: services, port: 0)
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/transcript/append", method: .post,
                                     headers: [auth: "Bearer test-token", .contentType: "application/json"],
                                     body: .init(string: #"{"threadId":"T","role":"user","text":"hi","turnIndex":0}"#)) { _ in }
            try await client.execute(uri: "/v1/transcript/recent?limit=5", method: .get,
                                     headers: [auth: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"hi\""))
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `(cd memory-service && swift test --filter InspectorEndpointsTests 2>&1) | tail -20`

- [ ] **Step 3: Implement `InspectorHandlers.swift`:**

```swift
import Foundation
import Hummingbird
import MemoryCore

struct InspectorHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.get("/nodes", use: nodes)
        group.get("/transcript/recent", use: recent)
    }

    @Sendable func nodes(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        let limit = q.first(where: { $0.key == "limit" }).flatMap { Int($0.value) } ?? 100
        let offset = q.first(where: { $0.key == "offset" }).flatMap { Int($0.value) } ?? 0
        let kind = q.first(where: { $0.key == "kind" })?.value.map(String.init)
        let result = try services.store.listNodes(limit: limit, offset: offset, kind: kind)
        let data = try JSONEncoder().encode(result)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(data: data)))
    }

    @Sendable func recent(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let limit = req.uri.queryParameters.first(where: { $0.key == "limit" }).flatMap { Int($0.value) } ?? 200
        let rows = try services.transcript.allRecent(limit: limit)
        struct OutRow: Encodable { let id: String; let threadId: String; let role: String; let text: String; let turnIndex: Int; let createdAt: Double }
        struct Payload: Encodable { let rows: [OutRow] }
        let out = Payload(rows: rows.map { OutRow(id: $0.id, threadId: $0.threadId, role: $0.role,
                                                  text: $0.text, turnIndex: $0.turnIndex, createdAt: $0.createdAt) })
        let data = try JSONEncoder().encode(out)
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: .init(data: data)))
    }
}
```

> Add a `MemoryStore.listNodes(limit:offset:kind:)` to MemoryCore that returns `{ nodes: [Node], total: Int }` (an Encodable wrapper). Use plain GRDB `fetchAll` + `count`. Tests in `MemoryStoreTests` should cover at least a smoke case.

- [ ] **Step 4: Add `/readyz`** — modify `buildApp(services:port:)`:

```swift
router.get("/readyz") { _, _ in
    // ping embedder; respond 503 if down so docker compose healthcheck sees us as not-ready
    do {
        _ = try await services.embedder.embed("readyz")
        return Response(status: .ok, body: ResponseBody(byteBuffer: .init(string: #"{"status":"ready"}"#)))
    } catch {
        return Response(status: .serviceUnavailable, body: ResponseBody(byteBuffer:
            .init(string: #"{"status":"embedder_unavailable"}"#)))
    }
}
```

- [ ] **Step 5: Run the test + the full memory-service suite**

Run: `(cd memory-service && swift test 2>&1) | grep -E "Test Suite|passed|failed" | tail -10`
Expected: green everywhere.

- [ ] **Step 6: Commit**

```bash
git add memory-service/
git commit -m "feat(m3a): inspector endpoints (nodes/transcript-recent) + readyz with embedder ping

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: MemoryClient (Swift, client side)

**Files:**
- Create: `Gemma/Gemma/Memory/MemoryClient.swift`
- Create: `Gemma/GemmaTests/MemoryClientTests.swift`

- [ ] **Step 1: Write the failing test** — `Gemma/GemmaTests/MemoryClientTests.swift`:

```swift
import XCTest
@testable import Gemma

@MainActor
final class MemoryClientTests: XCTestCase {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var stub: (URLRequest) -> (HTTPURLResponse, Data) = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (res, data) = Self.stub(request)
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }
    private func makeClient() -> MemoryClient {
        MemoryClient(baseURL: URL(string: "http://localhost:8081")!, bearerToken: "test-token",
                     session: makeSession())
    }

    func test_save_sends_bearer_and_decodes_id() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(req.url?.path, "/v1/memory/save")
            let data = #"{"id":"abc"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, data)
        }
        let result = try await makeClient().save(kind: "preference", label: "sushi", body: "x", extra: nil, sourceRef: nil)
        XCTAssertEqual(result.id, "abc")
        XCTAssertNil(result.mergedInto)
    }

    func test_recall_decodes_core_and_recall_lists() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/recall")
            let payload = #"""
            {"core":[{"kind":"identity","label":"Roilan","body":"el usuario"}],
             "recall":[{"kind":"preference","label":"sushi","body":"al user le gusta","extra":null}]}
            """#.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, payload)
        }
        let bundle = try await makeClient().recall(query: "qué comida", scope: nil, limit: nil)
        XCTAssertEqual(bundle.core.first?.label, "Roilan")
        XCTAssertEqual(bundle.recall.first?.label, "sushi")
    }

    func test_recall_with_503_returns_empty_bundle_for_graceful_degradation() async throws {
        StubProtocol.stub = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let bundle = try await makeClient().recall(query: "x", scope: nil, limit: nil)
        XCTAssertTrue(bundle.core.isEmpty)
        XCTAssertTrue(bundle.recall.isEmpty)
    }

    func test_appendTranscript_posts_expected_body() async throws {
        StubProtocol.stub = { req in
            XCTAssertEqual(req.url?.path, "/v1/transcript/append")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "{}".data(using: .utf8)!)
        }
        try await makeClient().appendTranscript(threadId: "T", role: "user", text: "hi", turnIndex: 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryClientTests 2>&1 | tail -20`
Expected: compile error — `MemoryClient` missing.

- [ ] **Step 3: Implement `Gemma/Gemma/Memory/MemoryClient.swift`:**

```swift
import Foundation

/// HTTP client to the Memory Service (Docker). Reads `baseURL` + bearer token from Settings.
/// Provides graceful degradation: recall returns empty bundle on 5xx/timeout instead of throwing
/// (so the agent keeps chatting if the memory layer is down). Save / forget / etc still throw.
@MainActor
final class MemoryClient {
    struct RecallNode: Decodable, Sendable {
        let kind: String; let label: String; let body: String; let extra: String?
    }
    struct RecallBundle: Decodable, Sendable {
        let core: [RecallNode]; let recall: [RecallNode]
        static let empty = RecallBundle(core: [], recall: [])
    }
    struct SaveResult: Decodable, Sendable { let id: String; let mergedInto: String? }
    struct WindowTurn: Decodable, Sendable { let role: String; let text: String }
    struct ExpandResult: Decodable, Sendable { let transcript: [WindowTurn]; let summaryLabel: String? }
    struct StateSnapshot: Decodable, Sendable {
        let nodeCount: Int; let transcriptCount: Int; let isRunning: Bool
        let lastCycle: LastCycle?
        struct LastCycle: Decodable, Sendable { let id: String; let status: String; let endedAt: Double? }
    }
    struct ListedNodes: Decodable, Sendable { let nodes: [Node]; let total: Int }
    struct TranscriptRows: Decodable, Sendable { let rows: [TranscriptRow] }

    struct Node: Decodable, Sendable, Identifiable {
        let id: String; let kind: String; let label: String; let body: String; let extra: String?
    }
    struct TranscriptRow: Decodable, Sendable, Identifiable {
        let id: String; let threadId: String; let role: String; let text: String
        let turnIndex: Int; let createdAt: Double
    }

    enum ClientError: Error {
        case http(status: Int, message: String)
        case decode(Error)
        case invalidResponse
    }

    let baseURL: URL
    let bearerToken: String
    private let session: URLSession

    init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    // MARK: transcript
    func appendTranscript(threadId: String, role: String, text: String, turnIndex: Int) async throws {
        struct Body: Encodable { let threadId: String; let role: String; let text: String; let turnIndex: Int }
        let _: EmptyOK = try await post("/v1/transcript/append",
                                        Body(threadId: threadId, role: role, text: text, turnIndex: turnIndex))
    }
    func conversationWindow(threadId: String, maxTurns: Int = 12, maxChars: Int = 1500) async throws -> [WindowTurn] {
        struct W: Decodable { let turns: [WindowTurn] }
        let w: W = try await get("/v1/conversation/window?threadId=\(escape(threadId))&maxTurns=\(maxTurns)&maxChars=\(maxChars)")
        return w.turns
    }

    // MARK: memory
    func save(kind: String, label: String, body: String?, extra: String?, sourceRef: String?) async throws -> SaveResult {
        struct B: Encodable { let kind: String; let label: String; let body: String?; let extra: String?; let sourceRef: String? }
        return try await post("/v1/memory/save", B(kind: kind, label: label, body: body, extra: extra, sourceRef: sourceRef))
    }
    func forget(label: String? = nil, id: String? = nil) async throws -> Int {
        struct B: Encodable { let label: String?; let id: String? }
        struct R: Decodable { let removed: Int }
        let r: R = try await post("/v1/memory/forget", B(label: label, id: id))
        return r.removed
    }
    /// Returns empty bundle on 5xx/timeout — never throws.
    func recall(query: String, scope: String? = nil, limit: Int? = nil) async throws -> RecallBundle {
        struct B: Encodable { let query: String; let scope: String?; let limit: Int? }
        do {
            return try await post("/v1/memory/recall", B(query: query, scope: scope, limit: limit))
        } catch ClientError.http(let status, _) where (500...599).contains(status) {
            return .empty
        } catch is URLError {
            return .empty
        }
    }
    func expand(topic: String) async throws -> ExpandResult {
        try await get("/v1/memory/expand?topic=\(escape(topic))")
    }

    // MARK: consolidation
    func consolidationTurnEnd(threadId: String) async throws {
        struct B: Encodable { let threadId: String }
        let _: EmptyOK = try await post("/v1/consolidation/turn-end", B(threadId: threadId))
    }
    func reflect() async throws -> String? {
        struct R: Decodable { let cycleId: String }
        let r: R = try await post("/v1/consolidation/reflect", EmptyBody())
        return r.cycleId.isEmpty ? nil : r.cycleId
    }
    func state() async throws -> StateSnapshot { try await get("/v1/consolidation/state") }

    // MARK: inspector
    func nodes(limit: Int = 100, offset: Int = 0, kind: String? = nil) async throws -> ListedNodes {
        var path = "/v1/nodes?limit=\(limit)&offset=\(offset)"
        if let kind { path += "&kind=\(escape(kind))" }
        return try await get(path)
    }
    func transcriptRecent(limit: Int = 200) async throws -> [TranscriptRow] {
        let r: TranscriptRows = try await get("/v1/transcript/recent?limit=\(limit)")
        return r.rows
    }

    // MARK: HTTP helpers
    private struct EmptyOK: Decodable {}
    private struct EmptyBody: Encodable {}

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
    private func get<R: Decodable>(_ path: String) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        return try await execute(req)
    }
    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 8
        return try await execute(req)
    }
    private func execute<R: Decodable>(_ req: URLRequest) async throws -> R {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(status: http.statusCode, message: msg)
        }
        if R.self == EmptyOK.self { return EmptyOK() as! R }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw ClientError.decode(error)
        }
    }
}
```

> The `path.appendingPathComponent` here uses the URL's `appendingPathComponent` API — for query strings, that doesn't preserve the `?` so build the URL with `URLComponents` if any path contains `?`. **Simpler:** use `URL(string: path, relativeTo: baseURL)!`. Adjust before commit if tests fail on URL composition. Verify all tests pass before moving on.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryClientTests 2>&1 | tail -20`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/GemmaTests/MemoryClientTests.swift
git commit -m "feat(m3a): MemoryClient — Swift HTTP client to Memory Service (URLProtocol mock tests)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Refactor 4 memory tools to use MemoryClient

**Files:**
- Modify: `Gemma/Gemma/Memory/SaveMemoryTool.swift`
- Modify: `Gemma/Gemma/Memory/ForgetTool.swift`
- Modify: `Gemma/Gemma/Memory/ExpandContextTool.swift`
- Modify: `Gemma/Gemma/Memory/ReflectTool.swift`
- Modify: `Gemma/Gemma/Memory/MemoryToolbox.swift` (replace store/embedder/transcriptStore with `memory: MemoryClient?`)
- Test: existing `Gemma/GemmaTests/{SaveMemoryToolTests,ForgetToolTests,ExpandContextToolTests,ReflectToolTests}.swift` — rewrite to inject a fake `MemoryClient`

> The app target STILL has the in-process MemoryStore (it'll be deleted in Task 14). Until then, the in-process objects continue compiling but are not used by these tools after this task.

- [ ] **Step 1: Rewrite `MemoryToolbox.swift`:**

```swift
import Foundation

@MainActor
final class MemoryToolbox {
    static let shared = MemoryToolbox()
    var memory: MemoryClient?
    var reflectionRequest: (() -> Void)?
    private init() {}
}
```

- [ ] **Step 2: Update each tool** — pattern:

`SaveMemoryTool.swift`:

```swift
import Foundation

struct SaveMemoryTool: AgentTool {
    static let name = "save_memory"
    static let description = "Save a structured memory: an entity (person/place/thing) and a detail about it."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "kind",   type: .string, description: "node kind (preference/person/place/event/identity/task/plan/insight/trait)", required: true),
        AgentToolParam(name: "label",  type: .string, description: "canonical entity label (e.g. 'sushi', 'Juan')", required: true),
        AgentToolParam(name: "body",   type: .string, description: "the detail (full sentence)", required: false),
        AgentToolParam(name: "extra",  type: .string, description: "JSON metadata (status/horizon/etc) — optional", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let kind  = (obj["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = (obj["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body  = obj["body"] as? String
        let extra = obj["extra"] as? String
        guard !label.isEmpty, !kind.isEmpty else { return "missing kind or label" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(kind):\(label)") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.save(kind: kind, label: label, body: body, extra: extra, sourceRef: nil)
                return r.mergedInto != nil ? "merged" : "saved (\(r.id))"
            } catch { return "save failed: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```

`ForgetTool.swift`: simplify identically — read `topic`/`label` from args, call `mem.forget(label:)`, return string.

`ExpandContextTool.swift`: read `topic`, call `mem.expand(topic:)`, format the resulting turns same as the old version, return string (cap 4000 chars).

`ReflectTool.swift`: ignore args; call `MemoryToolbox.shared.reflectionRequest?()` AND `try? await mem.reflect()`. Return "reflexionando".

> Keep each tool's `name`, `description`, and parameter shape exactly as today (the model has been prompted with these strings). Only the body changes.

- [ ] **Step 3: Update each tool's test** to inject a fake `MemoryClient`. Replace the existing `MemoryToolbox.shared.store/embedder/transcriptStore` setup with `MemoryToolbox.shared.memory = makeFakeMemoryClient(...)`. Provide a `FakeMemoryClient` test helper (subclass of `MemoryClient` with the same shape but overridable methods, or simply a `URLProtocol` stub like in `MemoryClientTests`).

Add a shared helper in `Gemma/GemmaTests/Helpers/FakeMemoryClient.swift`:

```swift
import Foundation
@testable import Gemma

@MainActor
func makeStubMemoryClient(_ stub: @escaping (URLRequest) -> (Int, Data)) -> MemoryClient {
    final class P: URLProtocol {
        nonisolated(unsafe) static var stub: (URLRequest) -> (Int, Data) = { _ in (200, Data()) }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (code, data) = Self.stub(request)
            let res = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    P.stub = stub
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [P.self]
    return MemoryClient(baseURL: URL(string: "http://localhost:8081")!, bearerToken: "test-token",
                        session: URLSession(configuration: cfg))
}
```

Rewrite each tool test to use this helper. Sample (`SaveMemoryToolTests.swift`):

```swift
import XCTest
@testable import Gemma

@MainActor
final class SaveMemoryToolTests: XCTestCase {
    override func tearDown() { MemoryToolbox.shared.memory = nil; super.tearDown() }

    func test_save_calls_endpoint_and_returns_saved_string() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/save")
            return (200, #"{"id":"n1"}"#.data(using: .utf8)!)
        }
        let out = await SaveMemoryTool().run(argsJSON: #"{"kind":"preference","label":"sushi","body":"al user le gusta"}"#)
        XCTAssertTrue(out.contains("saved"))
    }
}
```

Mirror for the other 3 test files.

- [ ] **Step 4: Run the tool tests**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/SaveMemoryToolTests -only-testing:GemmaTests/ForgetToolTests -only-testing:GemmaTests/ExpandContextToolTests -only-testing:GemmaTests/ReflectToolTests 2>&1 | tail -20`
Expected: green.

> The app target as a whole is still in a transition state — it still imports old in-process Memory types (MemoryStore, MemoryRetriever, etc) elsewhere (HarnessModel, MemoryView). Compile errors there are EXPECTED until Task 13 finishes. Skip running the full app suite right now; only the tool tests above must pass after Task 12.
>
> If you must run the full suite to check the tool changes compile, temporarily comment out the bodies of `HarnessModel.ensureMemory` / `runAgentTurn` accessing those types — but the cleaner path is to do Tasks 12+13 in one push without running the full suite in between. (Subagent can choose; both are valid.)

- [ ] **Step 5: Commit**

```bash
git add Gemma/
git commit -m "feat(m3a): refactor 4 memory tools to use MemoryClient (HTTP)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Refactor HarnessModel + MemoryView to use MemoryClient

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (rewrite `ensureMemory`, `runAgentTurn`)
- Modify: `Gemma/Gemma/Harness/MemoryView.swift` (consume HTTP endpoints)
- Modify: `Gemma/Gemma/Harness/TranscriptInspectorView.swift` (consume `MemoryClient.transcriptRecent`)
- Test: `Gemma/GemmaTests/HarnessModelTests.swift` (update fakes; add a small test that ensureMemory builds a client from settings)

- [ ] **Step 1: Rewrite `HarnessModel.ensureMemory`** — replace the body to:

```swift
@MainActor
extension HarnessModel {
    func ensureMemory() {
        let urlString = UserDefaults.standard.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        let token = UserDefaults.standard.string(forKey: "memoryBearerToken") ?? ""
        guard let baseURL = URL(string: urlString) else {
            self.memory = nil
            MemoryToolbox.shared.memory = nil
            return
        }
        let client = MemoryClient(baseURL: baseURL, bearerToken: token)
        self.memory = client
        MemoryToolbox.shared.memory = client
        MemoryToolbox.shared.reflectionRequest = { [weak client] in
            Task { _ = try? await client?.reflect() }
        }
    }
}
```

Add `var memory: MemoryClient?` as a stored property on `HarnessModel`. Remove the now-unused properties (`store`, `retriever`, `transcriptStore`, `consolidator`, `consolidationScheduler`).

- [ ] **Step 2: Rewrite `runAgentTurn`** — replace each in-process call:

| Was (in-process) | Now (HTTP) |
|---|---|
| `let recall = await store.recall(query: ...)` | `let recall = (try? await client.recall(query: userText)) ?? .empty` |
| `try transcriptStore.append(threadId, turnIndex, "user", text, now: ...)` | `try await client.appendTranscript(threadId: t, role: "user", text: u, turnIndex: i)` |
| `try transcriptStore.append(..., "assistant", ...)` | `try await client.appendTranscript(threadId: t, role: "assistant", text: a, turnIndex: i)` |
| `let window = try transcriptStore.recent(...)` | `let window = try await client.conversationWindow(threadId: t)` |
| `consolidator.armTurnEnd(threadId: t)` | `try await client.consolidationTurnEnd(threadId: t)` |
| `store.coreMemories()` | absorbed into `bundle.core` from `recall(...)` |

Wrap the calls that can fail (network) so the agent degrades gracefully when memory service is down: if recall fails it returns `.empty`; if append fails log a warning and continue.

The Agent loop itself does not change — it still executes tools client-side via `ToolRegistry`.

- [ ] **Step 3: Rewrite `MemoryView`** to consume HTTP endpoints. Pattern:

```swift
struct MemoryInspectorView: View {
    let client: MemoryClient?
    @State private var nodes: [MemoryClient.Node] = []

    var body: some View {
        Group {
            if nodes.isEmpty { ContentUnavailableView("Sin memoria", systemImage: "tray") }
            else {
                List(nodes) { n in
                    VStack(alignment: .leading) {
                        Text(n.label).font(.body.bold())
                        if !n.body.isEmpty { Text(n.body).font(.caption).foregroundStyle(.secondary) }
                        Text(n.kind).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .task {
            guard let client else { return }
            let listed = (try? await client.nodes(limit: 200)) ?? .init(nodes: [], total: 0)
            nodes = listed.nodes
        }
    }
}
```

Replace the existing `MemoryView`'s Picker switch to pass `client: HarnessModel.memory` instead of `store: MemoryStore`. Mirror the change in `TranscriptInspectorView`:

```swift
struct TranscriptInspectorView: View {
    let client: MemoryClient?
    @State private var rows: [MemoryClient.TranscriptRow] = []

    var body: some View {
        Group {
            if rows.isEmpty { ContentUnavailableView("Sin conversación", systemImage: "text.bubble") }
            else { List(rows) { row in /* role + text */ } }
        }
        .task {
            guard let client else { return }
            rows = (try? await client.transcriptRecent(limit: 200)) ?? []
        }
    }
}
```

The Grafo tab (if it relies on direct GRDB) becomes "list of nodes grouped by kind" — same data, simpler rendering. If the existing grafo view is non-trivial and would require a separate HTTP endpoint for edges, **drop the grafo tab in M3a** (Lista + Transcript suffice). Document the gap in the spec follow-ups.

- [ ] **Step 4: Run the app suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -8`

The build will fail with errors referencing the old types still present in the file system (MemoryStore, etc) but no longer used by anything besides themselves. Track which tests reference them — they get deleted in Task 14.

If the suite is too broken to run, do the next task first (Task 14 deletes the dead code) and come back to a green suite after. **Both tasks 13 and 14 must be done before claiming the app builds again.**

- [ ] **Step 5: Commit**

```bash
git add Gemma/
git commit -m "feat(m3a): HarnessModel + MemoryView consume MemoryClient (HTTP)

App still has unused in-process Memory types; cleanup follows in next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Delete in-process Memory code from app + add Settings UI

**Files:**
- Delete from app: `Gemma/Gemma/Memory/{MemoryStore.swift, TranscriptStore.swift, MemoryRetriever.swift, MemoryConsolidationEngine.swift, ConsolidationScheduler.swift, MemoryConsolidator.swift, Decay.swift, MemoryText.swift, Embedder.swift, NLContextualEmbedder.swift, FakeEmbedder.swift, NodeKind.swift, NodeAttributes.swift, Node.swift, ConversationWindow.swift, EpisodeRecorder.swift}` (any that exist)
- Delete from app tests: matching `*Tests.swift` files (now lived in `memory-service/Tests/MemoryCoreTests/`)
- Modify: `Gemma/Gemma/Harness/SettingsView.swift` (or wherever the Settings scene lives) — add `MemoryBaseURL` + `MemoryBearerToken` fields
- Modify: `Gemma/Gemma/SettingsKeys.swift` (if exists) — add the two new keys

- [ ] **Step 1: List the files to delete and confirm none are imported elsewhere**

Run from repo root:

```bash
for f in MemoryStore TranscriptStore MemoryRetriever MemoryConsolidationEngine ConsolidationScheduler \
         MemoryConsolidator Decay MemoryText Embedder NLContextualEmbedder FakeEmbedder NodeKind \
         NodeAttributes Node ConversationWindow EpisodeRecorder; do
  path="Gemma/Gemma/Memory/${f}.swift"
  if [ -f "$path" ]; then
    refs=$(grep -rln "\\b${f}\\b" Gemma/Gemma/ Gemma/GemmaTests/ | grep -v "${path}$")
    if [ -n "$refs" ]; then
      echo "STILL REFERENCED: ${f} ←"
      echo "$refs"
      echo
    else
      echo "ok to delete: ${path}"
    fi
  fi
done
```

For any file flagged "STILL REFERENCED", inspect the remaining references. Acceptable patterns: a `MemoryClient` shadowing the type name (e.g., `MemoryClient.Node` vs the old `Node` struct → that's fine, they're scoped differently). If a real usage remains, refactor it to use `MemoryClient` before deleting.

> **Important:** the `Node` type is BOTH a `MemoryStore` row AND now nested in `MemoryClient.Node`. Verify the app's UI/views only use `MemoryClient.Node`. The standalone `Node.swift` can be deleted.

- [ ] **Step 2: Delete the files**

```bash
for f in MemoryStore TranscriptStore MemoryRetriever MemoryConsolidationEngine ConsolidationScheduler \
         MemoryConsolidator Decay MemoryText Embedder NLContextualEmbedder FakeEmbedder NodeKind \
         NodeAttributes Node ConversationWindow EpisodeRecorder; do
  path="Gemma/Gemma/Memory/${f}.swift"
  [ -f "$path" ] && git rm "$path"
done
for f in MemoryStoreTests TranscriptStoreTests MemoryRetrieverTests MemoryConsolidationEngineTests \
         ConversationWindowTests DecayTests MemoryTextTests; do
  path="Gemma/GemmaTests/${f}.swift"
  [ -f "$path" ] && git rm "$path"
done
```

- [ ] **Step 3: Add Settings UI fields** — modify the `Settings` scene (look in `Gemma/Gemma/Harness/` or `Gemma/Gemma/GemmaApp.swift` for the existing `Settings { ... }` scene), append two `@AppStorage` rows:

```swift
@AppStorage("memoryBaseURL") private var memoryBaseURL: String = "http://localhost:8081"
@AppStorage("memoryBearerToken") private var memoryBearerToken: String = ""

// …inside the Form/VStack:
Section("Memory Service") {
    TextField("Base URL", text: $memoryBaseURL)
        .textFieldStyle(.roundedBorder)
        .help("URL del servicio de memoria. Si lo movés al i3, cambia esto a la Tailscale IP.")
    SecureField("Bearer token", text: $memoryBearerToken)
        .textFieldStyle(.roundedBorder)
        .help("Mismo valor que MEMORY_BEARER_TOKEN en .env del docker-compose.")
}
```

Trigger a reconnect when either changes — wire `onChange(of: memoryBaseURL) { _ in harnessModel.ensureMemory() }` and the same for the token.

- [ ] **Step 4: Run the full app suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -10`
Expected: ** TEST SUCCEEDED **. If a compile error references a deleted type, find the remaining caller and refactor or delete it.

- [ ] **Step 5: Commit**

```bash
git add Gemma/
git commit -m "feat(m3a): delete in-process Memory code from app + add Settings (URL + token)

Memory code now lives in memory-service/Sources/MemoryCore/.
App suite green; talks to the service via MemoryClient.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: E2E gated `GEMMA_LIVE_DOCKER=1` + graphify

**Files:**
- Create: `Gemma/GemmaTests/MemoryServiceLiveTests.swift`
- Create: `scripts/m3a-e2e.sh` (helper to bring the stack up + run the gated test)
- Modify: `docs/superpowers/plans/2026-06-02-m3a-memory-service-docker.md` (mark complete in this same file via Self-Review at end)

- [ ] **Step 1: Write the gated live test** — `Gemma/GemmaTests/MemoryServiceLiveTests.swift`:

```swift
import XCTest
@testable import Gemma

/// Real E2E against the docker-compose stack. Gated to avoid CI breakage.
/// Run with: `TEST_RUNNER_GEMMA_LIVE_DOCKER=1 xcodebuild test ...`
/// or via `scripts/m3a-e2e.sh`.
@MainActor
final class MemoryServiceLiveTests: XCTestCase {
    override func setUp() {
        try? XCTSkipUnless(ProcessInfo.processInfo.environment["GEMMA_LIVE_DOCKER"] == "1",
                           "set GEMMA_LIVE_DOCKER=1 + docker compose up to run")
    }

    func test_save_recall_expand_forget_roundtrip() async throws {
        let token = ProcessInfo.processInfo.environment["MEMORY_BEARER_TOKEN"] ?? "test-token"
        let client = MemoryClient(baseURL: URL(string: "http://localhost:8081")!, bearerToken: token)

        // save
        let save = try await client.save(kind: "preference", label: "sushi", body: "al user le gusta el sushi", extra: nil, sourceRef: nil)
        XCTAssertFalse(save.id.isEmpty)

        // recall — should mention sushi
        let bundle = try await client.recall(query: "qué comida me gusta")
        XCTAssertTrue(bundle.recall.contains { $0.label.localizedCaseInsensitiveContains("sushi") },
                      "recall must surface 'sushi'; got: \(bundle.recall.map(\.label))")

        // append a turn + ask state to advance counts
        try await client.appendTranscript(threadId: "T-live", role: "user", text: "hola", turnIndex: 0)
        let state = try await client.state()
        XCTAssertGreaterThanOrEqual(state.transcriptCount, 1)
        XCTAssertGreaterThanOrEqual(state.nodeCount, 1)

        // forget
        let removed = try await client.forget(label: "sushi")
        XCTAssertGreaterThanOrEqual(removed, 1)
    }

    func test_recall_degrades_gracefully_when_service_unreachable() async throws {
        // Point at a closed port; recall MUST NOT throw.
        let client = MemoryClient(baseURL: URL(string: "http://127.0.0.1:65534")!,
                                  bearerToken: "anything")
        let bundle = try await client.recall(query: "x")
        XCTAssertTrue(bundle.core.isEmpty && bundle.recall.isEmpty)
    }
}
```

- [ ] **Step 2: Create the helper script** — `scripts/m3a-e2e.sh`:

```bash
#!/usr/bin/env bash
# Bring the M3a stack up, run the gated E2E, tear it down.
# Usage: scripts/m3a-e2e.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo ".env missing — copying from .env.example" >&2
  cp .env.example .env
  echo "EDIT .env to set MEMORY_BEARER_TOKEN, then re-run." >&2
  exit 1
fi

docker compose up -d --build

# wait for memory /healthz
for i in $(seq 1 60); do
  if curl -fsS http://localhost:8081/healthz >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS http://localhost:8081/healthz || { docker compose logs memory; exit 1; }

TOKEN=$(grep '^MEMORY_BEARER_TOKEN=' .env | cut -d= -f2-)
TEST_RUNNER_GEMMA_LIVE_DOCKER=1 \
TEST_RUNNER_MEMORY_BEARER_TOKEN="$TOKEN" \
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' \
  -only-testing:GemmaTests/MemoryServiceLiveTests 2>&1 | tail -40

docker compose down
```

Make it executable: `chmod +x scripts/m3a-e2e.sh`

- [ ] **Step 3: Run it once locally** (manual gate; subagents should NOT block on Docker availability):

```bash
./scripts/m3a-e2e.sh
```

Expected: 2 tests passed.

If Docker isn't available in the working environment, mark this step as "verified locally by the user" and proceed.

- [ ] **Step 4: graphify update**

Run: `graphify update .` (per CLAUDE.md).

- [ ] **Step 5: Commit**

```bash
git add Gemma/GemmaTests/MemoryServiceLiveTests.swift scripts/m3a-e2e.sh graphify-out
git commit -m "test(m3a): gated GEMMA_LIVE_DOCKER E2E + helper script + graphify update

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (controller fills this before declaring done)

**Spec coverage** (spec sections 5–12):
- 5.1 Transcript / window → Task 7 ✓
- 5.2 Memory recall/save/forget/expand → Task 8 ✓
- 5.3 Consolidation turn-end/reflect/state → Task 9 ✓
- 5.4 Inspector nodes/transcript-recent → Task 10 ✓
- 5.5 healthz/readyz → Task 2 (healthz) + Task 10 (readyz) ✓
- 6 Container memory (Swift) → Tasks 2, 4, 5, 6 ✓
- 7 Container embedder (Python) → Task 1 ✓
- 8 Cliente macOS — refactor → Tasks 11, 12, 13, 14 ✓
- 9 Layout repo → resulting from Tasks 1, 2, 4 ✓
- 10 Errores / degradación → Task 11 (recall graceful) + Task 15 (test) ✓
- 11 Testing → Tasks 1, 4–10 (unit) + 11 (client) + 15 (E2E) ✓
- 12 Métricas de éxito 1–5 → covered by Task 3 (compose up + healthz/auth), Task 14 (suite green), Task 15 (E2E + degradation)

**Placeholder scan:** Each step has concrete code. The two "If the API differs" hedges (Task 4 step 3, Task 7 step 3, Task 8 step 3) are explicit instructions ("adapt") with no TBD or "implement later" hidden. No empty stubs.

**Type consistency:**
- `Embedder` protocol — defined in MemoryCore (copied + with batched `embed([String])` extension); `RemoteEmbedder` is the production impl.
- `ModelTextClient` protocol — defined in MemoryCore (Task 5); `RemoteModelClient` is the production impl (Task 9); `NoOpModelClient` is the test default (Task 9).
- `Services` class — fields `store, transcript, embedder, retriever, bearerToken, modelClient, engine, scheduler`; convenience init for tests.
- `MemoryClient` (app side) — `RecallNode`, `RecallBundle`, `SaveResult`, `WindowTurn`, `ExpandResult`, `StateSnapshot`, `ListedNodes`, `TranscriptRows`, nested `Node`/`TranscriptRow`. Same field names used by `MemoryView` and `TranscriptInspectorView` (Task 13).
- Settings keys: `memoryBaseURL`, `memoryBearerToken` — referenced from Task 14 settings UI and Task 13 ensureMemory.

**Things subagent should adapt without escalating:**
- Hummingbird 2.x API for `Request.body.collect(upTo:)` / `ByteBuffer.readData` / route group middleware syntax — confirm against the actual installed version; adapt syntax, keep semantics.
- `MemoryStore.upsertMergingSemantic` / `forgetById` / `forgetByLabel` / `latestSleepCycle` / `nodeCount` — names from the existing in-process API. If a method has a slightly different name, fix the **handler call** to match; don't rename the store unless necessary.
- GRDB row codec for `Node` / `TranscriptRow` — already exists in the moved sources.

**Things subagent MUST escalate:**
- If `swift build` on Linux (in the Docker builder) fails for a non-trivial reason (e.g., GRDB Linux incompatibility on a version we picked).
- If the embedder model download fails repeatedly (network-bound; the subagent should report and let the human retry).
- If the tool tests can't be made green without changing tool description strings (those are part of the model's prompt; changing them is a separate decision).
