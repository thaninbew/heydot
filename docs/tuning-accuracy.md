# Voice tuning accuracy, 2026-11-27

Issue #21. Before: `1d2e5b2` (main before this change). Synthetic speech only (macOS `say`), no microphone.

## What changed and why

- **Tuning listens to the user, not to our spelling.** Before, a take ticked only when `Hearing.judge` found the spelled
  name in what the model heard, so a speaker the model hears as "Hey Daughter" for "Hey Dot", or "Page Ray" for
  "Hey Trey", was told "a different name" or "without the start" and never got four ticks. Now a recording is a take
  when it is plausible (the model made words of it, at most a few more words than the phrase, under 4 s), and a slot
  ticks for each take that sounds like the user's other takes (`Takes.agreeing`: a sound-alike edit distance between
  takes, word breaks removed, bar 0.65). A stray take ("Hey John", a cough) stays out of the group. Hints describe
  the recording: "too quiet", "Didn't catch anything", "longer than a wake phrase", "sounded different from your
  others". `Hearing` is deleted.
- **No "say something else" step.** The eval tuned every speaker with and without the three recorded other phrases
  ("Hey John", the name alone, "Hey there"): every threshold, learned sequence, TA and FA was identical, so the step
  only made tuning feel like a test.
- **What calibration learns.** The token sequences the model heard in the agreeing takes: every long (specific)
  reading, and a short one only when the user repeats it and the listener would miss that take without it
  (`Takes.specific`, `Takes.repeated`). A one-off short reading is how the model misheard one take; learning it
  ("HEY DRAY" once among "HEY TRAY"s) answers "Hey Dre". The threshold rule is unchanged.

## Why a rushed "hey Trey" needed a pause

The spotter (sherpa-onnx KWS) fires only on an exact token path. Standard settings listened for the tokenizer's
spelling of the typed phrase, `▁HE Y ▁T RE Y`, but the model writes the sound "Trey" its own way: `▁TRA Y`, and when
rushed `▁DR A Y` or `▁HA T RE Y`. Said carefully after a pause, the T is clear enough for the keyword boost to pull
the beam onto the rare written path; rushed, it is not. Rushing changes the letters and moves the word break
(`▁HA T RE Y`), and no listened-for path matched either. The live listener has no segmenter and feeds one continuous
stream, so windowing is not involved; the tuning decoder heard `▁HE Y ▁TRA Y` for most voices with and without the
pause, so the "HEY" piece is intact.

Fix: every keyword set spots the phrase **as the model writes it** (`Spotter.written`): of the typed spelling and its
sound-alikes ("trey", "tray", "trei"), the one the tokenizer's unigram model finds most likely. For "hey trey" that is
`▁HE Y ▁TRA Y`; for "hey dot" or "hey tray" nothing changes. Regression: `rushedHeyTreyWakesOnStandardSettings`
(Karen at 340 and Daniel at 300 words/minute) fails on `1d2e5b2` and passes now.

