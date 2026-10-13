"use strict";
// Raphael Web — vanilla JS, no build step. Every string from the server goes through esc().

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const S = { state: null, ws: null, route: "overview", arg: "", history: {}, filters: {}, error: null };
const STATUSES = [["backlog", "Backlog"], ["ready", "Ready"], ["in_progress", "In Progress"], ["review", "Review"], ["done", "Done"]];
const LIFECYCLES = [["idea", "Idea"], ["planned", "Planned"], ["building", "Building"], ["live", "Live"], ["maintenance", "Maintenance"], ["archived", "Archived"]];
const PRIO = ["Tanpa", "Low", "Medium", "High", "Urgent"];

const NAV = [
  ["Ringkasan", [["overview", "⌂", "Overview"], ["incidents", "⚑", "Insiden"], ["notify", "✉", "Notifikasi"]]],
  ["Workspace", [["portfolio", "▦", "Portfolio"], ["tasks", "☑", "Semua task"], ["activity", "↻", "Activity"]]],
  ["Operations", [["servers", "▤", "Server"], ["websites", "◎", "Website"], ["jobs", "◷", "Cron & job"], ["traffic", "↗", "Traffic"], ["files", "▱", "File"]]],
  ["Intelligence", [["agents", "◈", "Agents & Token"], ["omniroute", "⇄", "OmniRoute"]]],
];

// ── Formatting ──
const pct = (v) => (v == null ? "–" : `${Math.round(v * 100)}%`);
function ago(t) {
  if (!t) return "–";
  const s = Date.now() / 1000 - t;
  if (s < 0) return inFuture(t);
  if (s < 60) return "baru saja";
  if (s < 3600) return `${Math.floor(s / 60)} mnt lalu`;
  if (s < 86400) return `${Math.floor(s / 3600)} jam lalu`;
  return `${Math.floor(s / 86400)} hari lalu`;
}
function inFuture(t) {
  const s = t - Date.now() / 1000;
  if (s < 3600) return `${Math.max(1, Math.round(s / 60))} mnt lagi`;
  if (s < 86400) return `${Math.floor(s / 3600)} jam lagi`;
  return `${Math.floor(s / 86400)} hari lagi`;
}
const dt = (t) => (t ? new Date(t * 1000).toLocaleString("id-ID", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "–");
const day = (t) => (t ? new Date(t * 1000).toLocaleDateString("id-ID", { day: "numeric", month: "short", year: "numeric" }) : "–");
function bytes(n) {
  if (n == null) return "–";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 && i ? 1 : 0)} ${u[i]}`;
}
const num = (n) => (n == null ? "–" : Number(n).toLocaleString("id-ID"));
function dur(s) {
  if (!s) return "–";
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
  return d ? `${d} hari ${h} jam` : `${h} jam ${Math.floor((s % 3600) / 60)} mnt`;
}
function throttleText(hex) {
  const v = parseInt(String(hex).slice(2), 16);
  if (Number.isNaN(v)) return hex;
  const now = [[0x1, "undervoltage"], [0x2, "frekuensi dibatasi"], [0x4, "throttled"], [0x8, "batas suhu"]].filter(([b]) => v & b).map((x) => x[1]);
  const past = [[0x10000, "undervoltage"], [0x40000, "throttled"], [0x80000, "batas suhu"]].filter(([b]) => v & b).map((x) => x[1]);
  return [now.length ? "sekarang: " + now.join(", ") : "", past.length ? "pernah: " + past.join(", ") : ""].filter(Boolean).join(" · ");
}
const level = (v, warn, bad) => (v >= bad ? "bad" : v >= warn ? "warn" : "ok");
const toDate = (s) => (s ? new Date(s + "T00:00:00").getTime() / 1000 : null);
const fromDate = (t) => (t ? new Date(t * 1000).toISOString().slice(0, 10) : "");

// ── API ──
async function api(method, path, body) {
  const opt = { method, headers: {} };
  if (method !== "GET") { opt.headers["X-Raphael"] = "1"; opt.headers["Content-Type"] = "application/json"; opt.body = JSON.stringify(body || {}); }
  const r = await fetch(path, opt);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `HTTP ${r.status}`);
  return j;
}
async function loadState() {
  try { S.state = await api("GET", "/api/state"); S.error = null; } catch (e) { S.error = e.message; }
}
async function loadWs() {
  try { S.ws = await api("GET", "/api/workspace"); } catch (e) { toast(e.message, true); }
}
async function mutate(method, path, body, msg) {
  try {
    const r = await api(method, path, body);
    await loadWs();
    render();
    if (msg) toast(msg);
    return r;
  } catch (e) { toast(e.message, true); return null; }
}
let toastTimer;
function toast(text, err = false) {
  const t = $("#toast");
  t.textContent = text; t.className = "toast show" + (err ? " err" : "");
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (t.className = "toast"), 3200);
}

// ── Charts ──
function spark(values, color = "var(--violet)", max = null) {
  const v = values.filter((x) => x != null);
  if (v.length < 2) return `<svg class="spark"></svg>`;
  const hi = max ?? Math.max(...v, 1e-9), w = 300, h = 44;
  const pts = values.map((x, i) => `${(i / (values.length - 1)) * w},${h - 2 - ((x ?? 0) / hi) * (h - 6)}`).join(" ");
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none"><polyline points="${pts}" fill="none" stroke="${color}" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>`;
}
function barsChart(items, key, color = "var(--violet)") {
  const hi = Math.max(1, ...items.map((d) => d[key] || 0)), w = 700, h = 160, bw = w / Math.max(items.length, 1);
  const bars = items.map((d, i) => {
    const bh = ((d[key] || 0) / hi) * (h - 28);
    return `<rect x="${i * bw + 6}" y="${h - 18 - bh}" width="${bw - 12}" height="${bh}" rx="4" fill="${color}"><title>${esc(d.date)}: ${num(d[key])}</title></rect>
      <text x="${i * bw + bw / 2}" y="${h - 4}" text-anchor="middle" font-size="11" fill="var(--muted)">${esc((d.date || "").slice(5))}</text>`;
  }).join("");
  return `<svg class="chart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">${bars}</svg>`;
}

// ── Shell ──
function counts() {
  const st = S.state, ws = S.ws;
  const bad = st ? st.alerts.filter((a) => a.level === 2).length : 0;
  const jobs = st ? st.alerts.filter((a) => a.kind === "job").length : 0;
  const sitesDown = st ? st.sites.filter((s) => s.status && !s.status.ok).length : 0;
  const nodesDown = st ? st.nodes.filter((n) => n.detail && n.detail.error).length : 0;
  const open = ws ? ws.tasks.filter((t) => !t.archived && t.status !== "done" && !t.parent_id).length : 0;
  return { bad, jobs, sitesDown, nodesDown, open };
}
function renderNav() {
  const c = counts();
  const om = S.state && S.state.omniroute;
  const badge = { overview: c.bad, websites: c.sitesDown, jobs: c.jobs, servers: c.nodesDown, omniroute: om && om.state === "ok" ? om.down : 0,
    incidents: S.state ? (S.state.openIncidents || []).length : 0 };
  $("#nav").innerHTML = NAV.map(([g, items]) => `<div class="group">${esc(g)}</div>` + items.map(([id, ico, title]) => {
    const on = S.route === id || (id === "portfolio" && S.route === "project");
    const b = badge[id] ? `<span class="badge${id === "jobs" ? " warn" : ""}">${badge[id]}</span>` : "";
    return `<a href="#/${id}" class="${on ? "on" : ""}"><span class="ico">${ico}</span>${esc(title)}${b}</a>`;
  }).join("")).join("") + ((S.state && S.state.links || []).length ? `<div class="group">Buka</div>` +
    S.state.links.map((l) => `<a href="${esc(l.url)}" target="_blank" rel="noopener noreferrer"><span class="ico">↗</span>${esc(l.name)}</a>`).join("") : "");
}
function head(title, sub, actions = "") {
  return `<div class="head"><div><h1>${esc(title)}</h1>${sub ? `<p>${sub}</p>` : ""}</div><div class="actions">${actions}</div></div>`;
}
const refreshBtn = `<button class="btn" data-act="refresh">↻ Refresh</button>`;

function render() {
  renderNav();
  const main = $("#main");
  if (!S.state && !S.error) { main.innerHTML = `<div class="empty"><b>Memuat…</b></div>`; return; }
  if (S.error && !S.state) { main.innerHTML = `<div class="empty"><b>Server tidak menjawab</b>${esc(S.error)}</div>`; return; }
  const pages = { overview, incidents, notify: notifyPage, servers, websites, jobs, traffic, files: filesPage, agents, omniroute, portfolio, project, tasks, activity };
  const keep = document.activeElement && document.activeElement.id ? document.activeElement.id : null;
  const scroll = window.scrollY;
  main.innerHTML = (pages[S.route] || overview)();
  if (keep && $("#" + CSS.escape(keep))) { const el = $("#" + CSS.escape(keep)); el.focus(); if (el.setSelectionRange && el.value) el.setSelectionRange(el.value.length, el.value.length); }
  window.scrollTo(0, scroll);
  if (S.route === "servers") drawHistory();
  if (S.route === "project") wireBoard();
  if (S.route === "agents") loadAgents();
  if (S.route === "omniroute") loadOmni();
  if (S.route === "files") loadFiles();
  if (S.route === "incidents") loadIncidents();
  if (S.route === "notify") loadNotify();
}

