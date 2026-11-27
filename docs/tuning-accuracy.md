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

## Follow-up before 0.2.5: the spelled phrase is spotted again

Spotting only `Spotter.written` replaced the spelled phrase with its most likely sound-alike, and the shortest
sound-alike usually won even where it doesn't sound like the name: "jerry" as `▁JE RY` ("jery"), "kitty" as `▁K ITY`,
"hey lee" as `▁HE Y ▁LE` (which fires on "hey lemon"), and "hey doot" as `▁HE Y ▁DO T` (which is "hey dot"). Now
every keyword set spots the spelled phrase as well as the written one (a shortened form that is a prefix of it drops
out), a doubled vowel is no longer a sound-alike ("doot" is not "dot"), and "-ie", "-y" and "-ee" are swapped only as
an unstressed ending ("katie", "katy"), not as a one-syllable name's only vowel ("lee", "ly"). Regression:
`soundAlikesNeverReplaceTheSpelledPhrase` (two new `say` fixtures, `hey-jerry-{Daniel,Samantha}`; "hey doot" against
the three "hey dot" fixtures) fails on `a01ce44` and passes now.

Same harness and corpus as above, before = `a01ce44`. The extra names ran with `HEYDOT_EVAL_PHRASES` and the
confusables in `AccuracyEval.similar` ("hey lee": "hey lets go", "hey leslie", "hey lemon"; "hey bee": "hey ben",
"hey becky", "hey beth"; "hey doot": "hey dot", "hey don", "hey dude"; "hey jerry": "hey jenny", "hey jeff",
"hey gary"). Rows not shown (luminaropolis, tray, dot, nova, maximilian, both settings) are identical before and
after; the TV stream gives 0 wakes for every phrase and setting.

| Phrase | Settings | TA before / after | TA fast before / after | TA fast paused before / after | FA before / after | FA fast before / after |
|---|---|---|---|---|---|---|
| hey trey | Standard | 62.5 / 56.2% | 40.6 / 40.6% | 43.8 / 43.8% | 1.3 / 3.0% | 0.6 / 0.6% |
| hey trey | Tuned | 89.6 / 85.4% | 59.4 / 59.4% | 62.5 / 62.5% | 4.2 / 5.3% | 2.3 / 2.3% |
| hey jerry | Standard | 2.1 / 81.2% | 0.0 / 65.6% | 0.0 / 68.8% | 0.0 / 1.0% | 0.0 / 0.0% |
| hey jerry | Tuned | 81.2 / 81.2% | 78.1 / 75.0% | 71.9 / 71.9% | 0.8 / 0.8% | 0.3 / 0.3% |
| hey kitty | Standard | 4.2 / 60.4% | 3.1 / 18.8% | 0.0 / 59.4% | 0.0 / 0.0% | 0.0 / 0.0% |
| hey kitty | Tuned | 66.7 / 62.5% | 25.0 / 21.9% | 53.1 / 65.6% | 0.0 / 0.0% | 0.0 / 0.0% |
| hey katie | Standard | 16.7 / 72.9% | 9.4 / 50.0% | 3.1 / 56.2% | 0.0 / 0.0% | 0.0 / 0.0% |
| hey katie | Tuned | 77.1 / 79.2% | 50.0 / 50.0% | 53.1 / 56.2% | 0.0 / 0.0% | 0.0 / 0.0% |
| hey happy | Standard | 16.7 / 77.1% | 9.4 / 81.2% | 3.1 / 78.1% | 0.0 / 0.0% | 0.0 / 0.0% |
| hey happy | Tuned | 85.4 / 77.1% | 78.1 / 81.2% | 59.4 / 78.1% | 0.8 / 0.8% | 0.0 / 0.0% |
| hey lee | Standard | 43.8 / 43.8% | 34.4 / 25.0% | 50.0 / 53.1% | 16.9 / 0.2% | 14.8 / 1.1% |
| hey lee | Tuned | 70.8 / 66.7% | 62.5 / 59.4% | 53.1 / 62.5% | 18.4 / 3.6% | 17.3 / 4.5% |
| hey bee | Standard | 62.5 / 45.8% | 50.0 / 6.2% | 40.6 / 34.4% | 12.5 / 1.5% | 14.5 / 0.3% |
| hey bee | Tuned | 66.7 / 60.4% | 59.4 / 34.4% | 37.5 / 34.4% | 12.9 / 4.2% | 12.8 / 1.1% |
| hey doot | Standard | 31.2 / 22.9% | 28.1 / 21.9% | 12.5 / 28.1% | 8.3 / 0.2% | 9.4 / 1.4% |
| hey doot | Tuned | 56.2 / 45.8% | 50.0 / 43.8% | 46.9 / 43.8% | 11.0 / 4.0% | 9.7 / 3.4% |

- **"hey trey" pays for it:** standard settings now also spot the spelled `▁T RE Y`, which a careful "Trey" can be
  pulled onto (see above) and which answers "hey troy" more (16 against 7 of 528 at test rates). Rushed TA is
  unchanged and `rushedHeyTreyWakesOnStandardSettings` still passes; standard TA stays above 0.2.0's 39.6%.
- **Fewer false wakes, fewer catches, for the short names:** "hey dot" no longer wakes "hey doot" (40 / 28 of 48 / 32
  before, 0 / 0 now); "hey lets go", "hey leslie" and "hey lemon" against "hey lee" fall from 89 to 1 at test rates.
  The hits "hey bee" and "hey doot" lose were mostly the shorter `▁BE` and `▁DO T` paths matching other words.

## Resources

Not re-measured. The listener spots the typed phrase and, for some names, one written sound-alike, plus at most
as many learned sequences as before. Calibration runs the decoder once per take, then releases it before the probe
spotter loads (one model at a time), as before; `calibration` stays under 2 s.

## Not verified

- **Live speech:** synthetic voices are cleaner and more uniform than a person. The owner's own rushed "Hey Trey"
  was not recorded or replayed. A speaker-to-microphone loop on my test Mac was not possible: its output is
  muted and the test process has no microphone permission.
- **Installed app:** no live tuning session or wake was run in the app; the tuning screens were checked with
  `HeyDot --qa-render` only.
