"use strict";
// Raphael Web — vanilla JS, no build step. Every string from the server goes through esc().

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const S = { state: null, ws: null, route: "overview", arg: "", history: {}, filters: {}, error: null };
const STATUSES = [["backlog", "Backlog"], ["ready", "Ready"], ["in_progress", "In Progress"], ["review", "Review"], ["done", "Done"]];
const LIFECYCLES = [["idea", "Idea"], ["planned", "Planned"], ["building", "Building"], ["live", "Live"], ["maintenance", "Maintenance"], ["archived", "Archived"]];
const PRIO = ["Tanpa", "Low", "Medium", "High", "Urgent"];

// Same groups, names and order as the Mac app's sidebar (CCSection.groups).
const ICON = {
  house: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h5v-6h4v6h5V9.5"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>',
  me: '<circle cx="10" cy="8" r="3.5"/><path d="M3.5 20c.8-3.6 3.4-5.5 6.5-5.5 1.2 0 2.3.3 3.2.8"/><path d="m15 18 2 2 4-4.5"/>',
  folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4.6l2 2.2h8.4A1.5 1.5 0 0 1 21 8.7v9.8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5Z"/>',
  folderGear: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4.6l2 2.2h8.4A1.5 1.5 0 0 1 21 8.7v3.3"/><path d="M3 6.5v12A1.5 1.5 0 0 0 4.5 20H12"/><circle cx="17.5" cy="17" r="2.2"/><path d="M17.5 13.3v1.5M17.5 19.2v1.5M21.2 17h-1.5M15.3 17h-1.5"/>',
  history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6"/><path d="M3 4v4.5h4.5"/><path d="M12 7.5V12l3 2"/>',
  pulse: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M6.5 13h2.5l1.5-4 3 7 1.5-3h2.5"/>',
  server: '<rect x="3.5" y="4" width="17" height="6.5" rx="1.5"/><rect x="3.5" y="13.5" width="17" height="6.5" rx="1.5"/><path d="M7 7.3h.01M7 16.8h.01"/>',
  apps: '<circle cx="6.5" cy="6.5" r="2.5"/><circle cx="17.5" cy="17.5" r="2.5"/><path d="M8.5 8.5 15.5 15.5"/><path d="M14 6.5h3.5V10"/>',
  chart: '<path d="M4 4v16h16"/><path d="m7.5 15 3.5-4.5 3 2.5 4.5-6"/>',
  route: '<circle cx="5.5" cy="12" r="2.2"/><circle cx="18.5" cy="5.5" r="2.2"/><circle cx="18.5" cy="18.5" r="2.2"/><path d="M7.5 11 16.5 6.5M7.5 13l9 4.5M18.5 7.7v8.6"/>',
  link: '<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
};
const icon = (k) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON[k] || ""}</svg>`;
const NAV = [
  ["Workspace", [["overview", "house", "Overview"], ["portfolio", "grid", "Portfolio"], ["tasks", "me", "My Work"]]],
  ["Development", [["projects", "folderGear", "Projects"], ["activity", "history", "Activity"]]],
  ["Operations", [["monitor", "pulse", "Monitor"], ["servers", "server", "Infrastruktur"], ["websites", "apps", "Aplikasi & Website"], ["files", "folder", "File"]]],
  ["Intelligence", [["agents", "chart", "Agents & Token"], ["omniroute", "route", "OmniRoute"]]],
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
  const badge = { websites: c.sitesDown, servers: c.nodesDown, omniroute: om && om.state === "ok" ? om.down : 0,
    monitor: (S.state ? (S.state.openIncidents || []).length : 0) + c.jobs };
  const monitorOn = S.route === "monitor";
  $("#nav").innerHTML = NAV.map(([g, items]) => `<div class="group">${esc(g)}</div>` + items.map(([id, ico, title]) => {
    const on = S.route === id || (id === "projects" && S.route === "project") || (id === "monitor" && monitorOn);
    const b = badge[id] ? `<span class="badge${id === "monitor" && !c.bad ? " warn" : ""}">${badge[id]}</span>` : "";
    return `<a href="#/${id}" class="${on ? "on" : ""}"><span class="ico">${icon(ico)}</span>${esc(title)}${b}</a>`;
  }).join("")).join("") + ((S.state && S.state.links || []).length ? `<div class="group">Buka</div>` +
    S.state.links.map((l) => `<a href="${esc(l.url)}" target="_blank" rel="noopener noreferrer"><span class="ico">${icon("link")}</span>${esc(l.name)}</a>`).join("") : "");
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
  const pages = { overview, monitor: monitorPage, servers: infra, websites: appsAndSites, files: filesPage, agents, omniroute, portfolio, project: projectsPage, projects: projectsPage, tasks, activity };
  const keep = document.activeElement && document.activeElement.id ? document.activeElement.id : null;
  const scroll = window.scrollY;
  main.innerHTML = (pages[S.route] || overview)();
  if (keep && $("#" + CSS.escape(keep))) { const el = $("#" + CSS.escape(keep)); el.focus(); if (el.setSelectionRange && el.value) el.setSelectionRange(el.value.length, el.value.length); }
  window.scrollTo(0, scroll);
  const mtab = S.route === "monitor" ? (S.arg || "summary").split("|")[0] : "";
  if (mtab === "servers") drawServerSparks();
  if (S.route === "project") wireBoard();
  if (S.route === "agents") loadAgents();
  if (S.route === "omniroute") loadOmni();
  if (S.route === "files") loadFiles();
  if (mtab === "incidents") loadIncidents();
  if (mtab === "notify") loadNotify();
  if (mtab === "traffic") { loadWorldMap(); loadClarity(); }
}

// ── Operations pages, laid out like the Mac app (MonitorView, InfraViews, MonitorApps) ──
const nodeLast = (n) => n.last || {};
const nodeDown = (n) => !!(n.detail && n.detail.error);
const pctTxt = (v) => (v == null ? "–" : `${Math.round(v * 100)}%`);
const barColor = (v) => (v >= 0.9 ? "var(--red)" : v >= 0.7 ? "var(--amber)" : "var(--green)");
const upTxt = (s) => { if (!s) return "–"; const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60); return d ? `${d}h ${h}j` : h ? `${h}j ${m}m` : `${m}m`; };
const rate = (b) => (b == null ? "–" : b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB/s` : b >= 1024 ? `${Math.round(b / 1024)} KB/s` : `${Math.round(b)} B/s`);
function nodeApps(n) {
  const d = n.detail || {}, out = [];
  for (const c of d.containers || []) out.push({ kind: "container", name: c.name, group: c.project || "", ports: c.ports || [], ok: /^Up/.test(c.status) && c.healthy !== false || /^Up/.test(c.status), status: c.status, node: n });
  for (const s of d.services || []) out.push({ kind: "service", name: s.name, group: "", ports: [], ok: s.running, status: s.running ? "running" : s.state, node: n, unit: s.unit, user: s.user });
  return out;
}
const healthOf = (n) => nodeDown(n) ? ["Tidak terjangkau", "bad"] : S.state.alerts.some((a) => a.node === n.name && a.level === 2) ? ["Perlu dicek", "warn"] : S.state.alerts.some((a) => a.node === n.name) ? ["Perlu dicek", "warn"] : ["Sehat", "ok"];
const meterRow = (label, right, v) => `<div class="mrow"><div class="row small"><span>${label}</span><span class="spacer"></span><span class="muted">${right}</span></div><div class="mbar"><i style="width:${Math.round(Math.min(1, v || 0) * 100)}%;background:${barColor(v || 0)}"></i></div></div>`;

// Infrastruktur: one card per device (NodeCard).
function infra() {
  const cards = S.state.nodes.map((n) => {
    const d = n.detail || {}, l = nodeLast(n), [h, hc] = healthOf(n), apps = nodeApps(n), down = apps.filter((a) => !a.ok).length;
    const cores = d.cores || 1, disk = (d.disks || [])[0] || {};
    const body = nodeDown(n) ? `<div class="small red">${esc(d.error)}</div>` : !l.t ? '<div class="small muted">Memeriksa…</div>' :
      meterRow("CPU", `load ${(l.load || 0).toFixed(2)} · ${cores} core`, (l.load || 0) / cores / 1.5) +
      meterRow("RAM", `${pctTxt(l.mem)} dari ${d.memTotalGB ? d.memTotalGB.toFixed(1) + " GB" : "–"}`, l.mem) +
      meterRow("Disk", `${pctTxt(l.disk)} dari ${disk.totalGB ? Math.round(disk.totalGB) + " GB" : "–"}`, l.disk) +
      `<div class="row wrap" style="gap:6px;margin-top:4px"><span class="chip">up ${upTxt(d.uptime)}</span>${l.temp != null ? `<span class="chip ${l.temp > 75 ? "bad" : ""}">${Math.round(l.temp)}°C</span>` : ""}<span class="chip ${down ? "bad" : "ok"}">${apps.length} app</span>${l.thr ? '<span class="chip warn">throttled</span>' : ""}</div>`;
    return `<div class="card ncard"><div class="row" style="align-items:flex-start"><span class="tile">${icon("server")}</span>
        <div style="flex:1;min-width:0"><b>${esc(n.name)}</b><div class="small ellipsis" style="color:var(--ink2)">${esc(hwSummary(n.detail))}</div><div class="tiny mono muted ellipsis">${esc(n.local ? "lokal (server ini)" : n.description || "")}</div></div>
        <span class="chip ${hc}">${h}</span></div>${body}
      <div class="row" style="gap:8px;margin-top:4px"><button class="btn" data-act="refresh" title="Refresh">↻</button><a class="btn" href="#/monitor/servers/${esc(n.id)}">Detail di Monitor</a></div></div>`;
  }).join("");
  return head("Infrastruktur", "RasPi dan server yang dipantau Raphael Web lewat SSH key", refreshBtn) + `<div class="grid g3">${cards}</div>`;
}

