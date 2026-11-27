# Contributing

HeyDot currently builds on Apple silicon Macs. Tested with Xcode 27.2 (27B52), Apple Swift 6.4.2 and macOS 26.7.2. The package declares macOS 14 as its deployment target; older systems have not been verified.

From the repository root:

```sh
Scripts/fetch-vendor.sh
swift build
swift test --no-parallel
HEYDOT_APPROVED_CERT_SHA1=<your-certificate-SHA1> ./build-app.sh release
```

The vendor script pins official sherpa-onnx release assets and the matching header with SHA-256 checks. Use a fresh Vendor directory to verify every download. Tests use synthetic WAV fixtures, without microphone capture. Serial execution avoids timing flakes.

Any valid code-signing identity works for a local source build, including the free Apple Development certificate Xcode creates for a signed-in Apple ID. Set its 40-character SHA-1 fingerprint in `HEYDOT_APPROVED_CERT_SHA1`; no maintainer certificate is required. Signing does not make a build notarized or trusted for public distribution. The script assembles and signs locally; it does not install or register the app. Its icon-only renderer runs during assembly, without starting the listener or a call.

Keep changes focused, run the affected checks, and describe behavior and validation in your pull request. See [Development](docs/DEVELOPMENT.md) (its code map shows where everything lives), [Design](DESIGN.md) (every control comes from a Frost role) and [Security](SECURITY.md). Resolve the fixture redistribution and dependency-notice gaps in THIRD_PARTY_NOTICES.md before a public release.
