# Wake Word "Hey Jarvis" Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hands-free voice for the Gemma macOS app — always-listen on-device for "Hey Jarvis" via openWakeWord's ONNX pipeline (run in Swift with onnxruntime), then auto-capture the utterance and run it through the existing Phase 1b voice path.

**Architecture:** One `AVAudioEngine` 16 kHz mono tap feeds a `WakeWordDetector` (melspectrogram → embedding → hey_jarvis ONNX models via onnxruntime). On score > 0.5, a `WakeListener` state machine auto-captures the utterance (energy-VAD endpointing) and calls the existing `VoiceController.send(wav)` (POST → play → chat), then re-arms. A toggle in the chat enables/disables listening.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (`AVAudioEngine`/`AVAudioConverter`), **onnxruntime** (`microsoft/onnxruntime-swift-package-manager`, ObjC API), openWakeWord pretrained ONNX models. macOS 15 target.

**Repo / branch:** `Gemma` app (in the `personal_agent` monorepo, git root `/Users/hashdown/Projects/personal_agent`). Create and work on branch `sp-wakeword`. The i3 backend is unchanged.

**Spec:** `docs/superpowers/specs/2026-06-08-wake-word-phase2-design.md`.

**Reference inference to match:** openWakeWord's pipeline — [openwakeword-simplified](https://github.com/sujitvasanth/openwakeword-simplified) (3 ONNX nets, single Python file) and [openWakeWord `model.py`](https://github.com/dscripka/openWakeWord/blob/main/openwakeword/model.py). The Swift `WakeWordDetector` must reproduce that streaming math.

**Confirmed model facts** (verify each against the actual `.onnx` at load):
- **Audio:** 16 kHz mono, fed in **1280-sample (80 ms)** chunks.
- **melspectrogram.onnx:** raw audio → mel frames (32 mel bins/frame).
- **embedding_model.onnx:** input a **76×32** mel window → output a **96-dim** embedding (output tensor shape `(1,1,1,96)`).
- **hey_jarvis_v0.1.onnx:** input a sliding window of the **last 16 embeddings** (`[1,16,96]`) → output a **score** `[1,1]` in 0..1. Threshold **0.5** (tunable).
- Models from openWakeWord **v0.5.1** release + the pretrained-models release.

**Build/test:** `xcodebuild -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' build` / `… test`. Focused: `… test -only-testing:GemmaTests/<Suite>`. The Xcode project uses **synchronized folders** (new `.swift` files auto-compile); the **onnxruntime SPM package** and the **model resources** are the only `project.pbxproj` changes. Known pre-existing failure: `HarnessModelTests.test_defaultBaseURL_isLocalhost8081` (env-coupled) — ignore; no NEW failures.

⚠️ **Never `git add -A`** in this repo (sweeps large graphify snapshots). Stage specific paths.

---

## File Structure

| File | Responsibility |
|---|---|
| `Gemma/Gemma/Voice/WakeWordDetector.swift` | `WakeDetecting` protocol + `WakeWordDetector` (onnxruntime sessions + the melspec→embedding→wake streaming pipeline). |
| `Gemma/Gemma/Voice/EnergyEndpointer.swift` | Pure-logic RMS-energy silence endpointer for the post-wake utterance. |
| `Gemma/Gemma/Voice/WakeListener.swift` | `@MainActor @Observable` — `AVAudioEngine` 16 kHz tap + state machine (listening→capturing→busy→re-arm). |
| `Gemma/Gemma/Voice/Models/{melspectrogram,embedding_model,hey_jarvis_v0.1}.onnx` | Bundled openWakeWord model resources. |
| `Gemma/GemmaTests/EnergyEndpointerTests.swift` | Pure-logic endpointer tests. |
| `Gemma/GemmaTests/WakeWordDetectorTests.swift` (+ `Resources/hey_jarvis.wav`, models) | Fixture-based detection + onnxruntime load smoke. |
| `Gemma/Gemma/Harness/HarnessModel.swift` (modify) | own `wake: WakeListener`, wire it. |
| `Gemma/Gemma/Harness/AgentChatView.swift` (modify) | listening toggle + indicator. |
| `Gemma/Gemma.xcodeproj/project.pbxproj` (modify) | onnxruntime SPM package ref + model/fixture resources. |

