/// JavaScript run in the chatgpt.com page, in WebKit's isolated `.defaultClient` world (page scripts can't
/// see or replace these functions; the DOM is shared). Bodies for `callAsyncJavaScript`, which passes the
/// arguments as real values instead of splicing strings.
enum PageScripts {
    /// The call-button script uses fail-closed rules: Cloudflare challenge, exact
    /// chatgpt.com host, exact dot path (trailing slashes ignored), exactly one enabled button whose
    /// aria-label or text is exactly `label`. Additions for a page HeyDot owns: `signed-out` (login page or
    /// login buttons) and, when clicking, `not-visible` while WebKit still treats the page as hidden (a
    /// microphone request from a hidden page waits forever). Arguments: dotPath, label, click.
    static let press = """
    const trim = (p) => p.replace(/\\/+$/, "");
    const text = (document.body && document.body.innerText) || "";
    const buttons = [...document.querySelectorAll("button")];
    const labelOf = (b) => (b.getAttribute("aria-label") || b.textContent || "").trim();
    if (document.title.trim().toLowerCase().startsWith("just a moment")
        || document.querySelector("iframe[src*='challenges.cloudflare.com'], .cf-turnstile, #challenge-form, #cf-chl-widget")
        || /verify you are human|checking your browser/i.test(text)) return { outcome: "challenge" };
    if (location.host !== "chatgpt.com") return { outcome: /(^|\\.)openai\\.com$/.test(location.host) ? "signed-out" : "wrong-dot", host: location.host };
    if (location.pathname.startsWith("/auth") || buttons.some((b) => /^(log in|sign up|sign up for free)$/i.test(labelOf(b)))) return { outcome: "signed-out" };
    if (trim(location.pathname) !== trim(dotPath)) return { outcome: "wrong-dot", path: location.pathname };
    const calls = buttons.filter((b) => (b.getAttribute("aria-label") || "").trim() === label || (b.textContent || "").trim() === label);
    if (calls.length === 0) return { outcome: "not-found" };
    if (calls.length > 1) return { outcome: "ambiguous" };
    const button = calls[0];
    if (button.disabled || button.getAttribute("aria-disabled") === "true") return { outcome: "disabled" };
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
