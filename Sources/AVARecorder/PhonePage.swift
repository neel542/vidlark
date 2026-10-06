import Foundation

/// The page a phone opens from its QR code. It holds the phone's camera, makes each picture into
/// H.264 with the phone's own encoder (WebCodecs), times it on the Mac's clock and sends it in small
/// batches over the one secure connection. The picture is Wide (1920 x 1080) or Tall (1080 x 1920),
/// picked on the phone and kept however the phone turns. Nothing to install: Safari on iOS 16.4 or
/// newer, or Chrome on Android.
enum PhonePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0E1110">
<meta name="robots" content="noindex">
<title>AVA camera</title>
<style>
:root { --body: #0E1110; --face: #151917; --raised: #1B201E; --well: #070908; --hair: rgba(255,255,255,.075);
  --engraved: #86918B; --dim: #A3ADA8; --ink: #ECF1EE; --signal: #3DCC80; --amber: #E8B34B; --red: #F04E3E;
  --ratio: 16 / 9; --ease: cubic-bezier(.16, 1, .3, 1); }
body.tall { --ratio: 9 / 16; }
html, body { margin: 0; background: var(--body); color: var(--ink); -webkit-text-size-adjust: 100%;
  font: 15px/1.45 -apple-system, system-ui, sans-serif; -webkit-tap-highlight-color: transparent; }
::selection { background: rgba(61,204,128,.32); color: var(--ink); }
button { appearance: none; margin: 0; font: inherit; color: inherit; touch-action: manipulation; -webkit-user-select: none; user-select: none; cursor: pointer; }
button:focus { outline: none; }
button:focus-visible { outline: 2px solid var(--signal); outline-offset: 2px; }
button:disabled { cursor: default; }
svg { flex: none; width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.75; stroke-linecap: round; stroke-linejoin: round; }
[hidden] { display: none !important; }

main { box-sizing: border-box; min-height: 100svh; max-width: 760px; margin: 0 auto; display: flex; flex-direction: column; gap: 14px;
  padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(20px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left)); }