---

## Task 1: Add onnxruntime (SPM) + a load smoke test

**Files:** Modify `Gemma/Gemma.xcodeproj/project.pbxproj`; Create `Gemma/GemmaTests/OnnxRuntimeSmokeTests.swift`.

This de-risks the runtime before any pipeline work. Adding an SPM package to an Xcode project is best done via Xcode (`File → Add Package Dependencies…`), which edits the pbxproj; the steps below describe the exact result to achieve.

- [ ] **Step 1: Add the package.** In Xcode (or by editing `project.pbxproj` to mirror the existing GRDB `XCRemoteSwiftPackageReference`), add package `https://github.com/microsoft/onnxruntime-swift-package-manager` with version rule **"Up to Next Major" from `1.17.0`**, and add its product **`onnxruntime`** to BOTH the `Gemma` app target and the `GemmaTests` test target. (The product module is imported in Swift as `import onnxruntime_objc`.)

- [ ] **Step 2: Write the smoke test — `Gemma/GemmaTests/OnnxRuntimeSmokeTests.swift`:**

```swift
import XCTest
import onnxruntime_objc
@testable import Gemma

final class OnnxRuntimeSmokeTests: XCTestCase {
    func test_can_create_ort_env_and_session_options() throws {
        // Proves the onnxruntime package links + its ObjC API is callable from Swift.
        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        XCTAssertNotNil(env)
        XCTAssertNotNil(opts)
    }
}
```

- [ ] **Step 3: Build + run → PASS.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/OnnxRuntimeSmokeTests 2>&1 | tail -8`
Expected: `Test Suite 'OnnxRuntimeSmokeTests' passed`. If `import onnxruntime_objc` fails, the module name differs by version — check the package's product/module name in Xcode's Package Dependencies and use that exact module name (do NOT proceed until this test compiles + passes; this is the integration gate).

- [ ] **Step 4: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma.xcodeproj/project.pbxproj Gemma/Gemma.xcodeproj/project.xcworkspace/xcshareddata Gemma/GemmaTests/OnnxRuntimeSmokeTests.swift
git commit -m "build(wake): add onnxruntime SPM package + load smoke test"
```
(If the SPM resolution wrote `Package.resolved` under the workspace `xcshareddata`, include it; do not `git add -A`.)

---

## Task 2: Bundle the openWakeWord models + a model-load smoke test

**Files:** Create `Gemma/Gemma/Voice/Models/{melspectrogram,embedding_model,hey_jarvis_v0.1}.onnx`; Modify `project.pbxproj` (add as app + test resources); Create test in `OnnxRuntimeSmokeTests.swift`.

- [ ] **Step 1: Download the three models** into `Gemma/Gemma/Voice/Models/`:

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma/Gemma/Voice && mkdir -p Models && cd Models
curl -L -o melspectrogram.onnx https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.onnx
curl -L -o embedding_model.onnx https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.onnx
curl -L -o hey_jarvis_v0.1.onnx  https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/hey_jarvis_v0.1.onnx
ls -lh *.onnx   # sanity: each is a non-trivial binary (KB–MB)
```
(If a filename/URL 404s, list the v0.5.1 release assets at https://github.com/dscripka/openWakeWord/releases and use the exact asset names; the pretrained wake models may live in a separate release tag — match the actual asset URLs.)

- [ ] **Step 2: Add the three `.onnx` as bundle resources** to BOTH the `Gemma` app target and `GemmaTests` (in Xcode: select the files → File Inspector → Target Membership: Gemma + GemmaTests). This writes `PBXBuildFile`/resources entries in `project.pbxproj`.

- [ ] **Step 3: Append a model-load smoke test to `Gemma/GemmaTests/OnnxRuntimeSmokeTests.swift`:**

```swift
    private func modelURL(_ name: String) throws -> URL {
        let b = Bundle(for: type(of: self))
        let url = b.url(forResource: name, withExtension: "onnx")
        return try XCTUnwrap(url, "\(name).onnx not in test bundle — check Target Membership")
    }

    func test_loads_all_three_openwakeword_models() throws {
        let env = try ORTEnv(loggingLevel: .warning)
        for name in ["melspectrogram", "embedding_model", "hey_jarvis_v0.1"] {
            let session = try ORTSession(env: env, modelPath: modelURL(name).path,
                                         sessionOptions: try ORTSessionOptions())
            let inputs = try session.inputNames()
            XCTAssertFalse(inputs.isEmpty, "\(name) has no inputs?")
            print("MODEL \(name): inputs=\(inputs) outputs=\(try session.outputNames())")
        }
    }