Rejected, measured: listening for every sound-alike at once (more "hey troy" hits); learning rushed forms from the
user's takes sped up with WSOLA, which reproduced what the model hears in real fast speech but tripled "hey dre"
hits (rushed "Trey" and "Dray" are the same token path, and per-keyword confidences don't separate them).

## Accuracy

`HEYDOT_EVAL=1 swift test --filter wakeAccuracyEval 2>&1 | grep 'EVAL|'` (cache `/tmp/heydot-eval-cache`; narrow a run
with `HEYDOT_EVAL_PHRASES` and `HEYDOT_EVAL_SCENARIOS`).
- **Voices:** 8 (Samantha, Daniel, Karen, Moira, Rishi, Tessa, Eddy US, Reed UK).
- **Test clips:** rates 140, 175, 210, each clean and noisy (white noise at 25 dB SNR plus another voice's sentence
  12 dB under): TA counts 48 positives, FA 528 confusables per phrase. **Fast:** rates 260 and 320, where `say` runs
  "hey" into the name with no pause: 32 positives, 352 confusables. **Fast paused:** the same with 500 ms of silence
  after "hey".
- **Tuned:** the tuning screen simulated per speaker: attempts at 150, 165, 190, 200 then 155, 180, 195, 205 until four
  takes count (before: until four ticked `Hearing.judge`), then calibration. The bug flow says "hey john" as attempt 2.

Both columns come from the same harness, the before column with the old judge and calibration.

| Phrase | Settings | TA before / after | TA fast before / after | TA fast paused before / after | FA before / after | FA fast before / after |
|---|---|---|---|---|---|---|
| hey trey | Standard | 39.6 / **62.5%** | 28.1 / **40.6%** | 28.1 / 43.8% | 2.1 / **1.3%** | 0.0 / 0.6% |
| hey trey | Tuned | 85.4 / **89.6%** | 59.4 / 59.4% | 62.5 / 62.5% | 5.1 / **4.2%** | 2.3 / 2.3% |
| hey tray | Standard | 54.2 / 54.2% | 40.6 / 40.6% | 46.9 / 46.9% | 1.3 / 1.3% | 0.6 / 0.6% |
| hey tray | Tuned | 75.0 / 75.0% | 59.4 / 59.4% | 71.9 / 78.1% | 5.1 / **4.2%** | 2.3 / 2.3% |
| hey dot | Standard | 83.3 / 83.3% | 87.5 / 87.5% | 65.6 / 65.6% | 3.4 / 3.4% | 4.8 / 4.8% |
| hey dot | Tuned | 81.2 / 83.3% | 87.5 / 84.4% | 68.8 / 65.6% | 3.6 / 3.2% | 4.5 / 4.0% |
| hey nova | Tuned | 75.0 / **85.4%** | 81.2 / 81.2% | 56.2 / 56.2% | 1.1 / 1.5% | 1.1 / 1.1% |
| hey maximilian | Tuned | 83.3 / 83.3% | 81.2 / 81.2% | 78.1 / 78.1% | 0.0 / 0.0% | 0.0 / 0.0% |
| rare five-syllable name | Tuned | 70.8 / 68.8% | 34.4 / 34.4% | 21.9 / 18.8% | 0.0 / 0.0% | 0.0 / 0.0% |

Standard rows not shown (nova, maximilian, the rare name) are unchanged. "hey john" FA is 0 everywhere; the TV stream
(107 s of ordinary speech with "hey <other name>" lines) gives 0 wakes for every phrase and setting.

- **Takes:** 212 attempts gave 188 agreeing takes and 1 voice stuck below three (before: 222 attempts, 182 ticks,
  3 stuck). In the bug flow "hey john" never joined a calibrated group; once it was the only take of a voice that
  then fell back to standard settings.
- **FA above before:** "hey nova" 8 against 6 of 528, all from Reed, whom the old judge refused ("a different name";
  stuck at 2 ticks, standard settings) and who now tunes 4 of 4 and catches 6 of 6. The extra hits are "hey noah".
- **The pause, synthetically:** `say` voices don't reproduce the pause dependence on standard settings (before: 9 of
  32 fast with and without the pause); the token path above is the mechanism, and the fix moves standard "hey trey"
  fast TA from 28.1% to 40.6%.
- **After tuning, rushed:** tuned fast TA is the same as before (59.4%): the old calibration already added the "tray"
  spelling. Further gains need the rushed `▁DR A Y` forms, which answer "hey dre" (see Rejected).

## Resources

Not re-measured. The listener spots one written phrase as before (a different spelling for some names) plus at most
as many learned sequences as before. Calibration runs the decoder once per take, then releases it before the probe
spotter loads (one model at a time), as before; `calibration` stays under 2 s.

## Not verified

- **Live speech:** synthetic voices are cleaner and more uniform than a person. The owner's own rushed "Hey Trey"
  was not recorded or replayed. A speaker-to-microphone loop on the agent Mac was not possible: its output is
  muted and the test process has no microphone permission.
- **Installed app:** no live tuning session or wake was run in the app; the tuning screens were checked with
  `HeyDot --qa-render` only.