// ── Overview ──
function overview() {
  const st = S.state, ws = S.ws, c = counts();
  const online = st.nodes.filter((n) => n.detail && !n.detail.error).length;
  const up = st.sites.filter((s) => s.status && s.status.ok).length, checked = st.sites.filter((s) => s.status).length;
  const active = ws ? ws.projects.filter((p) => p.lifecycle !== "archived" && !p.paused).length : 0;
  const overdue = ws ? ws.projects.reduce((a, p) => a + (p.overdue_tasks || 0), 0) : 0;
  const kpi = (v, l, n, cls = "") => `<div class="card kpi"><div class="v ${cls}">${v}</div><div class="l">${esc(l)}</div><div class="n">${n}</div></div>`;
  const alerts = st.alerts.slice(0, 12).map((a) => `<div class="item"><span class="dot ${["info", "warn", "bad"][a.level]}"></span>
      <div class="ellipsis"><b>${esc(a.node)}</b> <span class="muted">·</span> ${esc(a.text)}</div></div>`).join("");
  const nodes = st.nodes.map((n) => {
    const d = n.detail, s = n.last;
    const stt = !d ? `<span class="chip">belum ada data</span>` : d.error ? `<span class="chip bad">tidak terhubung</span>` : `<span class="chip ok">online</span>`;
    return `<div class="item"><div class="ellipsis" style="flex:1"><b>${esc(n.name)}</b><div class="tiny muted ellipsis">${esc(hwSummary(d))}</div></div>
      ${s ? `<span class="small muted hide-sm">CPU ${pct(s.cpu)} · RAM ${pct(s.mem)} · Disk ${pct(s.disk)}</span>` : ""}${stt}</div>`;
  }).join("");
  return head("Overview", st.alerts.length ? `${c.bad} masalah serius · ${st.alerts.length - c.bad} perlu dicek` : "Semua yang dipantau dalam kondisi baik", refreshBtn) +
    `<div class="grid g4" style="margin-bottom:16px">
      ${kpi(`${online}/${st.nodes.length}`, "Device online", "disampling tiap 60 detik", online < st.nodes.length ? "red" : "")}
      ${kpi(checked ? `${up}/${st.sites.length}` : "–", "Website up", checked ? "dicek tiap 60 detik" : "belum dicek", up < checked ? "red" : "")}
      ${kpi(c.bad, "Masalah serius", `${st.alerts.length} alert total`, c.bad ? "red" : "")}
      ${kpi(ws ? active : "–", "Project aktif", ws ? `${c.open} task terbuka${overdue ? ` · <span class="red">${overdue} lewat tenggat</span>` : ""}` : "")}
    </div>
    <div class="grid g2">
      <div class="card"><h2>Perlu perhatian</h2>${alerts ? `<div class="list">${alerts}</div>` : `<div class="empty"><b>Tidak ada alert</b>Semua sinyal yang dipantau normal.</div>`}</div>
      <div class="stack">
        ${(st.openIncidents || []).length ? `<div class="card"><h2>Insiden terbuka</h2><div class="list">${st.openIncidents.map((i) => `<div class="item"><span class="dot bad"></span><div class="ellipsis" style="flex:1"><b>${esc(i.title)}</b><div class="tiny muted ellipsis">${esc(i.detail || "")}</div></div><span class="small muted">sejak ${ago(i.started)}</span></div>`).join("")}</div><div class="small" style="margin-top:6px"><a href="#/incidents">Riwayat insiden →</a></div></div>` : ""}
        <div class="card"><h2>Device</h2><div class="list">${nodes}</div></div>
        ${backupCard()}
        <div class="card"><h2>Website</h2><div class="list">${st.sites.map(siteLine).join("") || `<div class="muted">Belum ada website.</div>`}</div></div>
      </div>
    </div>`;
}
function backupCard() {
  const b = S.state.backups || [];
  if (!b.length) return "";
  return `<div class="card"><h2>Backup</h2><div class="list">${b.map((x) => {
    const f = x.latest;
    return `<div class="item"><span class="dot ${x.problem ? "bad" : "ok"}"></span><div class="ellipsis" style="flex:1"><b>${esc(x.name)}</b>
      <div class="tiny ${x.problem ? "red" : "muted"} ellipsis">${x.problem ? esc(x.problem) : f ? `terakhir ${ago(f[2])} · ${bytes(f[1])} · ${x.count} file` : ""}</div></div>
      <span class="tiny muted">${esc(x.nodeName)} · batas ${x.maxAgeHours} jam</span></div>`;
  }).join("")}</div></div>`;
}
function siteLine(s) {
  const st = s.status;
  const cls = !st ? "" : st.ok ? "ok" : "bad";
  return `<div class="item"><span class="dot ${cls}"></span><div class="ellipsis" style="flex:1"><b>${esc(s.name)}</b><div class="tiny muted ellipsis mono">${esc(s.url)}</div></div>
    <span class="small muted">${st ? (st.ok ? `${st.ms} ms` : esc(st.error || `HTTP ${st.code}`)) : "belum dicek"}</span></div>`;
}
function hwSummary(d) {
  const hw = d && d.hw;
  if (!hw) return d && d.error ? d.error : "";
  const model = (hw.model || "").replace(/ Rev [\d.]+/, "").replace(" Plus", "+");
  const ram = d.memTotalGB ? `${d.memTotalGB < 1.5 ? 1 : Math.round(d.memTotalGB)} GB RAM` : "";
  const os = (hw.os || "").replace("GNU/Linux ", "").replace(/ \(.*\)/, "");
  return [model, ram, os].filter(Boolean).join(" · ");
}

// ── Servers ──
function servers() {
  const hours = S.filters.hours || 6;
  const seg = [1, 6, 24, 720].map((h) => `<button class="${hours === h ? "on" : ""}" data-act="hours" data-v="${h}">${h === 720 ? "30 hari" : h + " jam"}</button>`).join("");
  return head("Server", "Resource, container dan service di setiap device", `<div class="seg">${seg}</div>${refreshBtn}`) +
    `<div class="stack">${S.state.nodes.map(nodeCard).join("")}</div>`;
}
function nodeCard(n) {
  const d = n.detail, s = n.last;
  if (!d) return `<div class="card node"><h3>${esc(n.name)}</h3><p class="muted">Menunggu sampling pertama…</p></div>`;
  if (d.error && !s) return `<div class="card node"><div class="row"><h3>${esc(n.name)}</h3><span class="chip bad">tidak terhubung</span></div><p class="muted mono small">${esc(d.error)}</p></div>`;
  const m = (label, v, cls, extra = "") => `<div><div class="v ${cls}">${v}</div><div class="l">${label}</div>${extra}</div>`;
  const temp = s && s.temp != null ? `${Math.round(s.temp)}°C` : "–";
  const A = S.state.actions || {};
  const cBtns = (c) => `<button class="btn sm" data-act="logs" data-node="${esc(n.id)}" data-kind="container" data-v="${esc(c.name)}">Log</button>` +
    (A.containers ? ` <button class="btn sm" data-act="doAction" data-node="${esc(n.id)}" data-kind="restart-container" data-v="${esc(c.name)}">Restart</button>` : "");
  const sBtns = (v) => `<button class="btn sm" data-act="logs" data-node="${esc(n.id)}" data-kind="service" data-v="${esc(v.unit)}">Log</button>` +
    ` <button class="btn sm" data-act="doAction" data-node="${esc(n.id)}" data-kind="restart-service" data-v="${esc(v.unit)}">Restart</button>`;
  const containers = d.containers.map((c) => `<tr><td><span class="dot ${c.healthy ? "ok" : "bad"}"></span> <b>${esc(c.name)}</b>${c.project ? `<div class="tiny muted">${esc(c.project)}</div>` : ""}</td>
      <td class="small">${esc(c.status)}</td><td class="small mono">${c.cpu.toFixed(1)}%</td><td class="small mono">${esc(c.mem)}</td><td class="small">${c.restarts > 3 ? `<span class="amber">${c.restarts}×</span>` : c.restarts || ""}</td><td class="nw">${cBtns(c)}</td></tr>`).join("");
  const services = d.services.map((v) => `<tr><td><span class="dot ${v.running ? "ok" : "bad"}"></span> <b>${esc(v.name)}</b><div class="tiny muted">${esc(v.desc)}</div></td>
      <td class="small">${esc(v.state)} · ${esc(v.sub)}</td><td class="small mono">${v.mem ? bytes(v.mem) : "–"}</td><td class="small">${v.restarts || ""}</td><td class="nw">${sBtns(v)}</td></tr>`).join("");
  const failedSvc = (d.failed || []).map((f) => `<span class="chip bad">gagal: ${esc(f)}</span> <button class="btn sm" data-act="logs" data-node="${esc(n.id)}" data-kind="service" data-v="${esc(f)}">Log</button> <button class="btn sm" data-act="doAction" data-node="${esc(n.id)}" data-kind="restart-service" data-v="${esc(f)}">Restart</button>`).join(" ");
  const warn = [];
  if (d.error) warn.push(`<span class="chip bad">sampling terakhir gagal: ${esc(d.error)}</span>`);
  if (failedSvc) warn.push(failedSvc);
  if (d.throttled && d.throttled !== "0x0") warn.push(`<span class="chip warn" title="vcgencmd get_throttled ${esc(d.throttled)}">⚡ ${esc(throttleText(d.throttled))}</span>`);
  if (d.securityUpdates) warn.push(`<span class="chip warn">${d.securityUpdates} update keamanan</span>`);
  if (d.rebootRequired) warn.push(`<span class="chip">perlu reboot</span>`);
  return `<div class="card node">
    <div class="row wrap"><h3>${esc(n.name)}</h3><span class="chip ${d.error ? "bad" : "ok"}">${d.error ? "bermasalah" : "online"}</span>
      <span class="small muted">${esc(hwSummary(d))}</span><span class="spacer"></span><span class="tiny muted">diperbarui ${ago(d.at)} · uptime ${dur(d.uptime)}</span></div>
    ${warn.length ? `<div class="row wrap" style="margin-top:8px">${warn.join("")}</div>` : ""}
    <div class="metrics">
      ${m("CPU", pct(s && s.cpu), level(s ? s.cpu : 0, .7, .9), `<div data-chart="${esc(n.id)}" data-k="cpu"></div>`)}
      ${m(`RAM · ${d.memTotalGB.toFixed(1)} GB`, pct(s && s.mem), level(s ? s.mem : 0, .8, .9), `<div data-chart="${esc(n.id)}" data-k="mem"></div>`)}
      ${m("Disk /", pct(d.disk), level(d.disk, .85, .93), `<div class="meter ${level(d.disk, .85, .93)}" style="margin-top:8px"><i style="width:${Math.round(d.disk * 100)}%"></i></div>`)}
      ${m(`Suhu · load ${s ? s.load.toFixed(2) : "–"}`, temp, s && s.temp ? level(s.temp, 70, 80) : "", `<div data-chart="${esc(n.id)}" data-k="temp"></div>`)}
    </div>
    ${healthLine(n)}
    <div class="small muted">Jaringan: ↓ ${bytes(s && s.rx)}/s · ↑ ${bytes(s && s.tx)}/s${d.disks.length > 1 ? " · " + d.disks.filter((x) => x.mount !== "/").map((x) => `${esc(x.mount)} ${pct(x.used)}`).join(" · ") : ""}</div>
    ${containers || services ? `<details class="more"${S.filters["open:" + n.id] ? " open" : ""} data-open="${esc(n.id)}"><summary>${d.containers.length} container · ${d.services.length} service</summary>
      <div class="scroll-x">${containers ? `<table class="tbl" style="margin-top:10px"><tr><th>Container</th><th>Status</th><th>CPU</th><th>RAM</th><th>Restart</th><th></th></tr>${containers}</table>` : ""}
      ${services ? `<table class="tbl" style="margin-top:10px"><tr><th>Service</th><th>Status</th><th>RAM</th><th>Restart</th><th></th></tr>${services}</table>` : ""}</div></details>` : ""}
  </div>`;
}
function healthLine(n) {
  const h = n.health;
  if (!h) return "";
  const boot = h.uptime ? ago(Date.now() / 1000 - h.uptime) : "–";
  const sd = h.rootRO ? '<span class="red">filesystem read-only!</span>' : h.mmcErrors ? `<span class="amber">${h.mmcErrors} error kartu SD sejak boot</span>` : '<span class="green">kartu SD tanpa error</span>';
  return `<div class="small muted" style="margin-bottom:4px">Boot terakhir ${boot} · ${sd}</div>`;
}
async function drawHistory() {
  const hours = S.filters.hours || 6;
  if (hours === 720) return draw30();
  for (const n of S.state.nodes) {
    const key = `${n.id}:${hours}`, cached = S.history[key];
    if (!cached || Date.now() - cached.at > 30000) {
      try { S.history[key] = { at: Date.now(), samples: (await api("GET", `/api/history?node=${encodeURIComponent(n.id)}&hours=${hours}`)).samples }; } catch { continue; }
    }
    const samples = S.history[key].samples;
    for (const el of $$(`[data-chart="${CSS.escape(n.id)}"]`)) {
      const k = el.dataset.k;
      el.innerHTML = spark(samples.map((x) => x[k]), k === "temp" ? "var(--amber)" : k === "mem" ? "var(--blue)" : "var(--violet)", k === "temp" ? 90 : 1);
    }
  }
}

