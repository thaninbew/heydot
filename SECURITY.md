# HeyDot: what it stores and what leaves your Mac

**Short version:** Wake-word listening runs on device and its audio is never uploaded. Call audio goes to ChatGPT like any ChatGPT voice call. The built-in web view contacts ChatGPT and its sign-in providers, including their normal page resources. HeyDot checks this project's GitHub repo for updates. HeyDot has no servers, accounts of its own, telemetry or analytics.

## What leaves your Mac

| What | Where it goes | When |
| --- | --- | --- |
| Your ChatGPT session (the chatgpt.com page, your sign-in, the voice call) | chatgpt.com, and the sign-in page you choose (OpenAI, Google, Apple or Microsoft) | When you sign in, when HeyDot keeps your dot's page ready, and during a call |
| An update check (Sparkle): a request for `appcast.xml` that carries HeyDot's and Sparkle's versions in its User-Agent, no system profile | raw.githubusercontent.com | Once a day if you allow automatic checks (Sparkle asks on the second launch), or when you click **Check for Updates…** in Settings |
| An update download | github.com release assets | When you choose to install an update |

Apart from Sparkle's update checks, HeyDot's own code makes no network requests. Searching the source finds no `URLSession`, `Network`
framework, sockets to remote hosts, crash reporters or analytics. Sparkle installs an update only when its EdDSA signature matches the public key built into HeyDot and it is signed with the same certificate as the running app. Its call view restricts top-level navigation to `https://chatgpt.com/...`; this is not a firewall for page resources or sign-in providers.

## What HeyDot stores, and where

| What | Where | Protection |
| --- | --- | --- |
| Settings (dot name, wake phrase, tuning numbers, dot link, pause state) | `~/Library/Application Support/HeyDot/settings.json` | file 0600, folder 0700 |
| Settings backups from `--reset-onboarding` | next to `settings.json` | same |
| Imported avatars | `~/Library/Application Support/HeyDot/avatars/` | files 0600, folder 0700 |
| Control socket | `~/Library/Application Support/HeyDot/run/` | sockets 0600, folder 0700; only your user can connect |
| Log | `~/Library/Logs/HeyDot.log` (and one rotated `HeyDot.log.1`) | files 0600 (set by the log-rotation change) in your 0700 `~/Library/Logs` |
| ChatGPT sign-in (cookies and site data) | `~/Library/WebKit/app.heydot.HeyDot/WebsiteDataStore/` | managed by macOS WebKit; HeyDot never reads it |
| WebCrypto key (16 random bytes WebKit uses to protect keys the ChatGPT page stores) | `~/Library/Application Support/HeyDot/webcrypto.key` | file 0600, folder 0700. HeyDot hands it to WebKit through a private WebKit hook, so WebKit never makes a keychain item or asks for your password. A WebKit without the hook falls back to its own "HeyDot WebCrypto Master Key" keychain item |

**Not persisted by HeyDot:** wake-word or tuning audio. ChatGPT call audio is handled by ChatGPT under its own policies. Voice tuning keeps your sample clips in memory only while you tune. The
listener reads the microphone continuously but keeps only a short rolling buffer in memory. It records from the
built-in microphone unless you choose another in Settings, never switches to headphones on its own, and lets go
of the microphone while the display is off, the Mac sleeps or the screen is locked.

`HeyDot --uninstall-data` removes all of the above (see [Development](docs/DEVELOPMENT.md)).

## The rules HeyDot follows

- **Sign-in stays in HeyDot's browser.** Its WebKit store is persistent, so you sign in once, and it holds
  only ChatGPT's data. When the sign-in window closes, HeyDot removes website data for every site except
  chatgpt.com and openai.com (ChatGPT's own sign-in), such as the Google or Apple sign-in page you used.
  HeyDot never reads cookies or tokens. "Sign out" in Settings clears the whole store.
- **The hidden call page stays on chatgpt.com.** The window that places calls may only load
  `https://chatgpt.com` pages. A redirect anywhere else is blocked and the call fails without pressing
  anything. The sign-in window may visit the sign-in providers ChatGPT sends you to, over HTTPS only.
- **The microphone goes only to chatgpt.com, only during a call.** WebKit asks HeyDot before a page can use
  the microphone. HeyDot says yes only when all of these hold: the request comes from `https://chatgpt.com`
  in the call window, a call is being placed or is running, and it is a microphone request (never camera or
  screen). Everything else is denied, including the sign-in window.
- **The log holds operational details, including the wake phrase and dot path.** For example: "listening for 'hey tray'", a dot page's
  path, `wake_to_press_ms`, "pressed", microphone granted or denied. It never holds audio, transcripts,
  cookies, tokens, page text, tab titles or anything you or your dot say.

## Audit (November 2026)

| Check | Finding | Fix |
| --- | --- | --- |
| Network requests | ChatGPT and sign-in providers in WebKit | None needed |
| Folder modes | A first `run/` or `avatars/` folder could create `Application Support/HeyDot` with default 0755 | New parent folders are created 0700 |
| Log mode | `HeyDot.log` was created with the default 0644 | 0600 for the log and its rotated copy (in the log-rotation change) |
| Web data | Identity providers' cookies from sign-in stayed in the store | Removed when the sign-in window closes; only chatgpt.com and openai.com are kept |
| Call page | The hidden call page could follow a redirect to any site | Limited to https://chatgpt.com |
| Microphone | Already limited to chatgpt.com in the call window during a call | None needed |

## Reporting vulnerabilities

Use GitHub private vulnerability reporting in this repository’s Security tab. Do not post sensitive details in public issues.
