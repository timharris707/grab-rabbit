//
//  RecordingMediaChoice.swift
//  QuickRecorder
//

import Foundation

/// The capture-media decision for one recording session, resolved once from the
/// user's explicit settings when the session starts and never re-read from
/// mutable settings mid-flight. Every start path — the normal selectors,
/// quick-current-screen, and quick-topmost — shares this object, so a settings
/// mutation racing the asynchronous session setup cannot change what is captured.
struct RecordingMediaChoice: Equatable {
    let systemAudio: Bool
    let microphone: Bool

    /// `fastStart` may skip selection UI or a countdown, but it takes part in no
    /// audio decision. It is accepted here so every start path resolves through
    /// one signature and tests can prove it has no effect on the result.
    static func resolve(
        systemAudioEnabled: Bool,
        microphoneEnabled: Bool,
        fastStart: Bool
    ) -> RecordingMediaChoice {
        _ = fastStart
        return RecordingMediaChoice(
            systemAudio: systemAudioEnabled,
            microphone: microphoneEnabled
        )
    }

    /// Whether the ScreenCaptureKit stream should deliver system-audio samples.
    /// Audio-only sessions always capture: recording system audio is the very
    /// action the user chose there.
    func capturesSystemAudio(audioOnly: Bool) -> Bool {
        systemAudio || audioOnly
    }
}