async function draw30() {
  for (const n of S.state.nodes) {
    const key = `${n.id}:30d`, cached = S.history[key];
    if (!cached || Date.now() - cached.at > 300000) {
      try { S.history[key] = { at: Date.now(), hours: (await api("GET", `/api/history30?node=${encodeURIComponent(n.id)}`)).hours }; } catch { continue; }
    }
    const rows = S.history[key].hours;
    for (const el of $$(`[data-chart="${CSS.escape(n.id)}"]`)) {
      const k = el.dataset.k;
      if (!rows.length) { el.innerHTML = '<div class="tiny muted">mengumpulkan data per jam…</div>'; continue; }
      const vals = rows.map((x) => x[k === "temp" ? "tempMax" : k === "mem" ? "memMax" : "cpuMax"]);
      const thr = k === "temp" && rows.some((x) => x.thr) ? `<div class="tiny amber">throttle di ${rows.filter((x) => x.thr).length} dari ${rows.length} jam</div>` : "";
      el.innerHTML = spark(vals, k === "temp" ? "var(--amber)" : k === "mem" ? "var(--blue)" : "var(--violet)", k === "temp" ? 90 : 1) + thr;
    }
  }
}

// ── Incidents ──
const KIND = { site: "Website", node: "Server", temp: "Suhu", power: "Daya", disk: "Disk", job: "Job", ssl: "SSL", backup: "Backup", internet: "Internet", reboot: "Restart", sdcard: "Kartu SD" };
async function loadIncidents(force) {
  if (!force && S.inc && Date.now() - S.inc.at < 20000) return;
  try {
    const [a, b] = await Promise.all([api("GET", "/api/incidents?days=30"), api("GET", "/api/actionlog")]);
    S.inc = { ...a, actions: b.log, at: Date.now() };
  } catch (e) { S.inc = { error: e.message, at: Date.now() }; }
  if (S.route === "incidents") $("#main").innerHTML = incidents();
}
function incidents() {
  const x = S.inc;
  if (!x) return head("Insiden", "Memuat…");
  if (x.error) return head("Insiden", esc(x.error));
  const kind = S.filters.ikind || "";
  const list = x.incidents.filter((i) => !kind || i.kind === kind);
  const kinds = [...new Set(x.incidents.map((i) => i.kind))];
  const sel = `<select id="ikind"><option value="">Semua jenis</option>${kinds.map((k) => `<option value="${k}" ${k === kind ? "selected" : ""}>${esc(KIND[k] || k)}</option>`).join("")}</select>`;
  const rows = list.map((i) => {
    const open = !i.ended, dur = i.kind === "reboot" ? "" : (open ? "masih terbuka · " : "") + durText((i.ended || Date.now() / 1000) - i.started);
    return `<div class="item" style="align-items:flex-start"><span class="dot ${open ? "bad" : i.kind === "reboot" ? "warn" : "ok"}" style="margin-top:6px"></span>
      <div style="flex:1;min-width:0"><div class="row"><b class="ellipsis">${esc(i.title)}</b><span class="chip">${esc(KIND[i.kind] || i.kind)}</span></div>
      ${i.detail ? `<details class="more"><summary class="tiny">detail</summary><pre class="mono viewer">${esc(i.detail)}</pre></details>` : ""}</div>
      <div class="small muted" style="text-align:right;white-space:nowrap">${dt(i.started)}<div class="tiny">${dur}</div></div></div>`;
  }).join("");
  const acts = (x.actions || []).slice(0, 15).map((a) => `<div class="item"><span class="dot ${a.ok ? "ok" : "bad"}"></span><div class="ellipsis" style="flex:1"><b>${esc(a.kind)}</b> ${esc(a.target)} <span class="muted">di ${esc(a.node)}</span>
      <div class="tiny muted ellipsis">${esc(a.who || "")}</div></div><span class="small muted">${ago(a.t)}</span></div>`).join("");
  const down = x.incidents.filter((i) => i.kind === "site").reduce((a, i) => a + ((i.ended || Date.now() / 1000) - i.started), 0);
  return head("Insiden", `${x.open.length} terbuka · ${x.incidents.length} dalam 30 hari${down ? ` · website down total ${durText(down)}` : ""}`, sel) +
    `<div class="grid g2"><div class="card"><h2>Riwayat · 30 hari</h2><div class="list">${rows || '<div class="empty"><b>Belum ada insiden</b>Insiden dicatat saat masalah bertahan (mis. website down 2 cek berturut-turut).</div>'}</div></div>
     <div class="stack"><div class="card"><h2>Riwayat aksi</h2><div class="list">${acts || '<div class="muted small">Belum ada aksi.</div>'}</div></div></div></div>`;
}
function durText(s) {
  s = Math.max(0, Math.round(s));
  if (s < 90) return `${s} detik`;
  if (s < 3600) return `${Math.round(s / 60)} menit`;
  if (s < 86400) return `${Math.floor(s / 3600)} jam ${Math.floor((s % 3600) / 60)} menit`;
  return `${Math.floor(s / 86400)} hari ${Math.floor((s % 86400) / 3600)} jam`;
}

// ── Notifications ──
async function loadNotify(force) {
  if (!force && S.ntf && Date.now() - S.ntf.at < 20000) return;
  try { S.ntf = { ...(await api("GET", "/api/notify")), at: Date.now() }; } catch (e) { S.ntf = { error: e.message, at: Date.now() }; }
  if (S.route === "notify") $("#main").innerHTML = notifyPage();
}
function notifyPage() {
  const x = S.ntf;
  if (!x) return head("Notifikasi", "Memuat…");
  if (x.error) return head("Notifikasi", esc(x.error));
  const days = ["Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"];
  const log = (x.log || []).map((l) => `<div class="item" style="align-items:flex-start"><span class="dot ${l.ok ? "ok" : "bad"}" style="margin-top:6px"></span>
    <div style="flex:1;min-width:0"><pre class="mono tiny" style="margin:0;white-space:pre-wrap">${esc(l.text)}</pre>${l.error ? `<div class="tiny red">${esc(l.error)}</div>` : ""}</div><span class="small muted">${ago(l.t)}</span></div>`).join("");
  return head("Notifikasi", x.enabled ? `Aktif · dikirim lewat Hermes ke ${esc(x.label)}` : "Nonaktif — atur target di config server",
      `<button class="btn" data-act="ntfTest">Kirim tes</button><button class="btn" data-act="ntfPreview">Lihat laporan mingguan</button><button class="btn primary" data-act="ntfReport">Kirim laporan sekarang</button>`) +
    `<div class="grid g2"><div class="card"><h2>Yang dikirim</h2><div class="small" style="line-height:1.7">
       🌐 website down (2 cek berturut-turut) &amp; pulih · 🖥 server tidak terjangkau (3 menit) · 🌡 suhu ≥ 80°C (3 menit) · ⚡ undervoltage ·
       💾 disk ≥ 93% · ⏰ job gagal / terlewat · 🔒 SSL &lt; 7 hari · 🗄 backup basi/kosong/menyusut · 💽 error kartu SD · 🔁 restart mendadak (dengan dugaan penyebab) ·
       📡 internet rumah putus (status website ditahan)<br>
       📊 Laporan mingguan: tiap ${esc(days[(x.weekly || {}).weekday ?? 0])} ${String((x.weekly || {}).hour ?? 8).padStart(2, "0")}:00.</div>
       ${S.filters.report ? `<pre class="mono viewer">${esc(S.filters.report)}</pre>` : ""}</div>
     <div class="card"><h2>Terkirim terakhir</h2><div class="list">${log || '<div class="muted small">Belum ada.</div>'}</div></div></div>`;
}

// ── Actions & logs ──
const ACTION_TEXT = { "restart-service": "Restart service", "restart-container": "Restart container", "run-job": "Jalankan job sekarang" };
function confirmAction(node, kind, target) {
  const n = S.state.nodes.find((x) => x.id === node);
  openDialog(`<h3>${esc(ACTION_TEXT[kind] || kind)}?</h3>
    <p><b class="mono">${esc(target)}</b> di <b>${esc(n ? n.name : node)}</b></p>
    <p class="small muted">${kind === "run-job" ? "Perintah job dijalankan sekali, sekarang, sebagai user-nya. Bisa makan waktu beberapa menit." : "Layanan akan berhenti sebentar lalu menyala lagi."} Aksi ini dicatat di Riwayat aksi.</p>
    <div id="actOut"></div>
    <div class="foot"><button class="btn" value="cancel" formnovalidate>Batal</button><button class="btn primary" value="run">Ya, jalankan</button></div>`,
  async () => {
    const out = $("#actOut");
    out.innerHTML = '<p class="small muted">Menjalankan…</p>';
    $$("#dlg button").forEach((b) => (b.disabled = true));
    try {
      const r = await api("POST", "/api/action", { node, kind, target });
      out.innerHTML = `<p class="${r.ok ? "green" : "red"}"><b>${r.ok ? "Berhasil" : "Gagal"}</b> · ${esc(r.description)}</p>${r.output ? `<pre class="mono viewer">${esc(r.output)}</pre>` : ""}`;
    } catch (e) { out.innerHTML = `<p class="red">${esc(e.message)}</p>`; }
    $$("#dlg button").forEach((b) => (b.disabled = false));
    const run = $('#dlg button[value="run"]'); if (run) run.remove();
    const cancel = $('#dlg button[value="cancel"]'); if (cancel) cancel.textContent = "Tutup";
    setTimeout(tick, 3000);
    return false;
  });
}
async function showLogs(node, kind, target) {
  openDialog(`<h3>Log · <span class="mono">${esc(target)}</span></h3><div id="logOut"><p class="small muted">Memuat…</p></div>
    <div class="foot"><button class="btn" value="cancel" formnovalidate>Tutup</button></div>`, async () => {});
  $("#dlg").style.width = "min(980px, calc(100vw - 32px))";
  try {
    const r = await api("GET", `/api/logs?node=${encodeURIComponent(node)}&kind=${encodeURIComponent(kind)}&target=${encodeURIComponent(target)}`);
    $("#logOut").innerHTML = `<pre class="mono viewer" style="max-height:65vh">${esc(r.output || "(kosong)")}</pre>`;
    const pre = $("#logOut pre"); if (pre) pre.scrollTop = pre.scrollHeight;
  } catch (e) { $("#logOut").innerHTML = `<p class="red">${esc(e.message)}</p>`; }
}