// Monitor (Ringkasan · Aplikasi · Server · Jobs · Traffic, plus Insiden and Notifikasi on the web).
const MON_TABS = [["summary", "Ringkasan"], ["apps", "Aplikasi"], ["servers", "Server"], ["jobs", "Jobs"], ["traffic", "Traffic"], ["incidents", "Insiden"], ["notify", "Notifikasi"]];
function monitorPage() {
  const [tab0, sub] = (S.arg || "summary").split("|");
  const tab = MON_TABS.some(([t]) => t === tab0) ? tab0 : "summary";
  const st = S.state, allApps = st.nodes.flatMap(nodeApps);
  const badge = { summary: st.alerts.filter((a) => a.level === 2).length, apps: allApps.filter((a) => !a.ok).length,
    jobs: st.alerts.filter((a) => a.kind === "job").length, incidents: (st.openIncidents || []).length };
  const hours = S.filters.hours || 6;
  const rangeSeg = `<div class="seg">${[[1, "1 jam"], [6, "6 jam"], [24, "24 jam"]].map(([v, t]) => `<button class="${hours === v ? "on" : ""}" data-act="hours" data-v="${v}">${t}</button>`).join("")}</div>`;
  const tabs = `<div class="tabs" role="tablist">${MON_TABS.map(([t, l]) => `<a href="#/monitor/${t}" class="${tab === t ? "on" : ""}">${l}${badge[t] ? ` <span class="badge${t === "apps" || t === "jobs" ? " warn" : ""}">${badge[t]}</span>` : ""}</a>`).join("")}</div>`;
  const embed = (html) => `<div class="embedded">${html}</div>`;
  const body = tab === "summary" ? monSummary(allApps) : tab === "apps" ? monApps(st.nodes) : tab === "servers" ? monServers(sub)
    : tab === "jobs" ? embed(jobs()) : tab === "traffic" ? embed(traffic()) : tab === "incidents" ? embed(incidents()) : embed(notifyPage());
  return head("Monitor", "Semua server, aplikasi dan website yang dipantau Raphael Web", rangeSeg + refreshBtn) + tabs + body;
}
const ALERT_CATS = [["Daya & suhu", (a) => /daya|suhu|undervoltage|throttl/i.test(a.text)], ["Resource", (a) => /disk|ram|memori|swap|cpu|load/i.test(a.text)],
  ["Layanan", (a) => /container|service|unit|restart/i.test(a.text)], ["Cron & job", (a) => a.kind === "job"],
  ["Keamanan", (a) => /ssh|keamanan|security|update|reboot/i.test(a.text)], ["Website & traffic", (a) => a.kind === "site" || /website|ssl|tunnel|internet/i.test(a.text)]];
function monSummary(apps) {
  const st = S.state, alerts = st.alerts, running = apps.filter((a) => a.ok).length, bad = apps.filter((a) => !a.ok);
  const online = st.nodes.filter((n) => !nodeDown(n) && nodeLast(n).t).length;
  const req = st.nodes.reduce((x, n) => x + (nodeLast(n).req || 0), 0);
  const crit = alerts.filter((a) => a.level === 2).length, warn = alerts.filter((a) => a.level === 1).length, info = alerts.length - crit - warn;
  const kpi = (l, v, n, tone, ic, href) => `<a class="card mkpi" href="${href}"><div class="row"><span class="lbl">${l}</span><span class="spacer"></span><span class="ico" style="color:${tone}">${icon(ic)}</span></div><div class="v">${v}</div><div class="n" style="color:${tone === "var(--green)" || tone === "var(--violet)" ? "var(--muted)" : tone}">${n}</div></a>`;
  const used = new Set();
  const groups = ALERT_CATS.map(([name, f]) => { const l = alerts.filter((a) => !used.has(a) && f(a)); l.forEach((a) => used.add(a)); return [name, l]; });
  const rest = alerts.filter((a) => !used.has(a)); if (rest.length) groups.push(["Lainnya", rest]);
  const lvl = (a) => a.level === 2 ? ["Kritis", "bad"] : a.level === 1 ? ["Peringatan", "warn"] : ["Info", "info"];
  const grouped = groups.filter(([, l]) => l.length).map(([name, l]) => `<div class="agroup"><div class="small" style="font-weight:650;color:var(--ink2)">${esc(name)}</div>${l.map((a) => { const [t, c] = lvl(a); return `<div class="arow"><span class="chip ${c}" style="justify-content:center">${t}</span><b class="small ellipsis">${esc(a.node)}</b><span class="small" style="color:var(--ink2)">${esc(a.text)}</span></div>`; }).join("")}</div>`).join("");
  const appRows = bad.slice(0, 8).map((a) => `<div class="item"><span class="dot bad"></span><div class="ellipsis" style="flex:1"><b class="small">${esc(a.name)}</b><div class="tiny muted ellipsis">${esc(a.node.name)} · ${esc(a.status)}</div></div></div>`).join("");
  const tiles = st.nodes.map((n) => { const l = nodeLast(n), d = n.detail || {};
    return `<a class="card stile" href="#/monitor/servers|${esc(n.id)}"><div class="row"><span class="dot ${nodeDown(n) ? "bad" : l.t ? "ok" : ""}"></span><b class="ellipsis">${esc(n.name)}</b><span class="spacer"></span>${l.temp != null ? `<span class="tiny ${l.temp > 75 ? "red" : "muted"}">${Math.round(l.temp)}°C</span>` : ""}</div>
      <div class="tiny ellipsis" style="color:var(--ink2)">${esc(hwSummary(n.detail))}</div>${n.description ? `<div class="tiny muted" style="margin-top:2px">${esc(n.description)}</div>` : ""}
      ${meterRow("CPU", pctTxt(l.cpu), l.cpu)}${meterRow("RAM", pctTxt(l.mem), l.mem)}</a>`; }).join("");
  return `<div class="stack"><div class="grid g4">
      ${kpi("Aplikasi berjalan", `${running}/${apps.length}`, bad.length ? `${bad.length} bermasalah atau mati` : "semua normal", bad.length ? "var(--amber)" : "var(--green)", "apps", "#/monitor/apps")}
      ${kpi("Server online", `${online}/${st.nodes.length}`, online === st.nodes.length ? "semua terjangkau" : `${st.nodes.length - online} tidak terjangkau`, online === st.nodes.length ? "var(--green)" : "var(--red)", "server", "#/monitor/servers")}
      ${kpi("Traffic sekarang", req < 10 ? req.toFixed(1) : Math.round(req), "request / menit lewat tunnel", "var(--violet)", "chart", "#/monitor/traffic")}
      ${kpi("Sinyal", `${crit} kritis`, `${warn} peringatan · ${info} info`, crit ? "var(--red)" : "var(--green)", "pulse", "#/monitor/incidents")}
    </div>
    <div class="sumgrid"><div class="card"><div class="lbl" style="margin-bottom:10px">Perlu perhatian</div>${grouped || '<div class="small green">✓ Tidak ada masalah</div>'}</div>
      <div class="card"><div class="row" style="margin-bottom:6px"><span class="lbl">Aplikasi yang perlu dicek</span><span class="spacer"></span><a class="small" href="#/monitor/apps">Semua aplikasi</a></div>
        <div class="list">${appRows || '<div class="small green">✓ Semua aplikasi berjalan normal</div>'}</div></div></div>
    <div class="lbl">Server</div><div class="grid g3">${tiles}</div></div>`;
}
function appCards(nodes) {
  return nodes.map((n) => {
    const apps = nodeApps(n), ok = apps.filter((a) => a.ok).length;
    const groups = {};
    for (const a of apps) (groups[a.kind === "service" ? "SERVICE" : (a.group || "CONTAINER").toUpperCase()] ||= []).push(a);
    const rows = Object.entries(groups).map(([g, l]) => `<div class="lbl" style="margin:10px 0 4px">${esc(g)}</div>` + l.map((a) => `<div class="approw ${a.ok ? "" : "down"}"><span class="dot ${a.ok ? "ok" : "bad"}"></span><span class="ico">${icon(a.kind === "service" ? "pulse" : "grid")}</span><b class="small ellipsis">${esc(a.name)}</b>${a.ports.length ? `<span class="tiny mono muted">:${a.ports.join(", :")}</span>` : ""}<span class="spacer"></span><span class="small ${a.ok ? "muted" : "red"} ellipsis">${esc(a.status)}</span></div>`).join("")).join("");
    return `<div class="card"><div class="row"><span class="dot ${nodeDown(n) ? "bad" : ok === apps.length ? "ok" : "warn"}"></span><h3>${esc(n.name)}</h3><span class="spacer"></span><span class="chip ${ok === apps.length ? "ok" : "bad"}">${ok}/${apps.length} jalan</span></div>${rows || '<div class="small muted" style="margin-top:8px">Belum ada aplikasi terdeteksi.</div>'}</div>`;
  }).join("");
}
const monApps = (nodes) => `<div class="stack">${appCards(nodes)}</div>`;
function monServers(sub) {
  const list = S.state.nodes, sel = list.find((n) => n.id === sub) || list.find((n) => n.id === S.filters.server) || list[0];
  if (!sel) return '<div class="card empty"><b>Belum ada server</b></div>';
  S.filters.server = sel.id;
  const side = list.length > 1 ? `<div class="card slist">${list.map((n) => { const l = nodeLast(n);
    return `<a href="#/monitor/servers|${esc(n.id)}" class="${n.id === sel.id ? "on" : ""}"><span class="dot ${nodeDown(n) ? "bad" : l.t ? "ok" : ""}"></span><div style="min-width:0"><div class="small ellipsis" style="font-weight:${n.id === sel.id ? 650 : 500}">${esc(n.name)}</div><div class="tiny ellipsis" style="color:var(--ink2)">${esc(hwSummary(n.detail))}</div><div class="tiny muted">${l.t ? `CPU ${pctTxt(l.cpu)} · RAM ${pctTxt(l.mem)}` : esc((n.detail || {}).error || "…")}</div></div></a>`; }).join("")}</div>` : "";
  const d = sel.detail || {}, l = nodeLast(sel), hw = d.hw || {}, disks = d.disks || [];
  const mini = (k, label, value, foot, color) => `<div class="mmini"><div class="lbl">${label}</div><div class="v">${value}</div><div class="spark-slot" data-spark="${k}" data-color="${color}"></div>${foot ? `<div class="tiny muted">${foot}</div>` : ""}</div>`;
  const top = (rows, mode) => (rows || []).slice(0, 5).map((p) => `<div class="prow"><span class="ellipsis">${esc(p.name)}</span><span class="tiny muted">${mode === "cpu" ? `${(p.mem || 0).toFixed(1)}% RAM` : `pid ${p.pid}`}</span><b class="mono">${(mode === "cpu" ? p.cpu : p.mem || 0).toFixed(1)}%</b></div>`).join("") || '<div class="tiny muted">–</div>';
  const sys = [["Update paket", d.updates ? `${d.updates}${d.securityUpdates ? ` (${d.securityUpdates} keamanan)` : ""}` : "–"], ["Login SSH gagal 24 jam", d.sshFails ? String(d.sshFails) : "–"],
    ["Perlu reboot", d.rebootRequired ? "ya" : "tidak"], ["Service gagal", (d.failed || []).length ? d.failed.join(", ") : "tidak ada"]];
  const card = `<div class="card ndetail"><div class="row wrap"><span class="dot ${nodeDown(sel) ? "bad" : "ok"}" style="width:12px;height:12px"></span><h2 class="nname">${esc(sel.name)}</h2><span class="chip">up ${upTxt(d.uptime)}</span><span class="small muted">${d.cores || "–"} core · ${d.memTotalGB ? d.memTotalGB.toFixed(1) : "–"} GB RAM</span><span class="spacer"></span><span class="small muted">diperbarui ${ago(l.t || d.at)}</span></div>
    ${nodeDown(sel) ? `<div class="small red">${esc(d.error)}</div>` : ""}
    <div class="hwgrid"><div><div class="lbl">Perangkat</div><b>${esc((hw.model || "–").replace(/ Rev [\d.]+$/, ""))}</b></div><div><div class="lbl">Prosesor</div><b>${esc(hw.cpu || "–")}</b></div><div><div class="lbl">Sistem</div><b>${esc((hw.os || "–").replace(/ GNU\/Linux/, ""))}</b></div><div><div class="lbl">Penyimpanan</div><b>${esc((hw.storage || []).join(", ") || "–")}</b></div></div>
    <div class="mminis">${mini("cpu", "CPU", pctTxt(l.cpu), "", "var(--violet)")}${mini("mem", "RAM", pctTxt(l.mem), l.swap != null ? `swap ${pctTxt(l.swap)}` : "", "var(--blue)")}${mini("disk", "Disk /", pctTxt(l.disk), "", "var(--amber)")}${mini("rx", "Network", `↓${rate(l.rx)} ↑${rate(l.tx)}`, "", "var(--green)")}${mini("load", "Load", (l.load || 0).toFixed(2), `${d.cores || "–"} core`, "var(--orchid)")}${l.temp != null ? mini("temp", "Suhu", `${Math.round(l.temp)}°C`, l.thr ? "throttled" : "", "var(--red)") : ""}</div>
    <div class="ncols"><div><div class="lbl">Proses teratas · CPU</div>${top(d.topCPU, "cpu")}<div class="lbl" style="margin-top:14px">Proses teratas · RAM</div>${top(d.topMem, "mem")}</div>
      <div><div class="lbl">Disk</div>${disks.map((x) => `<div class="mrow"><div class="row small"><span class="mono">${esc(x.mount)}</span><span class="spacer"></span><span class="muted">${pctTxt(x.used)} dari ${Math.round(x.totalGB)} GB</span></div><div class="mbar"><i style="width:${Math.round(x.used * 100)}%;background:${barColor(x.used)}"></i></div></div>`).join("") || '<div class="tiny muted">–</div>'}
        <div class="lbl" style="margin-top:14px">Keamanan & sistem</div>${sys.map(([k, v]) => `<div class="prow"><span>${k}</span><span></span><b>${esc(v)}</b></div>`).join("")}</div></div></div>`;
  return `<div class="srvgrid ${side ? "" : "solo"}">${side}${card}</div>`;
}
async function drawServerSparks() {
  const id = S.filters.server, hours = S.filters.hours || 6;
  if (!id || !$("[data-spark]")) return;
  const key = `${id}:${hours}`;
  if (!S.history[key] || Date.now() - S.history[key].at > 30000) {
    try { S.history[key] = { at: Date.now(), samples: (await api("GET", `/api/history?node=${encodeURIComponent(id)}&hours=${hours}`)).samples }; } catch { return; }
  }
  const smp = S.history[key].samples;
  for (const el of $$("[data-spark]")) {
    const k = el.dataset.spark, vals = smp.map((x) => x[k]);
    el.innerHTML = spark(vals, el.dataset.color, k === "temp" ? 90 : ["cpu", "mem", "disk"].includes(k) ? 1 : null);
  }
}

