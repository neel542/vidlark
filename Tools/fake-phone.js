// Light stand-in phones for the self test: each sends a made-up H.264 picture stream to AVA the
// way the phone page does, with no browser and no camera, so a test hardly loads the Mac. Like the
// page, it stands by when AVA says so, sends a beep as its sound when AVA asks for its mic, and
// shares the mute switch with the Mac.
//   node Tools/fake-phone.js <seconds> [shape per phone: wide|tall ...] &
//   open -g -W -n --env AVA_QUIET=1 --env AVA_CAMERA=phones "dist/AVA Recorder.app" --args --self-test 25
// It reads the links from .selftest-phone.txt (one a line), as the self test writes them.
// The test pictures are made once with ffmpeg and kept in the temporary folder.
const fs = require("fs"), https = require("https"), os = require("os"), path = require("path"), { spawnSync } = require("child_process"), { performance } = require("perf_hooks");
const secs = Number(process.argv[2] || 60), shapes = process.argv.slice(3);
const linksFile = "/Users/Shared/AVA Recordings/.selftest-phone.txt";

function parse(file) {
  const b = fs.readFileSync(file), nals = [];
  let i = 0, start = -1;
  while (i + 3 <= b.length) {
    if (b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 1) {
      if (start >= 0) nals.push(b.subarray(start, i));
      start = i + 3; i += 3; continue;
    }
    i++;
  }
  if (start >= 0) nals.push(b.subarray(start));
  // Trim the zero before a 4 byte start code from the end of the previous NAL.
  const clean = nals.map(n => { let e = n.length; while (e > 0 && n[e - 1] === 0) e--; return n.subarray(0, e); });
  let sps, pps; const frames = [];
  for (const n of clean) {
    const t = n[0] & 0x1f;
    if (t === 7) sps = sps || n;
    else if (t === 8) pps = pps || n;
    else if (t === 1 || t === 5) {
      if (n[1] & 0x80 || !frames.length) frames.push({ key: t === 5, parts: [] });
      frames[frames.length - 1].parts.push(n);
    }
  }
  const avcC = Buffer.concat([Buffer.from([1, sps[1], sps[2], sps[3], 0xff, 0xe1, sps.length >> 8, sps.length & 255]), sps,
    Buffer.from([1, pps.length >> 8, pps.length & 255]), pps]);
  const data = frames.map(f => ({ key: f.key, bytes: Buffer.concat(f.parts.flatMap(p => { const l = Buffer.alloc(4); l.writeUInt32BE(p.length); return [l, p]; })) }));
  return { avcC, frames: data };
}

function made(shape) {
  const dir = path.join(os.tmpdir(), "ava-fake-phone"), file = path.join(dir, shape + ".h264");
  if (!fs.existsSync(file)) {
    fs.mkdirSync(dir, { recursive: true });
    const size = shape === "tall" ? "1080x1920" : "1920x1080";
    const r = spawnSync("nice", ["-n", "15", "ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", `testsrc2=size=${size}:rate=30,format=yuv420p`, "-t", "20",
      "-c:v", "libx264", "-profile:v", "main", "-preset", "veryfast", "-tune", "zerolatency", "-bf", "0", "-g", "30",
      "-b:v", "8M", "-maxrate", "8M", "-bufsize", "8M", "-bsf:v", "h264_mp4toannexb", "-f", "h264", file], { stdio: "inherit" });
    if (r.status !== 0) { console.error("ffmpeg could not make the test pictures"); process.exit(1); }
  }
  return parse(file);
}
const streams = { wide: made("wide"), tall: made("tall") };
const pause = ms => new Promise(r => setTimeout(r, ms));
// Every line starts with the seconds since the fake phones started, so a log lines up with a test.
const began = performance.now(), say = console.log;
console.log = (...words) => say(((performance.now() - began) / 1000).toFixed(1).padStart(6), ...words);

// FAKE_MUTE="3:on,8:off" flips the phone's own mute switch that many seconds into each take, as
// the person holding the phone would.
const muteFlips = (process.env.FAKE_MUTE || "").split(",").filter(Boolean).map(x => { const [at, on] = x.split(":"); return { at: Number(at), on: on === "on" }; });