// ── Websites ──
function websites() {
  const rows = S.state.sites.map((s) => {
    const st = s.status, cls = !st ? "" : st.ok ? "ok" : "bad";
    const bars = (s.recent || []).map((c) => `<i class="${c.ok ? "" : "bad"}" style="height:${Math.min(100, 25 + c.ms / 20)}%" title="${dt(c.t)} · ${c.ms} ms"></i>`).join("");
    const cert = s.certDays == null ? `<span class="muted">SSL –</span>` : `<span class="${s.certDays < 5 ? "red" : s.certDays < 14 ? "amber" : "green"}">SSL ${s.certDays} hari</span>`;
    const code = st ? (st.ok ? `<span class="green">HTTP ${st.code}</span>` : `<span class="red">${esc(st.error || `HTTP ${st.code}`)}</span>`) : `<span class="muted">belum dicek</span>`;
    return `<div class="grow site">
      <div class="g-main"><div class="row"><span class="dot ${cls}"></span><b class="ellipsis">${esc(s.name)}</b>${s.auto ? `<span class="chip">tunnel ${esc(s.node)}</span>` : ""}</div>
        <div class="tiny mono ellipsis"><a href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">${esc(s.url)}</a></div></div>
      <div class="g-bars"><div class="bars">${bars || '<i class="none"></i>'}</div></div>
      <div class="g-meta small">${code}<span class="mono">${st ? `${st.ms} ms` : "–"}</span></div>
      <div class="g-meta small"><span>${s.uptime == null ? "–" : `${(s.uptime * 100).toFixed(1)}%`} <span class="muted">uptime 24 jam</span></span>${cert}</div></div>`;
  }).join("");
  return head("Website", "Uptime, waktu respons dan sertifikat SSL — dicek dari server Raphael Web tiap 60 detik", refreshBtn) +
    `<div class="card"><div class="glist">${rows}</div>
    <p class="tiny muted">Daftar = website di config + semua hostname Cloudflare Tunnel yang ditemukan di device. Balok = 60 cek terakhir (tinggi = waktu respons).</p></div>`;
}

// ── Jobs ──
function jobs() {
  const f = S.filters;
  const all = S.state.nodes.flatMap((n) => ((n.detail && n.detail.jobs) || []).map((j) => ({ n, j })));
  const q = (f.jobq || "").toLowerCase();
  const vis = all.filter(({ j }) => (f.sys || !j.system || j.health === "failed") && (!f.problems || ["failed", "missed"].includes(j.health))
    && (!q || j.name.toLowerCase().includes(q) || j.command.toLowerCase().includes(q)));
  const failed = all.filter(({ j }) => j.health === "failed").length, missed = all.filter(({ j }) => j.health === "missed" && !j.system).length;
  const rank = { failed: 0, missed: 1, running: 2, unknown: 3, scheduled: 4, ok: 5, disabled: 6 };
  const col = { ok: "green", failed: "red", missed: "amber", running: "blue", scheduled: "blue" };
  const now = Date.now() / 1000;
  const cards = S.state.nodes.map((n) => {
    const list = vis.filter((x) => x.n.id === n.id).map((x) => x.j).sort((a, b) => rank[a.health] - rank[b.health] || a.name.localeCompare(b.name));
    if (!list.length) return "";
    return `<div class="card"><div class="row"><h3>${esc(n.name)}</h3><span class="tiny muted">diperbarui ${ago(n.detail && n.detail.at)}</span></div>
      <div class="glist" style="margin-top:6px">${list.map((j) => {
        const key = n.id + "|" + j.id, open = f["job:" + key];
        const next = j.next ? (j.next > now ? inFuture(j.next) : "lewat " + ago(j.next)) : "–";
        return `<div class="grow job click" data-act="job" data-v="${esc(key)}">
          <div class="g-main"><div class="row"><b class="ellipsis">${esc(j.name)}</b>${j.system ? '<span class="chip">sistem</span>' : ""}</div>
            <div class="tiny ellipsis ${j.health === "failed" && j.detail ? "red" : "muted mono"}">${esc(j.detail || j.command)}</div></div>
          <div class="g-meta small"><span>${esc(j.scheduleText)}</span><span class="muted">${esc(j.kindTitle)}</span></div>
          <div class="g-meta small"><span><span class="muted">terakhir</span> ${ago(j.last)}</span><span class="${j.next && j.next < now - 900 ? "amber" : ""}"><span class="muted">berikutnya</span> ${next}</span></div>
          <div class="g-status small"><b class="${col[j.health] || "muted"}">● ${esc(j.healthTitle)}</b></div></div>
          ${open ? `<div class="g-detail">${jobDetail({ ...j, _node: n.id })}</div>` : ""}`;
      }).join("")}</div></div>`;
  }).join("");
  return head("Cron & job", `<span class="${failed ? "red" : ""}">${failed} gagal</span> · <span class="${missed ? "amber" : ""}">${missed} terlewat</span> · ${all.filter((x) => !x.j.system).length} job aplikasi · ${all.filter((x) => x.j.system).length} job sistem`,
    `<input type="search" id="jobq" placeholder="Cari job…" value="${esc(f.jobq || "")}">
     <button class="btn ${f.problems ? "primary" : ""}" data-act="toggle" data-v="problems">Hanya bermasalah</button>
     <button class="btn ${f.sys ? "primary" : ""}" data-act="toggle" data-v="sys">Job sistem</button>`) +
    `<div class="stack">${backupCard()}${cards || `<div class="card empty"><b>Belum ada data job</b>crontab, /etc/cron.d, systemd timer dan cron Hermes dibaca saat sampling.</div>`}
    <p class="tiny muted">Status cron dibaca dari journal, lalu dari file log bila baris cron menulis ke log. "Terlewat" = jadwal menunjukkan job harusnya sudah jalan setelah run terakhir.</p></div>`;
}
function jobDetail(j) {
  const kv = (k, v, mono) => (v ? `<div class="row" style="align-items:flex-start"><span class="small muted" style="width:120px;flex:none">${k}</span><span class="small ${mono ? "mono" : ""}" style="overflow-wrap:anywhere">${esc(v)}</span></div>` : "");
  const hist = (j.history || []).map((r) => `<div class="row small"><span class="dot ${r.status === "failed" || r.status === "error" ? "bad" : "ok"}"></span><span class="mono">${dt(r.started)}</span><span>${esc(r.status)}</span><span class="red ellipsis">${esc(r.error)}</span></div>`).join("");
  return `<div class="stack" style="gap:6px;background:var(--wash);padding:12px;border-radius:12px">
    ${kv("Jenis", [j.kindTitle, j.source, j.user && "user " + j.user].filter(Boolean).join(" · "))}
    ${kv("Ekspresi", j.expr + (j.expectedLast ? ` · seharusnya terakhir ${dt(j.expectedLast)}` : ""))}
    ${kv("Perintah", j.command, true)}${kv("Folder", j.workdir, true)}${kv("Log", j.log ? j.log + (j.logModified ? ` · diubah ${ago(j.logModified)}` : "") : "", true)}
    ${j.failureStreak ? kv("Gagal beruntun", `${j.failureStreak}×`) : ""}${hist ? `<div class="small muted">Eksekusi terakhir</div>${hist}` : ""}
    <div class="row wrap" style="margin-top:4px">${!j.system && S.state.actions && S.state.actions.jobs && ["cron", "hermes"].includes(j.kind) ? `<button class="btn sm" data-act="doAction" data-node="${esc(j._node)}" data-kind="run-job" data-v="${esc(j.id)}">Jalankan sekarang</button>` : ""}
      ${j.log ? `<button class="btn sm" data-act="logs" data-node="${esc(j._node)}" data-kind="job" data-v="${esc(j.id)}">Lihat log</button>` : ""}</div></div>`;
}

// ── Traffic ──
function traffic() {
  const st = S.state, cf = st.cloudflare;
  const tunnels = st.nodes.filter((n) => n.detail && n.detail.tunnel).map((n) => {
    const t = n.detail.tunnel, tot = Object.values(t.codes).reduce((a, b) => a + b, 0) || 1;
    const grp = (p) => Object.entries(t.codes).filter(([k]) => k.startsWith(p)).reduce((a, [, v]) => a + v, 0);
    const parts = [["2", "var(--green)", "2xx sukses"], ["3", "var(--blue)", "3xx redirect/cache"], ["4", "var(--amber)", "4xx ditolak"], ["5", "var(--red)", "5xx error server"]];
    return `<div class="card"><div class="row wrap"><h3>☁ Cloudflare Tunnel · ${esc(n.name)}</h3><span class="chip ${t.connections > 0 ? "ok" : "bad"}">${t.connections} koneksi</span>
      <span class="spacer"></span><span class="small muted">${t.hosts.map(esc).join(" · ")}</span></div>
      <div class="grid g2" style="margin-top:12px"><div><div class="small muted">Request / menit</div><div class="kpi"><div class="v violet">${n.last && n.last.req != null ? n.last.req.toFixed(1) : "–"}</div></div></div>
      <div><div class="small muted">Sejak tunnel jalan · ${num(t.total)} request</div>
        <div class="row" style="height:10px;border-radius:99px;overflow:hidden;gap:2px;margin:8px 0">${parts.map(([p, c]) => `<i style="background:${c};height:100%;flex:${grp(p)}"></i>`).join("")}</div>
        ${parts.map(([p, c, l]) => `<div class="row small"><span class="dot" style="background:${c}"></span>${l}<span class="spacer"></span><span class="mono">${num(grp(p))} · ${Math.round((grp(p) / tot) * 100)}%</span></div>`).join("")}
        ${t.errors ? `<div class="small amber">${num(t.errors)} request gagal diteruskan ke server</div>` : ""}</div></div></div>`;
  }).join("");
  let analytics;
  if (cf.state === "ok") {
    analytics = cf.zones.map((z) => {
      const sum = (k) => z.days.reduce((a, d) => a + (d[k] || 0), 0), req = sum("requests");
      return `<div class="card"><div class="row wrap"><h3>${esc(z.name)}</h3><span class="spacer"></span><span class="small muted">7 hari</span></div>
        <div class="grid g4" style="margin:12px 0">
          <div class="kpi"><div class="v">${num(req)}</div><div class="l">Request</div></div>
          <div class="kpi"><div class="v">${num(sum("visitors"))}</div><div class="l">Pengunjung unik (jumlah harian)</div></div>
          <div class="kpi"><div class="v">${bytes(sum("bytes"))}</div><div class="l">Bandwidth · cache ${req ? Math.round((sum("cached") / req) * 100) : 0}%</div></div>
          <div class="kpi"><div class="v ${sum("threats") ? "amber" : ""}">${num(sum("threats"))}</div><div class="l">Ancaman diblokir</div></div></div>
        ${barsChart(z.days, "requests")}
        <div class="grid g2" style="margin-top:10px"><div><div class="small muted">Negara teratas</div>${z.countries.map(([c, v]) => `<div class="row small"><span>${esc(c)}</span><span class="spacer"></span><span class="mono">${num(v)}</span></div>`).join("") || '<div class="small muted">–</div>'}</div>
        <div><div class="small muted">Status di edge</div>${z.statuses.map(([c, v]) => `<div class="row small"><span class="${c[0] === "5" ? "red" : c[0] === "4" ? "amber" : ""}">${esc(c)}</span><span class="spacer"></span><span class="mono">${num(v)}</span></div>`).join("")}</div></div></div>`;
    }).join("") || `<div class="card empty"><b>Token valid, tapi tidak ada zone aktif</b></div>`;
  } else {
    const msg = { noToken: "Belum ada token Cloudflare.", noPermission: "Token Cloudflare yang ditemukan tidak punya izin Analytics.", idle: "Memuat…", error: "Cloudflare menolak permintaan." }[cf.state] || cf.state;
    analytics = `<div class="card"><h3>Cloudflare Analytics · 7 hari</h3><p><b>${esc(msg)}</b></p>
      ${(cf.tried || []).map((t) => `<div class="small mono muted">• ${esc(t.source)}: ${esc(t.result)}</div>`).join("")}
      <p class="small muted">Buat token di dash.cloudflare.com → My Profile → API Tokens → template <b>"Read analytics and logs"</b>. Simpan di <span class="mono">~/.hermes/.env</span> di server ini sebagai <span class="mono">CLOUDFLARE_API_TOKEN_FULL=…</span> (lewat Raphael Mac → Knowledge → .env), lalu klik Muat ulang. Token dibaca di server dan tidak pernah dikirim ke browser.</p>
      <button class="btn" data-act="cf">Muat ulang Cloudflare</button></div>`;
  }
  return head("Traffic", `Cloudflare Tunnel (langsung dari cloudflared) dan Cloudflare Analytics${cf.loadedAt ? ` · dimuat ${ago(cf.loadedAt)}` : ""}`, refreshBtn) +
    `<div class="stack">${tunnels}${analytics}</div>`;
}