```
(The `print` of input/output names is intentional — it reveals the exact input/output tensor names the next task needs.)

- [ ] **Step 4: Run → PASS** and note the printed input/output names.

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/OnnxRuntimeSmokeTests 2>&1 | tail -20`
Expected: both tests pass; the log prints each model's input/output names (record them — used in Task 3).

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Voice/Models Gemma/Gemma.xcodeproj/project.pbxproj Gemma/GemmaTests/OnnxRuntimeSmokeTests.swift
git commit -m "feat(wake): bundle openWakeWord ONNX models + load smoke test"
```

---

## Task 3: `WakeWordDetector` — the ONNX detection pipeline

**Files:** Create `Gemma/Gemma/Voice/WakeWordDetector.swift`, `Gemma/GemmaTests/WakeWordDetectorTests.swift`, `Gemma/GemmaTests/Resources/hey_jarvis.wav`.

This ports openWakeWord's streaming inference to Swift. The **fixture test is the correctness gate** — a real "hey jarvis" clip must score > 0.5.

- [ ] **Step 1: Obtain a positive fixture** `Gemma/GemmaTests/Resources/hey_jarvis.wav` (16 kHz mono). Use openWakeWord's test audio if available, else generate one and downsample:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma/GemmaTests && mkdir -p Resources
say -v Daniel "hey jarvis" -o /tmp/hj.aiff && afconvert /tmp/hj.aiff Resources/hey_jarvis.wav -d LEI16@16000 -c 1 -f WAVE
```
Add it to the `GemmaTests` target (Target Membership). (If `say`'s voice doesn't trigger detection in Step 4, replace the fixture with a real recording of "hey jarvis" or openWakeWord's bundled positive sample — the model was trained on TTS so `say` often works, but a real clip is the fallback.)

- [ ] **Step 2: Write the failing test — `Gemma/GemmaTests/WakeWordDetectorTests.swift`:**

```swift
import XCTest
import AVFoundation
@testable import Gemma

final class WakeWordDetectorTests: XCTestCase {
    /// Read a 16 kHz mono WAV from the test bundle as Float samples.
    private func samples(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: name, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        // processingFormat is the file's format (16k mono PCM16 → float via channelData)
        let n = Int(buf.frameLength)
        let ch = buf.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ch, count: n))
    }

    private func maxScore(over audio: [Float], detector: WakeWordDetector) -> Float {
        var best: Float = 0
        var i = 0
        while i + 1280 <= audio.count {
            let frame = Array(audio[i ..< i + 1280])
            best = max(best, detector.process(frame: frame))
            i += 1280
        }
        return best
    }

    func test_detects_hey_jarvis_above_threshold() throws {
        let d = try WakeWordDetector()
        let score = maxScore(over: try samples("hey_jarvis"), detector: d)
        XCTAssertGreaterThan(score, 0.5, "hey_jarvis clip should score > 0.5, got \(score)")
    }

    func test_silence_scores_low() throws {
        let d = try WakeWordDetector()
        let silence = [Float](repeating: 0, count: 16000)   // 1 s of silence
        XCTAssertLessThan(maxScore(over: silence, detector: d), 0.3, "silence should score low")
    }
}
```

- [ ] **Step 3: Run → FAIL** (no `WakeWordDetector`).

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/WakeWordDetectorTests 2>&1 | tail -8`
Expected: `cannot find 'WakeWordDetector' in scope`.

- [ ] **Step 4: Create `Gemma/Gemma/Voice/WakeWordDetector.swift`.** Port openWakeWord's streaming math (reference: `openwakeword-simplified`). Structure below — fill the ONNX I/O using the input/output **names from Task 2's printout** and the confirmed shapes; verify shapes from the model at load and adjust buffering to match the reference exactly:

```swift
import Foundation
import onnxruntime_objc

/// On-device wake-word detection. Swappable so WakeListener can be tested with a fake.
protocol WakeDetecting: AnyObject {
    func process(frame: [Float]) -> Float   // feed one 80ms (1280-sample @16kHz) frame, returns wake score 0..1
    func reset()
}

/// openWakeWord pipeline in Swift: raw audio -> melspectrogram.onnx -> embedding_model.onnx
/// -> hey_jarvis.onnx. Streaming: keep a rolling mel buffer (>=76 frames) for each embedding,
/// and a rolling embedding buffer (last 16) for each wake score. Matches openWakeWord reference.
final class WakeWordDetector: WakeDetecting {
    private let env: ORTEnv
    private let melSession: ORTSession
    private let embSession: ORTSession
    private let wakeSession: ORTSession

    // Rolling buffers
    private var melFrames: [[Float]] = []        // each is 32 mel bins
    private var embeddings: [[Float]] = []       // each is 96 dims
    private let melWindow = 76                   // mel frames per embedding
    private let embWindow = 16                   // embeddings per wake score

    init() throws {
        func url(_ n: String) throws -> String {
            try Bundle.main.url(forResource: n, withExtension: "onnx").map(\.path)
                ?? Bundle(for: WakeWordDetector.self).url(forResource: n, withExtension: "onnx")!.path
        }
        env = try ORTEnv(loggingLevel: .warning)
        let o = try ORTSessionOptions()
        melSession  = try ORTSession(env: env, modelPath: try url("melspectrogram"), sessionOptions: o)
        embSession  = try ORTSession(env: env, modelPath: try url("embedding_model"), sessionOptions: o)
        wakeSession = try ORTSession(env: env, modelPath: try url("hey_jarvis_v0.1"), sessionOptions: o)
    }

    func reset() { melFrames.removeAll(); embeddings.removeAll() }

    func process(frame: [Float]) -> Float {
        // 1) audio -> mel frames (append). 2) when >=76 mel frames, emit embeddings (slide). 3) when
        //    >=16 embeddings, run wake model on the last 16. Implement each ONNX call with the model's
        //    real input/output names + shapes (see Task 2 printout); reshape per the confirmed dims:
        //    mel out: 32-bin frames; emb in: [1,76,32,1] -> out [1,1,1,96]; wake in: [1,16,96] -> [1,1].
        // (Port the exact buffering from openwakeword-simplified; return the latest wake score, else 0.)
        ...
    }

    // Helpers: makeTensor([Float], shape:[NSNumber]) -> ORTValue; run(session, inputs) -> [Float]
}
```
The `...` is the streaming port — write it fully against the reference. Use `ORTValue(tensorData:elementType:.float shape:)` for inputs and read outputs via `ORTValue.tensorData()`. The fixture test (Step 5) is the gate: iterate until `test_detects_hey_jarvis_above_threshold` passes. If it never exceeds 0.5, the buffering/shape doesn't match the reference — diff against `openwakeword-simplified` (mel hop, the 76-frame window stride, the 16-embedding window) until the real clip scores high.

- [ ] **Step 5: Run → PASS.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/WakeWordDetectorTests 2>&1 | tail -10`
Expected: both tests pass (hey_jarvis > 0.5, silence < 0.3).

- [ ] **Step 6: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Voice/WakeWordDetector.swift Gemma/GemmaTests/WakeWordDetectorTests.swift Gemma/GemmaTests/Resources/hey_jarvis.wav Gemma/Gemma.xcodeproj/project.pbxproj
git commit -m "feat(wake): WakeWordDetector ONNX pipeline (melspec->embedding->hey_jarvis) + fixture test"
```

---

## Task 4: `EnergyEndpointer` (post-wake utterance silence detection)

**Files:** Create `Gemma/Gemma/Voice/EnergyEndpointer.swift`, `Gemma/GemmaTests/EnergyEndpointerTests.swift`.

- [ ] **Step 1: Write the failing test — `Gemma/GemmaTests/EnergyEndpointerTests.swift`:**

```swift
import XCTest
@testable import Gemma

final class EnergyEndpointerTests: XCTestCase {
    // frame_ms=80; end after 320ms (4 frames) trailing silence following >=160ms (2 frames) speech.
    private func make() -> EnergyEndpointer {
        EnergyEndpointer(frameMs: 80, silenceMs: 320, minSpeechMs: 160, energyThreshold: 0.01)
    }
    private let loud = [Float](repeating: 0.2, count: 1280)     // RMS 0.2 > threshold
    private let quiet = [Float](repeating: 0.0, count: 1280)    // RMS 0 < threshold

    func test_triggers_after_trailing_silence() {
        let ep = make()
        for _ in 0..<3 { XCTAssertFalse(ep.update(frame: loud)) }   // speech, never ends mid-speech
        let r = (0..<4).map { _ in ep.update(frame: quiet) }
        XCTAssertTrue(r.last!)                                       // ends on the 4th silent frame
        XCTAssertFalse(r.dropLast().contains(true))
    }

    func test_ignores_short_blip() {
        // needs 320ms (4 frames) of speech to "start"; a 160ms blip never triggers an end.
        let ep = EnergyEndpointer(frameMs: 80, silenceMs: 320, minSpeechMs: 320, energyThreshold: 0.01)
        for _ in 0..<2 { _ = ep.update(frame: loud) }               // 160ms speech -> not started
        XCTAssertFalse((0..<10).map { _ in ep.update(frame: quiet) }.contains(true))
    }
}
```

- [ ] **Step 2: Run → FAIL.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/EnergyEndpointerTests 2>&1 | tail -6`
Expected: `cannot find 'EnergyEndpointer'`.

- [ ] **Step 3: Create `Gemma/Gemma/Voice/EnergyEndpointer.swift`:**

```swift
import Foundation

/// RMS-energy silence endpointer for the post-wake utterance. Pure logic — feed one audio frame
/// at a time; returns true once `silenceMs` of trailing sub-threshold audio follows >= `minSpeechMs`
/// of speech.
final class EnergyEndpointer {
    private let silenceNeeded: Int
    private let minSpeech: Int
    private let threshold: Float
    private var speechFrames = 0
    private var trailingSilence = 0
    private var started = false

    init(frameMs: Int = 80, silenceMs: Int = 800, minSpeechMs: Int = 300, energyThreshold: Float = 0.01) {
        self.silenceNeeded = max(1, silenceMs / frameMs)
        self.minSpeech = max(1, minSpeechMs / frameMs)
        self.threshold = energyThreshold
    }

    static func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(frame.count)).squareRoot()
    }

    func update(frame: [Float]) -> Bool {
        let voiced = Self.rms(frame) >= threshold
        if voiced {
            speechFrames += 1
            trailingSilence = 0
            if speechFrames >= minSpeech { started = true }
        } else if started {
            trailingSilence += 1
        }
        return started && trailingSilence >= silenceNeeded
    }
}
```

- [ ] **Step 4: Run → PASS.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/EnergyEndpointerTests 2>&1 | tail -6`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Voice/EnergyEndpointer.swift Gemma/GemmaTests/EnergyEndpointerTests.swift
git commit -m "feat(wake): EnergyEndpointer (RMS silence endpointing) + tests"
```

---

## Task 5: `WakeListener` — AVAudioEngine + state machine

**Files:** Create `Gemma/Gemma/Voice/WakeListener.swift`, `Gemma/GemmaTests/WakeListenerTests.swift`.

`WakeListener` is hardware-bound for live audio, but its **transition logic** is testable via a fake detector + a directly-driven frame feed. The live `AVAudioEngine` capture is verified manually.

- [ ] **Step 1: Write the failing test — `Gemma/GemmaTests/WakeListenerTests.swift`:**

```swift
import XCTest
@testable import Gemma

@MainActor
final class WakeListenerTests: XCTestCase {
    final class FakeDetector: WakeDetecting {
        var nextScore: Float = 0
        private(set) var resetCount = 0
        func process(frame: [Float]) -> Float { nextScore }
        func reset() { resetCount += 1 }
    }

    func test_wake_then_silence_yields_a_wav_and_rearms() async {
        let det = FakeDetector()
        var sent: [Data] = []
        let wl = WakeListener(detector: det, sendWav: { wav in sent.append(wav) })
        wl.beginListeningForTest()                       // enters .listening without a real engine
        XCTAssertEqual(wl.state, .listening)

        det.nextScore = 0.9                              // next frame fires the wake word
        wl.feedFrameForTest(Array(repeating: 0.2, count: 1280))
        XCTAssertEqual(wl.state, .capturing)
        XCTAssertEqual(det.resetCount, 1)                // detector reset on wake

        // speak a bit then go silent -> endpointer fires -> a WAV is produced
        for _ in 0..<5 { wl.feedFrameForTest(Array(repeating: 0.2, count: 1280)) }   // speech
        for _ in 0..<12 { wl.feedFrameForTest(Array(repeating: 0.0, count: 1280)) }  // silence
        XCTAssertEqual(sent.count, 1, "one utterance WAV should be sent")
        XCTAssertEqual(sent.first?.prefix(4).map { $0 }, Array("RIFF".utf8))         // valid WAV
    }
}
```

- [ ] **Step 2: Run → FAIL.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/WakeListenerTests 2>&1 | tail -6`
Expected: `cannot find 'WakeListener'`.

- [ ] **Step 3: Create `Gemma/Gemma/Voice/WakeListener.swift`:**

```swift
import Foundation
import AVFoundation
import Observation

/// Always-listening orchestrator. When enabled, one AVAudioEngine 16 kHz mono tap feeds frames to
/// the wake detector; on "Hey Jarvis" it auto-captures the utterance (EnergyEndpointer) and hands a
/// WAV to `sendWav` (wired to VoiceController.send). Re-arms after. Detection is paused while busy.
@MainActor
@Observable
final class WakeListener {
    enum WakeState: Equatable { case off, listening, capturing, busy }
    private(set) var state: WakeState = .off

    @ObservationIgnored private let detector: WakeDetecting
    @ObservationIgnored private let sendWav: (Data) -> Void
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var endpointer: EnergyEndpointer?
    @ObservationIgnored private var captured: [Float] = []
    @ObservationIgnored private let sampleRate = 16000.0
    @ObservationIgnored private let maxUtteranceFrames = 188   // ~15 s at 80 ms/frame

    init(detector: WakeDetecting, sendWav: @escaping (Data) -> Void) {
        self.detector = detector
        self.sendWav = sendWav
    }

    /// Toggle entry points (UI). enable() starts the engine; disable() stops it.
    func enable() async {
        guard state == .off else { return }
        // mic permission reused from AudioRecorder
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return }
        do { try startEngine(); state = .listening } catch { state = .off }
    }
    func disable() { engine?.stop(); engine = nil; state = .off }

    /// Called by VoiceController when playback finishes, to re-arm.
    func notePlaybackFinished() { if state == .busy { state = .listening } }

    // MARK: frame handling (the core; shared by the live tap and tests)
    private func handle(frame: [Float]) {
        switch state {
        case .listening:
            if detector.process(frame: frame) > 0.5 {
                detector.reset()
                captured = []
                endpointer = EnergyEndpointer(frameMs: 80, silenceMs: 800, minSpeechMs: 300)
                state = .capturing
            }
        case .capturing:
            captured.append(contentsOf: frame)
            let done = endpointer?.update(frame: frame) ?? true
            if done || captured.count >= maxUtteranceFrames * 1280 {
                let wav = Self.makeWav(captured, sampleRate: Int(sampleRate))
                state = .busy
                if captured.count >= 1280 * 4 { sendWav(wav) } else { state = .listening }  // discard too-short
            }
        case .off, .busy:
            break   // ignore frames while off or while sending/playing
        }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: hwFormat, to: target)!
        let frameSamples: AVAudioFrameCount = 1280
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // convert to 16 kHz mono float, then slice into 1280-sample frames
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / hwFormat.sampleRate) + 1280
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)!
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in status.pointee = .haveData; return buffer }
            let n = Int(out.frameLength); let ch = out.floatChannelData![0]
            let samples = Array(UnsafeBufferPointer(start: ch, count: n))
            Task { @MainActor in self.pump(samples, frameSamples: Int(frameSamples)) }
        }
        engine.prepare(); try engine.start()
        self.engine = engine
    }

    private var pending: [Float] = []
    private func pump(_ samples: [Float], frameSamples: Int) {
        pending.append(contentsOf: samples)
        while pending.count >= frameSamples {
            let frame = Array(pending.prefix(frameSamples))
            pending.removeFirst(frameSamples)
            handle(frame: frame)
        }
    }

    /// Minimal 16-bit PCM WAV from float samples.
    static func makeWav(_ samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8); d.append(le32(36 + pcm.count)); d.append("WAVE".utf8.map { $0 }, count: 4)
        d.append("fmt ".utf8.map { $0 }, count: 4); d.append(le32(16)); d.append(le16(1)); d.append(le16(1))
        d.append(le32(sampleRate)); d.append(le32(sampleRate * 2)); d.append(le16(2)); d.append(le16(16))
        d.append("data".utf8.map { $0 }, count: 4); d.append(le32(pcm.count)); d.append(pcm)
        return d
    }

    // MARK: test hooks
    func beginListeningForTest() { state = .listening }
    func feedFrameForTest(_ frame: [Float]) { handle(frame: frame) }
}
```
(If the `Data.append(_:count:)` overloads for the WAV header don't compile cleanly, build the header with explicit `Data` appends — the goal is a valid 16 kHz mono PCM16 WAV; the test only checks the `RIFF` magic + that a WAV is produced.)

- [ ] **Step 4: Run → PASS.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/WakeListenerTests 2>&1 | tail -8`
Expected: the transition test passes (wake → capturing → WAV sent → resets).

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Voice/WakeListener.swift Gemma/GemmaTests/WakeListenerTests.swift
git commit -m "feat(wake): WakeListener (AVAudioEngine 16kHz tap + state machine) + transition test"
```

---

## Task 6: Wire `HarnessModel.wake` + the toggle in the chat

**Files:** Modify `Gemma/Gemma/Harness/HarnessModel.swift`, `Gemma/Gemma/Harness/AgentChatView.swift`.

- [ ] **Step 1: Add the listener to `HarnessModel`.** After the `voice` property (added in the Phase-1b work), add:

```swift
    /// Always-listening "Hey Jarvis". Built lazily so onnxruntime model load failure doesn't crash init.
    @ObservationIgnored private(set) var wake: WakeListener?
