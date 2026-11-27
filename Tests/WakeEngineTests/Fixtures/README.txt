Generated locally with macOS say on 2026-11-14. Synthetic speech, no personal recordings.
Command for positive fixtures (voice Samantha, Daniel, Karen; phrase hey dot, hey tray):
  say -v "$voice" -r 150 -o "$file.wav" --file-format=WAVE --data-format=LEI16@16000 "$phrase"
Negatives use Samantha: hey jarvis, hey there.
Python reference: sentencepiece 0.2.2 and sherpa-onnx 1.13.8, KeywordDetector defaults.
Run PYTHONPATH=. .venv/bin/python apps/HeyDot/Scripts/check-parity.py from the repository root.
Added 2026-11-15 for the Hey John regression (same command, rate 170 unless named): hey-luminaropolis-Daniel-{150,165,170,195},
  hey-john-{Daniel,Samantha}, hey-jeff-Daniel, luminaropolis-Daniel.
WAV payloads total < 600 KB. No microphone, network, or OS speech synthesis used in tests.

The Tray and Luminaropolis fixtures were regenerated from the neutral example phrases on 2026-11-17 with the command above.
The rare-name regression enrolls at 150, 165 and 195 words/minute and holds out 170; the public corpus uses distinct enrollment and held-out utterances without changing the matcher or assertions.
The rare-spelling test uses Lumynaropolis as the target spelling for the spoken synthetic Luminaropolis to preserve coverage of learned tokens differing from spelled tokens.
hey-dot-Daniel-320.wav uses the same command at 320 words/minute to test a short tuning attempt at the start of capture.