// ── Agents & Token (Hermes) ──
const fmtTok = (n) => (n >= 1e9 ? (n / 1e9).toFixed(2) + " M" : n >= 1e6 ? (n / 1e6).toFixed(1) + " jt" : n >= 1e3 ? (n / 1e3).toFixed(1) + " rb" : String(n || 0));
async function loadAgents(force) {
  const want = S.filters.profile || "";
  if (!force && S.agents && S.agents.want === want && Date.now() - S.agents.at < 30000) return;
  try {
    const r = await api("GET", "/api/agents" + (want ? `?profile=${encodeURIComponent(want)}` : ""));
    S.agents = { ...r, want, at: Date.now() };
  } catch (e) { S.agents = { error: e.message, want, at: Date.now() }; }
  if (S.route === "agents") { $("#main").innerHTML = agents(); }
}
function agents() {
  const a = S.agents;
  if (!a) return head("Agents & Token", "Memuat…");
  if (a.error) return head("Agents & Token", esc(a.error));
  const sel = `<select id="profileSel">${a.profiles.map((p) => `<option value="${esc(p.id)}" ${p.id === a.profile ? "selected" : ""}>${esc(p.name)}</option>`).join("")}</select>`;
  const s = a.snapshot;
  if (!s || s.error) return head("Agents & Token", esc((s && s.error) || "Tidak ada data"), sel);
  const week = s.days.reduce((x, d) => x + d.tokens, 0), weekCalls = s.days.reduce((x, d) => x + d.calls, 0);
  const kpi = (v, l, n = "") => `<div class="card kpi"><div class="v">${v}</div><div class="l">${esc(l)}</div><div class="n">${n}</div></div>`;
  const bucket = (list) => list.map((b) => `<div class="item"><div class="ellipsis" style="flex:1"><b>${esc(b.name)}</b><div class="tiny muted">${num(b.sessions)} sesi · ${num(b.calls)} panggilan</div></div><span class="mono small">${fmtTok(b.tokens)}</span></div>`).join("") || '<div class="muted small">–</div>';
  const recent = s.recent.map((x) => `<div class="item"><span class="dot ${x.active ? "ok" : ""}"></span><div class="ellipsis" style="flex:1"><b>${esc(x.title)}</b>
      <div class="tiny muted ellipsis">${esc(x.source)} · ${esc(x.model)} · ${num(x.messages)} pesan · ${num(x.toolCalls)} tool</div></div>
      <span class="small muted">${fmtTok(x.input + x.cacheRead + x.output)} · ${ago(x.lastActivity || x.startedAt)}</span></div>`).join("");
  return head("Agents & Token", "Sesi dan pemakaian token Hermes di server ini (dibaca langsung dari state.db, hanya baca)", sel +
      `<button class="btn" data-act="agentsReload">↻ Refresh</button>`) +
    `<div class="grid g4" style="margin-bottom:16px">
      ${kpi(fmtTok(s.today.tokens), "Token hari ini", `${num(s.today.calls)} panggilan API`)}
      ${kpi(fmtTok(week), "Token 7 hari", `${num(weekCalls)} panggilan`)}
      ${kpi(num(s.allTime.sessions), "Sesi total", `${fmtTok(s.allTime.input + s.allTime.cacheRead + s.allTime.output)} token sepanjang waktu`)}
      ${kpi(s.allTime.cost ? "$" + s.allTime.cost.toFixed(2) : "–", "Biaya tercatat", `state.db ${bytes(s.dbBytes)}`)}
    </div>
    <div class="card" style="margin-bottom:16px"><h2>Token per hari · 7 hari</h2>${barsChart(s.days, "tokens", "var(--violet)")}</div>
    <div class="grid g2">
      <div class="card"><h2>Sesi terbaru</h2><div class="list">${recent || '<div class="muted">Belum ada sesi.</div>'}</div></div>
      <div class="stack"><div class="card"><h2>Per sumber · 7 hari</h2><div class="list">${bucket(s.sources)}</div></div>
        <div class="card"><h2>Per model · 7 hari</h2><div class="list">${bucket(s.models)}</div></div></div>
    </div>`;
}

// ── OmniRoute ──
async function loadOmni(force) {
  if (!force && S.omni && Date.now() - S.omni.fetched < 20000) return;
  try { S.omni = { ...(await api("GET", "/api/omniroute")), fetched: Date.now() }; } catch (e) { S.omni = { state: "error", error: e.message, fetched: Date.now() }; }
  if (S.route === "omniroute") $("#main").innerHTML = omniroute();
}
function omniroute() {
  const o = S.omni;
  if (!o) return head("OmniRoute", "Memuat…");
  const open = o.dashboard ? `<a class="btn" href="${esc(o.dashboard)}" target="_blank" rel="noopener noreferrer">↗ Buka dashboard</a>` : "";
  const actions = open + `<button class="btn" data-act="omniReload">↻ Refresh</button>`;
  if (o.state !== "ok") {
    const msg = { noKey: "Belum ada API key OmniRoute di server ini.", denied: "API key OmniRoute ditolak.", idle: "Memuat…", error: "OmniRoute tidak terjangkau." }[o.state] || o.state;
    return head("OmniRoute", esc(o.base || ""), actions) + `<div class="card"><p><b>${esc(msg)}</b></p>
      ${(o.tried || []).map((t) => `<div class="small mono muted">• ${esc(t.source)}: ${esc(t.result)}</div>`).join("")}
      <p class="small muted">Server membaca key dari <span class="mono">OMNIROUTE_API_KEY</span> (atau key OmniRoute milik Hermes) di <span class="mono">~/.hermes/.env</span>. Key tidak pernah dikirim ke browser.</p></div>`;
  }
  const st = (x) => (x === "healthy" ? "ok" : x === "degraded" ? "warn" : x === "down" ? "bad" : "");
  const u = o.usage || {};
  const kpi = (v, l, n = "", cls = "") => `<div class="card kpi"><div class="v ${cls}">${v}</div><div class="l">${esc(l)}</div><div class="n">${n}</div></div>`;
  const metrics = (o.metrics || []).map((m) => `<div class="item"><span class="dot ${st(m.state)}"></span><div class="ellipsis" style="flex:1"><b>${esc(m.provider)}</b>
      <div class="tiny muted">${num(m.requests)} request · ${m.latency ? m.latency + " ms" : "–"}${m.lastAt ? " · terakhir " + esc(dt(Date.parse(m.lastAt) / 1000)) : ""}</div></div>
      <span class="small mono">${m.successRate != null ? Number(m.successRate).toFixed(0) + "%" : "–"}</span></div>`).join("");
  const conns = (o.connections || []).map((c) => `<div class="item"><span class="dot ${c.active ? (c.lastError ? "warn" : "ok") : ""}"></span><div class="ellipsis" style="flex:1"><b>${esc(c.name)}</b>
      <div class="tiny ${c.lastError ? "amber" : "muted"} ellipsis">${esc(c.provider)}${c.lastError ? " · " + esc(c.lastError) : ""}</div></div><span class="chip ${c.active ? "ok" : ""}">${c.active ? "aktif" : "nonaktif"}</span></div>`).join("");
  const quotas = (o.quotas || []).filter((q) => q.windows.length).map((q) => `<div class="item" style="align-items:flex-start"><div style="flex:1;min-width:0"><b>${esc(q.account)}</b> <span class="tiny muted">${esc(q.provider)}${q.plan ? " · " + esc(q.plan) : ""}</span>
      ${q.windows.map((w) => `<div class="row small" style="margin-top:4px"><span class="ellipsis" style="width:140px;flex:none">${esc(w.label)}</span>
        <div class="meter ${w.remaining < 10 ? "bad" : w.remaining < 30 ? "warn" : "ok"}" style="flex:1"><i style="width:${Math.max(2, w.remaining)}%"></i></div><span class="mono tiny" style="width:44px;text-align:right">${Math.round(w.remaining)}%</span></div>`).join("")}</div></div>`).join("");
  return head("OmniRoute", `Gateway AI di ${esc(o.base)} · diperbarui ${ago(o.at)}`, actions) +
    `<div class="grid g4" style="margin-bottom:16px">
      ${kpi(`${o.healthy}/${o.healthy + o.degraded + o.down}`, "Provider sehat", `${o.degraded} turun performa · ${o.down} down`, o.down ? "red" : "")}
      ${kpi(num(u.requests), "Request", u.since ? "sejak " + esc(day(Date.parse(u.since) / 1000)) : "")}
      ${kpi(fmtTok(u.tokens || 0), "Token", u.cost ? "$" + Number(u.cost).toFixed(2) : "")}
      ${kpi(u.successRate != null ? Number(u.successRate).toFixed(1) + "%" : "–", "Sukses", u.latency ? Math.round(u.latency) + " ms rata-rata" : "")}
    </div>
    ${(o.days || []).length ? `<div class="card" style="margin-bottom:16px"><h2>Request per hari</h2>${barsChart(o.days, "requests", "var(--blue)")}</div>` : ""}
    <div class="grid g2"><div class="card"><h2>Provider</h2><div class="list">${metrics || '<div class="muted small">–</div>'}</div></div>
      <div class="stack">${quotas ? `<div class="card"><h2>Sisa kuota</h2><div class="list">${quotas}</div></div>` : ""}
      <div class="card"><h2>Koneksi</h2><div class="list">${conns || '<div class="muted small">–</div>'}</div></div></div></div>`;
}