// Aplikasi & Website: websites first, then each server's containers and services.
function appsAndSites() {
  const rows = S.state.sites.map((s) => { const st = s.status;
    return `<div class="siterow"><span class="dot ${!st ? "" : st.ok ? "ok" : "bad"}"></span><b class="ellipsis">${esc(s.name)}</b><a class="mono small ellipsis" href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">${esc(s.url)}</a><span class="spacer"></span>
      <span class="small ${st && !st.ok ? "red" : ""}">${st ? (st.ok ? `HTTP ${st.code}` : esc(st.error || `HTTP ${st.code}`)) : "belum dicek"}</span><span class="small mono muted">${st ? `${st.ms} ms` : "–"}</span>
      <span class="small ${s.certDays != null && s.certDays < 14 ? "amber" : "muted"}">${s.certDays == null ? "" : `SSL ${s.certDays} hr`}</span></div>`; }).join("");
  return head("Aplikasi & Website", "Container Docker, service systemd dan website di setiap server", `<button class="btn" data-act="refresh">↻ Cek ulang</button>`) +
    `<div class="stack"><div class="card"><div class="lbl" style="margin-bottom:8px">Website</div>${rows || '<div class="small muted">Belum ada website.</div>'}</div>${appCards(S.state.nodes)}</div>`;
}

// ── Workspace pages, laid out like the Mac app (OverviewView, PortfolioView, ProjectWorkspace, Activity) ──
Object.assign(ICON, {
  sparkles: '<path d="M12 3.5 13.6 9l5.4 1.6-5.4 1.6L12 17.6l-1.6-5.4L5 10.6 10.4 9Z"/><path d="M18.5 3v3M17 4.5h3M5.5 16.5v3M4 18h3"/>',
  check: '<circle cx="12" cy="12" r="8.5"/><path d="m8.2 12.3 2.6 2.6 5-5.4"/>',
  folderPlus: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4.6l2 2.2h8.4A1.5 1.5 0 0 1 21 8.7v9.8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5Z"/><path d="M12 11v6M9 14h6"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  sync: '<path d="M4.5 12a7.5 7.5 0 0 1 12.8-5.3L19.5 9"/><path d="M19.5 4.5V9H15"/><path d="M19.5 12a7.5 7.5 0 0 1-12.8 5.3L4.5 15"/><path d="M4.5 19.5V15H9"/>',
  cloud: '<path d="M7 18.5a4.5 4.5 0 0 1-.6-9 6 6 0 0 1 11.4 1.6A3.8 3.8 0 0 1 17.3 18.5Z"/><path d="m9.5 13.5 2 2 3.5-3.5"/>',
});
function emptyState(ic, title, msg, primary, secondary) {
  return `<div class="estate"><span class="eico">${icon(ic)}</span><b>${esc(title)}</b><p>${esc(msg)}</p>
    <div class="row" style="justify-content:center;gap:8px">${primary ? `<button class="btn primary" data-act="${primary[1]}">${esc(primary[0])}</button>` : ""}${secondary ? `<button class="btn" data-act="${secondary[1]}">${esc(secondary[0])}</button>` : ""}</div></div>`;
}
const meName = () => { try { return localStorage.getItem("raphaelMe") || "Saya"; } catch { return "Saya"; } };
const projActions = `<button class="btn" data-act="discover">${icon("search")} Temukan project</button><button class="btn primary" data-act="newProject">${icon("plus")} Project baru</button>`;
const openTasks = (ws) => ws.tasks.filter((t) => !t.archived && !t.parent_id && t.status !== "done");
const isOverdue = (t) => t.due_date && t.due_date < Date.now() / 1000 && t.status !== "done";

