/// JavaScript run in the chatgpt.com page, in WebKit's isolated `.defaultClient` world (page scripts can't
/// see or replace these functions; the DOM is shared). Bodies for `callAsyncJavaScript`, which passes the
/// arguments as real values instead of splicing strings.
enum PageScripts {
    /// The call-button script uses fail-closed rules: Cloudflare challenge, exact
    /// chatgpt.com host, exact dot path (trailing slashes ignored), exactly one enabled button whose
    /// aria-label or text is exactly `label`. Additions for a page HeyDot owns: `signed-out` (login page or
    /// login buttons) and, when clicking, `not-visible` while WebKit still treats the page as hidden (a
    /// microphone request from a hidden page waits forever). When the button isn't on the page, it opens the
    /// dot's profile popover, where ChatGPT now keeps it, and the next poll finds it. Arguments: dotPath, label, click.
    static let press = """
    const trim = (p) => p.replace(/\\/+$/, "");
    const text = (document.body && document.body.innerText) || "";
    const buttons = [...document.querySelectorAll("button")];
    const labelOf = (b) => (b.getAttribute("aria-label") || b.textContent || "").trim();
    if (document.title.trim().toLowerCase().startsWith("just a moment")
        || document.querySelector("iframe[src*='challenges.cloudflare.com'], .cf-turnstile, #challenge-form, #cf-chl-widget")
        || /verify you are human|checking your browser/i.test(text)) return { outcome: "challenge" };
    if (location.host !== "chatgpt.com") return { outcome: /(^|\\.)openai\\.com$/.test(location.host) ? "signed-out" : "wrong-dot", host: location.host };
    // A signed-out dot page shows "Log in" as a link, not only as a button.
    if (location.pathname.startsWith("/auth")
        || [...document.querySelectorAll("button, a")].some((b) => /^(log in|sign up|sign up for free)$/i.test(labelOf(b)))) return { outcome: "signed-out" };
    if (trim(location.pathname) !== trim(dotPath)) return { outcome: "wrong-dot", path: location.pathname };
    const calls = buttons.filter((b) => (b.getAttribute("aria-label") || "").trim() === label || (b.textContent || "").trim() === label);
    if (calls.length === 0) {
      // Since Nov 2026 the dot's call button lives in its profile popover ("Open <name>’s profile" in the
      // header). Opening that popover only shows the profile; the call itself still needs the exact button.
      // Exactly one opener, never while it reports itself open, and at most once every 2 s so polling can't
      // toggle it shut again.
      const openers = buttons.filter((b) => /^open .+[’']s profile$/i.test((b.getAttribute("aria-label") || "").trim()));
      const now = Date.now();
      if (openers.length === 1 && openers[0].getAttribute("aria-expanded") !== "true"
          && now - (globalThis.__heyDotProfileOpenedAt || 0) > 2000) {
        globalThis.__heyDotProfileOpenedAt = now;
        openers[0].click();
        return { outcome: "not-found", opened: true };
      }
      // For the log only: what call-like controls the page does show, so a renamed button is diagnosable.
      return { outcome: "not-found", near: [...document.querySelectorAll("button, [role=button]")]
        .map(labelOf).filter((l) => /call|voice|talk|speak/i.test(l)).slice(0, 8).map((l) => l.slice(0, 40)) };
    }
    if (calls.length > 1) return { outcome: "ambiguous" };
    const button = calls[0];
    // It is a toggle now: pressed means a call is already running.
    if (button.disabled || button.getAttribute("aria-disabled") === "true" || button.getAttribute("aria-pressed") === "true")
      return { outcome: "disabled" };
    if (!click) return { outcome: "would-press" };
    if (document.visibilityState !== "visible") return { outcome: "not-visible" };
    button.click();
    return { outcome: "pressed" };
    """

    /// Whether the page is signed in, plus the dots it links to (the sidebar, or the open dot itself).
    /// Reads only link targets and their visible names. No arguments.
    static let state = """
    const labelOf = (b) => (b.getAttribute("aria-label") || b.textContent || "").trim();
    const text = (document.body && document.body.innerText) || "";
    const challenge = document.title.trim().toLowerCase().startsWith("just a moment")
        || !!document.querySelector("iframe[src*='challenges.cloudflare.com'], .cf-turnstile, #challenge-form, #cf-chl-widget")
        || /verify you are human|checking your browser/i.test(text);
    const onChatGPT = location.host === "chatgpt.com";
    const loggedOut = !onChatGPT || location.pathname.startsWith("/auth")
        || [...document.querySelectorAll("button, a")].some((b) => /^(log in|sign up|sign up for free)$/i.test(labelOf(b)));
    const dots = new Map();
    const add = (u, title) => {
      if (u.host !== "chatgpt.com" || !/^\\/dots\\/[^/]+/.test(u.pathname)) return;
      const key = "https://chatgpt.com" + u.pathname.replace(/\\/+$/, "");
      const name = (title || "").trim().split("\\n")[0].slice(0, 60);
      if (!dots.has(key) || (!dots.get(key) && name)) dots.set(key, name);
    };
    for (const a of document.querySelectorAll("a[href]")) {
      try { add(new URL(a.getAttribute("href"), location.href), a.innerText || a.getAttribute("aria-label")); } catch (e) {}
    }
    add(new URL(location.href), document.title);
    return { ready: document.readyState === "complete" && text.length > 0, signedIn: onChatGPT && !loggedOut && !challenge,
             challenge, host: location.host, path: location.pathname,
             dots: [...dots].map(([url, title]) => ({ url, title: title || url.split("/").pop() })) };
    """
}