```
And a builder + re-arm wiring. Add this method near `ensureVoice()`:

```swift
    /// Build the wake listener (loads the ONNX models). On failure, leaves `wake == nil` (toggle disabled).
    func ensureWake() {
        guard wake == nil else { return }
        guard let detector = try? WakeWordDetector() else {
            agentLog.append("voice: wake word no disponible (no pude cargar el modelo).")
            return
        }
        let listener = WakeListener(detector: detector) { [weak self] wav in
            guard let self else { return }
            Task { await self.voice.send(wav); self.wake?.notePlaybackFinished() }
        }
        self.wake = listener
    }
```
(`voice.send` appends `you:`/`gemma:` and plays; after it returns, `notePlaybackFinished()` re-arms. This serializes one wake-turn at a time.)

- [ ] **Step 2: Add the toggle + indicator to `AgentChatView`.** Add a toolbar item (next to the existing ones in the `.toolbar { … }` block):

```swift
            ToolbarItem {
                Button {
                    model.ensureWake()
                    Task {
                        if model.wake?.state == .off { await model.wake?.enable() }
                        else { model.wake?.disable() }
                    }
                } label: {
                    Label(model.wake?.state == .off || model.wake == nil ? "Hey Jarvis: off" : "Escuchando",
                          systemImage: model.wake?.state == .off || model.wake == nil ? "ear" : "ear.badge.checkmark")
                        .foregroundStyle(model.wake != nil && model.wake?.state != .off ? .green : .secondary)
                }
                .help("Activar/desactivar escucha continua \u{201C}Hey Jarvis\u{201D}")
            }
