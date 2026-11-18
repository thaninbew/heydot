# WakeEngine native dependencies

Run from the repository root:

```sh
Scripts/fetch-vendor.sh
swift build
swift test --no-parallel
export HEYDOT_MODEL_DIR="$PWD/Vendor/models"
swift run --skip-build heydot-engine-check Tests/WakeEngineTests/Fixtures/hey-tray-Samantha.wav 'hey tray'
```

The no-argument engine/enroller constructors resolve models when first used. Package the model
folder in the app bundle's Resources (directly or inside `models/`), or set `HEYDOT_MODEL_DIR` to
the model folder or its parent for development. The app must supply `NSMicrophoneUsageDescription`
and, if sandboxed, the audio-input entitlement. `start` is synchronous per the API; the first
permission request waits for the system authorization callback. No microphone use occurs in tests.

The official arm64 static release has no headers. The fetch script also retrieves and verifies the
matching v1.13.8 C header. SwiftPM's CSherpa module imports it and links the static C API, core,
ONNX Runtime and support libraries plus libc++ and Accelerate. No runtime dylib installation or
Python is needed. Preserve upstream license notices from the release/model when distributing.

Despite its name, this model's `bpe.model` uses SentencePiece unigram pieces. The native encoder
reads ModelProto piece scores and uses Viterbi segmentation. It accepts English letters and
whitespace, uppercases and normalizes whitespace, and rejects unsupported input with invalidPhrase.
Tokenizer expectations are verified by the native engine tests. `check-parity.py` is an optional historical comparison that requires the separate Python listener source and its environment; it is not part of the standalone build.

Calibration tries score ascending then threshold descending, preferring lower boost before higher
threshold. Each trial owns a fresh spotter; each clip owns a fresh stream and gets one second of
silence on each side. It stops at the first perfect result or evaluates all 20 settings and returns
the greatest `caught - 2 * falseHits`, with strictness breaking ties. Up to three deterministic
last-word aliases share the wake label. The timing test covers five 2-second positives and three
2-second negatives; exhaustive no-perfect searches take longer and are not a hard real-time bound.