// ── Files (read-only) ──
async function loadFiles() {
  const f = S.files || (S.files = { node: S.state.nodes[0] && S.state.nodes[0].id, path: "~" });
  if (f.loaded === `${f.node}|${f.path}|${f.view || ""}`) return;
  f.loaded = `${f.node}|${f.path}|${f.view || ""}`;
  try {
    f.list = await api("GET", `/api/files?node=${encodeURIComponent(f.node)}&path=${encodeURIComponent(f.path)}`);
    f.file = f.view ? await api("GET", `/api/file?node=${encodeURIComponent(f.node)}&path=${encodeURIComponent(f.view)}`) : null;
  } catch (e) { f.list = { error: e.message }; }
  if (S.route === "files") $("#main").innerHTML = filesPage();
}
function filesPage() {
  const f = S.files || { node: S.state.nodes[0] && S.state.nodes[0].id, path: "~" };
  const nodeSel = `<select id="fileNode">${S.state.nodes.map((n) => `<option value="${esc(n.id)}" ${n.id === f.node ? "selected" : ""}>${esc(n.name)}</option>`).join("")}</select>`;
  const quick = ["~", "/etc", "/var/log", "/srv", "/opt", "~/.hermes"].map((p) => `<button class="btn sm" data-act="fgo" data-v="${esc(p)}">${esc(p)}</button>`).join("");
  const l = f.list;
  let list = '<div class="muted">Memuat…</div>';
  if (l && l.error) list = `<div class="red small">${esc(l.error)}</div>`;
  else if (l && l.items) {
    const up = l.path !== "/" ? `<div class="item click" data-act="fgo" data-v="${esc(l.parent)}"><span class="ico">↰</span><b>..</b></div>` : "";
    list = up + l.items.map((it) => {
      const full = (l.path.endsWith("/") ? l.path : l.path + "/") + it.name;
      if (it.secret) return `<div class="item"><span>🔒</span><span class="ellipsis muted" style="flex:1">${esc(it.name)}</span><span class="tiny muted">disembunyikan</span></div>`;
      return `<div class="item click" data-act="${it.dir ? "fgo" : "fview"}" data-v="${esc(full)}"><span>${it.dir ? "▸" : "·"}</span><span class="ellipsis" style="flex:1">${esc(it.name)}${it.link ? ' <span class="tiny muted">↪</span>' : ""}</span>
        <span class="tiny muted hide-sm">${it.dir ? "" : bytes(it.size)}</span><span class="tiny muted">${ago(it.mtime)}</span></div>`;
    }).join("");
  }
  const v = f.file;
  const viewer = !f.view ? "" : !v ? '<div class="muted">Memuat…</div>' : v.error ? `<div class="red small">${esc(v.error)}</div>`
    : v.binary ? `<div class="muted small">File biner (${bytes(v.size)}) — tidak ditampilkan.</div>`
    : `${v.truncated ? `<div class="amber small">Hanya 512 KB pertama dari ${bytes(v.size)}.</div>` : ""}<pre class="mono viewer">${esc(v.text)}</pre>`;
  return head("File", "Hanya baca, sebagai user biasa. File yang biasanya berisi rahasia (.env, key, token) tidak ditampilkan.", nodeSel) +
    `<div class="row wrap" style="margin-bottom:12px">${quick}</div>
    <div class="grid ${f.view ? "g2" : ""}"><div class="card"><div class="small mono muted ellipsis" style="margin-bottom:8px">${esc(l && l.path || f.path)}</div><div class="list files">${list}</div></div>
    ${f.view ? `<div class="card"><div class="row"><b class="mono small ellipsis" style="flex:1">${esc(f.view)}</b><button class="btn sm" data-act="fclose">Tutup</button></div>${viewer}</div>` : ""}</div>`;
}

// ── Workspace: portfolio ──
const lcTitle = (v) => (LIFECYCLES.find((x) => x[0] === v) || [v, v])[1];
function portfolio() {
  const ws = S.ws;
  if (!ws) return head("Portfolio", "Memuat…");
  const f = S.filters, pf = f.pf || "", lc = f.lc || "";
  const list = ws.projects.filter((p) => (!pf || p.portfolio_id === pf) && (lc ? p.lifecycle === lc : p.lifecycle !== "archived"));
  const pfs = ws.portfolios.filter((p) => !p.archived);
  const pfSel = `<select id="pfSel"><option value="">Semua portfolio</option>${pfs.map((p) => `<option value="${esc(p.id)}" ${p.id === pf ? "selected" : ""}>${esc(p.name)}</option>`).join("")}</select>`;
  const lcSel = `<select id="lcSel"><option value="">Semua (tanpa arsip)</option>${LIFECYCLES.map(([v, t]) => `<option value="${v}" ${v === lc ? "selected" : ""}>${t}</option>`).join("")}</select>`;
  const cards = list.map((p) => {
    const port = ws.portfolios.find((x) => x.id === p.portfolio_id);
    const prog = p.progress == null ? `<span class="small muted">Belum terukur</span>` : `<div class="row"><div class="meter ok" style="flex:1"><i style="width:${Math.round(p.progress * 100)}%"></i></div><span class="small mono">${pct(p.progress)}</span></div>`;
    return `<a class="card pcard" href="#/project/${esc(p.id)}" style="color:inherit;text-decoration:none">
      <div class="row"><span class="chip v mono">${esc(p.key)}</span><span class="chip">${esc(lcTitle(p.lifecycle))}</span>${p.paused ? '<span class="chip warn">paused</span>' : ""}<span class="spacer"></span>${p.priority >= 3 ? `<span class="prio p${p.priority}">${PRIO[p.priority]}</span>` : ""}</div>
      <div><h3>${esc(p.name)}</h3><div class="small muted ellipsis">${esc(p.description || (port ? port.name : ""))}</div></div>${prog}
      <div class="small muted">${p.open_tasks} task terbuka${p.blocked_tasks ? ` · <span class="red">${p.blocked_tasks} terblokir</span>` : ""}${p.overdue_tasks ? ` · <span class="red">${p.overdue_tasks} lewat tenggat</span>` : ""}${p.target_date ? ` · target ${day(p.target_date)}` : ""}</div></a>`;
  }).join("");
  return head("Portfolio", `${ws.projects.filter((p) => p.lifecycle !== "archived").length} project · ${pfs.length} portfolio`,
    `${pfSel}${lcSel}<button class="btn" data-act="newPortfolio">+ Portfolio</button><button class="btn primary" data-act="newProject">+ Project</button>`) +
    (cards ? `<div class="grid g3">${cards}</div>` : `<div class="card empty"><b>${ws.projects.length ? "Tidak ada project di filter ini" : "Belum ada project"}</b>Buat project pertama — task, board dan progress mengikuti.</div>`);
}

