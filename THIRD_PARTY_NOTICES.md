# Third-party notices

HeyDot's original code is Apache-2.0; see LICENSE. The following components are linked into the executable or bundled as resources. Upstream license texts and notices are retained verbatim under licenses/ and copied into the app's Resources.

| Component | Exact input version | License and evidence |
| --- | --- | --- |
| sherpa-onnx (C API and core) | 1.13.8, arm64 static no-TTS release | Apache-2.0, licenses/sherpa-onnx/LICENSE |
| ONNX Runtime | 1.28.2 (also present in the linked archive's version strings) | MIT; licenses/onnxruntime/LICENSE and ThirdPartyNotices.txt |
| kaldi-native-fbank | 1.22.3 | Apache-2.0, licenses/kaldi-native-fbank/LICENSE |
| KissFFT (float) | febd4caeed32e33ad8b2e0bb5ea77542c40f18ec | BSD-3-Clause; licenses/kissfft/COPYING and LICENSES/ |
| simple-sentencepiece (ssentencepiece_core) | 0.7 | Apache-2.0, licenses/simple-sentencepiece/LICENSE |
| Darts-clone (vendored in simple-sentencepiece) | 0.32 header in simple-sentencepiece 0.7 | BSD-2-Clause; licenses/simple-sentencepiece/darts.h-NOTICE.txt |
| ThreadPool (vendored header) | exact copy in simple-sentencepiece 0.7, no separate version declared | zlib; licenses/simple-sentencepiece/threadpool.h-NOTICE.txt |
| OpenFst (FST and FAR) | 1.8.5-2026-07-09, selected by sherpa-onnx's top-level build | Apache-2.0; licenses/openfst/COPYING |
| kaldifst | 1.8.0 | Apache-2.0; licenses/kaldifst/LICENSE |
| kaldi-decoder | 0.3.0 | Apache-2.0; licenses/kaldi-decoder/LICENSE |
| nlohmann/json | 3.12.0 | MIT; licenses/json/ |
| Eigen (decoder headers) | 3.4.0, selected in kaldi-decoder 0.3.0 | MPL-2.0 and per-file terms; licenses/eigen-3.4.0/ (MPL-2.0 and bundled alternative license texts) |
| Sparkle (Sparkle.framework, bundled for self-updates) | 2.10.1, official Swift Package Manager release asset | MIT, with bsdiff (BSD-2-Clause), sais-lite (MIT), orlp/ed25519 (zlib) and SUSignatureVerifier (BSD) notices; licenses/Sparkle/LICENSE |
| GigaSpeech KWS Zipformer model, 3.3M | 2024-01-01 | Apache-2.0 declaration in licenses/GigaSpeech-model-card.md |

The model comes from the official k2-fsa/sherpa-onnx `kws-models` release asset `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2`, SHA-256 `f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a`. Its fetched README explicitly declares Apache License 2.0 and describes GigaSpeech XL training using icefall. The original model card is shipped next to the int8 weights, tokens and BPE model, with the full Apache-2.0 license. This provenance note does not resolve separate training-data rights questions.

The dependency versions above are derived from the fetched sherpa-onnx v1.13.8 source CMake inputs, and their checksum-verified dependency source archives. The prebuilt static release contains libraries only, without license/NOTICE files or a full build manifest. This limits what can be proven about its transitive contents. ONNX Runtime is incorporated through sherpa-onnx, not downloaded separately by Scripts/fetch-vendor.sh. Its selected static package is identified in upstream `cmake/onnxruntime-osx-arm64-static.cmake` as `onnxruntime-osx-arm64-static_lib-1.28.2.zip` (SHA-256 `bf6e35dc9440d2899c3d21f52b1045fb99176a6ae822281b7245c5418cc338ab`). PortAudio and TTS archives are not linked by Package.swift.

Sparkle comes from the official sparkle-project/Sparkle `Sparkle-for-Swift-Package-Manager.zip` release asset for tag 2.10.1 (commit ab7d71291238df6e0492143b120c9b696a35f603), SHA-256 `4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a`, which SwiftPM checks on download. Its LICENSE is copied unchanged from that archive. Sparkle's XPC services are not shipped.

macOS frameworks, libc++ and Accelerate are linked system components supplied by Apple, not redistributed in the ZIP. The original avatar artwork and embedded prompts are covered by HeyDot's LICENSE. The WAV test fixtures are synthesized using macOS system voices; their redistribution rights have not been established, so the root Apache license must not be interpreted as resolving those rights.

ONNX Runtime's LICENSE and ThirdPartyNotices.txt are taken from Microsoft's official onnxruntime 1.28.0 macOS arm64 wheel on PyPI (onnxruntime-1.28.0-cp312-cp312-macosx_14_0_arm64.whl, SHA-256 26ff0fdd06efb6c155bae95387a09db1a2be89c7a03e4d0bffd5a171cc2826da), the closest published release to the 1.28.2 static library linked through sherpa-onnx; the 1.28.2 source tag was not reachable when these notices were collected.
