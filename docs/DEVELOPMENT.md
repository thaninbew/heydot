# HeyDot

A macOS menu bar app (SwiftUI, Swift 6, macOS 14+). Say "Hey" plus your dot's name and HeyDot starts
that dot's voice call in its own hidden, signed-in web view.

Unofficial; not affiliated with OpenAI. Wake-word listening runs on device and its audio is never uploaded. Call audio goes to ChatGPT like any ChatGPT voice call. The built-in web view contacts ChatGPT and its sign-in providers. Details: [SECURITY.md](../SECURITY.md).

Requires your own eligible ChatGPT account with existing dot access. Calls remain subject to ChatGPT’s terms and limits. This independent integration depends on ChatGPT’s interface and may stop working when it changes. Integration permission, clean-machine acceptance, public binary trust and fixture redistribution remain release gates; see [Third-party notices](../THIRD_PARTY_NOTICES.md).

## Code map

`Sources/HeyDot/Main` only calls `HeyDotMain.run`. Everything else in the app is the `HeyDotKit` target in
`Sources/HeyDot/Kit`, internal except that entry point; the on-device listener is the `WakeEngine` target.

| `Sources/HeyDot/Kit/` | What it holds |
| --- | --- |
| `App/` | `HeyDotMain` (launch flags), `AppDelegate` (status item, windows), `AppModel` (status, listening, calls, settings changes), `SystemHooks`, `Updates` (Sparkle) |
| `Core/` | The settings file, paths, name and wake phrase rules, the log, the lifecycle lease, erase and uninstall, listener usage |
| `Control/` | `--control`: the command line, the app-side service and timed-pause expiry, the socket and its JSON |
| `Web/` | The built-in browser: `WebCalling` (and `NoWeb` for fixtures), `WebCallBackend`, the sign-in window, page scripts, `CallResult` and its messages, the WebCrypto key |
| `Dot/` | The dot: `DotDesign` (the saved design), `DotGeometry` (every vector part), `DotView` and `DotTile`, `DotGlyph` (menu bar), imported avatars, the logo |
| `Frost/` | The design system in [DESIGN.md](../DESIGN.md): tokens, `Theme`, `Accent`, `OKLCH`, backdrop, floating tile, button roles, cards, fields, choices, banners |
| `Components/` | Views several windows share: the microphone menu, the menu bar icon picker, the result banner, level bars |
| `Onboarding/`, `Popover/`, `Settings/`, `DotMaker/`, `Troubleshoot/` | One folder per window: its view, and its model when it has one (`OnboardingModel`, `Troubleshooter`) |
| `QA/` | `--qa-render`, `--qa-boards` and `--qa-signin`, with fakes that never touch the microphone, login items or the profile |
| `Resources/` | Files compiled into the binary: the logo PNGs and the avatar prompt |

| `Sources/WakeEngine/` | What it holds |
| --- | --- |
| `WakeEngineAPI.swift` | Everything the app uses: `WakeSettings`, `WakeEvent`, errors, `WakeListening`, `WakeEnrolling` |
| `Microphone.swift` | The capture session, the live `WakeEngine` listener and the `Enroller` (voice tuning calibration) |
| `Supervisor.swift` | `ListenerSupervisor`: restarts, display sleep and lock, device changes |
| `Spotter.swift`, `Decoder.swift`, `Tokenizer.swift` | Keyword spotting, what the model heard (`PhraseDecoder`, `Takes`), the model's tokenizer |
| `Utterances.swift` | Utterance segmentation and the `TuningListener` |
| `AudioInputs.swift`, `ListenerMeter.swift` | Which microphone to use; the listener's CPU and memory readout |
| `EngineCheck/` | `heydot-engine-check`, a command line that runs the engine on a WAV file |

Tests: `Tests/HeyDotTests` has one file per behavior (`OnboardingTests`, `CallTests`, `ThemeTests` and so on) plus
`TestSupport.swift` for shared fakes; `Tests/WakeEngineTests` covers the engine with WAV fixtures.

## How it works

