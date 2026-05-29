import Foundation
import LiteRTLM

/// One step of the vision/audio backend fallback cascade.
public enum MMAttempt: CaseIterable, Equatable {
    /// Use the engine's main backend (GPU when the user picked GPU) for vision/audio.
    case primary
    /// Pin vision/audio to CPU (the main LLM backend is unchanged).
    case cpu
    /// Request no multimodal executors — text only.
    case textOnly
}

/// The ordered attempts to try when loading. If the model declares no multimodal
/// support there is nothing to fall back from, so we go straight to text-only.
public func multimodalAttemptPlan(image: Bool, audio: Bool) -> [MMAttempt] {
    (image || audio) ? [.primary, .cpu, .textOnly] : [.textOnly]
}

/// Backends to request for a given attempt. A modality the model does not support
/// is `nil` in every attempt — we never degrade something that was not requested.
public func multimodalBackends(
    image: Bool,
    audio: Bool,
    attempt: MMAttempt,
    main: Backend
) -> (vision: Backend?, audio: Backend?) {
    switch attempt {
    // When `main` is already .cpu, .primary and .cpu produce the same tuple; the
    // extra (identical) attempt on failure is harmless, not a bug.
    case .primary:
        return (image ? main : nil, audio ? main : nil)
    case .cpu:
        return (image ? .cpu() : nil, audio ? .cpu() : nil)
    case .textOnly:
        return (nil, nil)
    }
}