header { display: flex; align-items: center; gap: 10px; }
h1 { flex: 1; margin: 0; font-size: 15px; font-weight: 600; }
h1 small { margin-left: 6px; color: var(--engraved); font-size: 11px; font-weight: 600; letter-spacing: .1em; text-transform: uppercase; }
.lamp { flex: none; width: 9px; height: 9px; border-radius: 50%; background: var(--engraved); opacity: .5; }
.lamp.ok { opacity: 1; background: radial-gradient(circle at 40% 35%, #B4F5D0, var(--signal) 62%); }
.lamp.warn { opacity: 1; background: radial-gradient(circle at 40% 35%, #FBE3AE, var(--amber) 62%); }
.lamp.rec { opacity: 1; background: radial-gradient(circle at 40% 35%, #FFB8AE, var(--red) 62%); animation: breathe 1.4s ease-in-out infinite alternate; }
@keyframes breathe { from { opacity: .45; } to { opacity: 1; } }
.state { color: var(--dim); font-size: 13px; font-variant-numeric: tabular-nums; }

/* The viewfinder: the picture in the shape it is sent, on the page or filling the phone. */
.view { position: relative; display: flex; align-items: center; justify-content: center; background: var(--well);
  border: 1px solid var(--hair); border-radius: 12px; overflow: hidden; }
.frame { position: relative; aspect-ratio: var(--ratio); width: min(100%, calc(62svh * 16 / 9)); overflow: hidden; background: #000; }
body.tall .frame { width: auto; height: min(56svh, 560px); }
video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; visibility: hidden; }
video.on { visibility: visible; }
.veil { position: absolute; inset: 0; z-index: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px;
  padding: 18px; text-align: center; background: rgba(0,0,0,.62); }
.veil b { font-size: 17px; font-weight: 600; }
.veil span { max-width: 34ch; color: var(--dim); font-size: 13px; }
.hint { position: absolute; z-index: 1; left: 50%; bottom: 12px; transform: translateX(-50%); width: max-content; max-width: calc(100% - 24px);
  box-sizing: border-box; display: flex; gap: 10px; align-items: flex-start; padding: 10px 14px; border-radius: 12px;
  background: rgba(7,9,8,.78); border: 1px solid var(--hair); -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px); }
.hint .lamp { margin-top: 6px; }
.hint b { display: block; font-size: 15px; font-weight: 600; }
.hint span { display: block; max-width: 30ch; color: var(--dim); font-size: 13px; line-height: 1.35; }

/* Full screen: the page steps back and the picture fills the phone, with a thin bar at each end. */
.bar { display: none; }
body.full { overflow: hidden; }
body.full .view { position: fixed; inset: 0; z-index: 20; border: 0; border-radius: 0; background: #000; }
body.full .frame { width: min(100vw, calc(100dvh * 16 / 9)); height: auto; }
body.full.tall .frame { width: auto; height: min(100dvh, calc(100vw * 16 / 9)); }
body.full .bar { position: absolute; left: 0; right: 0; z-index: 2; display: flex; align-items: center; gap: 10px;
  padding-left: max(16px, env(safe-area-inset-left)); padding-right: max(16px, env(safe-area-inset-right)); }
body.full .bar.top { top: 0; padding-top: max(12px, env(safe-area-inset-top)); padding-bottom: 28px;
  background: linear-gradient(rgba(0,0,0,.6), rgba(0,0,0,0)); }
body.full .bar.bottom { bottom: 0; justify-content: space-between; padding-bottom: max(14px, env(safe-area-inset-bottom)); padding-top: 28px;
  background: linear-gradient(rgba(0,0,0,0), rgba(0,0,0,.6)); }
body.full .hint { bottom: calc(84px + env(safe-area-inset-bottom)); }
.bar .who { flex: 1; font-size: 13px; font-weight: 600; text-shadow: 0 1px 2px rgba(0,0,0,.5); }
.bar .who small { margin-left: 6px; color: var(--dim); font-size: 11px; letter-spacing: .1em; text-transform: uppercase; }
.bar .state { color: var(--ink); text-shadow: 0 1px 2px rgba(0,0,0,.5); }
.round { display: inline-flex; align-items: center; justify-content: center; gap: 7px; height: 44px; min-width: 44px; padding: 0 14px;
  border: 1px solid rgba(255,255,255,.14); border-radius: 22px; background: rgba(14,17,16,.62); color: var(--ink);
  font-size: 15px; font-weight: 500; -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px);
  transition: background-color .2s var(--ease), transform .2s var(--ease); }
.round.icon { padding: 0; }
.round:active { transform: scale(.96); background: rgba(27,32,30,.8); }

/* The shape: one choice of two, picked before the camera starts and locked while AVA records. */
.shape { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; padding: 4px; border: 1px solid var(--hair); border-radius: 14px; background: var(--face); }
.shape button { display: flex; align-items: center; gap: 12px; padding: 12px; border: 1px solid transparent; border-radius: 10px;
  background: transparent; color: var(--dim); text-align: left; transition: background-color .2s var(--ease), color .2s var(--ease); }
.shape button svg { width: 26px; height: 26px; stroke-width: 1.6; }
.shape button b { display: block; color: inherit; font-size: 15px; font-weight: 600; }
.shape button span { display: block; color: var(--engraved); font-size: 13px; font-variant-numeric: tabular-nums; }
.shape button[aria-pressed="true"] { background: var(--raised); border-color: var(--hair); color: var(--ink); }
.shape button[aria-pressed="true"] svg { color: var(--signal); }
.shape button:disabled:not([aria-pressed="true"]) { opacity: .4; }
.mini { display: inline-flex; padding: 3px; gap: 2px; border: 1px solid rgba(255,255,255,.14); border-radius: 22px;
  background: rgba(14,17,16,.62); -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px); }
.mini button { display: inline-flex; align-items: center; gap: 6px; height: 36px; padding: 0 12px; border: 0; border-radius: 18px;
  background: transparent; color: var(--dim); font-size: 13px; font-weight: 600; font-variant-numeric: tabular-nums; }
.mini button svg { width: 16px; height: 16px; }
.mini button[aria-pressed="true"] { background: rgba(255,255,255,.12); color: var(--ink); }
.mini button[aria-pressed="true"] svg { color: var(--signal); }
.mini button:disabled:not([aria-pressed="true"]) { opacity: .4; }
.locked { margin: 0; color: var(--engraved); font-size: 13px; }

.go { width: 100%; padding: 16px; border: 0; border-radius: 14px; background: var(--signal); color: #06130C; font-size: 17px; font-weight: 600; }
.go:active { filter: brightness(.92); }
.go:disabled { opacity: .5; }
.tools { display: flex; gap: 10px; align-items: center; }
.small { display: inline-flex; align-items: center; gap: 8px; padding: 10px 14px; border: 1px solid var(--hair); border-radius: 10px;
  background: var(--face); color: var(--ink); font-size: 15px; font-weight: 500; }
.small svg { width: 18px; height: 18px; }
.small:active { background: var(--raised); }
.facts { flex: 1; text-align: right; color: var(--engraved); font-size: 11px; font-weight: 600; letter-spacing: .1em; text-transform: uppercase; }
ol { margin: 0; padding-left: 20px; color: var(--dim); font-size: 15px; }
ol li { margin: 5px 0; }
.note { margin: 0; color: var(--amber); font-size: 15px; }
@media (prefers-reduced-motion: reduce) { .lamp.rec { animation: none; } .round, .shape button { transition: none; } }
</style>
</head>
<body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <symbol id="i-wide" viewBox="0 0 24 24"><rect x="2.5" y="6.5" width="19" height="11" rx="2.2"/></symbol>
  <symbol id="i-tall" viewBox="0 0 24 24"><rect x="6.5" y="2.5" width="11" height="19" rx="2.2"/></symbol>
  <symbol id="i-flip" viewBox="0 0 24 24"><path d="M4.5 11a7.5 7.5 0 0 1 13-4.2L19.5 9"/><path d="M19.5 4.5V9H15"/><path d="M19.5 13a7.5 7.5 0 0 1-13 4.2L4.5 15"/><path d="M4.5 19.5V15H9"/></symbol>
  <symbol id="i-out" viewBox="0 0 24 24"><path d="M9 4v5H4"/><path d="M15 4v5h5"/><path d="M9 20v-5H4"/><path d="M15 20v-5h5"/></symbol>
  <symbol id="i-in" viewBox="0 0 24 24"><path d="M4 9V4h5"/><path d="M20 9V4h-5"/><path d="M4 15v5h5"/><path d="M20 15v5h-5"/></symbol>
</svg>
<main>
  <header><i class="lamp" data-lamp></i><h1>AVA camera<small data-phone></small></h1><span class="state" data-state>Not started</span></header>
  <div class="view" id="view">
    <div class="frame">
      <video id="v" playsinline muted autoplay></video>
    </div>
    <div class="veil" id="veil"><b id="veilTitle">This phone becomes a camera for AVA</b><span id="veilText">Pick the shape, then tap Start camera. The picture goes to AVA Recorder on the Mac, over your Wi-Fi.</span></div>
    <div class="hint" id="hint" hidden><i class="lamp warn"></i><div><b id="hintTitle"></b><span id="hintText"></span></div></div>
    <div class="bar top">
      <i class="lamp" data-lamp></i><span class="who">AVA camera<small data-phone></small></span><span class="state" data-state></span>
    </div>
    <div class="bar bottom">
      <button class="round icon" data-flip aria-label="Use the other camera"><svg><use href="#i-flip"/></svg></button>
      <div class="mini" role="group" aria-label="Picture shape">
        <button data-shape="wide" aria-pressed="true"><svg><use href="#i-wide"/></svg>16:9</button>
        <button data-shape="tall" aria-pressed="false"><svg><use href="#i-tall"/></svg>9:16</button>
      </div>
      <button class="round" id="exit"><svg><use href="#i-out"/></svg>Exit</button>
    </div>
  </div>
  <p class="note" id="note" hidden></p>
  <div class="shape" role="group" aria-label="Picture shape">
    <button data-shape="wide" aria-pressed="true"><svg><use href="#i-wide"/></svg><div><b>Wide</b><span>16:9 · YouTube</span></div></button>
    <button data-shape="tall" aria-pressed="false"><svg><use href="#i-tall"/></svg><div><b>Tall</b><span>9:16 · Shorts, Reels</span></div></button>
  </div>
  <p class="locked" id="locked" hidden>The shape stays as it is while AVA records.</p>
  <button class="go" id="go">Start camera</button>
  <div class="tools" id="tools" hidden>
    <button class="small" data-flip><svg><use href="#i-flip"/></svg><span data-flipword>Front camera</span></button>
    <button class="small" id="full"><svg><use href="#i-in"/></svg>Full screen</button>
    <span class="facts" id="facts"></span>
  </div>
  <ol id="tips">
    <li>Wide is for YouTube, Tall for Shorts. The picture keeps that shape however the phone turns.</li>
    <li>Keep this page open. The screen stays on by itself.</li>
    <li>For a long take, plug the phone in to charge.</li>
  </ol>
</main>
<script>
"use strict";
// /<secret>/<n>/ is phone n's page; it posts to /<secret>/<n>/send. Without a number it is phone 1.
const parts = location.pathname.split("/").filter(Boolean);
const numbered = /^[0-9]+$/.test(parts[1] || "");
const base = "/" + parts[0] + "/" + (numbered ? parts[1] + "/" : "");
const phone = numbered ? parts[1] : "1";
const sid = Math.random().toString(36).slice(2) + Date.now().toString(36);
const $ = id => document.getElementById(id);
const all = sel => document.querySelectorAll(sel);
let shape = "wide";
try { if (localStorage.getItem("ava-shape") === "tall") shape = "tall"; } catch (e) {}
let W = 1920, H = 1080;
let stream = null, encoder = null, canvas = null, ctx = null, config = null, wakeLock = null;
let running = false, facing = "environment", resting = false, recording = false, full = false;
let offset = null, clock = [], failures = 0, lastPost = 0;
let queue = [], queued = 0, forceKey = true, needKey = false, frames = 0, formatRec = null, formatKey = "";
let sentCount = 0, sentSince = performance.now(), fps = 0;

all("[data-phone]").forEach(e => e.textContent = "Phone " + phone);
document.title = "AVA camera · Phone " + phone;

function setState(text, lamp) {
  all("[data-state]").forEach(e => e.textContent = text);
  all("[data-lamp]").forEach(e => e.className = "lamp " + (lamp || ""));
}
function veil(title, text) {
  if (title === null) { $("veil").hidden = true; return; }
  $("veil").hidden = false; $("veilTitle").textContent = title; $("veilText").textContent = text || "";
}
function note(text) { $("note").hidden = !text; $("note").textContent = text || ""; }

// The phone is turned the other way from the shape: the picture keeps its shape and films the middle.
function turned() {
  const v = $("v");
  return running && v.videoWidth > 0 && (v.videoWidth > v.videoHeight) !== (shape === "wide");
}

function show() {
  syncShape();
  $("hint").hidden = true;
  if (!running) return;
  if (resting) { setState("Resting", ""); veil("AVA is resting the camera", "It wakes by itself when someone looks at AVA on the Mac."); return; }
  veil(null);
  if (turned()) {
    $("hint").hidden = false;
    $("hintTitle").textContent = shape === "wide" ? "Turn the phone sideways" : "Hold the phone upright";
    $("hintText").textContent = shape === "wide"
      ? "AVA keeps the picture 16:9 and films the middle until you do. If it is already sideways, switch rotation lock off."
      : "AVA keeps the picture 9:16 and films the middle until you do. If it is already upright, switch rotation lock off.";
  }
  if (failures > 2) setState("Cannot reach the Mac", "warn");
  else if (recording) setState("Recording", "rec");
  else setState("Sending to AVA", "ok");
  $("facts").textContent = fps ? `${Math.min(W, H)}p · ${fps} fps` : "";
}

function syncShape() {
  document.body.classList.toggle("tall", shape === "tall");
  all("[data-shape]").forEach(b => { b.setAttribute("aria-pressed", String(b.dataset.shape === shape)); b.disabled = recording; });
  $("locked").hidden = !recording;
  all("[data-flipword]").forEach(e => e.textContent = facing === "user" ? "Back camera" : "Front camera");
}

// One batch to the Mac. The reply carries the Mac's clock: the quickest round trips of the last
// forty give the gap between the two clocks, so every picture is timed as the Mac sees it.
async function post(body) {
  const t1 = performance.now();
  const r = await fetch(base + "send", { method: "POST", body, cache: "no-store",
    headers: { "Content-Type": "application/octet-stream", "X-Session": sid } });
  const t4 = performance.now();
  lastPost = t4;
  if (!r.ok) throw new Error("The Mac answered " + r.status);
  const j = await r.json();
  clock.push([t4 - t1, j.mac - (t1 + t4) / 2]);
  if (clock.length > 40) clock.shift();
  offset = clock.reduce((a, b) => b[0] < a[0] ? b : a)[1];
  return j;
}

function handle(j) {
  if (j.replaced) { stop(); veil("Another phone took over", "Another phone or tab opened this same code, so AVA uses that one now. Tap Start camera to take it back."); return; }
  if (j.key) forceKey = true;
  if (j.rest !== resting) { resting = j.rest; forceKey = true; }
  recording = j.recording;
  show();
}

async function pump() {
  while (running) {
    const now = performance.now();
    if (!queue.length) {
      // Nothing to send: a quiet hello now and then keeps the clock right and hears when to wake.
      if (now - lastPost > 500) { try { handle(await post(new Uint8Array(0))); failures = 0; } catch (e) { failures++; show(); await pause(400); } }
      else await pause(15);
      continue;
    }
    const batch = queue; queue = []; queued = 0;
    let size = 0; for (const b of batch) size += b.byteLength;
    const body = new Uint8Array(size); let at = 0;
    for (const b of batch) { body.set(new Uint8Array(b), at); at += b.byteLength; }
    try {
      handle(await post(body)); failures = 0;
      sentCount += batch.length;
      if (now - sentSince > 2000) { fps = Math.round(sentCount * 1000 / (now - sentSince)); sentCount = 0; sentSince = now; }
    } catch (e) {
      failures++; show();
      // A Wi-Fi hiccup: keep what is waiting, up to about 4 seconds of pictures, and try again.
      queue = batch.concat(queue);
      queued = queue.reduce((n, b) => n + b.byteLength, 0);
      if (queued > 4000000) { queue = formatRec ? [formatRec] : []; queued = 0; needKey = true; forceKey = true; }
      await pause(400);
    }
  }
}
const pause = ms => new Promise(r => setTimeout(r, ms));

function formatRecord(desc, w, h) {
  const d = desc instanceof ArrayBuffer ? new Uint8Array(desc) : new Uint8Array(desc.buffer, desc.byteOffset, desc.byteLength);
  const b = new ArrayBuffer(9 + d.byteLength), v = new DataView(b);
  v.setUint8(0, 1); v.setUint16(1, w, true); v.setUint16(3, h, true); v.setUint32(5, d.byteLength, true);
  new Uint8Array(b, 9).set(d);
  return b;
}

function pictureRecord(chunk, macMs) {
  const b = new ArrayBuffer(14 + chunk.byteLength), v = new DataView(b);
  v.setUint8(0, 2); v.setUint8(1, chunk.type === "key" ? 1 : 0); v.setFloat64(2, macMs, true); v.setUint32(10, chunk.byteLength, true);
  chunk.copyTo(new Uint8Array(b, 14));
  return b;
}

function makeOutput(w, h) {
  return (chunk, meta) => {
    const desc = meta && meta.decoderConfig && meta.decoderConfig.description;
    if (desc) {
      const rec = formatRecord(desc, w, h), key = Array.from(new Uint8Array(rec)).join(",");
      if (key !== formatKey) { formatKey = key; formatRec = rec; queue.push(rec); }
    }
    if (needKey) { if (chunk.type !== "key") return; needKey = false; }
    if (offset === null) return;
    const rec = pictureRecord(chunk, chunk.timestamp / 1000 + offset);
    queue.push(rec); queued += rec.byteLength;
  };
}

async function makeEncoder() {
  config = null;
  for (const codec of ["avc1.640028", "avc1.4d0028", "avc1.42e028"]) {
    const c = { codec, width: W, height: H, bitrate: 8000000, framerate: 30, latencyMode: "realtime", avc: { format: "avc" } };
    try { if ((await VideoEncoder.isConfigSupported(c)).supported) { config = c; break; } } catch (e) {}
  }
  if (!config) throw new Error("no H.264");
  const made = new VideoEncoder({ output: makeOutput(W, H), error: e => { stop(); note("The picture encoder stopped (" + e.message + "). Tap Start camera again."); } });
  made.configure(config);
  encoder = made;
}

function frame(now, meta) {
  if (!running) return;
  const v = $("v");
  v.requestVideoFrameCallback(frame);
  if (resting || offset === null || document.hidden || !v.videoWidth) return;
  if (!encoder || encoder.state !== "configured" || encoder.encodeQueueSize > 3) return;
  // Fill the chosen shape, trimming whatever does not fit: turning the phone never changes it.
  const s = Math.max(W / v.videoWidth, H / v.videoHeight), dw = v.videoWidth * s, dh = v.videoHeight * s;
  ctx.drawImage(v, (W - dw) / 2, (H - dh) / 2, dw, dh);
  const taken = meta && meta.captureTime ? meta.captureTime : now;
  const f = new VideoFrame(canvas, { timestamp: Math.round(taken * 1000) });
  encoder.encode(f, { keyFrame: forceKey || frames % 60 === 0 });
  forceKey = false; frames++;
  f.close();
}

function sizeFor(s) { return s === "tall" ? [1080, 1920] : [1920, 1080]; }

async function setShape(next) {
  if (next === shape || recording) return;
  shape = next;
  try { localStorage.setItem("ava-shape", shape); } catch (e) {}
  [W, H] = sizeFor(shape);
  lockTurning();
  if (running) {
    // A new size is a new encoder; what was waiting at the old size is dropped, and the new
    // format goes first with a whole picture.
    const old = encoder; encoder = null;
    try { if (old && old.state !== "closed") old.close(); } catch (e) {}
    canvas.width = W; canvas.height = H;
    queue = []; queued = 0; formatKey = ""; formatRec = null; forceKey = true; needKey = false; frames = 0;
    try { await makeEncoder(); } catch (e) { stop(); note("This phone cannot make a " + (shape === "tall" ? "tall" : "wide") + " picture. Pick the other shape."); }
  }
  show();
}

// Full screen fills the phone with the picture. Where the browser allows it (Android, iPad) the
// browser's own bars go too and the screen stops turning; an iPhone keeps Safari's bars.
function enterFull() {
  full = true;
  document.body.classList.add("full");
  const el = document.documentElement;
  const ask = el.requestFullscreen ? el.requestFullscreen({ navigationUI: "hide" }) : el.webkitRequestFullscreen ? el.webkitRequestFullscreen() : null;
  if (ask && ask.then) ask.then(lockTurning).catch(() => {});
}
function exitFull() {
  full = false;
  document.body.classList.remove("full");
  try { if (screen.orientation && screen.orientation.unlock) screen.orientation.unlock(); } catch (e) {}
  const out = document.fullscreenElement ? document.exitFullscreen() : document.webkitFullscreenElement ? document.webkitExitFullscreen() : null;
  if (out && out.catch) out.catch(() => {});
}
function lockTurning() {
  if (!(document.fullscreenElement || document.webkitFullscreenElement)) return;
  try { if (screen.orientation && screen.orientation.lock) screen.orientation.lock(shape === "tall" ? "portrait" : "landscape").catch(() => {}); } catch (e) {}
}

async function camera() {
  if (stream) stream.getTracks().forEach(t => t.stop());
  stream = await navigator.mediaDevices.getUserMedia({ audio: false,
    video: { facingMode: { ideal: facing }, width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } } });
  const v = $("v");
  v.srcObject = stream;
  v.classList.add("on");
  v.style.transform = facing === "user" ? "scaleX(-1)" : "";
  await v.play().catch(() => {});
  forceKey = true;
}

async function awake() {
  try { if ("wakeLock" in navigator) wakeLock = await navigator.wakeLock.request("screen"); } catch (e) {}
}

async function start() {
  note("");
  if (!window.isSecureContext || !navigator.mediaDevices) { note("Open this page from the QR code in AVA Recorder, so it comes over AVA's secure link."); return; }
  if (typeof VideoEncoder === "undefined" || typeof VideoFrame === "undefined") { note("This browser is too old for AVA. On an iPhone, update to iOS 16.4 or newer. On Android, update Chrome, or open this link in Chrome."); return; }
  // Full screen has to be asked for straight from the tap, before the camera question.
  enterFull();
  $("go").disabled = true; setState("Starting", "");
  try { await camera(); }
  catch (e) {
    exitFull();
    $("go").disabled = false; setState("Not started", "");
    note(e.name === "NotAllowedError" ? "The camera was not allowed. Tap Start camera and choose Allow. If it does not ask: on an iPhone, Settings, Apps, Safari, Camera, Allow; on Android, tap the icon left of the address, then Permissions, Camera, Allow." : "The camera did not start: " + e.message);
    return;
  }
  [W, H] = sizeFor(shape);
  canvas = document.createElement("canvas"); canvas.width = W; canvas.height = H;
  ctx = canvas.getContext("2d", { alpha: false });
  try { await makeEncoder(); }
  catch (e) { stop(); note("This phone cannot make the video AVA needs. Update its system and browser; on Android, use Chrome."); return; }
  running = true; frames = 0; failures = 0; needKey = false; forceKey = true; queue = []; formatKey = ""; formatRec = null;
  $("go").hidden = true; $("go").disabled = false; $("tools").hidden = false; $("tips").hidden = true;
  awake();
  try { handle(await post(new Uint8Array(0))); } catch (e) { failures = 3; }
  show();
  pump();
  $("v").requestVideoFrameCallback(frame);
}

function stop() {
  running = false; recording = false;
  if (stream) stream.getTracks().forEach(t => t.stop());
  stream = null;
  $("v").classList.remove("on");
  try { if (encoder && encoder.state !== "closed") encoder.close(); } catch (e) {}
  encoder = null;
  if (wakeLock) { wakeLock.release().catch(() => {}); wakeLock = null; }
  exitFull();
  setState("Not started", "");
  $("go").hidden = false; $("tools").hidden = true; $("hint").hidden = true;
  syncShape();
}

$("go").addEventListener("click", start);
$("full").addEventListener("click", enterFull);
$("exit").addEventListener("click", exitFull);
all("[data-shape]").forEach(b => b.addEventListener("click", () => setShape(b.dataset.shape)));
all("[data-flip]").forEach(b => b.addEventListener("click", async () => {
  facing = facing === "user" ? "environment" : "user";
  syncShape();
  try { await camera(); } catch (e) { note("That camera did not start: " + e.message); }
}));
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && running) { awake(); forceKey = true; }
  show();
});
$("v").addEventListener("resize", show);
syncShape();
</script>
</body>
</html>
"""#
}
