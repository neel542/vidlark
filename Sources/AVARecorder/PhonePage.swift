import Foundation

/// The page the iPhone opens from the QR code. It holds the iPhone's camera, makes each picture into
/// H.264 with the iPhone's own encoder (WebCodecs), times it on the Mac's clock and sends it in small
/// batches over the one secure connection. Nothing to install; Safari on iOS 16.4 or newer.
enum PhonePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex">
<title>AVA camera</title>
<style>
:root { --body: #0E1110; --face: #151917; --raised: #1B201E; --well: #070908; --hair: rgba(255,255,255,.075);
  --engraved: #86918B; --dim: #A3ADA8; --ink: #ECF1EE; --signal: #3DCC80; --amber: #E8B34B; --red: #F04E3E; }
html, body { margin: 0; background: var(--body); color: var(--ink); -webkit-text-size-adjust: 100%;
  font: 15px/1.45 -apple-system, system-ui, sans-serif; }
main { box-sizing: border-box; min-height: 100svh; max-width: 760px; margin: 0 auto; display: flex; flex-direction: column; gap: 14px;
  padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(20px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left)); }
header { display: flex; align-items: center; gap: 10px; }
h1 { flex: 1; margin: 0; font-size: 15px; font-weight: 600; }
.lamp { flex: none; width: 9px; height: 9px; border-radius: 50%; background: var(--engraved); opacity: .5; }
.lamp.ok { opacity: 1; background: radial-gradient(circle at 40% 35%, #B4F5D0, var(--signal) 62%); }
.lamp.warn { opacity: 1; background: radial-gradient(circle at 40% 35%, #FBE3AE, var(--amber) 62%); }
.lamp.rec { opacity: 1; background: radial-gradient(circle at 40% 35%, #FFB8AE, var(--red) 62%); animation: breathe 1.4s ease-in-out infinite alternate; }
@keyframes breathe { from { opacity: .45; } to { opacity: 1; } }
#state { color: var(--dim); font-size: 13px; font-variant-numeric: tabular-nums; }
.view { position: relative; aspect-ratio: 16 / 9; background: var(--well); border: 1px solid var(--hair); border-radius: 12px; overflow: hidden; }
video { display: block; width: 100%; height: 100%; object-fit: cover; visibility: hidden; }
video.on { visibility: visible; }
.veil { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px;
  padding: 18px; text-align: center; background: rgba(0,0,0,.62); }
.veil[hidden] { display: none; }
.veil b { font-size: 16px; font-weight: 600; }
.veil span { max-width: 34ch; color: var(--dim); font-size: 13.5px; }
.go { appearance: none; width: 100%; padding: 16px; border: 0; border-radius: 14px; background: var(--signal); color: #06130C;
  font: 600 17px -apple-system, system-ui, sans-serif; }
.go:active { filter: brightness(.92); }
.go:disabled { opacity: .5; }
.go[hidden], .tools[hidden], ol[hidden], .note[hidden] { display: none; }
.tools { display: flex; gap: 10px; align-items: center; }
.small { appearance: none; padding: 10px 14px; border: 1px solid var(--hair); border-radius: 10px; background: var(--face); color: var(--ink);
  font: 500 14px -apple-system, system-ui, sans-serif; }
.facts { flex: 1; text-align: right; color: var(--engraved); font-size: 11px; font-weight: 600; letter-spacing: .1em; text-transform: uppercase; }
ol { margin: 0; padding-left: 20px; color: var(--dim); font-size: 14px; }
ol li { margin: 5px 0; }
.note { margin: 0; color: var(--amber); font-size: 14px; }
</style>
</head>
<body>
<main>
  <header><i class="lamp" id="lamp"></i><h1>AVA camera</h1><span id="state">Not started</span></header>
  <div class="view">
    <video id="v" playsinline muted autoplay></video>
    <div class="veil" id="veil"><b id="veilTitle">This phone becomes AVA's camera</b><span id="veilText">Tap Start camera. The picture goes to AVA Recorder on the Mac, over your Wi-Fi.</span></div>
  </div>
  <p class="note" id="note" hidden></p>
  <button class="go" id="go">Start camera</button>
  <div class="tools" id="tools" hidden><button class="small" id="flip">Use the front camera</button><span class="facts" id="facts"></span></div>
  <ol id="tips">
    <li>Turn the phone sideways, with the back camera facing you.</li>
    <li>Keep this page open. The screen stays on by itself.</li>
    <li>For a long take, plug the phone in to charge.</li>
  </ol>
</main>
<script>
"use strict";
const token = location.pathname.split("/")[1];
const sid = Math.random().toString(36).slice(2) + Date.now().toString(36);
const W = 1920, H = 1080;
const $ = id => document.getElementById(id);
let stream = null, encoder = null, canvas = null, ctx = null, config = null, wakeLock = null;
let running = false, facing = "environment", resting = false, recording = false;
let offset = null, clock = [], failures = 0, lastPost = 0;
let queue = [], queued = 0, forceKey = true, needKey = false, frames = 0, formatRec = null, formatKey = "";
let sentCount = 0, sentSince = performance.now(), fps = 0;

function setState(text, lamp) { $("state").textContent = text; $("lamp").className = "lamp " + (lamp || ""); }
function veil(title, text) {
  if (title === null) { $("veil").hidden = true; return; }
  $("veil").hidden = false; $("veilTitle").textContent = title; $("veilText").textContent = text || "";
}
function note(text) { $("note").hidden = !text; $("note").textContent = text || ""; }
function portrait() { const v = $("v"); return v.videoHeight > v.videoWidth; }

function show() {
  if (!running) return;
  if (resting) { setState("Resting", ""); veil("AVA is resting the camera", "It wakes by itself when someone looks at AVA on the Mac."); return; }
  if (portrait()) { setState("Turn sideways", "warn"); veil("Turn the phone sideways", "AVA records a wide picture, like YouTube shows."); return; }
  veil(null);
  if (failures > 2) setState("Cannot reach the Mac", "warn");
  else if (recording) setState("Recording", "rec");
  else setState("Sending to AVA", "ok");
  $("facts").textContent = fps ? `1080p · ${fps} fps` : "";
}

// One batch to the Mac. The reply carries the Mac's clock: the quickest round trips of the last
// forty give the gap between the two clocks, so every picture is timed as the Mac sees it.
async function post(body) {
  const t1 = performance.now();
  const r = await fetch(`/${token}/send`, { method: "POST", body, cache: "no-store",
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
  if (j.replaced) { stop(); veil("Another page took over", "AVA is using the camera from another tab or phone now. Tap Start camera to take it back."); return; }
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

function formatRecord(desc) {
  const d = desc instanceof ArrayBuffer ? new Uint8Array(desc) : new Uint8Array(desc.buffer, desc.byteOffset, desc.byteLength);
  const b = new ArrayBuffer(9 + d.byteLength), v = new DataView(b);
  v.setUint8(0, 1); v.setUint16(1, W, true); v.setUint16(3, H, true); v.setUint32(5, d.byteLength, true);
  new Uint8Array(b, 9).set(d);
  return b;
}

function pictureRecord(chunk, macMs) {
  const b = new ArrayBuffer(14 + chunk.byteLength), v = new DataView(b);
  v.setUint8(0, 2); v.setUint8(1, chunk.type === "key" ? 1 : 0); v.setFloat64(2, macMs, true); v.setUint32(10, chunk.byteLength, true);
  chunk.copyTo(new Uint8Array(b, 14));
  return b;
}

function onChunk(chunk, meta) {
  const desc = meta && meta.decoderConfig && meta.decoderConfig.description;
  if (desc) {
    const rec = formatRecord(desc), key = Array.from(new Uint8Array(rec)).join(",");
    if (key !== formatKey) { formatKey = key; formatRec = rec; queue.push(rec); }
  }
  if (needKey) { if (chunk.type !== "key") return; needKey = false; }
  if (offset === null) return;
  const rec = pictureRecord(chunk, chunk.timestamp / 1000 + offset);
  queue.push(rec); queued += rec.byteLength;
}

async function makeEncoder() {
  config = null;
  for (const codec of ["avc1.640028", "avc1.4d0028", "avc1.42e028"]) {
    const c = { codec, width: W, height: H, bitrate: 8000000, framerate: 30, latencyMode: "realtime", avc: { format: "avc" } };
    try { if ((await VideoEncoder.isConfigSupported(c)).supported) { config = c; break; } } catch (e) {}
  }
  if (!config) throw new Error("no H.264");
  encoder = new VideoEncoder({ output: onChunk, error: e => { stop(); note("The picture encoder stopped (" + e.message + "). Tap Start camera again."); } });
  encoder.configure(config);
}

function frame(now, meta) {
  if (!running) return;
  const v = $("v");
  v.requestVideoFrameCallback(frame);
  if (resting || offset === null || document.hidden || portrait() || !v.videoWidth) return;
  if (encoder.encodeQueueSize > 3) return;
  // Fill the wide picture, trimming the edges of anything taller.
  const s = Math.max(W / v.videoWidth, H / v.videoHeight), dw = v.videoWidth * s, dh = v.videoHeight * s;
  ctx.drawImage(v, (W - dw) / 2, (H - dh) / 2, dw, dh);
  const taken = meta && meta.captureTime ? meta.captureTime : now;
  const f = new VideoFrame(canvas, { timestamp: Math.round(taken * 1000) });
  encoder.encode(f, { keyFrame: forceKey || frames % 60 === 0 });
  forceKey = false; frames++;
  f.close();
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
  $("flip").textContent = facing === "user" ? "Use the back camera" : "Use the front camera";
  forceKey = true;
}

async function awake() {
  try { if ("wakeLock" in navigator) wakeLock = await navigator.wakeLock.request("screen"); } catch (e) {}
}

async function start() {
  note("");
  if (!window.isSecureContext || !navigator.mediaDevices) { note("Open this page from the QR code in AVA Recorder, so it comes over AVA's secure link."); return; }
  if (typeof VideoEncoder === "undefined" || typeof VideoFrame === "undefined") { note("This browser is too old for AVA. On an iPhone, update to iOS 16.4 or newer. On Android, update Chrome, or open this link in Chrome."); return; }
  $("go").disabled = true; setState("Starting", "");
  try { await camera(); }
  catch (e) {
    $("go").disabled = false; setState("Not started", "");
    note(e.name === "NotAllowedError" ? "The camera was not allowed. Tap Start camera and choose Allow. If it does not ask: on an iPhone, Settings, Apps, Safari, Camera, Allow; on Android, tap the icon left of the address, then Permissions, Camera, Allow." : "The camera did not start: " + e.message);
    return;
  }
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
  running = false;
  if (stream) stream.getTracks().forEach(t => t.stop());
  stream = null;
  $("v").classList.remove("on");
  try { if (encoder && encoder.state !== "closed") encoder.close(); } catch (e) {}
  encoder = null;
  if (wakeLock) { wakeLock.release().catch(() => {}); wakeLock = null; }
  setState("Not started", "");
  $("go").hidden = false; $("tools").hidden = true;
}

$("go").addEventListener("click", start);
$("flip").addEventListener("click", async () => {
  facing = facing === "user" ? "environment" : "user";
  try { await camera(); } catch (e) { note("That camera did not start: " + e.message); }
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && running) { awake(); forceKey = true; }
  show();
});
$("v").addEventListener("resize", show);
</script>
</body>
</html>
"""#
}
