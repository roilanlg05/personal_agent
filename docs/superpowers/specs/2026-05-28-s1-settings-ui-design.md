# S1 Plan 3b — Settings UI (design spec)

**Date:** 2026-05-28
**Status:** approved (brainstorming) — pending spec review
**Position:** S1 Plan 3b. Previous: Plan 3a (LiteRT-LM core, on-device GPU working). Bench + report deferred to a later Plan 3c.

## Goal

A Settings sheet that lets the user tune all generation/engine parameters and experiment interactively. Settings persist to disk and, on **Save**, apply immediately — auto-reloading the model when an Engine-level parameter changed.

## Parameter taxonomy

Two classes, because the runtime recreates the `Conversation` per generation but the `Engine` only at load:

- **Engine-level (require reload):** `backend` (cpu/gpu), `contextLength` (KV-cache / `maxNumTokens`), `useSpeculativeDecoding` (MTP).
- **Live (applied next generation, no reload):** `systemPrompt`, `temperature`, `topP`, `topK`, `maxOutputTokens`.

> `maxOutputTokens` *enforcement* already landed (LiteRTLMRuntime caps the stream at `options.maxTokens`). Plan 3b only makes it user-configurable.

## Components

### 1. `GenerationSettings` (Codable, Equatable, Sendable)
Single struct holding all eight fields above. `static let `default`` = Edge Gallery recipe: `backend .gpu`, `contextLength 4096`, `useSpeculativeDecoding false`, `systemPrompt ""`, `temperature 1.0`, `topP 0.95`, `topK 64`, `maxOutputTokens 256`. Provides `engineLevelDiffers(from:) -> Bool` (compares only the three Engine-level fields) to drive reload detection.

New file: `Gemma/Gemma/Settings/GenerationSettings.swift`.

### 2. `SettingsStore`
Thin persistence wrapper over `UserDefaults` (JSON-encoded `GenerationSettings` under one key). Injectable (`init(defaults: UserDefaults = .standard)`) so tests use a temporary suite, mirroring the `InstalledModels` pattern. API: `load() -> GenerationSettings`, `save(_:)`.

New file: `Gemma/Gemma/Settings/SettingsStore.swift`.

### 3. Runtime wiring (`LiteRTLMRuntime`, `ModelRuntime` types)
- `makeConversation` takes sampler params (`temperature`, `topP`, `topK`) and `systemPrompt` from the current generation instead of the hardcoded `64 / 0.95 / 1.0`. Source them from `GenerationOptions` (already carries `temperature/topP/topK/maxTokens`) plus a stored `systemPrompt`.
- `ModelLoadOptions` is built from settings for backend/context/MTP/systemPrompt (already supported).
- No change to the maxTokens cap (already enforced).

### 4. `HarnessModel`
- Holds `private(set) var settings: GenerationSettings`, loaded from an injected `SettingsStore` at init.
- `saveSettings(_ new: GenerationSettings)`: persist via store; if `new.engineLevelDiffers(from: settings)` **and** `modelLoaded`, `await toggleLoad()` twice (unload + reload) to apply; assign `settings = new`. Live fields take effect on the next `generate` automatically.
- `toggleLoad` builds `ModelLoadOptions` from `settings` (backend, contextLength, useSpeculativeDecoding, systemPrompt).
- `runSingle`/`runBench` build `GenerationOptions` from `settings` (temperature, topP, topK, maxTokens = maxOutputTokens).
- `settings` injected for testing.

### 5. UI — `SettingsView` (sheet)
- Opened from a ⚙️ button in `HarnessView.statusBar` (disabled while generating/loading).
- `TabView` with two tabs:
  - **Parameters:** backend `Picker` (CPU/GPU), context `Stepper`/menu (e.g. 1024/2048/4096/8192), MTP `Toggle`, `temperature`/`topP` sliders with value labels, `topK` stepper, `maxOutputTokens` stepper. Engine-level rows show a small "requires reload" caption when the draft differs from the loaded config.
  - **System Prompt:** `TextEditor` (multiline) with a keyboard "Done" button (reuse the focus pattern from HarnessView).
- Edits a `@State private var draft: GenerationSettings` seeded from `model.settings`. **Save** → `await model.saveSettings(draft)` then dismiss. **Cancel** → dismiss without saving.

New file: `Gemma/Gemma/Harness/SettingsView.swift`. Modify `HarnessView.swift` (gear button + `.sheet`).

## Data flow

`SettingsStore (UserDefaults)` → `HarnessModel.settings` → (load) `ModelLoadOptions` and (generate) `GenerationOptions` → `LiteRTLMRuntime`. `SettingsView` edits a draft → `saveSettings` → store + optional reload.

## Error handling
- Save persists unconditionally; a reload that fails surfaces via the existing `statusMessage` ("Load failed: …"), leaving settings saved.
- Sampler bounds clamped in the UI (temperature ≥ 0, 0 ≤ topP ≤ 1, topK ≥ 1) so `SamplerConfig` init never throws.

## Testing (TDD)
- `GenerationSettings`: Codable round-trip; `default` values; `engineLevelDiffers` true on backend/context/MTP change, false on sampler/systemPrompt change.
- `SettingsStore`: save→load round-trip on a temp `UserDefaults(suiteName:)`; returns `.default` when empty.
- `HarnessModel.saveSettings`: with a counting/spy `DummyRuntime`, an Engine-level change while loaded triggers unload+reload; a live-only change does not; `settings` updated either way.
- Runtime sampler/systemPrompt sourcing verified on-device (native), not unit-tested.

## Out of scope (later)
- Bench combos (MTP on/off, cpu/gpu, E2B/E4B) + S1 report → Plan 3c.
- Multimodal image generation (vision backend GPU) → separate plan.
- Per-prompt bench progress UI.
