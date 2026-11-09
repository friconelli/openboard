/// The iPhone page. Chat text is untrusted (it can contain anything a tool printed), so the
/// script builds the page with DOM calls and textContent only, never innerHTML.
enum RemoteAssets {
    static let manifest = #"""
    {"name":"OpenBoard","short_name":"OpenBoard","start_url":"/","display":"standalone","background_color":"#121413","theme_color":"#121413","icons":[{"src":"/icon.png","sizes":"1024x1024","type":"image/png"}]}
    """#

    static let html = #"""
    <!doctype html>
    <html lang="it">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="OpenBoard">
    <meta name="theme-color" content="#121413">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/icon.png">
    <link rel="stylesheet" href="/app.css">
    <title>OpenBoard</title>
    </head>
    <body>
    <main id="app"></main>
    <script src="/app.js"></script>
    </body>
    </html>
    """#

    static let style = #"""
    :root { color-scheme: light dark; --bg:#fbfcfa; --card:#fff; --text:#1d211e; --muted:#6b736d; --line:#e1e5e0; --accent:#4e7d5d; --on:#fff; --bubble:#e5eee7; --ok:#6b8a2e; --warn:#a86a0e; --bad:#b8483a; }
    @media (prefers-color-scheme: dark) { :root { --bg:#121413; --card:#1a1d1b; --text:#e6e9e6; --muted:#8e968f; --line:#2a2e2b; --accent:#7fa88b; --on:#121413; --bubble:#1d2a22; --ok:#9db45a; --warn:#c67f13; --bad:#da5b4a; } }
    * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
    html,body { margin:0; height:100%; background:var(--bg); color:var(--text); font:16px/1.4 -apple-system,system-ui,sans-serif; }
    #app { height:100dvh; display:flex; flex-direction:column; padding-top:env(safe-area-inset-top); }
    header { display:flex; align-items:center; gap:10px; padding:10px 16px; border-bottom:1px solid var(--line); flex:none; }
    header h1 { font-size:17px; margin:0; flex:1; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    button { font:inherit; color:inherit; background:var(--card); border:1px solid var(--line); border-radius:10px; padding:9px 14px; min-height:44px; }
    button.primary { background:var(--accent); color:var(--on); border-color:var(--accent); font-weight:600; }
    button.back { border:0; background:none; color:var(--accent); padding:0 8px 0 0; font-size:17px; }
    input,textarea { font:inherit; font-size:16px; color:inherit; background:var(--card); border:1px solid var(--line); border-radius:12px; padding:10px 12px; width:100%; }
    .scroll { flex:1; overflow-y:auto; -webkit-overflow-scrolling:touch; padding:12px 16px calc(12px + env(safe-area-inset-bottom)); }
    .usage { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:10px 12px; margin-bottom:12px; font-size:13px; }
    .usage b { display:block; margin-top:6px; font-size:13px; } .usage b:first-child { margin-top:0; }
    .bar { display:grid; grid-template-columns:38px 1fr 40px 76px; gap:6px; align-items:center; color:var(--muted); }
    .track { height:5px; border-radius:3px; background:var(--line); overflow:hidden; } .fill { height:100%; border-radius:3px; }
    .pct { text-align:right; font-weight:600; font-variant-numeric:tabular-nums; } .left { text-align:right; font-variant-numeric:tabular-nums; }
    .row { display:block; width:100%; text-align:left; background:none; border:0; border-bottom:1px solid var(--line); border-radius:0; padding:11px 0; }
    .row .top { display:flex; align-items:center; gap:7px; } .row .name { font-weight:600; flex:1; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .row .when,.row .sub { color:var(--muted); font-size:13px; } .row .sub { display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; margin-top:2px; }
    .dot { width:9px; height:9px; border-radius:50%; flex:none; } .running { background:var(--warn); } .waiting { background:var(--ok); } .permission { background:var(--bad); }
    .tag { font-size:11px; color:var(--accent); border:1px solid var(--line); border-radius:6px; padding:0 5px; }
    .msg { margin:10px 0; overflow-wrap:anywhere; } .user { background:var(--bubble); border-radius:16px; padding:9px 13px; margin-left:12%; white-space:pre-wrap; }
    .assistant p { margin:0 0 8px; } .assistant h3 { font-size:16px; margin:10px 0 6px; } .assistant ul { margin:0 0 8px; padding-left:20px; }
    code { font:13px ui-monospace,Menlo,monospace; background:var(--line); border-radius:4px; padding:0 3px; }
    pre { font:12.5px/1.4 ui-monospace,Menlo,monospace; background:var(--card); border:1px solid var(--line); border-radius:8px; padding:10px; overflow-x:auto; margin:0 0 8px; }
    .tool,.notice,.command { color:var(--muted); font-size:13px; white-space:pre-wrap; } .tool.err { color:var(--bad); }
    .queued { opacity:.55; } .perm { background:var(--card); border:1px solid var(--warn); border-radius:12px; padding:12px; margin:10px 0; }
    .perm h2 { font-size:15px; margin:0 0 6px; } .perm .cmd { font:12.5px ui-monospace,Menlo,monospace; white-space:pre-wrap; overflow-wrap:anywhere; margin-bottom:10px; color:var(--muted); }
    .perm .actions { display:flex; gap:8px; } .perm .actions button { flex:1; }
    .composer { flex:none; display:flex; gap:8px; align-items:flex-end; padding:8px 12px calc(8px + env(safe-area-inset-bottom)); border-top:1px solid var(--line); }
    .composer textarea { resize:none; max-height:130px; }
    .center { margin:auto; padding:24px; max-width:360px; display:flex; flex-direction:column; gap:12px; } .center p { color:var(--muted); margin:0; }
    .hint { color:var(--muted); font-size:13px; text-align:center; padding:6px 0; }
    """#

    static let script = #"""
    "use strict";
    const app = document.getElementById("app");
    let timer = null, current = null, wasRunning = false, sending = false, shownLive = "";

    function el(tag, cls, text) {
      const node = document.createElement(tag);
      if (cls) node.className = cls;
      if (text !== undefined) node.textContent = text;
      return node;
    }
    function clear() { app.replaceChildren(); if (timer) { clearTimeout(timer); timer = null; } }

    async function api(path, body) {
      const options = body ? { method: "POST", headers: { "Content-Type": "application/json", "X-OpenBoard": "1" }, body: JSON.stringify(body) } : {};
      const response = await fetch(path, options);
      if (response.status === 401) { login(); throw new Error("login"); }
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || "Errore");
      return data;
    }

    function login() {
      clear(); current = null;
      const box = el("div", "center");
      box.append(el("h2", "", "OpenBoard"), el("p", "", "Incolla il link o il codice che trovi in OpenBoard sul Mac (⌘L)."));
      const input = el("input"); input.placeholder = "Link o codice"; input.autocapitalize = "off"; input.autocomplete = "off";
      const error = el("p");
      const button = el("button", "primary", "Entra");
      button.onclick = async () => {
        const match = input.value.trim().match(/[0-9a-f]{64}/);
        const response = await fetch("/api/login", { method: "POST", headers: { "Content-Type": "application/json", "X-OpenBoard": "1" }, body: JSON.stringify({ token: match ? match[0] : "" }) });
        if (response.ok) showList(); else error.textContent = "Codice non valido.";
      };
      box.append(input, button, error);
      app.append(box);
    }

    function usageBar(label, win) {
      if (!win) return null;
      const row = el("div", "bar");
      const track = el("div", "track"), fill = el("div", "fill");
      const pct = win.percent;
      const color = pct < 60 ? "var(--ok)" : pct < 85 ? "var(--warn)" : "var(--bad)";
      fill.style.width = Math.min(100, pct) + "%"; fill.style.background = color;
      track.append(fill);
      const value = el("span", "pct", pct + "%"); value.style.color = color;
      row.append(el("span", "", label), track, value, el("span", "left", String(win.resets || "").replace("tra ", "")));
      return row;
    }

    let filter = "";
    async function showList() {
      clear(); current = null;
      const header = el("header"); header.append(el("h1", "", "OpenBoard"));
      const body = el("div", "scroll");
      const search = el("input"); search.placeholder = "Cerca"; search.value = filter;
      const usage = el("div"), list = el("div");
      body.append(usage, search, list);
      app.append(header, body);
      let state = null;
      function draw() {
        if (!state) return;
        const query = filter.toLowerCase();
        list.replaceChildren(...state.chats.filter(c => !query || (c.title + " " + c.project).toLowerCase().includes(query)).map(chat => {
          const row = el("button", "row");
          const top = el("div", "top");
          if (chat.state) top.append(el("span", "dot " + chat.state));
          top.append(el("span", "name", chat.title));
          if (chat.agent === "codex") top.append(el("span", "tag", "Codex"));
          top.append(el("span", "when", chat.modified));
          row.append(top, el("div", "sub", chat.description || chat.project));
          row.onclick = () => showChat(chat.id, chat.title);
          return row;
        }));
      }
      search.oninput = () => { filter = search.value; draw(); };
      async function poll() {
        try {
          state = await api("/api/state");
          usage.replaceChildren();
          if (state.usage.length) {
            const card = el("div", "usage");
            for (const account of state.usage) {
              card.append(el("b", "", account.name));
              for (const row of [usageBar("5h", account.session), usageBar("Sett.", account.week)]) if (row) card.append(row);
            }
            usage.append(card);
          }
          draw();
        } catch (e) { if (e.message === "login") return; }
        if (current === null && app.contains(list)) timer = setTimeout(poll, 5000);
      }
      poll();
    }

    function inline(parent, text) {
      for (const part of text.split(/(\*\*[^*]+\*\*|`[^`]+`)/)) {
        if (part.startsWith("**") && part.endsWith("**") && part.length > 4) parent.append(el("strong", "", part.slice(2, -2)));
        else if (part.startsWith("`") && part.endsWith("`") && part.length > 2) parent.append(el("code", "", part.slice(1, -1)));
        else if (part) parent.append(document.createTextNode(part));
      }
    }
    function markdown(text) {
      const box = el("div", "msg assistant");
      const chunks = text.split(/```[^\n]*\n?/);
      chunks.forEach((chunk, index) => {
        if (index % 2) { box.append(el("pre", "", chunk.replace(/\n$/, ""))); return; }
        for (const block of chunk.split(/\n{2,}/)) {
          const lines = block.split("\n").filter(l => l.trim());
          if (!lines.length) continue;
          if (lines.every(l => /^\s*([-*•]|\d+[.)])\s/.test(l))) {
            const list = el("ul");
            for (const line of lines) { const item = el("li"); inline(item, line.replace(/^\s*([-*•]|\d+[.)])\s/, "")); list.append(item); }
            box.append(list);
          } else if (lines.length === 1 && /^#{1,6}\s/.test(lines[0])) {
            const heading = el("h3"); inline(heading, lines[0].replace(/^#+\s/, "")); box.append(heading);
          } else {
            const paragraph = el("p");
            lines.forEach((line, i) => { if (i) paragraph.append(el("br")); inline(paragraph, line); });
            box.append(paragraph);
          }
        }
      });
      return box;
    }
    function message(row) {
      switch (row.kind) {
        case "user": return el("div", "msg user", row.text);
        case "assistant": return markdown(row.text);
        case "tool": return el("div", "msg tool" + (row.error ? " err" : ""), (row.done ? (row.error ? "✕ " : "✓ ") : "… ") + row.name + " " + row.text);
        case "tools": return el("div", "msg tool", row.text);
        case "thinking": return el("div", "msg notice", "Sta pensando…");
        default: return el("div", "msg " + row.kind, row.text);
      }
    }

    async function showChat(id, title) {
      clear(); current = id; wasRunning = false; shownLive = "";
      const header = el("header");
      const back = el("button", "back", "‹ Chat"); back.onclick = showList;
      const stop = el("button", "", "Stop"); stop.hidden = true;
      stop.onclick = () => api("/api/stop", { id }).catch(() => {});
      header.append(back, el("h1", "", title), stop);
      const body = el("div", "scroll");
      const history = el("div"), live = el("div");
      body.append(history, live);
      const composer = el("div", "composer");
      const input = el("textarea"); input.rows = 1; input.placeholder = "Scrivi…";
      input.value = sessionStorage.getItem("draft:" + id) || "";
      input.oninput = () => { sessionStorage.setItem("draft:" + id, input.value); input.style.height = "auto"; input.style.height = input.scrollHeight + "px"; };
      const send = el("button", "primary", "Invia");
      send.onclick = async () => {
        const text = input.value.trim();
        if (!text || sending) return;
        sending = true;
        try { await api("/api/send", { id, text }); input.value = ""; sessionStorage.removeItem("draft:" + id); input.style.height = "auto"; refresh(true); }
        catch (e) { if (e.message !== "login") alert(e.message); }
        sending = false;
      };
      composer.append(input, send);
      app.append(header, body, composer);

      const nearBottom = () => body.scrollHeight - body.scrollTop - body.clientHeight < 120;
      const toBottom = () => { body.scrollTop = body.scrollHeight; };

      async function loadHistory() {
        const data = await api("/api/history?id=" + encodeURIComponent(id));
        if (current !== id) return;
        history.replaceChildren(...data.messages.map(message));
        toBottom();
      }
      async function refresh(force) {
        if (timer) { clearTimeout(timer); timer = null; }
        try {
          const data = await api("/api/live?id=" + encodeURIComponent(id));
          if (current !== id) return;
          if (wasRunning && !data.running) { live.replaceChildren(); shownLive = ""; await loadHistory(); }
          wasRunning = data.running;
          stop.hidden = !data.running;
          input.disabled = data.blocked;
          input.placeholder = data.blocked ? "Aperta in un terminale sul Mac" : data.running ? "Finirà in coda…" : "Scrivi…";
          const signature = JSON.stringify([data.items, data.permission, data.queued]);
          if (signature !== shownLive || force) {
            shownLive = signature;
            const stick = nearBottom();
            const nodes = (data.items || []).map(message);
            for (const text of data.queued) nodes.push(el("div", "msg user queued", text));
            if (data.permission) {
              const permission = data.permission, card = el("div", "perm");
              card.append(el("h2", "", "Permesso: " + permission.tool), el("div", "cmd", permission.command || permission.summary));
              const actions = el("div", "actions");
              const answer = allow => () => api("/api/permission", { id, permission: permission.id, allow }).then(() => refresh(true)).catch(e => { if (e.message !== "login") alert(e.message); });
              const yes = el("button", "primary", "Consenti"), no = el("button", "", "Nega");
              yes.onclick = answer(true); no.onclick = answer(false);
              actions.append(no, yes); card.append(actions); nodes.push(card);
            }
            live.replaceChildren(...nodes);
            if (stick) toBottom();
          }
        } catch (e) { if (e.message === "login") return; }
        if (current === id && !document.hidden) timer = setTimeout(refresh, 1200);
      }
      refresh.loop = true;
      window.resume = () => refresh(true);
      try { await loadHistory(); } catch (e) { if (e.message === "login") return; }
      refresh(true);
    }

    document.addEventListener("visibilitychange", () => {
      if (!document.hidden && current && window.resume) window.resume();
    });
    showList();
    """#
}