// ── Workspace: project board ──
function project() {
  const ws = S.ws;
  if (!ws) return head("Project", "Memuat…");
  const p = ws.projects.find((x) => x.id === S.arg);
  if (!p) return head("Project", "Tidak ditemukan") + `<a href="#/portfolio">← Portfolio</a>`;
  const tasks = ws.tasks.filter((t) => t.project_id === p.id && !t.archived && !t.parent_id);
  const view = S.filters.view || "board";
  const seg = `<div class="seg"><button class="${view === "board" ? "on" : ""}" data-act="view" data-v="board">Board</button><button class="${view === "list" ? "on" : ""}" data-act="view" data-v="list">List</button></div>`;
  const sub = `<span class="mono">${esc(p.key)}</span> · ${esc(lcTitle(p.lifecycle))}${p.paused ? " · paused" : ""} · ${p.progress == null ? "belum terukur" : pct(p.progress) + " selesai"}${p.description ? " · " + esc(p.description) : ""}`;
  let body;
  if (view === "list") {
    const rows = [...tasks].sort((a, b) => STATUSES.findIndex((s) => s[0] === a.status) - STATUSES.findIndex((s) => s[0] === b.status) || b.priority - a.priority)
      .map((t) => `<tr class="click" data-act="task" data-v="${esc(t.id)}"><td class="mono small">${esc(p.key)}-${t.number}</td><td><b>${esc(t.title)}</b>${t.blocked ? ' <span class="chip bad">terblokir</span>' : ""}</td>
        <td class="small">${esc((STATUSES.find((s) => s[0] === t.status) || [])[1])}</td><td class="small">${t.priority ? `<span class="prio p${t.priority}">${PRIO[t.priority]}</span>` : "–"}</td>
        <td class="small">${esc(t.assignee || "–")}</td><td class="small ${dueClass(t)}">${t.due_date ? day(t.due_date) : "–"}</td></tr>`).join("");
    body = `<div class="card scroll-x">${rows ? `<table class="tbl"><tr><th>#</th><th>Task</th><th>Status</th><th>Prioritas</th><th>PIC</th><th>Tenggat</th></tr>${rows}</table>` : `<div class="empty"><b>Belum ada task</b></div>`}</div>`;
  } else {
    body = `<div class="board">${STATUSES.map(([s, title]) => {
      const col = tasks.filter((t) => t.status === s).sort((a, b) => a.position - b.position);
      const lim = (p.wip_limits || {})[s];
      return `<div class="col" data-col="${s}"><div class="col-head">${title} <span class="muted">${col.length}</span>${lim ? `<span class="wip ${col.length > lim ? "over" : ""}">WIP ${col.length}/${lim}</span>` : ""}</div>
        ${col.map((t) => taskCard(t, p)).join("")}
        <form class="quick" data-quick="${s}"><input type="text" id="quick-${s}" placeholder="+ Task baru" maxlength="300"></form></div>`;
    }).join("")}</div>`;
  }
  return `<div class="small"><a href="#/portfolio">← Portfolio</a></div>` + head(p.name, sub, `${seg}<button class="btn" data-act="editProject" data-v="${esc(p.id)}">Pengaturan</button><button class="btn primary" data-act="newTask" data-v="${esc(p.id)}">+ Task</button>`) + body;
}
const dueClass = (t) => (t.due_date && t.status !== "done" && t.due_date < new Date().setHours(0, 0, 0, 0) / 1000 ? "red" : "");
function taskCard(t, p) {
  return `<div class="tcard" draggable="true" data-task="${esc(t.id)}" data-act="task" data-v="${esc(t.id)}">
    <div class="t">${esc(t.title)}</div>
    <div class="m"><span class="mono">${esc(p.key)}-${t.number}</span>${t.priority ? `<span class="prio p${t.priority}">${PRIO[t.priority]}</span>` : ""}
      ${t.blocked ? '<span class="chip bad">terblokir</span>' : ""}${t.assignee ? `<span>👤 ${esc(t.assignee)}</span>` : ""}
      ${t.due_date ? `<span class="${dueClass(t)}">📅 ${day(t.due_date)}</span>` : ""}${(t.labels || []).map((l) => `<span class="chip">${esc(l)}</span>`).join("")}</div></div>`;
}
function wireBoard() {
  let dragId = null;
  for (const c of $$(".tcard")) {
    c.addEventListener("dragstart", (e) => { dragId = c.dataset.task; S.dragging = true; c.classList.add("dragging"); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", dragId); });
    c.addEventListener("dragend", () => { S.dragging = false; c.classList.remove("dragging"); $$(".drop-before").forEach((x) => x.classList.remove("drop-before")); $$(".col.over").forEach((x) => x.classList.remove("over")); });
  }
  for (const col of $$(".col")) {
    col.addEventListener("dragover", (e) => {
      if (!dragId) return;
      e.preventDefault();
      col.classList.add("over");
      $$(".drop-before").forEach((x) => x.classList.remove("drop-before"));
      const before = cardAfter(col, e.clientY);
      if (before) before.classList.add("drop-before");
    });
    col.addEventListener("dragleave", (e) => { if (!col.contains(e.relatedTarget)) col.classList.remove("over"); });
    col.addEventListener("drop", async (e) => {
      e.preventDefault();
      const id = dragId; dragId = null;
      const before = cardAfter(col, e.clientY);
      col.classList.remove("over");
      if (!id) return;
      await mutate("POST", `/api/task/${encodeURIComponent(id)}/move`, { status: col.dataset.col, before: before ? before.dataset.task : null });
    });
  }
}
function cardAfter(col, y) {
  return $$(".tcard:not(.dragging)", col).find((c) => { const r = c.getBoundingClientRect(); return y < r.top + r.height / 2; }) || null;
}

// ── Workspace: tasks & activity ──
function tasks() {
  const ws = S.ws;
  if (!ws) return head("Semua task", "Memuat…");
  const f = S.filters, mine = f.assignee || "";
  const proj = Object.fromEntries(ws.projects.map((p) => [p.id, p]));
  const list = ws.tasks.filter((t) => !t.archived && !t.parent_id && t.status !== "done" && proj[t.project_id] && proj[t.project_id].lifecycle !== "archived" && !proj[t.project_id].paused
    && (!mine || t.assignee === mine)).sort((a, b) => (a.due_date || 9e12) - (b.due_date || 9e12) || b.priority - a.priority);
  const people = [...new Set(ws.tasks.map((t) => t.assignee).filter(Boolean))].sort();
  const sel = `<select id="assigneeSel"><option value="">Semua orang</option>${people.map((a) => `<option ${a === mine ? "selected" : ""}>${esc(a)}</option>`).join("")}</select>`;
  const rows = list.map((t) => { const p = proj[t.project_id]; return `<tr class="click" data-act="task" data-v="${esc(t.id)}"><td class="mono small">${esc(p.key)}-${t.number}</td>
    <td><b>${esc(t.title)}</b>${t.blocked ? ' <span class="chip bad">terblokir</span>' : ""}<div class="tiny muted">${esc(p.name)}</div></td>
    <td class="small">${esc((STATUSES.find((s) => s[0] === t.status) || [])[1])}</td><td class="small">${t.priority ? `<span class="prio p${t.priority}">${PRIO[t.priority]}</span>` : "–"}</td>
    <td class="small">${esc(t.assignee || "–")}</td><td class="small ${dueClass(t)}">${t.due_date ? day(t.due_date) : "–"}</td></tr>`; }).join("");
  return head("Semua task", `${list.length} task terbuka di project aktif`, sel) +
    `<div class="card scroll-x">${rows ? `<table class="tbl"><tr><th>#</th><th>Task</th><th>Status</th><th>Prioritas</th><th>PIC</th><th>Tenggat</th></tr>${rows}</table>` : `<div class="empty"><b>Tidak ada task terbuka</b></div>`}</div>`;
}
function activity() {
  const ws = S.ws;
  if (!ws) return head("Activity", "Memuat…");
  const rows = ws.activity.map((a) => `<div class="item"><span class="dot ${a.type.includes("completed") ? "ok" : a.type.includes("down") || a.type.includes("failed") ? "bad" : "info"}"></span>
    <div class="ellipsis" style="flex:1">${esc(a.title)}<div class="tiny muted">${esc(a.project_name || "")} · ${esc(a.source)}</div></div><span class="small muted">${ago(a.ts)}</span></div>`).join("");
  return head("Activity", "Kejadian terbaru di workspace") + `<div class="card">${rows ? `<div class="list">${rows}</div>` : `<div class="empty"><b>Belum ada aktivitas</b></div>`}</div>`;
}

// ── Dialogs ──
function openDialog(html, onSubmit) {
  const d = $("#dlg");
  d.style.width = "";
  d.innerHTML = `<form method="dialog">${html}</form>`;
  const form = $("form", d);
  form.addEventListener("submit", async (e) => {
    const action = e.submitter && e.submitter.value;
    if (action === "cancel") return;
    e.preventDefault();
    const data = Object.fromEntries(new FormData(form).entries());
    if (await onSubmit(action, data) !== false) d.close();
  });
  d.showModal();
  const first = $("input,textarea,select", d); if (first) first.focus();
}
const field = (label, input) => `<label class="field">${esc(label)}${input}</label>`;
const opts = (list, v) => list.map(([k, t]) => `<option value="${esc(k)}" ${String(k) === String(v) ? "selected" : ""}>${esc(t)}</option>`).join("");

function projectDialog(p) {
  const ws = S.ws, isNew = !p;
  p = p || { name: "", description: "", lifecycle: "idea", priority: 0, portfolio_id: S.filters.pf || "", labels: [] };
  openDialog(`<h3>${isNew ? "Project baru" : "Pengaturan project"}</h3>
    ${field("Nama", `<input type="text" name="name" required maxlength="300" value="${esc(p.name)}">`)}
    ${field("Deskripsi", `<textarea name="description" maxlength="2000">${esc(p.description)}</textarea>`)}
    <div class="grid g2" style="gap:10px">
      ${field("Portfolio", `<select name="portfolio_id"><option value="">Tanpa portfolio</option>${opts(ws.portfolios.filter((x) => !x.archived).map((x) => [x.id, x.name]), p.portfolio_id || "")}</select>`)}
      ${field("Lifecycle", `<select name="lifecycle">${opts(LIFECYCLES, p.lifecycle)}</select>`)}
      ${field("Prioritas", `<select name="priority">${opts(PRIO.map((t, i) => [i, t]), p.priority)}</select>`)}
      ${field("Target", `<input type="date" name="target_date" value="${fromDate(p.target_date)}">`)}
    </div>
    ${field("Label (pisah koma)", `<input type="text" name="labels" value="${esc((p.labels || []).join(", "))}">`)}
    ${isNew ? "" : `<label class="row small"><input type="checkbox" name="paused" ${p.paused ? "checked" : ""}> Paused</label>`}
    <div class="foot">${isNew ? "" : `<button class="btn danger" value="delete" formnovalidate>Hapus project</button><span class="spacer"></span>`}
      <button class="btn" value="cancel" formnovalidate>Batal</button><button class="btn primary" value="save">${isNew ? "Buat" : "Simpan"}</button></div>`,
  async (action, d) => {
    if (action === "delete") {
      if (!confirm(`Hapus project "${p.name}" beserta semua task-nya? Tidak bisa dibatalkan.`)) return false;
      await mutate("DELETE", `/api/project/${encodeURIComponent(p.id)}`, null, "Project dihapus");
      location.hash = "#/portfolio";
      return;
    }
    const body = { ...d, priority: Number(d.priority), target_date: toDate(d.target_date), labels: d.labels };
    if (!isNew) body.paused = !!d.paused;
    const r = isNew ? await mutate("POST", "/api/project", body, "Project dibuat") : await mutate("PATCH", `/api/project/${encodeURIComponent(p.id)}`, body, "Tersimpan");
    if (!r) return false;
    if (isNew) location.hash = `#/project/${r.id}`;
  });
}
function portfolioDialog() {
  openDialog(`<h3>Portfolio baru</h3>${field("Nama", `<input type="text" name="name" required maxlength="300">`)}${field("Deskripsi", `<textarea name="description"></textarea>`)}
    <div class="foot"><button class="btn" value="cancel" formnovalidate>Batal</button><button class="btn primary" value="save">Buat</button></div>`,
  async (_, d) => (await mutate("POST", "/api/portfolio", d, "Portfolio dibuat")) ? undefined : false);
}
function taskDialog(t, projectId) {
  const isNew = !t, ws = S.ws;
  const p = ws.projects.find((x) => x.id === (t ? t.project_id : projectId));
  t = t || { title: "", description: "", status: "backlog", priority: 0, assignee: "", labels: [], blocked: 0, blocked_reason: "" };
  const ms = ws.milestones.filter((m) => m.project_id === p.id);
  openDialog(`<h3>${isNew ? "Task baru" : `<span class="mono muted">${esc(p.key)}-${t.number}</span>`}</h3>
    ${field("Judul", `<input type="text" name="title" required maxlength="300" value="${esc(t.title)}">`)}
    ${field("Deskripsi", `<textarea name="description" maxlength="10000">${esc(t.description)}</textarea>`)}
    <div class="grid g2" style="gap:10px">
      ${field("Status", `<select name="status">${opts(STATUSES, t.status)}</select>`)}
      ${field("Prioritas", `<select name="priority">${opts(PRIO.map((x, i) => [i, x]), t.priority)}</select>`)}
      ${field("PIC", `<input type="text" name="assignee" maxlength="80" value="${esc(t.assignee)}">`)}
      ${field("Tenggat", `<input type="date" name="due_date" value="${fromDate(t.due_date)}">`)}
      ${ms.length ? field("Milestone", `<select name="milestone_id"><option value="">–</option>${opts(ms.map((m) => [m.id, m.title]), t.milestone_id || "")}</select>`) : ""}
      ${field("Label (pisah koma)", `<input type="text" name="labels" value="${esc((t.labels || []).join(", "))}">`)}
    </div>
    <label class="row small"><input type="checkbox" name="blocked" ${t.blocked ? "checked" : ""}> Terblokir</label>
    ${field("Alasan terblokir", `<input type="text" name="blocked_reason" maxlength="300" value="${esc(t.blocked_reason)}">`)}
    ${isNew ? "" : `<div class="tiny muted">Dibuat ${dt(t.created_at)}${t.started_at ? ` · mulai ${dt(t.started_at)}` : ""}${t.completed_at ? ` · selesai ${dt(t.completed_at)}` : ""}</div>`}
    <div class="foot">${isNew ? "" : `<button class="btn danger" value="delete" formnovalidate>Hapus</button><button class="btn" value="archive" formnovalidate>Arsipkan</button><span class="spacer"></span>`}
      <button class="btn" value="cancel" formnovalidate>Batal</button><button class="btn primary" value="save">${isNew ? "Buat" : "Simpan"}</button></div>`,
  async (action, d) => {
    if (action === "delete") {
      if (!confirm("Hapus task ini? Tidak bisa dibatalkan.")) return false;
      return (await mutate("DELETE", `/api/task/${encodeURIComponent(t.id)}`, null, "Task dihapus")) ? undefined : false;
    }
    if (action === "archive") return (await mutate("PATCH", `/api/task/${encodeURIComponent(t.id)}`, { archived: true }, "Task diarsipkan")) ? undefined : false;
    const body = { ...d, priority: Number(d.priority), due_date: toDate(d.due_date), blocked: !!d.blocked, milestone_id: d.milestone_id || null };
    if (isNew) return (await mutate("POST", "/api/task", { ...body, project_id: p.id }, "Task dibuat")) ? undefined : false;
    return (await mutate("PATCH", `/api/task/${encodeURIComponent(t.id)}`, body, "Tersimpan")) ? undefined : false;
  });
}

// ── Events ──
document.addEventListener("click", (e) => {
  const a = e.target.closest("[data-act]");
  if (!a) return;
  const v = a.dataset.v, act = a.dataset.act;
  if (act === "refresh") { api("POST", "/api/refresh").then(() => toast("Sampling dimulai…")).catch((x) => toast(x.message, true)); setTimeout(tick, 6000); }
  else if (act === "cf") { api("POST", "/api/cloudflare").then(() => toast("Memuat Cloudflare…")); setTimeout(tick, 5000); }
  else if (act === "hours") { S.filters.hours = Number(v); render(); }
  else if (act === "toggle") { S.filters[v] = !S.filters[v]; render(); }
  else if (act === "job") { S.filters["job:" + v] = !S.filters["job:" + v]; render(); }
  else if (act === "view") { S.filters.view = v; render(); }
  else if (act === "newProject") projectDialog(null);
  else if (act === "newPortfolio") portfolioDialog();
  else if (act === "editProject") projectDialog(S.ws.projects.find((p) => p.id === v));
  else if (act === "newTask") taskDialog(null, v);
  else if (act === "task") taskDialog(S.ws.tasks.find((t) => t.id === v));
  else if (act === "agentsReload") loadAgents(true);
  else if (act === "doAction") { e.stopPropagation(); confirmAction(a.dataset.node, a.dataset.kind, v); }
  else if (act === "logs") { e.stopPropagation(); showLogs(a.dataset.node, a.dataset.kind, v); }
  else if (act === "ntfTest") api("POST", "/api/notify", { test: true }).then((r) => { toast(r.ok ? "Tes terkirim — cek WhatsApp" : "Gagal: " + r.error, !r.ok); loadNotify(true); }).catch((x) => toast(x.message, true));
  else if (act === "ntfReport") { if (confirm("Kirim laporan mingguan sekarang ke WhatsApp?")) api("POST", "/api/notify", { report: true }).then((r) => { toast(r.ok ? "Laporan terkirim" : "Gagal: " + r.error, !r.ok); loadNotify(true); }); }
  else if (act === "ntfPreview") api("GET", "/api/report").then((r) => { S.filters.report = r.text; $("#main").innerHTML = notifyPage(); });
  else if (act === "omniReload") { api("POST", "/api/omniroute").catch(() => {}); setTimeout(() => loadOmni(true), 4000); toast("Memuat OmniRoute…"); }
  else if (act === "fgo") { S.files.path = v; S.files.view = null; S.files.file = null; render(); }
  else if (act === "fview") { S.files.view = v; S.files.file = null; render(); }
  else if (act === "fclose") { S.files.view = null; S.files.file = null; render(); }
});
document.addEventListener("toggle", (e) => { const id = e.target.dataset && e.target.dataset.open; if (id) S.filters["open:" + id] = e.target.open; }, true);
document.addEventListener("input", (e) => { if (e.target.id === "jobq") { S.filters.jobq = e.target.value; render(); } });
document.addEventListener("change", (e) => {
  if (e.target.id === "pfSel") { S.filters.pf = e.target.value; render(); }
  if (e.target.id === "lcSel") { S.filters.lc = e.target.value; render(); }
  if (e.target.id === "assigneeSel") { S.filters.assignee = e.target.value; render(); }
  if (e.target.id === "ikind") { S.filters.ikind = e.target.value; $("#main").innerHTML = incidents(); }
  if (e.target.id === "profileSel") { S.filters.profile = e.target.value; loadAgents(true); }
  if (e.target.id === "fileNode") { S.files = { node: e.target.value, path: "~" }; render(); }
});
document.addEventListener("submit", async (e) => {
  const f = e.target.closest("form[data-quick]");
  if (!f) return;
  e.preventDefault();
  const input = $("input", f), title = input.value.trim();
  if (!title) return;
  input.value = "";
  await mutate("POST", "/api/task", { project_id: S.arg, title, status: f.dataset.quick });
  const again = $(`#quick-${f.dataset.quick}`); if (again) again.focus();
});
$("#menuBtn").addEventListener("click", () => $("#side").classList.toggle("open"));
$("#side").addEventListener("click", (e) => { if (e.target.closest("nav a")) $("#side").classList.remove("open"); });

// Theme
function applyTheme(t) {
  if (t === "auto") document.documentElement.removeAttribute("data-theme"); else document.documentElement.dataset.theme = t;
  $$(".theme button").forEach((b) => b.classList.toggle("on", b.dataset.theme === t));
  try { localStorage.setItem("raphaelTheme", t); } catch { /* private mode */ }
}
$$(".theme button").forEach((b) => b.addEventListener("click", () => applyTheme(b.dataset.theme)));
let savedTheme = "auto"; try { savedTheme = localStorage.getItem("raphaelTheme") || "auto"; } catch { /* ignore */ }
applyTheme(savedTheme);

// Routing & polling
function route() {
  const [r, arg] = location.hash.replace(/^#\/?/, "").split("/");
  S.route = r || "overview"; S.arg = decodeURIComponent(arg || "");
  render();
  $("#main").focus({ preventScroll: true });
}
window.addEventListener("hashchange", () => { window.scrollTo(0, 0); route(); });
async function tick() {
  if (document.hidden) return;
  if ($("#dlg").open || S.dragging) return;                 // don't redraw under an open form or a drag
  const busy = document.activeElement && ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName);
  await loadState();
  if (S.state && S.ws && S.state.wsRev != null && S.state.wsRev !== S.ws.rev) await loadWs();   // changed elsewhere (Mac app)
  if (!busy) render(); else renderNav();
}
(async () => {
  await Promise.all([loadState(), loadWs()]);
  api("GET", "/api/me").then((m) => { if (m.login) $("#me").textContent = `Masuk sebagai ${m.name || m.login}`; }).catch(() => {});
  route();
  setInterval(tick, 15000);
  setInterval(() => { if (!document.hidden && !$("#dlg").open) loadWs(); }, 60000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });
})();

// ── ⌘K palette ──
function paletteItems() {
  const out = [];
  NAV.forEach(([, items]) => items.forEach(([id, ico, title]) => out.push({ t: title, s: "Halaman", h: `#/${id}`, ico })));
  const st = S.state || { nodes: [], sites: [] };
  st.nodes.forEach((n) => {
    out.push({ t: n.name, s: "Server", h: "#/servers", ico: "▤" });
    ((n.detail && n.detail.jobs) || []).filter((j) => !j.system).forEach((j) => out.push({ t: j.name, s: `Job · ${n.name}`, h: "#/jobs", ico: "◷", job: `${n.id}|${j.id}` }));
    ((n.detail && n.detail.containers) || []).forEach((c) => out.push({ t: c.name, s: `Container · ${n.name}`, h: "#/servers", ico: "▣" }));
  });
  st.sites.forEach((x) => out.push({ t: x.name, s: "Website", h: "#/websites", ico: "◎" }));
  if (S.ws) {
    S.ws.projects.forEach((p) => out.push({ t: p.name, s: `Project · ${p.key}`, h: `#/project/${p.id}`, ico: "▦" }));
    const keys = Object.fromEntries(S.ws.projects.map((p) => [p.id, p]));
    S.ws.tasks.filter((t) => !t.archived && keys[t.project_id]).forEach((t) => out.push({ t: t.title, s: `${keys[t.project_id].key}-${t.number} · ${keys[t.project_id].name}`, h: `#/project/${t.project_id}`, ico: "☑", task: t.id }));
  }
  return out;
}
let palIndex = 0, palResults = [];
function openPalette() {
  const p = $("#palette");
  $("#palQ").value = ""; palIndex = 0; drawPalette();
  p.showModal(); $("#palQ").focus();
}
function drawPalette() {
  const q = $("#palQ").value.trim().toLowerCase();
  const all = paletteItems();
  palResults = (q ? all.filter((x) => (x.t + " " + x.s).toLowerCase().includes(q)) : all.filter((x) => x.s === "Halaman")).slice(0, 40);
  palIndex = Math.min(palIndex, Math.max(0, palResults.length - 1));
  $("#palList").innerHTML = palResults.map((x, i) => `<div class="pal-item ${i === palIndex ? "on" : ""}" data-i="${i}"><span class="ico">${x.ico}</span><span class="ellipsis" style="flex:1">${esc(x.t)}</span><span class="tiny muted ellipsis">${esc(x.s)}</span></div>`).join("") || '<div class="muted small" style="padding:12px">Tidak ada hasil</div>';
}
function choosePalette(i) {
  const x = palResults[i];
  if (!x) return;
  $("#palette").close();
  if (x.job) S.filters["job:" + x.job] = true;
  location.hash = x.h;
  if (x.task) setTimeout(() => { const t = S.ws.tasks.find((y) => y.id === x.task); if (t) taskDialog(t); }, 150);
}
$("#openPalette").addEventListener("click", openPalette);
$("#palQ").addEventListener("input", () => { palIndex = 0; drawPalette(); });
$("#palQ").addEventListener("keydown", (e) => {
  if (e.key === "ArrowDown") { palIndex = Math.min(palIndex + 1, palResults.length - 1); drawPalette(); e.preventDefault(); }
  else if (e.key === "ArrowUp") { palIndex = Math.max(palIndex - 1, 0); drawPalette(); e.preventDefault(); }
  else if (e.key === "Enter") { choosePalette(palIndex); e.preventDefault(); }
});
$("#palList").addEventListener("click", (e) => { const it = e.target.closest(".pal-item"); if (it) choosePalette(Number(it.dataset.i)); });
$("#palette").addEventListener("click", (e) => { if (e.target.id === "palette") $("#palette").close(); });
document.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); if ($("#palette").open) $("#palette").close(); else openPalette(); }
});
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