async function phone(link, shape) {
  const s = streams[shape], [w, h] = shape === "tall" ? [1080, 1920] : [1920, 1080];
  const url = new URL(link + "send"), sid = Math.random().toString(36).slice(2);
  const agent = new https.Agent({ keepAlive: true, maxSockets: 1, rejectUnauthorized: false });
  let offset = null, clock = [], queue = [], resting = false, recording = false, jump = true, index = 0, sent = 0;
  // As the page: a camera until told otherwise, sending until told to stand by, the mic off until asked.
  let camera = true, sending = true, micWanted = false, muted = false, pendingMute = null, sounds = 0, recordedAt = 0;
  let flips = muteFlips.map(f => ({ ...f })), takes = 0;
  const label = "phone " + link.split("/").filter(Boolean).pop();
  function post(body) {
    return new Promise((done, fail) => {
      const t1 = performance.now();
      const headers = { "Content-Type": "application/octet-stream", "X-Session": sid, "Content-Length": body.length,
        "X-Has": [camera ? "camera" : "", micWanted && !muted ? "mic" : ""].filter(Boolean).join(","),
        "X-Mic": muted ? "muted" : micWanted ? "on" : "off", "X-Shape": shape, "X-Muted": muted ? "1" : "0" };
      if (pendingMute !== null) headers["X-Mute-Set"] = pendingMute ? "1" : "0";
      const req = https.request(url, { method: "POST", agent, headers }, res => {
        const chunks = []; res.on("data", c => chunks.push(c)); res.on("end", () => {
          const t4 = performance.now();
          try {
            const j = JSON.parse(Buffer.concat(chunks).toString());
            clock.push([t4 - t1, j.mac - (t1 + t4) / 2]); if (clock.length > 40) clock.shift();
            offset = clock.reduce((a, b) => b[0] < a[0] ? b : a)[1];
            done(j);
          } catch (e) { fail(e); }
        });
      });
      req.on("error", fail); req.end(body);
    });
  }
  function handle(j) {
    if (j.key) jump = true;
    if (j.rest !== resting) { resting = j.rest; jump = true; console.log(label, resting ? "Resting" : "Awake"); }
    if (j.recording !== recording) {
      recording = j.recording; recordedAt = performance.now(); console.log(label, recording ? "Recording" : "Stopped");
      if (recording) flips = muteFlips.map(f => ({ ...f }));
    }
    if (j.send !== undefined && j.send !== sending) { sending = j.send; if (sending) jump = true; console.log(label, sending ? "Sending" : "Standing by"); }
    if (j.camera !== undefined && j.camera !== camera) { camera = j.camera; console.log(label, camera ? "Camera" : "Microphone only"); }
    if (j.muted !== undefined) {
      if (pendingMute !== null && j.muted === pendingMute) pendingMute = null;
      if (pendingMute === null && j.muted !== muted) { muted = j.muted; console.log(label, muted ? "Muted from the " + j.mutedBy : "Unmuted from the " + j.mutedBy); }
    }
    if (!!j.mic !== micWanted) { micWanted = !!j.mic; console.log(label, micWanted ? "Mic on" : "Mic off"); }
  }
  const format = Buffer.alloc(9 + s.avcC.length);
  format.writeUInt8(1, 0); format.writeUInt16LE(w, 1); format.writeUInt16LE(h, 3); format.writeUInt32LE(s.avcC.length, 5); s.avcC.copy(format, 9);
  handle(await post(Buffer.alloc(0)));
  let formatSent = false;
  const t0 = performance.now(); let tick = 0;
  // The camera: one picture every 1/30 s, timed on the Mac's clock, while AVA wants them.
  (async () => {
    while (performance.now() - t0 < secs * 1000) {
      tick++;
      const wait = t0 + tick * 1000 / 30 - performance.now();
      if (wait > 0) await pause(wait);
      if (!camera || resting || !sending || offset === null) continue;
      if (!formatSent) { queue.push(format); formatSent = true; }
      if (jump) { while (!s.frames[index % s.frames.length].key) index++; jump = false; }
      const f = s.frames[index++ % s.frames.length];
      const rec = Buffer.alloc(14 + f.bytes.length);
      rec.writeUInt8(2, 0); rec.writeUInt8(f.key ? 1 : 0, 1); rec.writeDoubleLE(performance.now() + offset, 2); rec.writeUInt32LE(f.bytes.length, 10);
      f.bytes.copy(rec, 14);
      queue.push(rec);
      if (queue.length > 160) { queue = [format]; jump = true; }
    }
  })();
  // The mic: 2048 samples at 48 kHz at a time, numbered from the start like a page's sound clock.
  // A 1 kHz beep for the first 200 ms of every second of the Mac's clock, so a file shows where
  // each second fell; silence otherwise. Nothing is sent while muted or not asked for.
  (async () => {
    const rate = 48000, size = 2048; let first = 0;
    const s0 = performance.now();
    while (performance.now() - t0 < secs * 1000) {
      first += size;
      const wait = s0 + first / rate * 1000 - performance.now();
      if (wait > 0) await pause(wait);
      if (recording) for (const flip of flips) {
        if (!flip.done && performance.now() - recordedAt >= flip.at * 1000) { flip.done = true; muted = flip.on; pendingMute = flip.on; console.log(label, flip.on ? "Muted on the phone" : "Unmuted on the phone"); }
      }
      if (!micWanted || muted || resting || offset === null) continue;
      const start = first - size, macMs = s0 + start / rate * 1000 + offset;
      const rec = Buffer.alloc(25 + size * 2);
      rec.writeUInt8(3, 0); rec.writeUInt32LE(rate, 1); rec.writeDoubleLE(start, 5); rec.writeDoubleLE(macMs, 13); rec.writeUInt32LE(size, 21);
      for (let i = 0; i < size; i++) {
        const ms = macMs + i * 1000 / rate;
        const beep = ((ms % 1000) + 1000) % 1000 < 200;
        rec.writeInt16LE(beep ? Math.round(12000 * Math.sin(2 * Math.PI * 1000 * (start + i) / rate)) : 0, 25 + i * 2);
      }
      queue.push(rec); sounds++;
    }
  })();
  let last = performance.now();
  while (performance.now() - t0 < secs * 1000) {
    if (!queue.length) {
      if (performance.now() - last > 500 || pendingMute !== null) { try { handle(await post(Buffer.alloc(0))); } catch (e) { await pause(400); } last = performance.now(); }
      else await pause(15);
      continue;
    }
    const batch = queue; queue = [];
    try { handle(await post(Buffer.concat(batch))); sent += batch.length; last = performance.now(); }
    catch (e) { queue = batch.concat(queue); await pause(400); }
  }
  console.log(label, "done, records sent", sent, "of them sound", sounds);
  agent.destroy();
}

(async () => {
  const deadline = Date.now() + 60000;
  while (!fs.existsSync(linksFile) && Date.now() < deadline) await pause(250);
  const links = fs.readFileSync(linksFile, "utf8").split("\n").map(l => l.trim()).filter(Boolean);
  console.log("links", links.length);
  await Promise.all(links.map((l, i) => phone(l, shapes[i] || (i % 2 ? "tall" : "wide"))));
  process.exit(0);
})();