```

- [ ] **Step 3: Build to verify.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' build 2>&1 | tail -6`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Harness/AgentChatView.swift
git commit -m "feat(wake): HarnessModel.wake + ensureWake() + Hey Jarvis toggle in chat"
```

---

## Task 7: Full build + test suite green

**Files:** none.

- [ ] **Step 1: Run the full suite.**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -scheme Gemma -project Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -25`
Expected: build succeeds; `OnnxRuntimeSmokeTests`, `WakeWordDetectorTests`, `EnergyEndpointerTests`, `WakeListenerTests` all pass; all other suites pass EXCEPT the known pre-existing `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`. No NEW failures.

- [ ] **Step 2: Fix any NEW failure before proceeding** (don't mask it). Re-run until only the known one remains.

---

## Task 8: Manual always-listening E2E (you)

**Files:** none. Done by the user; the implementer leaves the app built + documents the steps.

- [ ] **Step 1:** Run the app (the i3 voice service must be reachable — same setup as Phase 1b). Toggle **"Hey Jarvis"** on in the toolbar; grant mic permission.
- [ ] **Step 2:** Say **"Hey Jarvis"**, pause, then **"¿qué hora es?"**. Expect: it captures after the wake word, answers by voice, shows `you:`/`gemma:` in the chat, and re-arms (the indicator returns to listening).
- [ ] **Step 3:** Confirm it ignores normal talk that doesn't start with "Hey Jarvis", and that it doesn't self-trigger while Gemma is speaking. Tune the threshold (0.5) in `WakeWordDetector`/`WakeListener` if it's too eager or too deaf in your environment.
- [ ] **Step 4:** Toggle off → the mic indicator stops; manual tap-to-talk still works.

---

## Self-Review

**1. Spec coverage:**
- §4.1 always-listen → detect → capture → send → re-arm → Tasks 3 (detector), 5 (listener), 6 (wiring). ✓
- §4.2 WakeWordDetector (3 ONNX models, rolling buffers, protocol) → Tasks 2+3. ✓ WakeListener (AVAudioEngine, state machine, energy-VAD, reuse send, pause during busy) → Task 5. ✓ EnergyEndpointer → Task 4. ✓
- §4.3 reuse `VoiceController.send` unchanged → Task 6 (`sendWav` → `voice.send`). ✓
- §4.4 onnxruntime dep + bundled models → Tasks 1+2. ✓
- §4.5 toggle + indicator in AgentChatView; HarnessModel.wake → Task 6. ✓
- §4.6 errors (mic denied, model-load fail → toggle disabled + notice, no-speech discard, pause during playback) → Task 5 (states) + Task 6 (`ensureWake` nil path). ✓ (Mic-denied reverting the toggle is handled by `enable()` returning without leaving `.off`.)
- §5 testing (detector fixture, endpointer logic, onnxruntime smoke, listener transitions, manual) → Tasks 1–5, 8. ✓
- §6 order → Tasks 1→8 match. ✓ §7 risks (onnxruntime first, match reference w/ fixture gate, off-thread inference) → Task 1 de-risk + Task 3 fixture gate; inference runs in the tap closure then hops to MainActor (acceptable; if it stalls audio, move ONNX off the callback — noted). 

**2. Placeholder scan:** The only deliberately-incomplete code is `WakeWordDetector.process` (the `...` streaming port) — this is NOT a vague placeholder: the surrounding structure, the exact ONNX models, confirmed tensor shapes (76×32→96, 16→score), the reference repo to port from, and a real fixture test gate are all specified. Matching a reference pipeline + iterating against a passing fixture test is a bounded, concrete implementation activity (same pattern as the kokoro/faster-whisper API matching in the voice-backend plan). Every other step has complete code + exact commands.

**3. Type consistency:** `WakeDetecting{process(frame:)->Float, reset()}` used identically in `WakeWordDetector`, the fake, and `WakeListener`. `WakeListener(detector:sendWav:)` + `state: WakeState{off,listening,capturing,busy}` + `enable()/disable()/notePlaybackFinished()/beginListeningForTest()/feedFrameForTest()` consistent across the file, its test, and `HarnessModel.ensureWake`. `EnergyEndpointer(frameMs:silenceMs:minSpeechMs:energyThreshold:)` + `update(frame:)->Bool` consistent across impl, tests, and `WakeListener`. `HarnessModel.wake: WakeListener?` + `ensureWake()` match the AgentChatView toggle usage. 1280-sample/80 ms frame size consistent throughout. ✓