function overview() {
  const ws = S.ws;
  if (!ws) return head("Overview", "Memuat…");
  const live = ws.projects.filter((p) => p.lifecycle !== "archived");
  if (!ws.projects.length) return head("Overview", "Belum ada project", projActions) + `<div class="card">${emptyState("sparkles", "Mulai dengan project",
    "Raphael menyatukan task, roadmap, repo, deployment dan kesehatan server per project. Temukan project dari ~/Projects, GitHub, Vercel dan Monitor, atau buat sendiri. Angka di halaman ini baru muncul setelah ada data nyata.",
    ["Temukan project", "discover"], ["Project baru", "newProject"])}</div>`;
  const now = Date.now() / 1000, open = openTasks(ws), proj = Object.fromEntries(ws.projects.map((p) => [p.id, p]));
  const active = live.filter((p) => !p.paused).length, wip = open.filter((t) => t.status === "in_progress").length;
  const overdue = open.filter(isOverdue).length, blocked = open.filter((t) => t.blocked).length;
  const risk = ws.milestones.filter((m) => !m.completed_at && m.target_date && m.target_date < now + 7 * 86400);
  const done90 = ws.tasks.filter((t) => t.completed_at && t.started_at && t.completed_at > now - 90 * 86400);
  const cycle = done90.length ? done90.reduce((a, t) => a + (t.completed_at - t.started_at), 0) / done90.length / 86400 : null;
  const kpi = (l, v, n, tone) => `<div class="card okpi"><div class="lbl">${l}</div><div class="v" ${tone ? `style="color:${tone}"` : ""}>${v}</div><div class="n">${n}</div></div>`;
  const attention = live.filter((p) => !p.paused).map((p) => {
    const ts = open.filter((t) => t.project_id === p.id), r = [];
    let action = "", score = 0;
    const mr = risk.filter((m) => m.project_id === p.id);
    if (mr.length) { r.push([`Milestone berisiko: ${mr.map((m) => m.title).join(", ")}`, "var(--red)"]); action = "Tinjau cakupan atau tanggal milestone"; score += 15 * mr.length; }
    const od = ts.filter(isOverdue).length, bl = ts.filter((t) => t.blocked).length;
    if (od) { r.push([`${od} task lewat tenggat`, "var(--red)"]); action ||= "Selesaikan atau jadwal ulang task yang lewat"; score += 5 * od; }
    if (bl) { r.push([`${bl} task terblokir`, "var(--amber)"]); action ||= "Lepaskan blokir"; score += 4 * bl; }
    if (p.target_date && p.target_date < now && ["idea", "planned", "building"].includes(p.lifecycle)) { r.push([`Target project lewat (${day(p.target_date)})`, "var(--amber)"]); action ||= "Perbarui target atau lifecycle"; score += 6; }
    return { p, r, action, score };
  }).filter((a) => a.r.length).sort((a, b) => b.score - a.score);
  const attHtml = attention.length ? attention.slice(0, 8).map((a) => `<a class="attn" href="#/project/${esc(a.p.id)}"><div style="flex:1;min-width:0"><div class="row" style="gap:6px"><b>${esc(a.p.name)}</b><span class="chip">${esc(lcTitle(a.p.lifecycle))}</span></div>
      ${a.r.slice(0, 3).map(([t, c]) => `<div class="small ellipsis" style="color:var(--ink2)"><span class="dot" style="background:${c};width:6px;height:6px"></span> ${esc(t)}</div>`).join("")}</div>
      <div class="next"><div class="tiny muted">Berikutnya</div><div class="small" style="color:var(--violet);font-weight:650">${esc(a.action)}</div></div></a>`).join("")
    : '<div class="small green">✓ Tidak ada yang mendesak: tidak ada task lewat tenggat, blokir, milestone berisiko atau target yang lewat.</div>';
  const me = meName(), mine = open.filter((t) => t.assignee === me).sort((a, b) => (isOverdue(b) - isOverdue(a)) || ((a.due_date || 9e12) - (b.due_date || 9e12))).slice(0, 7);
  const taskLine = (t) => `<div class="item click" data-act="task" data-v="${esc(t.id)}"><span class="dot ${isOverdue(t) ? "bad" : t.status === "in_progress" ? "info" : ""}"></span><div class="ellipsis" style="flex:1"><b class="small">${esc(t.title)}</b><div class="tiny muted">${esc((proj[t.project_id] || {}).name || "")}</div></div><span class="tiny ${isOverdue(t) ? "red" : "muted"}">${t.due_date ? day(t.due_date) : ""}</span></div>`;
  const weeks = Array.from({ length: 8 }, (_, i) => { const end = now - (7 - i) * 7 * 86400, start = end - 7 * 86400;
    return { date: new Date(end * 1000).toISOString().slice(0, 10), done: ws.tasks.filter((t) => t.completed_at > start && t.completed_at <= end).length }; });
  const st = S.state, crit = st ? st.alerts.filter((a) => a.level === 2).length : 0;
  const ev = ws.activity.slice(0, 10).map((a) => `<div class="item"><span class="dot info"></span><div class="ellipsis" style="flex:1"><span class="small">${esc(a.title)}</span><div class="tiny muted">${esc(a.project_name || "")}</div></div><span class="tiny muted">${ago(a.ts)}</span></div>`).join("");
  return head("Overview", attention.length ? `${attention.length} project perlu perhatian` : "Tidak ada project yang butuh perhatian", projActions) +
    `<div class="stack"><div class="grid g6">${kpi("Project aktif", active, "tidak paused")}${kpi("Task terbuka", open.length, `${wip} sedang dikerjakan`)}
      ${kpi("Lewat tenggat", overdue, "task belum selesai", overdue ? "var(--red)" : "")}${kpi("Terblokir", blocked, "flag / dependensi", blocked ? "var(--amber)" : "")}
      ${kpi("Milestone berisiko", risk.length, "lewat atau mepet", risk.length ? "var(--red)" : "")}${kpi("Siklus rata-rata", cycle == null ? "–" : `${cycle.toFixed(1)} hari`, cycle == null ? "belum ada data" : `${done90.length} task, 90 hari`)}</div>
    <div class="sumgrid"><div class="card"><div class="lbl" style="margin-bottom:10px">Perlu perhatian & langkah berikutnya</div>${attHtml}</div>
      <div class="card"><div class="row"><span class="lbl">Task saya berikutnya</span><span class="spacer"></span><a class="small" href="#/tasks">My Work</a></div><div class="list">${mine.map(taskLine).join("") || `<div class="small muted">Belum ada task yang ditugaskan ke ${esc(me)}.</div>`}</div></div></div>
    <div class="sumgrid"><div class="card"><div class="row"><span class="lbl">Task selesai per minggu · 8 minggu</span><span class="spacer"></span><span class="tiny muted">dari tanggal selesai task</span></div>
        ${weeks.some((w) => w.done) ? lineChart(weeks, [{ key: "done", label: "Selesai", color: "var(--violet)" }], 160) : '<div class="small muted" style="height:120px">Belum ada task yang selesai dalam 8 minggu terakhir.</div>'}</div>
      <div class="card"><div class="lbl" style="margin-bottom:8px">Operasional</div>
        <div class="prow"><span>Sinyal kritis</span><span></span><b class="${crit ? "red" : "green"}">${crit}</b></div>
        <div class="prow"><span>Server online</span><span></span><b>${st ? st.nodes.filter((n) => !nodeDown(n)).length + "/" + st.nodes.length : "–"}</b></div>
        <div class="prow"><span>Website naik</span><span></span><b>${st ? st.sites.filter((s) => s.status && s.status.ok).length + "/" + st.sites.length : "–"}</b></div>
        <a class="small" href="#/monitor">Buka Monitor →</a></div></div>
    <div class="card"><div class="row"><span class="lbl">Aktivitas terbaru</span><span class="spacer"></span><a class="small" href="#/activity">Semua</a></div><div class="list">${ev || '<div class="small muted">Belum ada aktivitas.</div>'}</div></div></div>`;
}

function portfolio() {
  const ws = S.ws;
  if (!ws) return head("Portfolio", "Memuat…");
  const f = S.filters, view = f.pview || "grid", q = (f.pq || "").toLowerCase();
  const all = ws.projects.filter((p) => p.lifecycle !== "archived");
  const list = all.filter((p) => (f.pfav ? p.favorite : true) && (f.ppaused === false ? !p.paused : true)
    && (!q || `${p.name} ${p.key} ${p.description || ""} ${p.labels || ""}`.toLowerCase().includes(q)));
  const sub = `${all.filter((p) => !p.paused).length} project aktif · ${all.filter((p) => p.lifecycle === "building").length} building · ${all.filter((p) => p.lifecycle === "live").length} live
    <span class="synced">${icon("cloud")} Workspace bersama di Raphael Web · rev ${S.ws.rev ?? "–"}</span>`;
  const ctl = `<div class="row wrap ctlrow"><div class="seg">${[["grid", "Grid"], ["list", "List"], ["kanban", "Kanban"]].map(([v, t]) => `<button class="${view === v ? "on" : ""}" data-act="pview" data-v="${v}">${t}</button>`).join("")}</div>
    <input type="search" id="pq" placeholder="Cari project, label…" value="${esc(f.pq || "")}" style="width:260px">
    <label class="check"><input type="checkbox" data-act="pfav" ${f.pfav ? "checked" : ""}> Favorit</label><label class="check"><input type="checkbox" data-act="ppaused" ${f.ppaused === false ? "" : "checked"}> Paused</label></div>`;
  if (!ws.projects.length) return head("Portfolio", sub, projActions) + ctl + `<div class="card">${emptyState("grid", "Belum ada project",
    "Buat project sendiri, atau biarkan Raphael menemukan project dari ~/Projects, GitHub, Vercel dan aplikasi yang dipantau di Monitor. Kamu yang memutuskan mana yang digabung.", ["Temukan project", "discover"], ["Project baru", "newProject"])}</div>`;
  const prog = (p) => p.progress == null ? `<span class="small muted">Belum terukur</span>` : `<div class="row"><div class="mbar" style="flex:1;margin:0"><i style="width:${Math.round(p.progress * 100)}%;background:var(--green)"></i></div><span class="small mono">${pct(p.progress)}</span></div>`;
  let body;
  if (view === "list") {
    body = `<div class="card scroll-x"><table class="tbl"><tr><th>Project</th><th>Lifecycle</th><th>Progress</th><th>Task terbuka</th><th>Target</th></tr>${list.map((p) => `<tr class="click" data-act="openProject" data-v="${esc(p.id)}"><td><span class="chip v mono">${esc(p.key)}</span> <b>${esc(p.name)}</b>${p.paused ? ' <span class="chip warn">paused</span>' : ""}</td><td class="small">${esc(lcTitle(p.lifecycle))}</td><td style="min-width:140px">${prog(p)}</td><td class="small">${p.open_tasks}${p.blocked_tasks ? ` · <span class="red">${p.blocked_tasks} terblokir</span>` : ""}</td><td class="small">${p.target_date ? day(p.target_date) : "–"}</td></tr>`).join("")}</table></div>`;
  } else if (view === "kanban") {
    body = `<div class="kanban">${LIFECYCLES.filter(([v]) => v !== "archived").map(([v, t]) => { const col = list.filter((p) => p.lifecycle === v);
      return `<div class="kcol"><div class="row"><span class="lbl">${t}</span><span class="spacer"></span><span class="tiny muted">${col.length}</span></div>${col.map((p) => `<a class="card kcard" href="#/project/${esc(p.id)}"><span class="chip v mono">${esc(p.key)}</span><b>${esc(p.name)}</b>${prog(p)}</a>`).join("")}</div>`; }).join("")}</div>`;
  } else {
    body = `<div class="grid g3">${list.map((p) => `<a class="card pcard" href="#/project/${esc(p.id)}" style="color:inherit;text-decoration:none">
      <div class="row"><span class="chip v mono">${esc(p.key)}</span><span class="chip">${esc(lcTitle(p.lifecycle))}</span>${p.paused ? '<span class="chip warn">paused</span>' : ""}${p.favorite ? '<span class="chip">★</span>' : ""}<span class="spacer"></span>${p.priority >= 3 ? `<span class="prio p${p.priority}">${PRIO[p.priority]}</span>` : ""}</div>
      <div><h3>${esc(p.name)}</h3><div class="small muted ellipsis">${esc(p.description || "")}</div></div>${prog(p)}
      <div class="small muted">${p.open_tasks} task terbuka${p.blocked_tasks ? ` · <span class="red">${p.blocked_tasks} terblokir</span>` : ""}${p.overdue_tasks ? ` · <span class="red">${p.overdue_tasks} lewat tenggat</span>` : ""}${p.target_date ? ` · target ${day(p.target_date)}` : ""}</div></a>`).join("")}</div>`;
  }
  return head("Portfolio", sub, projActions) + ctl + (list.length ? body : `<div class="card">${emptyState("search", "Tidak ada project di filter ini", "Ubah pencarian atau filter di atas.")}</div>`);
}