- **Listening:** the `WakeEngine` target spots the wake phrase on device (sherpa-onnx keyword model): `hey <name>`
  by default, or the user's own phrase (`AppSettings.wakePhrase`, 2 to 6 words of a to z that the model's
  tokenizer encodes; words or phrases of other assistants such as "jarvis", "siri", "alexa" or "ok google" are
  refused). Changing it resets tuning and re-runs voice tuning.
- **Which microphone:** the built-in microphone, unless the user picks another in Settings > Microphone (or on
  the tuning screen), remembered by its Core Audio UID. HeyDot never follows the macOS default input and never
  changes it, so Bluetooth headphones or an iPhone's Continuity microphone are used only when deliberately
  chosen. While a chosen device is disconnected HeyDot records from the built-in microphone, never from whatever
  the default became (`AudioInputs.choose`). A Mac with no built-in microphone and no choice reports an error.
  This keeps HeyDot off headphones shared with a phone: holding their microphone, and re-taking it on every
  default-input change, dropped the example FaceTime calls.
- **Capture:** an `AVCaptureSession` on exactly the chosen device (`AVCaptureDevice(uniqueID:)`, which is the Core
  Audio UID), delivering 16 kHz mono Float32. Not AVAudioEngine: on macOS its input and output nodes share one I/O
  unit bound to an aggregate of the default devices, and pointing it at another microphone fails (-10851) or
  leaves it with no input channels, so no audio arrives.
- **Display off or locked:** the microphone is released, not muted, while the displays sleep, the Mac sleeps,
  the screen is locked or the session is switched away, and opened again when all of those have ended.
- **Listener restarts:** a capture dies quietly when the Mac sleeps or the audio hardware is reconfigured.
  `ListenerSupervisor` tears down the tap and engine and starts a fresh one, on the same chosen or built-in
  device, on a capture session runtime error or interruption (for its own session), `NSWorkspace.didWakeNotification`,
  `screensDidWakeNotification`, a device connecting or disconnecting that changes which device should be used
  (a new default input alone changes nothing), or no audio buffer for 6 s while listening. Restarts coalesce
  (0.5 s), back off to 30 s while they repeat, reset after 10 s of audio, and each one logs
  `listener: restart N (reasons) ok|failed` to the log.
- **Listener readout** ("Listener: 0.4% CPU · ~39 MB", Settings > Privacy): only the listener.
  CPU is the thread CPU time (`CLOCK_THREAD_CPUTIME_ID`) spent in the input tap and in the processing
  block (keyword decode, metering), per wall-second, as percent of one core (`ListenerMeter`). Memory is an
  estimate (hence `~`): the footprint growth measured while the first keyword model loaded (never less
  than the model files), per loaded model, plus the bounded audio queue. The built-in browser's WebKit
  processes are not included.
