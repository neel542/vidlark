// The panel's side of the bridge. It asks the C++ app for devices, shows the camera picture and level,
// counts down, starts and stops takes, and follows the finisher. The C++ side does the recording.
const bridge = window.chrome && window.chrome.webview;
const $ = (id) => document.getElementById(id);
const send = (message) => bridge && bridge.postMessage(message);

let devices = { cameras: [], microphones: [] };
let opened = { camera: "", microphone: "" };
let phase = "idle"; // idle, countdown, recording, finishing
let countdownTimer = null;

// The meter: 24 segments, green through amber to red, like the Mac panel's.
const segments = Array.from({ length: 24 }, (_, i) => {
  const segment = document.createElement("i");
  if (i >= 17) segment.className = i >= 21 ? "red" : "amber";
  $("meter").append(segment);
  return segment;
});

function timecode(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const pad = (n) => String(n).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
}

function fill(select, list, chosenName) {
  select.replaceChildren(...list.map((d) => {
    const option = document.createElement("option");
    option.value = d.id;
    option.textContent = d.name;
    option.selected = d.name === chosenName;
    return option;
  }));
  select.disabled = list.length === 0 || phase !== "idle";
  if (!list.length) {
    const option = document.createElement("option");
    option.textContent = "None found";
    select.append(option);
  }
}

function showExtras() {
  const others = devices.microphones.filter((m) => m.name !== opened.microphone);
  $("extras-box").hidden = others.length === 0;
  const ticked = new Set([...document.querySelectorAll("#extras input:checked")].map((box) => box.value));
  $("extras").replaceChildren(...others.map((m) => {
    const label = document.createElement("label");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.value = m.id;
    box.checked = ticked.has(m.id);
    box.disabled = phase !== "idle";
    label.append(box, document.createTextNode(m.name));
    return label;
  }));
}

function status(html) {
  $("status").innerHTML = html;
}

function setPhase(next) {
  phase = next;
  const button = $("record");
  button.classList.toggle("stop", phase === "recording");
  button.setAttribute("aria-label", phase === "recording" ? "Stop" : phase === "countdown" ? "Call off the take" : "Record");
  button.disabled = phase === "finishing" || (phase === "idle" && !(opened.camera && opened.microphone));
  $("timecode").classList.toggle("live", phase === "recording");
  for (const control of [$("camera"), $("mic"), $("video-title")]) control.disabled = phase !== "idle";
  for (const box of document.querySelectorAll("#extras input")) box.disabled = phase !== "idle";
}

// The Mac's beeps: three short ones at 880 Hz, then a long one at 1320 Hz when the take starts.
let audio = null;
function beep(frequency, seconds) {
  audio = audio || new AudioContext();
  const tone = audio.createOscillator();
  const gain = audio.createGain();
  tone.frequency.value = frequency;
  gain.gain.setValueAtTime(0.25, audio.currentTime);
  gain.gain.exponentialRampToValueAtTime(0.001, audio.currentTime + seconds);
  tone.connect(gain).connect(audio.destination);
  tone.start();
  tone.stop(audio.currentTime + seconds);
}

function startCountdown() {
  setPhase("countdown");
  let n = 3;
  const show = () => {
    $("countdown").hidden = false;
    $("countdown").textContent = n;
    beep(880, 0.12);
  };
  show();
  countdownTimer = setInterval(() => {
    n -= 1;
    if (n > 0) return show();
    clearInterval(countdownTimer);
    $("countdown").hidden = true;
    beep(1320, 0.35);
    const extraMics = [...document.querySelectorAll("#extras input:checked")].map((box) => box.value);
    send({ type: "record", title: $("video-title").value.trim(), extraMics });
  }, 1000);
}

function cancelCountdown() {
  clearInterval(countdownTimer);
  $("countdown").hidden = true;
  setPhase("idle");
  status("Take called off.");
}

$("record").addEventListener("click", () => {
  if (phase === "idle") startCountdown();
  else if (phase === "countdown") cancelCountdown();
  else if (phase === "recording") send({ type: "stop" });
});
$("camera").addEventListener("change", () => send({ type: "open", camera: $("camera").value, microphone: $("mic").value }));
$("mic").addEventListener("change", () => send({ type: "open", camera: $("camera").value, microphone: $("mic").value }));

const handlers = {
  devices(m) {
    devices = m;
    fill($("camera"), m.cameras || [], opened.camera);
    fill($("mic"), m.microphones || [], opened.microphone);
    const screen = (m.screens || []).find((s) => s.primary) || (m.screens || [])[0];
    if (screen) $("screen-detail").textContent = `${screen.width} × ${screen.height}. Recording it comes in the next build.`;
    showExtras();
  },
  opened(m) {
    opened = m;
    fill($("camera"), devices.cameras || [], m.camera);
    fill($("mic"), devices.microphones || [], m.microphone);
    $("camera-lamp").className = "lamp " + (m.camera ? "ok" : "fail");
    $("mic-lamp").className = "lamp " + (m.microphone ? "ok" : "fail");
    $("camera-detail").textContent = m.size || "";
    if (!m.camera) {
      $("preview").hidden = true;
      $("picture-note").hidden = false;
      $("picture-note").textContent = devices.cameras.length ? "The camera could not open." : "No camera found.";
    }
    showExtras();
    status(m.problems && m.problems.length ? `<span class="bad">${m.problems.map(escape).join("<br>")}</span>` : "");
    setPhase(phase === "idle" ? "idle" : phase);
  },
  preview(m) {
    $("preview").src = "data:image/jpeg;base64," + m.jpeg;
    $("preview").hidden = false;
    $("picture-note").hidden = true;
  },
  tick(m) {
    const level = typeof m.level === "number" ? m.level : -160;
    // -60 dB to 0 dB across the 24 segments.
    const lit = Math.round(Math.max(0, Math.min(1, (level + 60) / 60)) * segments.length);
    segments.forEach((segment, i) => segment.classList.toggle("on", i < lit));
    if (m.cameraOk === false && opened.camera) $("camera-lamp").className = "lamp fail";
    if (phase === "recording" && typeof m.seconds === "number") $("timecode").textContent = timecode(m.seconds);
  },
  recording() {
    setPhase("recording");
    status("Recording.");
  },
  problem(m) {
    setPhase("idle");
    status(`<span class="bad">${escape(m.message)}</span>`);
  },
  stopped() {
    setPhase("finishing");
    status("Lining up and finishing the files…");
  },
  finishing(m) {
    status(`Finishing: ${escape(m.line)}`);
  },
  finished(m) {
    setPhase("idle");
    $("timecode").textContent = "00:00";
    const folder = m.folder;
    status(`${m.ok ? "" : '<span class="bad">'}${escape(m.message)}${m.ok ? "" : "</span>"}<br><button type="button" class="refresh" id="show-take">Show the take</button>`);
    $("show-take").addEventListener("click", () => send({ type: "show-take", folder }));
  },
};

function escape(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

if (bridge) {
  bridge.addEventListener("message", (event) => {
    const message = event.data;
    if (message && handlers[message.type]) handlers[message.type](message);
  });
  send({ type: "hello" });
}
setPhase("idle");