function tasks() {
  const ws = S.ws;
  if (!ws) return head("My Work", "Memuat…");
  const me = meName(), withNone = !!S.filters.unassigned, proj = Object.fromEntries(ws.projects.map((p) => [p.id, p]));
  const list = openTasks(ws).filter((t) => proj[t.project_id] && (t.assignee === me || (withNone && !t.assignee)))
    .sort((a, b) => (isOverdue(b) - isOverdue(a)) || ((a.due_date || 9e12) - (b.due_date || 9e12)) || b.priority - a.priority);
  const ctl = `<label class="small muted row" style="gap:8px">Nama saya <input type="text" id="meName" value="${esc(me)}" style="width:150px"></label><label class="check"><input type="checkbox" data-act="unassigned" ${withNone ? "checked" : ""}> Termasuk tanpa orang</label>`;
  const groups = STATUSES.filter(([s]) => s !== "done").map(([s, title]) => [title, list.filter((t) => t.status === s)]).filter(([, l]) => l.length);
  const body = groups.map(([title, l]) => `<div class="card"><div class="lbl" style="margin-bottom:6px">${esc(title)} · ${l.length}</div><div class="list">${l.map((t) => { const p = proj[t.project_id];
    return `<div class="item click" data-act="task" data-v="${esc(t.id)}"><span class="mono tiny muted">${esc(p.key)}-${t.number}</span><div class="ellipsis" style="flex:1"><b class="small">${esc(t.title)}</b>${t.blocked ? ' <span class="chip bad">terblokir</span>' : ""}<div class="tiny muted">${esc(p.name)}</div></div>${t.priority ? `<span class="prio p${t.priority}">${PRIO[t.priority]}</span>` : ""}<span class="tiny ${dueClass(t)}">${t.due_date ? day(t.due_date) : ""}</span></div>`; }).join("")}</div></div>`).join("");
  return head("My Work", `Task yang ditugaskan ke ${esc(me)} di semua project`, ctl) +
    (list.length ? `<div class="stack">${body}</div>` : `<div class="card">${emptyState("check", "Tidak ada task untukmu", `Tugaskan task ke "${me}" dari board atau isi kolom Orang di detail task.`)}</div>`);
}

function projectsPage() {
  const ws = S.ws;
  if (!ws) return head("Projects", "Memuat…");
  const q = (S.filters.prq || "").toLowerCase(), list = ws.projects.filter((p) => p.lifecycle !== "archived" && (!q || `${p.name} ${p.key}`.toLowerCase().includes(q)));
  const side = `<div class="ppane"><div class="row" style="gap:8px"><input type="search" id="prq" placeholder="Cari project…" value="${esc(S.filters.prq || "")}" style="flex:1"><button class="btn icon-btn" data-act="newProject" title="Project baru">${icon("plus")}</button></div>
    <div class="plist">${list.map((p) => `<a href="#/project/${esc(p.id)}" class="${p.id === S.arg ? "on" : ""}"><span class="dot ${p.paused ? "" : p.lifecycle === "live" ? "ok" : "info"}"></span><div style="min-width:0"><div class="small ellipsis" style="font-weight:600">${esc(p.name)}</div><div class="tiny muted">${esc(p.key)} · ${esc(lcTitle(p.lifecycle))}</div></div></a>`).join("")}</div></div>`;
  const main = S.arg && ws.projects.some((p) => p.id === S.arg) ? project()
    : `<div class="pempty">${emptyState("folderPlus", "Belum ada project", "Project menyatukan repo, server, domain, deployment dan task dalam satu konteks.", ["Project baru", "newProject"], ["Temukan project", "discover"])}</div>`;
  return `<div class="projects">${side}<div class="pmain">${main}</div></div>`;
}

const ACT_KINDS = [["all", "Semua"], ["task", "Task"], ["code", "Kode"], ["ci", "CI & deploy"], ["ops", "Operasional"], ["agent", "Agent"]];
const actKind = (a) => { const s = `${a.type} ${a.source}`.toLowerCase();
  return /agent|hermes/.test(s) ? "agent" : /ci|deploy|vercel|release|workflow/.test(s) ? "ci" : /git|commit|push|pr\b|pull/.test(s) ? "code" : /monitor|incident|server|site|down|backup/.test(s) ? "ops" : "task"; };
function activity() {
  const ws = S.ws;
  if (!ws) return head("Activity", "Memuat…");
  const f = S.filters, kind = f.akind || "all", days = f.adays || 30, pid = f.aproj || "";
  const list = ws.activity.filter((a) => a.ts > Date.now() / 1000 - days * 86400 && (kind === "all" || actKind(a) === kind) && (!pid || a.project_id === pid));
  const ctl = `<div class="row wrap ctlrow"><div class="seg">${ACT_KINDS.map(([v, t]) => `<button class="${kind === v ? "on" : ""}" data-act="akind" data-v="${v}">${t}</button>`).join("")}</div>
    <select id="adays">${[[7, "7 hari"], [30, "30 hari"], [90, "90 hari"]].map(([v, t]) => `<option value="${v}" ${days === v ? "selected" : ""}>${t}</option>`).join("")}</select>
    <select id="aproj"><option value="">Semua project</option>${ws.projects.map((p) => `<option value="${esc(p.id)}" ${p.id === pid ? "selected" : ""}>${esc(p.name)}</option>`).join("")}</select></div>
    <div class="row" style="margin:-4px 0 14px;gap:10px"><span class="small muted">${list.length} kejadian</span><button class="btn" data-act="wsSync">${icon("sync")} Sinkron</button></div>`;
  const rows = list.map((a) => `<div class="item"><span class="dot ${a.type.includes("completed") ? "ok" : /down|failed/.test(a.type) ? "bad" : "info"}"></span>
    <div class="ellipsis" style="flex:1"><span class="small">${esc(a.title)}</span><div class="tiny muted">${esc(a.project_name || "")} · ${esc(a.source)}</div></div><span class="small muted">${ago(a.ts)}</span></div>`).join("");
  return head("Activity", "Semua kejadian dari task, GitHub, CI/deploy, Monitor dan agent, berurutan") + ctl +
    `<div class="card">${rows ? `<div class="list">${rows}</div>` : emptyState("history", "Belum ada aktivitas", "Aktivitas muncul saat task berubah, dan dari repo/Vercel/aplikasi yang ditautkan ke project.")}</div>`;
}