- **Built-in browser:** `Web/WebCallBackend.swift`. Sign-in happens once in a visible "Sign in to ChatGPT" window (Return goes to the page's form; Done is
  not a default button). The page offers its available sign-in methods; providers can reject embedded
  WebKit, notably Google. If that happens, try another sign-in method offered for your account. An external
  browser session is not imported into HeyDot. Provider sign-in paths have not been verified for this snapshot.
  HeyDot uses WebKit's own user agent, with no bot-check evasion. The session lives in a
  persistent `WKWebsiteDataStore(forIdentifier:)`, pruned to chatgpt.com and openai.com records when the
  sign-in window closes; WebKit's public API places it under
  `~/Library/WebKit/app.heydot.HeyDot/WebsiteDataStore/<id>` (Application Support is only reachable through
  private API, which HeyDot does not use). The dot is picked from the dots the signed-in page links to, or
  pasted. The hidden call view may navigate its main frame only to https://chatgpt.com. A borderless,
  ordered-out panel keeps the dot page warm for at most 30 idle seconds, then releases the page and panel.
  The next wake loads it again. On a wake
  the panel goes on screen fully transparent, click-through and non-activating (WebKit holds a hidden
  page's microphone request forever), then `PageScripts.press` runs in WebKit's isolated world: exact chatgpt.com host and dot path, exactly one enabled
  "Start call", Cloudflare challenge detection, plus `signed-out` and `not-visible`. The microphone is
  granted only to https://chatgpt.com's top frame in the call panel while a call is being placed or runs.
  The panel leaves the screen when the page's microphone capture ends (or after 20 s if it never opened);
  the popover's **Hang up** ends the call by releasing the page and panel. **Mute** sets WebKit's own capture state for
  the page (`setMicrophoneCaptureState(.muted)`): the page's getUserMedia track goes silent without ending
  the call, and the button shows the state WebKit reports back (a failed toggle says so and keeps the real
  state). The log is bounded to 1 MiB plus one 1 MiB `.1` archive. Each wake logs `wake_to_press_ms` with
  `"backend":"built-in"`.
Settings live in `~/Library/Application Support/HeyDot/settings.json` (0600).

## Dot maker

"Design your dot" offers avatar controls (Shape, Color, Eyes, Glasses,
Accessories, Accessory color and Nickname). All artwork is ours, in the flat vector
style: bold flat bodies on a 96-unit grid, pill eyes, add-ons separated by a cut gutter instead of an
outline. Every part is a vector path (`Sources/HeyDot/Kit/Dot/DotGeometry.swift`), so one model draws
the menu bar template glyph, the popover avatar, the maker and the app icon.

**Color** goes in the eyes on an ink body by default (the flat vector identity: one-colour body, accent
eyes). It keeps every dot recognisably ours, keeps the menu bar silhouette independent of colour, and
keeps contrast high. "Color goes on: Body" colours the whole dot with ink eyes. Charcoal accessories
are for the generic shapes, including the plain Rounded triangle.

**Fit:** each shape declares what its parts mean (eye line, hat opening width, ear line, its ears on top,
how far headphone cups lean); everything else is measured from the body path (`Face.anchors`: crown, the
seat where a hat's opening meets the outline, ear edges, band clearance, neck, eye-line edges). Hats,
beanies, berets and crowns slide down until their opening meets the head, and a dip under the opening
(between a butterfly's wings or a cat's ears) is filled so no sliver shows. Headphone bands are searched
to clear the head by a gutter. On shapes with ears on top (cat and bear) the cups sit on the head
below the ears and the band passes behind them: it is cut away around each ear, so ears are never covered
or cut. The triangle's cups lean with its sides; the butterfly's sit on its upper wings, its widest line.
Glasses shrink only when wider than the face at the eye line; the monocle slides in and shrinks until its
ring keeps a band of face outside it. `--qa-boards DIR` renders every shape against every accessory and
glasses style (`DIR/fit`, with one large sheet per option in `DIR/fit/rows`) plus the anchor overlay.

**Menu bar icon:** in the dot maker (under the preview) and in Settings > Your dot, each with the real
18 pt glyph on a light and a dark bar. Monochrome (default) is a template image macOS tints; Color draws
the dot's own colours for the bar's light or dark appearance, with an orange attention badge.

**Custom avatar:** the dot maker's last section, below Accessory color (Nickname is the first). It offers:

- **Import SVG or PNG.** SVGs must be self-contained shapes (`svg`, `g`, `path`, `circle`, `ellipse`,
  `rect`, `polygon`, `polyline`, `line`, `title`, `desc`; no scripts, styles, images, links, `url()`,
  `data:`, event attributes, DOCTYPE or entities; at most 200 KB); PNGs 64 to 4096 px, at most 2 MB; both
  roughly square. Import trims the transparent margin, fits the 3-unit dot margin and stores three 512 px
  PNGs under `Application Support/HeyDot/avatars`: as drawn, a dark-tile variant (ink turned white) and the
  monochrome mask (an SVG's `<g id="eyes">` is left out, so eyes read as holes). An image without a
  transparent background has no silhouette: the monochrome menu bar shows the HeyDot logo and Color shows
  the image.
- **Design with your agent:** a copy-ready prompt (`Kit/Resources/AvatarAgentPrompt.md`) with the flat vector
  rules (bold flat silhouette on the 96-unit grid, pill eyes, one accent, cut gutters around add-ons,
  16 to 18 px legibility) and the exact SVG contract the importer checks.

## Look: Frost

The design language (glass, pills, radii, spacing, type, accent, motion, icons, native exceptions) is written down
in [DESIGN.md](../DESIGN.md); `Kit/Frost/` implements it. HeyDot's hidden main menu gives every HeyDot window
Command-Q (quit; mid-setup it stops tuning first and setup reopens next launch), Command-W and the Edit shortcuts.

Setup is a see-through window the wallpaper tints (`NSVisualEffectView`, behind-window) with two soft tint blobs
drifting behind it, the app tile floating at the centre, minimal text, and centred Liquid Glass buttons: one
capsule size for every button, filled with `glassEffect` (tinted for the primary) on macOS 26 and a drawn gradient
capsule on 14 and 15. Every step that can wait has **Later** plus where to find it again; the microphone and the
call route can't wait. Each button row is back, Later where it applies, and the primary; the tinted primary is the
recommended way, with no badge.

The default logo uses coral. Redesigning a dot updates the buttons, focus rings, progress indicators
and popover meter to follow its colours. Imported avatars use the Frost theme.
Motion is Core Animation on plain layers (the tile is rendered once into a layer), so it costs the app no
CPU, stops when the window closes, and is off with Reduce Motion. Closing a window releases its content. The
popover draws the same tint statically.

## Popover

Status, one **Call** button, pause, and small Design, Settings and Quit icons. **Call** presses the call the
same fail-closed way a wake does, and works while listening is paused. During a call it becomes round
**Mute / Unmute** and **Hang up**. **Pause** is
one tap: 15 min, 1 hour or Tomorrow (the morning time set in Settings > General, default 8:00 AM; later today
when that time is still ahead). The timer button holds every option: 15 or 30 minutes, 1, 2 or 4 hours, until
tomorrow morning, until I turn it back on, and a custom duration (hours and minutes, up to 24 hours). While a
timed pause runs, the popover shows the time left and the status line and Settings say when listening resumes
(the same timed pause as `--control pause --until`). **Check** (find the call button without pressing it), the
privacy note and the listener readout are in Settings.

Feedback never piles up: there is one result at a time. "Call started" and "Ready" show for four seconds,
with a check badge on the menu bar icon, then clear themselves. Problems stay, with a dismiss button, until
a later result replaces them. HeyDot posts no system notifications.

**HeyDot** is the coral open-cradle microphone. It is the first choice under Shape and the design
restored by **Reset to HeyDot**. Both keep the nickname. The welcome graphic and stock avatar tiles
use the bundled designer artwork.

## Build and test

```sh
Scripts/fetch-vendor.sh          # engine vendor files (sherpa-onnx static libs, model), SHA-256 checked
swift build
swift test --no-parallel
./build-app.sh debug --preview   # HeyDotPreview.app: unsigned, fixtures and screenshots only
HEYDOT_APPROVED_CERT_SHA1=<40 hex> ./build-app.sh release   # signed, hardened runtime, audio-input entitlement
HEYDOT_VERSION=<version> HEYDOT_BUILD=<build> HEYDOT_APPROVED_CERT_SHA1=<40 hex> HEYDOT_NOTARY_PROFILE=<profile> ./build-app.sh release   # also notarized and stapled
```

`HEYDOT_VERSION` and `HEYDOT_BUILD` set `CFBundleShortVersionString` and `CFBundleVersion` (default 0.1.0 and 1 for local development). Set both explicitly for a notarized build.
The bundle embeds Sparkle.framework without its XPC services and re-signs Sparkle's Autoupdate, Updater.app and the
framework with the same certificate as the app.

`release` refuses to run without `HEYDOT_APPROVED_CERT_SHA1`, refuses a certificate that is not a valid
code signing identity on this Mac, and never falls back to ad-hoc
signing. With `HEYDOT_NOTARY_PROFILE` it signs with a secure timestamp, submits the app to Apple's notary service,
staples the ticket and checks it with `spctl`. The profile comes from
`xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>`, which keeps an app-specific
password in the login keychain. Neither mode installs the app or registers a login item. Assembly runs only the icon renderer; it does not start listening or place calls.

## Releasing an update

HeyDot updates itself through [Sparkle](https://sparkle-project.org) from `appcast.xml` on `main`
(`SUFeedURL`). Sparkle installs an update only when its EdDSA signature matches `SUPublicEDKey` in build-app.sh
and its code signature matches the running app's.

1. Raise `HEYDOT_BUILD` (Sparkle compares it) and `HEYDOT_VERSION`, then build the release with the Developer ID
   certificate and `HEYDOT_NOTARY_PROFILE`.
2. `ditto -c -k --sequesterRsrc --keepParent HeyDot.app HeyDot-<version>.zip`
3. `.build/artifacts/sparkle/Sparkle/bin/sign_update HeyDot-<version>.zip` prints the `sparkle:edSignature` and
   `length` attributes. It reads the private key from the maintainer's login keychain; the first run asks for the
   keychain password, so click Always Allow.
4. Attach the zip to the GitHub release, then add an `<item>` to `appcast.xml` whose enclosure points at that asset,
   with `sparkle:version` set to the build, `sparkle:shortVersionString` to the version and
   `sparkle:minimumSystemVersion` 14.0. Merging it to `main` offers the update to everyone.

The private key was made once with Sparkle's `generate_keys` and lives only in the maintainer's keychain; back it
up with `generate_keys -x <file>` to somewhere safe. Sparkle accepts a new EdDSA key only in an update signed with
the same Developer ID as the installed app, and never both changed at once, so keep both.

## Erase local data

**Settings → Privacy → Erase and Start Over** clears the local profile and reopens HeyDot at Welcome.
It uses the same cleanup as `--uninstall-data`.

### Clean uninstall

Quit HeyDot, then:

```sh
/Applications/HeyDot.app/Contents/MacOS/HeyDot --uninstall-data --dry-run   # lists what it would remove
/Applications/HeyDot.app/Contents/MacOS/HeyDot --uninstall-data             # removes it and prints each path
tccutil reset Microphone app.heydot.HeyDot                                  # optional: forget the microphone permission
rm -rf /Applications/HeyDot.app
```

`--uninstall-data` removes the login item, `~/Library/Application Support/HeyDot` (settings, reset backups,
avatars, sockets), the built-in browser's sign-in store `~/Library/WebKit/app.heydot.HeyDot` plus HeyDot's
caches, HTTP storage, saved state and preferences when present, and `~/Library/Logs/HeyDot.log`
(`--keep-logs` keeps it). It refuses while HeyDot runs. The next install starts at the
welcome screen, signed out, with Open at login off.

Start setup over: quit HeyDot, then `HeyDot.app/Contents/MacOS/HeyDot --reset-onboarding` moves
`settings.json` to `settings.json.reset-<timestamp>` next to it (kept) and the next launch starts at the
welcome screen. It refuses while the app runs, and leaves the login item, microphone
permission and the built-in browser's sign-in alone.

Developer flags: `HeyDot --qa-signin DIR` renders the sign-in window over the live, logged-out chatgpt.com
in a throwaway store; `HeyDot --qa-render DIR` renders every screen (light and dark) with fake engine and system hooks; `HeyDot --qa-boards DIR` renders the fit grids and logo board; `HeyDot --render-icon DIR`
writes the 1024 px icon and iconset. Only the installed `app.heydot.HeyDot` bundle can open the real profile.
Set `HEYDOT_HOME` to an absolute disposable path before launching other builds or running commands that change profile data.
An isolated build uses transient WebKit and skips native login-item, preference, keychain and updater actions.
To test persistent WebKit, use a separate bundle ID and a fresh `HEYDOT_WEBKIT_STORE_ID` UUID, with `HOME`,
`CFFIXED_USER_HOME` and `HEYDOT_HOME` all pointing to the same disposable directory.

## First run

Guided: welcome, name your dot (default "Dot"; 1 to 3 words; "jarvis" is reserved; **Design your dot** and **Later**
chips sit under the tile; Name and Wake word are separate fields, the wake word on **Auto** ("Hey <Name>") until
typed in; both changeable in Settings), voice tuning, connect ChatGPT, done. **Later** leaves the Design your dot
chip there and adds one on the last step (and the popover's palette icon). Tuning has **Later**
(standard settings, re-run from Settings > Voice tuning). Settings > Your dot has the same Wake phrase field; a change there re-runs voice tuning.

**Voice tuning is one screen.** It first shows the microphone permission as macOS reports it
(`AVCaptureDevice.authorizationStatus`): "Microphone: allowed", an **Enable microphone** button that asks, or
**Open Privacy Settings** (the Microphone pane) when it is off; it is re-read whenever HeyDot becomes active.
Nothing listens until **Start**. Then "Say 'Hey <Name>' four times" with rings around the tile that follow the
microphone level, a Listening label and four slots. `UtteranceSegmenter` (energy VAD: 60 ms to open, 500 ms of
quiet to close, 300 ms pre-roll) cuts each utterance, and the keyword model, run as a plain recognizer only while
tuning (`PhraseDecoder`), says what it heard. Tuning learns the user's own way of saying the phrase and never
compares a take with the spelling: a plausible recording (heard words, at most a few more words than the phrase,
under 4 s) is a take, and a slot ticks for each take that sounds like the others (`Takes.agreeing`, a sound-alike
edit distance between takes with word breaks removed). Hints describe the recording: "too quiet", "Didn't catch
anything", "longer than a wake phrase", or "sounded different from your others". Tapping a ticked slot retries that take,
and the **Start over** pill clears every sample and listens again. No audio buffer for 3 s, or only digital silence (below -100 dBFS), stops with "No sound is coming
from <mic>", **Try again** and the microphone menu, and logs `tuning: no audio from the built-in microphone (...)`.
Real audio with no speech for 10 s is only a hint. The microphone menu sets HeyDot's own microphone (the macOS
default input is left alone). There is no "say something else" step: recorded confusables never changed a tuned
setting in the accuracy eval. **Continue** runs `Enroller.calibrate` once three takes agree: it stores, as
`WakeSettings.learned`, the token sequences the model heard in those takes that are long enough to be specific, or
that the user repeats and the listener would otherwise miss, and leans the threshold below the weakest take. Every
keyword set, standard or tuned, spots the typed phrase and the phrase as the model writes it (`Spotter.written`:
"Trey" as `▁TRA Y`). See
[tuning accuracy](tuning-accuracy.md).
The listener spots the learned sequences beside the spelled phrase at no extra idle cost. The live listener is paused
while tuning so a "Hey <Name>" can't start a real call. The privacy note and the listener readout are in
Settings > Privacy.

**Connect ChatGPT** (required, no Later) signs in to the built-in browser only: a hidden browser inside HeyDot,
signed in once, with nothing going through HeyDot servers. **Sign in…** opens the sign-in window,
then the dots the signed-in page links to are listed (or paste a link) and the call button is checked
in the hidden page without pressing it. Settings > ChatGPT can open the sign-in window or sign out
(clears HeyDot's web data).
Settings is a resizable window whose form scrolls, down to a 360 pt height.
**Done** offers Open at login, a passive "say it to try it" check and an explicit real test call (**Try a call**).

## Control from the command line

The same executable controls the running app over a private socket
(`~/Library/Application Support/HeyDot/run/control.sock`, 0600 in a 0700 directory):

    HeyDot.app/Contents/MacOS/HeyDot --control status|pause [--until ISO8601]|resume [--json]

`status` reports `wake`: `"on"` while listening for the phrase, `"off"` while paused, `null` otherwise
(setup needed, microphone off, engine failed, or the app not running, which is `state: "not_running"`).
`pause` stays off, across app restarts, until `resume` or the menu's Resume. `pause --until` (local time
when it has no offset) resumes inside the app at that time, or at the next launch if it was closed then.
Exit 0 ok, 1 not running or failed, 2 usage or refused.

For another machine, give its key a forced command in `~/.ssh/authorized_keys`:
`command="<path>/HeyDot.app/Contents/MacOS/HeyDot --control-ssh",no-pty,no-port-forwarding,...`.
`--control-ssh` runs only `status`, `pause [--until ISO8601]` or `resume` (each optionally `--json`, after an
ignored `<path>/HeyDot --control` prefix) from `$SSH_ORIGINAL_COMMAND`, and refuses anything else,
including an interactive login.
