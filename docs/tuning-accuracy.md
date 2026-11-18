# Voice tuning accuracy, 2026-11-15

Branch `heydot-tuning`. Baseline `15a3cad`; after `e5d482e`. Synthetic speech only (macOS `say`), no microphone.


- The tuning screen ticked a slot when the lenient detector matched **or** for any 0.35 to 2.8 s utterance
  (`OnboardingModel.heard`). "Hey John" is phrase length, so it ticked.
- The detector could not have helped a rare name: its tokenizer spelling (for example `▁LU MI NA RO PO LI S`) can differ
  from the token path the model actually hears. sherpa-onnx KWS only fires on an exact token path, so such a phrase
  scored 0 even at threshold 0.01, and calibration then tried looser settings chasing positives it could never catch.
- The detector never fired on "hey john" either (FA 0/48 before and after). The false success was the tick.

## Approach

1. `PhraseDecoder`: the same keyword model run as a plain recognizer, only while tuning. No new model or dependency.
2. `Hearing.judge`: a slot ticks only when the heard name matches the phrase by a sound-alike edit distance
   (spelling-of-sound normalization, half cost for vowels and voiced/unvoiced pairs, stricter bar for short names).
   Otherwise the hint says "a different name", "without the start" or "didn't catch that".
3. Calibration stores the heard token sequences as extra keywords (`WakeSettings.learned`), for short names only when
   the match is clear and starts with the same sound. The threshold sits 40% of the way from the strongest recorded
   negative to the weakest sample, at least 0.03 above that negative and never above that sample. A recorded
   negative is never answered.
4. The tuning screen asks for "Hey John" (or "Hey Sam"), the name alone and "Hey there". The Start over pill clears
   all samples. Tapping a tick retries that sample.

Rejected: a DTW template verifier (not needed once the right tokens are spotted), openWakeWord (per-word training on
TTS plus about 2,000 h of negatives, too heavy on device), Porcupine (closed engine, cloud training), and hotword
biasing of the tuning decoder (measured no effect).
Sources: sherpa-onnx v1.13.8 `transducer-keyword-decoder.cc` (trigger = mean raw token probability of the best
path, L147-160), `context-graph.cc`, `utils.cc` keyword syntax; Hazen et al. ASRU 2009; Zhang and Glass ASRU 2009.

## Accuracy

`HEYDOT_EVAL=1 swift test --filter wakeAccuracyEval 2>&1 | grep 'EVAL|'` (cache `/tmp/heydot-eval-cache`).
- **Voices:** 8 (Samantha, Daniel, Karen, Moira, Rishi, Tessa, Eddy US, Reed UK).
- **Test clips:** rates 140, 175 and 210, each clean and noisy (white noise at 25 dB SNR plus another voice's
  sentence 12 dB under).
- **Tuned:** per speaker, then aggregated. TA counts 48 positives and FA 528 confusables per phrase.

The baseline harness (same corpus) differed in its tuned flow. It calibrated four fixed enrollment clips; the bug
flow replaced the last with "hey john", which the old screen ticked. Negatives were "hey there", the name alone and
"I'm making a cup of coffee". The tuned flow now simulates the current screen: attempts at enrollment rates 150,
165, 190 and 200, then retries at 155, 180, 195 and 205, ticking only on `Hearing.judge`. The bug flow says
"hey john" as attempt 2. Continue needs three ticks, else Later.

| Phrase | Tuned TA before | Tuned TA after | Clean before / after | Noisy before / after | FA before / after | FA "hey john" |
|---|---|---|---|---|---|---|
| hey dot | 83.3% | 81.2% | 100 / 100% | 66.7 / 62.5% | 3.4 / 3.6% | 0 / 0 |
| hey nova | 77.1% | 75.0% | 91.7 / 87.5% | 62.5 / 62.5% | 1.3 / 1.1% | 0 / 0 |
| hey maximilian | 54.2% | **83.3%** | 70.8 / 95.8% | 37.5 / 70.8% | 0.0 / 0.0% | 0 / 0 |
| rare five-syllable name | 0.0% | **45.8%** | 0.0 / 66.7% | 0.0 / 25.0% | 0.0 / 0.0% | 0 / 0 |
| short one-syllable name | 60.4% | **85.4%** | 75.0 / 95.8% | 45.8 / 75.0% | 3.0 / 5.1% | 0 / 0 |

- **Bug flow:** identical to the honest flow after the fix. "hey john" ticked 0 of 40 times. Before, the duration rule
  ticked any phrase-length "hey john".
- **Short-name FA breakdown:** "hey dre" 0 to 12/48 and "hey troy" 16 to 13/48 (tuned), "hey" and "hey ray" 1/48 each.
  `say` pronounces "Dre" as "Dray", one voicing step from "Tray"; excluding it, tuned FA is 15/480 (3.1%) against
  16/480 (3.3%) before.
- **Thresholds cannot separate these:** a 0.5 lean and a 0.08 floor each cost TA and removed no FA.
- **Stuck below three ticks:** 5 of 40 speaker-phrase pairs (the rare name with Eddy and Reed, dot with Rishi and Eddy, nova with
  Reed). The model hears those voices as other words ("PAID OUT", "HEY DAUGHTER"). They fall back to standard.
- **TV stream:** 107 s of ordinary speech with "hey <other name>" lines, 0 hits for every phrase.

## Resources

`HEYDOT_ENGINE_PROBE=1 HEYDOT_ENGINE_CONFIG=N swift test --filter engineCostProbe`, one configuration per process.
Each measurement is 120 s of audio in 683-sample buffers, run through the live path.

| | Idle CPU (one core) | Active CPU | Model RSS |
|---|---|---|---|
| Before, standard short name (2 runs) | 1.65-1.66% | 1.64-1.68% | +40.0-42.2 MiB |
| After, standard short name | 1.68% | 1.76% | +44.0 MiB |
| After, tuned short name (3 learned) | 1.63% | 1.63% | +42.7 MiB |
| After, tuned rare name (3 learned) | 1.66% | 1.71% | +41.0 MiB |

All within run-to-run noise. Learned sequences only add context-graph paths, and the beam stays 4.
- **Tuning only:** the decoder replaces the old preview spotter (one model either way), about 21 ms per utterance.
- **Calibration:** releases the decoder before loading its probe spotter, so one model at a time. It took 1.4 to
  1.8 s for 8 clips.

## Not verified

  Synthetic voices are cleaner and more uniform than live speech.
- **Live behaviour:** no live call or idle measurement was run on the installed app.