// ── Overview ──
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
  if (S.route === "monitor") render();
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
  if (S.route === "monitor") render();
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
// ── Clarity (visitor behaviour; fetched by the server, 10 calls/day) ──
async function loadClarity(force) {
  if (S.clarityLoading || (!force && S.clarity && Date.now() - S.clarityAt < 60000)) return;
  S.clarityLoading = true;
  try { S.clarity = await api("GET", "/api/clarity"); S.clarityAt = Date.now(); } catch (e) { S.clarity = { state: "error", error: e.message }; }
  finally { S.clarityLoading = false; if (S.route === "monitor") render(); }
}
const clDur = (sec) => sec == null ? "–" : sec >= 60 ? `${Math.floor(sec / 60)} mnt ${Math.round(sec % 60)} dtk` : `${Math.round(sec)} dtk`;
const clPct = (v) => v == null ? "–" : `${Number(v).toFixed(v < 10 ? 1 : 0)}%`;
const clPath = (u) => { try { const x = new URL(u); return x.pathname + x.search || "/"; } catch { return u || "–"; } };
function clarityCard() {
  const c = S.clarity;
  if (!c) return `<div class="card"><h3>Perilaku pengunjung · Clarity</h3><p class="small muted">Memuat…</p></div>`;
  const quota = `${num(c.used || 0)}/${num(c.limit || 10)} permintaan hari ini`;
  const btn = `<button class="btn" data-act="clarity">Muat ulang Clarity</button>`;
  const hdr = (sub) => `<div class="row wrap"><div><h3>Perilaku pengunjung · Clarity${c.site ? ` · ${esc(c.site)}` : ""}</h3><div class="small muted">${sub}</div></div><span class="spacer"></span>${btn}<a class="btn" href="https://clarity.microsoft.com/projects" target="_blank" rel="noopener">Buka Clarity ↗</a></div>`;
  if (c.state === "noToken" || c.state === "idle" && !c.totals) {
    return `<div class="card">${hdr("Heatmap, rekaman sesi, lama kunjungan dan klik kontak dari Microsoft Clarity")}
      <p><b>${c.state === "noToken" ? "Belum ada token Clarity." : "Menunggu pemuatan pertama…"}</b></p>
      <p class="small muted">Di clarity.microsoft.com → project → <b>Settings → Data Export → Generate new API token</b>. Simpan di <span class="mono">~/.hermes/.env</span> di server ini sebagai <span class="mono">CLARITY_API_TOKEN=…</span> (lewat Raphael Mac → Knowledge → .env), lalu klik Muat ulang. Token dibaca di server dan tidak pernah dikirim ke browser. Clarity hanya mengizinkan 10 permintaan per hari, jadi Raphael memuat tiap ${num(c.everyHours || 6)} jam.</p></div>`;
  }
  const t = c.totals || {}, problem = c.state !== "ok" ? `<div class="cf-analytics-status" role="status">${esc(c.error || c.state)}${c.at ? ` · angka di bawah dari ${esc(ago(c.at))}` : ""}</div>` : "";
  const tried = c.state !== "ok" ? (c.tried || []).map((x) => `<div class="small mono muted">• ${esc(x.source)}: ${esc(x.result)}</div>`).join("") : "";
  const kpi = (v, l, n) => `<div class="kpi"><div class="v">${v}</div><div class="l">${l}</div>${n ? `<div class="n small muted">${n}</div>` : ""}</div>`;
  const issue = (k, l, tip) => { const x = t[k] || {}; return x.sessions == null && x.pct == null ? "" : `<span class="chip" title="${esc(tip)}">${l} · ${num(x.sessions)} sesi${x.pct != null ? ` (${clPct(x.pct)})` : ""}</span>`; };
  const pages = (c.pages || []).slice(0, 15).map((p) => `<tr><td class="ellipsis" style="max-width:320px" title="${esc(p.url)}">${esc(clPath(p.url))}</td><td class="mono">${num(p.sessions)}</td><td class="mono">${clPct(p.scrollDepth)}</td><td class="mono">${clDur(p.activeTime)}</td><td class="mono">${num(p.deadClicks)}</td><td class="mono">${num(p.rageClicks)}</td><td class="mono">${num(p.quickbacks)}</td></tr>`).join("");
  const list = (k, title) => { const l = (c.lists || {})[k] || []; return l.length ? `<div><div class="small muted">${title}</div>${l.slice(0, 6).map((x) => `<div class="row small"><span class="ellipsis">${esc(x.name)}</span><span class="spacer"></span><span class="mono">${num(x.sessions)}</span></div>`).join("")}</div>` : ""; };
  const lists = ["devices", "referrers", "countries", "browsers"].map((k, i) => list(k, ["Perangkat", "Datang dari", "Negara", "Browser"][i])).filter(Boolean).join("");
  const hist = (c.history || []).filter((h) => h.sessions != null);
  return `<div class="card">${hdr(`24 jam terakhir${c.at ? ` · dimuat ${esc(ago(c.at))}` : ""} · ${quota}`)}${problem}${tried}
    <div class="grid g4" style="margin:14px 0">
      ${kpi(num(t.sessions), "Sesi", t.bots != null ? `${num(t.bots)} sesi bot` : "")}
      ${kpi(num(t.users), "Pengguna unik", t.pagesPerSession != null ? `${Number(t.pagesPerSession).toFixed(1)} halaman / sesi` : "")}
      ${kpi(clPct(t.scrollDepth), "Scroll rata-rata", "seberapa jauh halaman dibaca")}
      ${kpi(clDur(t.activeTime), "Waktu aktif", t.totalTime != null ? `total ${clDur(t.totalTime)}` : "")}
    </div>
    <div class="row wrap" style="gap:6px">${issue("deadClicks", "Dead click", "Klik pada sesuatu yang tidak bisa diklik")}${issue("rageClicks", "Rage click", "Klik berulang karena frustrasi")}${issue("quickbacks", "Quick back", "Langsung kembali setelah membuka halaman")}${issue("excessiveScroll", "Scroll berlebihan", "Scroll naik-turun mencari sesuatu")}${issue("scriptErrors", "Error script", "Error JavaScript di halaman")}${issue("errorClicks", "Klik error", "Klik yang memicu error")}</div>
    ${hist.length > 1 ? `<h3 style="margin-top:16px;font-size:12px">Sesi per hari (riwayat Raphael)</h3>${barsChart(hist, "sessions")}` : ""}
    ${pages ? `<div class="scroll-x" style="margin-top:14px"><table class="tbl"><tr><th>Halaman</th><th>Sesi</th><th>Scroll</th><th>Aktif</th><th>Dead</th><th>Rage</th><th>Quick back</th></tr>${pages}</table></div>` : ""}
    ${lists ? `<div class="grid g4" style="margin-top:14px">${lists}</div>` : ""}
    <p class="small muted" style="margin-top:12px">Klik kontak (WhatsApp, email, telepon, form) tidak ikut diekspor Clarity. Lihat di Clarity → <b>Recordings</b> atau <b>Dashboard</b> → filter <b>Custom events</b>: <span class="mono">kontak_whatsapp</span>, <span class="mono">kontak_email</span>, <span class="mono">kontak_telepon</span>, <span class="mono">buka_halaman_kontak</span>, <span class="mono">kirim_form</span>.</p>
  </div>`;
}
const cfCount = (v) => Number.isFinite(Number(v)) ? Math.max(0, Number(v)) : 0;
const cfDays = (z) => (z.days || []).filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d.date || "")).sort((a, b) => a.date.localeCompare(b.date));
const cfSum = (z, key) => (z.days || []).reduce((a, d) => a + cfCount(d[key]), 0);
const cfDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || "") ? new Date(d + "T00:00:00Z").toLocaleDateString("id-ID", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }) : "–";
let cfNames;
try { cfNames = new Intl.DisplayNames(["id"], { type: "region" }); } catch { /* country codes remain readable */ }
function cfCountryName(code) {
  if (code === "UNASSIGNED") return "Asal belum dilaporkan";
  if (["?", "XX", "ZZ", ""].includes(code)) return "Lokasi tidak diketahui";
  if (code === "T1") return "Jaringan Tor";
  const shape = S.worldPaths && S.worldPaths.find((c) => c.code === code);
  try { if (/^[A-Z]{2}$/.test(code)) return (cfNames && cfNames.of(code)) || (shape && shape.name) || code; } catch { /* unsupported region */ }
  return (shape && shape.name) || code;
}
function cfCountries(z) {
  const counts = new Map();
  for (const [raw, value] of z.countries || []) { const c = String(raw || "").trim().toUpperCase(), code = ["", "?", "ZZ"].includes(c) ? "XX" : c; counts.set(code, (counts.get(code) || 0) + cfCount(value)); }
  const remainder = cfSum(z, "requests") - [...counts.values()].reduce((a, n) => a + n, 0);
  if (remainder > 0) counts.set("UNASSIGNED", remainder);
  return [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}
async function loadWorldMap() {
  if (S.worldPaths || S.worldLoading || S.worldError) return;
  S.worldLoading = true;
  try {
    const r = await fetch("/world-countries.json");
    if (!r.ok) throw new Error("HTTP " + r.status);
    const data = await r.json();
    if (!Array.isArray(data.countries)) throw new Error("Format peta tidak valid");
    S.worldSource = data.source;
    S.worldPaths = data.countries.map((country) => ({ code: String(country.code).toUpperCase(), name: country.name,
      path: (country.rings || []).map((ring) => ring.filter((p) => Array.isArray(p) && Number.isFinite(p[0]) && Number.isFinite(p[1]))
        .map((p, i) => `${i ? "L" : "M"}${((p[0] + 180) / 360 * 1000).toFixed(1)},${((90 - p[1]) / 180 * 500).toFixed(1)}`).join(" ") + " Z").join(" "),
    })).filter((c) => (/^[A-Z]{2}$/.test(c.code) || c.code.startsWith("NE-")) && c.path.length > 3);
  } catch (e) { S.worldError = e.message; }
  finally { S.worldLoading = false; if (S.route === "monitor") render(); }
}
function cfOriginMap(z, available = true) {
  const countries = available ? cfCountries(z) : [], counts = new Map(countries), selected = available ? S.filters.cfCountry || "" : "", total = available ? cfSum(z, "requests") : 0;
  const paths = S.worldPaths || [], mapped = new Set(paths.filter((c) => /^[A-Z]{2}$/.test(c.code)).map((c) => c.code)), unmapped = countries.filter(([c]) => !mapped.has(c));
  const maximum = Math.max(1, ...countries.map(([, n]) => n));
  let map;
  if (S.worldError) map = `<div class="cf-map-empty">Peta belum tersedia.${available ? " Semua angka negara tetap dapat dibaca di daftar." : " Data analytics juga belum tersedia."}</div>`;
  else if (!S.worldPaths) map = `<div class="cf-map-empty">Memuat peta dunia…</div>`;
  else map = `<svg class="cf-world-map" viewBox="0 0 1000 500" aria-label="${available ? `Peta asal request untuk ${esc(z.name)}` : "Peta dunia · data asal belum tersedia"}">
    <g aria-label="Negara">${paths.map((c) => { if (!mapped.has(c.code)) return `<path class="cf-map-country neutral" d="${c.path}" fill-rule="evenodd" aria-hidden="true"/>`;
      const value = counts.get(c.code) || 0, label = `${cfCountryName(c.code)} · ${available ? `${num(value)} request` : "data belum tersedia"}`;
      return `<path id="cf-map-${esc(c.code)}" class="cf-map-country ${available ? "" : "no-data"} ${value ? "with-data" : ""} ${selected === c.code ? "selected" : ""}" d="${c.path}" fill-rule="evenodd" style="--heat:${0.2 + 0.8 * Math.sqrt(value / maximum)}" data-code="${esc(c.code)}" ${available ? `data-act="cfCountry" data-v="${esc(c.code)}" role="button" tabindex="0" aria-pressed="${selected === c.code}"` : 'role="img"'} aria-label="${esc(label)}"><title>${esc(label)}</title></path>`;
    }).join("")}</g></svg>`;
  const value = counts.get(selected) || 0;
  const detail = !available ? '<span class="muted">Peta akan menampilkan asal request saat data Cloudflare tersedia.</span>' : selected ? `<b>${esc(cfCountryName(selected))}</b><span class="mono">${num(value)} request${total ? ` · ${(value / total * 100).toFixed(1)}% dari seluruh request domain` : ""}</span>${!mapped.has(selected) ? '<span class="small muted">Asal ini tidak dapat ditempatkan pada peta.</span>' : ""}` : '<span class="muted">Pilih negara pada peta atau daftar untuk melihat jumlah request.</span>';
  return `<div class="cf-origin-grid"><div class="cf-map-panel">
    <div class="row wrap"><h3>Asal request</h3><span class="spacer"></span><span class="small muted">${available ? `${num(countries.filter(([, n]) => n > 0).length)} asal tercatat` : "Belum ada data"}</span></div>
    <p class="small muted">${available ? `Negara asal IP request · seluruh domain ${esc(z.name)}` : "Negara asal IP request akan ditampilkan di peta ini."}</p>
    <div class="cf-map-stage">${map}</div>
    <div class="cf-map-key small"><span class="cf-key-none"></span>${available ? 'Tanpa request tercatat<span class="cf-key-scale"></span>Lebih banyak request' : "Data asal belum tersedia"}</div>
    <div id="cf-country-detail" class="cf-country-detail" aria-live="polite">${detail}</div>
    ${unmapped.length && S.worldPaths ? `<p class="small muted">${num(unmapped.reduce((a, [, n]) => a + n, 0))} request dari ${num(unmapped.length)} asal tidak terpetakan tetap tercantum di daftar.</p>` : ""}
    <p class="tiny muted">Asal diambil dari geolokasi IP, termasuk bot dan API. Warna menunjukkan request, bukan pengunjung unik.${S.worldSource ? ` Peta: ${esc(S.worldSource.name || "Natural Earth")} · ${esc(S.worldSource.license || "")}.` : ""}</p>
    </div><div class="cf-country-list"><div class="row"><h3>Semua asal</h3><span class="spacer"></span><span class="small muted">Request</span></div>
      <div class="cf-country-rows">${countries.map(([c, n]) => `<button id="cf-row-${esc(c)}" class="cf-country-row ${selected === c ? "selected" : ""}" data-act="cfCountry" data-v="${esc(c)}" aria-pressed="${selected === c}"><span class="cf-country-code mono">${c === "UNASSIGNED" ? "–" : esc(c)}</span><span class="cf-country-name">${esc(cfCountryName(c))}${S.worldPaths && !mapped.has(c) ? '<small>Tidak terpetakan</small>' : ""}</span><span class="mono">${num(n)}</span></button>`).join("") || '<div class="cf-map-empty">Belum ada data asal request.</div>'}</div>
    </div></div>`;
}
function cfAnalytics(cf) {
  // Like the Mac app: a failed refresh keeps the last snapshot (with a note); missing access shows nothing.
  const stale = (cf.state === "error" || cf.state === "loading") && (cf.zones || []).length > 0;
  const zones = cf.state === "ok" || stale ? [...(cf.zones || [])].sort((a, b) => cfSum(b, "requests") - cfSum(a, "requests")) : [];
  const z = zones.find((v) => v.id === S.filters.cfZone) || zones[0] || { name: "Domain belum tersedia", days: [], countries: [], statuses: [] };
  const days = cfDays(z), latest = days[days.length - 1], available = days.length > 0, period = available ? `7 hari · ${days.length} hari tersedia` : "Belum ada data harian", metric = (key, value, label, note) => `<div class="kpi" data-metric="${key}"><div class="v">${value}</div><div class="l">${label}</div><div class="n">${note}</div></div>`;
  const status = { noToken: "Hubungkan Cloudflare untuk memuat statistik pengunjung.", noPermission: "Token yang ditemukan belum punya izin Analytics. Angka pengunjung dan asal request belum dapat dimuat.", error: "Cloudflare belum berhasil dimuat.", idle: "Sedang menunggu data Cloudflare…", loading: "Sedang memuat data Cloudflare…" }[cf.state] || (!zones.length ? "Token valid, tetapi belum ada zone aktif." : "Belum ada data harian untuk domain ini. Data Cloudflare dapat terlambat; muat ulang setelah tersedia.");
  return `<div class="card cf-analytics"><div class="row wrap"><div><h3>Pengunjung & asal traffic</h3><div class="small muted">Statistik seluruh zone Cloudflare, termasuk semua subdomain.</div></div><span class="spacer"></span>
    <label class="cf-zone-label" for="cf-zone-filter">Domain<select id="cf-zone-filter" ${zones.length ? "" : "disabled"}>${zones.map((v) => `<option value="${esc(v.id)}" ${v.id === z.id ? "selected" : ""}>${esc(v.name)}</option>`).join("") || '<option value="">Belum tersedia</option>'}</select></label></div>
    <div class="cf-kpis grid g4">
      ${metric("latest-uniques", latest ? num(latest.visitors) : "–", "IP unik · data harian terbaru", latest ? esc(cfDate(latest.date)) : "Belum ada data harian")}
      ${metric("daily-uniques", days.length ? num(cfSum(z, "visitors")) : "–", "IP unik · jumlah harian", esc(period))}
      ${metric("requests", days.length ? num(cfSum(z, "requests")) : "–", "Request", esc(period))}
      ${metric("pageviews", days.length ? num(cfSum(z, "pageViews")) : "–", "Pageview", esc(period))}
    </div>
    <p class="small muted cf-metric-note">IP unik dihitung per hari. IP yang kembali pada hari lain dihitung lagi dalam jumlah harian; angka ini bukan jumlah orang unik selama 7 hari. Traffic dapat mencakup bot. ${latest ? `Data terbaru ${esc(cfDate(latest.date))}.` : ""}</p>
    ${stale ? `<div class="cf-analytics-status" data-state="stale" role="status">Data terakhir: ${cf.loadedAt ? esc(ago(cf.loadedAt)) : "sebelumnya"} · ${cf.state === "loading" ? "sedang memperbarui" : "pembaruan gagal"}. Angka dan peta memakai snapshot sebelumnya.</div>` : ""}
    ${available ? "" : `<div class="cf-analytics-status" data-state="${esc(cf.state || "idle")}" role="status">${esc(status)}</div>`}
    <div class="cf-trends grid g2"><div id="cf-unique-trend"><h3>IP unik per hari</h3>${available ? barsChart(days, "visitors", "var(--green)") : '<div class="cf-trend-placeholder">Belum ada data harian</div>'}</div><div id="cf-request-trend"><h3>Request per hari</h3>${available ? barsChart(days, "requests") : '<div class="cf-trend-placeholder">Belum ada data harian</div>'}</div></div>
    ${cfOriginMap(z, available)}
    <div class="cf-analytics-foot"><span>${available ? `Bandwidth ${bytes(cfSum(z, "bytes"))} · cache ${cfSum(z, "requests") ? Math.round(cfSum(z, "cached") / cfSum(z, "requests") * 100) : 0}% · ${num(cfSum(z, "threats"))} ancaman` : "Bandwidth – · cache – · ancaman –"}</span><span>Status edge: ${available ? (z.statuses || []).map(([c, n]) => `${esc(c)}: ${num(n)}`).join(" · ") || "belum ada data" : "–"}</span></div>
  </div>`;
}
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
  let analytics = cfAnalytics(cf);
  if (cf.state !== "ok") {
    const msg = { noToken: "Belum ada token Cloudflare.", noPermission: "Token Cloudflare yang ditemukan tidak punya izin Analytics.", idle: "Memuat…", loading: "Memuat…", error: "Cloudflare menolak permintaan." }[cf.state] || cf.state;
    analytics += `<div class="card cf-connection-info"><h3>Cloudflare Analytics · 7 hari</h3><p><b>${esc(msg)}</b></p>
      ${(cf.tried || []).map((t) => `<div class="small mono muted">• ${esc(t.source)}: ${esc(t.result)}</div>`).join("")}
      <p class="small muted">Buat token di dash.cloudflare.com → My Profile → API Tokens → template <b>"Read analytics and logs"</b>. Simpan di <span class="mono">~/.hermes/.env</span> di server ini sebagai <span class="mono">CLOUDFLARE_API_TOKEN_FULL=…</span> (lewat Raphael Mac → Knowledge → .env), lalu klik Muat ulang. Token dibaca di server dan tidak pernah dikirim ke browser.</p>
      <button class="btn" data-act="cf">Muat ulang Cloudflare</button></div>`;
  }
  return head("Traffic", `Cloudflare Tunnel (langsung dari cloudflared) dan Cloudflare Analytics${cf.state === "ok" && cf.loadedAt ? ` · dimuat ${ago(cf.loadedAt)}` : ""}`, `${refreshBtn}<button class="btn" data-act="cf">Muat ulang analytics</button>`) +
    `<div class="stack">${clarityCard()}${analytics}${tunnels}</div>`;
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
const compact = (n) => { const v = Number(n) || 0, a = Math.abs(v);
  return a >= 1e9 ? (v / 1e9).toFixed(2) + "B" : a >= 1e6 ? (v / 1e6).toFixed(1) + "M" : a >= 1e3 ? (v / 1e3).toFixed(1) + "K" : String(Math.round(v)); };
const SERIES = ["var(--violet)", "var(--mint)", "var(--blue)", "var(--orchid)", "var(--amber)", "#0EA5B7", "var(--red)", "#6366F1", "#84CC16"];

/** Line chart like the Mac app's Swift Charts: shared y axis on the right, grid, first series filled. */
function lineChart(days, series, height = 260) {
  const w = 1000, h = height, L = 12, R = 70, T = 10, B = 26, n = days.length;
  if (!n) return '<div class="muted small">Belum ada data</div>';
  const hi = Math.max(1, ...days.flatMap((d) => series.map((sr) => d[sr.key] || 0)));
  const mag = Math.pow(10, Math.floor(Math.log10(hi / 4))), step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((x) => hi / x <= 4) || mag * 10, top = Math.ceil(hi / step) * step;
  const x = (i) => L + (n === 1 ? (w - L - R) / 2 : (i / (n - 1)) * (w - L - R)), y = (v) => T + (1 - v / top) * (h - T - B);
  let g = "";
  for (let v = 0; v <= top + 1e-9; v += step) g += `<line x1="${L}" x2="${w - R}" y1="${y(v)}" y2="${y(v)}" stroke="var(--line)"/><text x="${w - R + 10}" y="${y(v) + 4}">${compact(v)}</text>`;
  days.forEach((d, i) => { g += `<line x1="${x(i)}" x2="${x(i)}" y1="${T}" y2="${h - B}" stroke="var(--line)" stroke-dasharray="3 4"/><text x="${x(i)}" y="${h - 6}" text-anchor="middle">${esc((d.date || "").slice(5))}</text>`; });
  const lines = series.map((sr, k) => {
    const pts = days.map((d, i) => [x(i), y(d[sr.key] || 0)]), path = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join("");
    const area = k === 0 ? `<path d="${path}L${pts[n - 1][0]},${y(0)}L${pts[0][0]},${y(0)}Z" fill="${sr.color}" opacity=".10"/>` : "";
    return area + `<path d="${path}" fill="none" stroke="${sr.color}" stroke-width="2.5" stroke-linejoin="round"/>` +
      pts.map((p, i) => `<circle cx="${p[0]}" cy="${p[1]}" r="3.5" fill="${sr.color}"><title>${esc(sr.label)} ${esc(days[i].date)}: ${num(days[i][sr.key])}</title></circle>`).join("");
  }).join("");
  return `<div class="legend">${series.map((sr) => `<span><i style="background:${sr.color}"></i>${esc(sr.label)}</span>`).join("")}</div>
    <svg class="lchart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" style="height:${h}px">${g}${lines}</svg>`;
}

/** "Dari mana" / "Model" cards: one stacked bar, then rows with value and share. */
function breakdown(title, items) {
  const total = items.reduce((a, b) => a + (b.tokens || 0), 0) || 1;
  const bar = items.map((b, i) => `<i style="flex:${b.tokens || 0};background:${SERIES[i % SERIES.length]}" title="${esc(b.name)}"></i>`).join("");
  const rows = items.slice(0, 6).map((b, i) => `<div class="brow"><span class="sq" style="background:${SERIES[i % SERIES.length]}"></span><span class="ellipsis" title="${esc(b.name)} · ${num(b.sessions)} sesi · ${num(b.calls)} panggilan">${esc(b.name)}</span><span class="num">${compact(b.tokens)}</span><span class="pc">${Math.round((b.tokens || 0) / total * 100)}%</span></div>`).join("");
  return `<div class="card"><div class="lbl">${esc(title)}</div>${items.length ? `<div class="stackbar">${bar}</div>${rows}` : '<div class="muted small" style="margin-top:10px">–</div>'}</div>`;
}

function agents() {
  const a = S.agents;
  if (!a) return head("Agents & Token", "Memuat…");
  if (a.error) return head("Agents & Token", esc(a.error));
  const sel = `<select id="profileSel">${a.profiles.map((p) => `<option value="${esc(p.id)}" ${p.id === a.profile ? "selected" : ""}>${esc(p.name)}</option>`).join("")}</select>`;
  const s = a.snapshot;
  if (!s || s.error) return head("Agents & Token", esc((s && s.error) || "Tidak ada data"), sel);
  const prof = (a.profiles.find((p) => p.id === a.profile) || {}).name || "Hermes";
  const all = s.allTime, total = all.input + all.cacheRead + all.output;
  const sum = (k) => s.days.reduce((x, d) => x + (d[k] || 0), 0);
  const week = sum("tokens"), weekCalls = sum("calls"), ctx = weekCalls ? (sum("input") + sum("cacheRead")) / weekCalls : 0;
  const cacheRatio = sum("input") + sum("cacheRead") ? sum("cacheRead") / (sum("input") + sum("cacheRead")) : 0;
  const mini = (l, v, n) => `<div class="mini"><div class="lbl">${l}</div><div class="v">${v}</div><div class="n">${n}</div></div>`;
  const stat = (l, v, n, color = "") => `<div class="card stat"><div class="lbl">${l}</div><div class="v" ${color ? `style="color:${color}"` : ""}>${v}</div><div class="n">${n}</div></div>`;
  const days = s.days.map((d) => ({ ...d, total: d.tokens }));
  const recent = s.recent.map((x) => `<div class="item"><span class="dot ${x.active ? "ok" : ""}"></span><div class="ellipsis" style="flex:1"><b>${esc(x.title)}</b>
      <div class="tiny muted ellipsis">${esc(x.source)} · ${esc(x.model)} · ${num(x.messages)} pesan · ${num(x.toolCalls)} tool</div></div>
      <span class="small muted">${compact(x.input + x.cacheRead + x.output)} · ${ago(x.lastActivity || x.startedAt)}</span></div>`).join("");
  return head("Agents & Token", `Hermes · ${esc(prof)} · berapa token terpakai dan untuk apa`, sel + `<button class="btn" data-act="agentsReload">↻ Refresh</button>`) +
    `<div class="stack">
      <div class="card hero-card"><div><div class="lbl">Total token terpakai · sepanjang waktu</div><div class="big">${num(total)}</div>
        <div class="small muted">${num(all.sessions)} sesi · ${num(all.calls)} panggilan API</div></div>
        <div class="minis">${mini("Hari ini", compact(s.today.tokens), `${num(s.today.calls)} call`)}${mini("7 hari", compact(week), `${num(weekCalls)} call`)}
          ${mini("Input baru", compact(all.input), "semua waktu")}${mini("Cache read", compact(all.cacheRead), "konteks diulang")}${mini("Output", compact(all.output), "jawaban")}</div></div>
      <div class="grid g3">
        ${stat("Konteks / panggilan", compact(ctx), ctx > 30000 ? "terlalu besar · target &lt; 30K" : "sehat · target &lt; 30K", ctx > 30000 ? "var(--red)" : "var(--green)")}
        ${stat("Rasio cache", `${Math.round(cacheRatio * 100)}%`, "makin tinggi makin murah")}
        ${stat("State.db", bytes(s.dbBytes), all.cost ? `biaya tercatat $${all.cost.toFixed(2)}` : "database sesi Hermes")}
      </div>
      <div class="card"><div class="lbl">Token per hari · 7 hari</div>${lineChart(days, [
        { key: "total", label: "Total", color: "var(--violet)" }, { key: "cacheRead", label: "Cache read", color: "var(--orchid)" },
        { key: "input", label: "Input baru", color: "var(--blue)" }, { key: "output", label: "Output", color: "var(--mint)" }])}</div>
      <div class="grid g2">${breakdown("Dari mana · 7 hari", s.sources)}${breakdown("Model · 7 hari", s.models)}</div>
      <div class="card"><div class="lbl" style="margin-bottom:6px">Sesi terbaru</div><div class="list">${recent || '<div class="muted">Belum ada sesi.</div>'}</div></div>
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
  else if (act === "cf") { api("POST", "/api/cloudflare").then(() => toast("Memuat Cloudflare…")).catch((x) => toast(x.message, true)); setTimeout(tick, 5000); }
  else if (act === "clarity") { api("POST", "/api/clarity").then(() => { toast("Memuat Clarity…"); setTimeout(() => loadClarity(true), 8000); }).catch((x) => toast(x.message, true)); }
  else if (act === "cfCountry") { S.filters.cfCountry = v; render(); }
  else if (act === "hours") { S.filters.hours = Number(v); render(); }
  else if (act === "toggle") { S.filters[v] = !S.filters[v]; render(); }
  else if (act === "job") { S.filters["job:" + v] = !S.filters["job:" + v]; render(); }
  else if (act === "view") { S.filters.view = v; render(); }
  else if (act === "newProject") projectDialog(null);
  else if (act === "discover") toast("Penemuan project (dari ~/Projects, GitHub, Vercel dan Monitor) berjalan di app Mac; hasilnya tersinkron ke sini.");
  else if (act === "pview") { S.filters.pview = v; render(); }
  else if (act === "akind") { S.filters.akind = v; render(); }
  else if (act === "openProject") location.hash = `#/project/${v}`;
  else if (act === "wsSync") loadWs().then(() => { render(); toast("Workspace dimuat ulang"); });
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
document.addEventListener("keydown", (e) => {
  if ((e.key === "Enter" || e.key === " ") && e.target.matches(".cf-map-country")) { e.preventDefault(); S.filters.cfCountry = e.target.dataset.v; render(); }
});
document.addEventListener("input", (e) => {
  if (e.target.id === "jobq") { S.filters.jobq = e.target.value; render(); }
  if (e.target.id === "pq" || e.target.id === "prq") { S.filters[e.target.id] = e.target.value; render(); }
  if (e.target.id === "meName") { try { localStorage.setItem("raphaelMe", e.target.value.trim() || "Saya"); } catch { /* ignore */ } render(); }
});
document.addEventListener("change", (e) => {
  if (e.target.dataset.act === "pfav") { S.filters.pfav = e.target.checked; render(); }
  if (e.target.dataset.act === "ppaused") { S.filters.ppaused = e.target.checked; render(); }
  if (e.target.dataset.act === "unassigned") { S.filters.unassigned = e.target.checked; render(); }
  if (e.target.id === "adays") { S.filters.adays = Number(e.target.value); render(); }
  if (e.target.id === "aproj") { S.filters.aproj = e.target.value; render(); }
  if (e.target.id === "cf-zone-filter") { S.filters.cfZone = e.target.value; S.filters.cfCountry = ""; render(); }
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
let savedTheme = "light"; try { savedTheme = localStorage.getItem("raphaelTheme") || "light"; } catch { /* ignore */ }   // the Mac app is light by default too
applyTheme(savedTheme);

// Routing & polling
function route() {
  let [r, arg] = location.hash.replace(/^#\/?/, "").split("/");
  const old = { incidents: "incidents", notify: "notify", jobs: "jobs", traffic: "traffic" };   // earlier web routes → Monitor tabs
  if (old[r]) { location.replace(`#/monitor/${old[r]}`); return; }
  if (r === "projects" && !arg) {                           // like the Mac app: the board of the last (or first active) project
    const ps = S.ws ? S.ws.projects.filter((p) => p.lifecycle !== "archived") : [];
    let last = ""; try { last = localStorage.getItem("raphaelLastProject") || ""; } catch { /* ignore */ }
    const p = ps.find((x) => x.id === last) || ps[0];
    if (p) { location.replace(`#/project/${p.id}`); return; }
  }
  if (r === "project" && arg) { try { localStorage.setItem("raphaelLastProject", decodeURIComponent(arg)); } catch { /* ignore */ } }
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
    out.push({ t: n.name, s: "Server", h: `#/monitor/servers|${n.id}`, ico: "▤" });
    ((n.detail && n.detail.jobs) || []).filter((j) => !j.system).forEach((j) => out.push({ t: j.name, s: `Job · ${n.name}`, h: "#/jobs", ico: "◷", job: `${n.id}|${j.id}` }));
    ((n.detail && n.detail.containers) || []).forEach((c) => out.push({ t: c.name, s: `Container · ${n.name}`, h: "#/monitor/apps", ico: "▣" }));
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
