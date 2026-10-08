// The panel's side of the bridge. It asks the C++ app for devices, shows the camera picture and level,
// counts down, starts and stops takes, and follows the finisher. The C++ side does the recording.
const bridge = window.chrome && window.chrome.webview;
const $ = (id) => document.getElementById(id);
const send = (message) => bridge && bridge.postMessage(message);

let devices = { cameras: [], microphones: [] };
let opened = { camera: "", microphone: "" };
let cameraAlive = true; // false once an opened camera stops sending pictures
let phase = "idle"; // idle, countdown, recording, finishing
let countdownTimer = null;

// What Share screen records: a whole screen or one window, remembered for next time, and the take's
// screen state from the C++ side.
const load = (key) => { try { return JSON.parse(localStorage.getItem(key)); } catch { return null; } };
const save = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* not kept */ } };
let shareTarget = load("shareTarget");
let computerSound = load("computerSound") === true;
let take = { recording: false };
const picker = { mode: "choose", tab: "screen", choices: null, picked: null };

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

function showShareTarget() {
  const screens = devices.screens || [];
  if (!shareTarget || (shareTarget.kind === "screen" && !screens.some((s) => s.id === shareTarget.id))) {
    const main = screens.find((s) => s.primary) || screens[0];
    shareTarget = main ? { kind: "screen", id: main.id, name: main.name } : null;
  }
  $("screen-detail").textContent = !shareTarget ? "No screen found"
    : shareTarget.kind === "screen" ? `Entire screen: ${shareTarget.name}` : `A window: ${shareTarget.name}`;
  showShare();
}

function showShare() {
  const canShare = phase === "recording" && take.recording && !take.hasScreen;
  $("share-box").hidden = !canShare;
  $("share").disabled = !!take.sharing;
  $("share").textContent = take.sharing ? "Sharing the screen…" : "Share screen";
  $("screen-note").textContent = take.hasScreen ? "Recording now" : "Recorded once you press Share screen";
  $("screen-lamp").className = "lamp " + (take.hasScreen ? "fail" : shareTarget ? "ok" : "off");
  $("choose-screen").disabled = phase !== "idle";
}

// The picker: every screen and open window, with a picture of each, the last pick already picked.
function openPicker(mode) {
  picker.mode = mode;
  picker.choices = null;
  picker.tab = shareTarget && shareTarget.kind === "window" ? "window" : "screen";
  picker.picked = shareTarget ? `${shareTarget.kind}:${shareTarget.id}` : null;
  $("picker-hint").textContent = mode === "share"
    ? "Pick the whole screen or one window. Only what you pick goes into the video."
    : "This is recorded once you press Share screen. Only what you pick goes into the video.";
  $("picker-go").textContent = mode === "share" ? "Share" : "Use this";
  $("computer-sound").checked = computerSound;
  $("picker").hidden = false;
  drawTiles();
  send({ type: "share-choices" });
}

function closePicker() {
  $("picker").hidden = true;
}

function pickerList() {
  if (!picker.choices) return null;
  return picker.tab === "screen" ? picker.choices.screens || [] : picker.choices.windows || [];
}

function chosen() {
  return (pickerList() || []).find((c) => `${c.kind}:${c.id}` === picker.picked) || null;
}

function drawTiles() {
  $("tab-screen").setAttribute("aria-selected", String(picker.tab === "screen"));
  $("tab-window").setAttribute("aria-selected", String(picker.tab === "window"));
  const list = pickerList();
  const note = (text) => {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = text;
    return p;
  };
  if (!list) {
    $("tiles").replaceChildren(note("Looking at what is open…"));
  } else if (!list.length) {
    $("tiles").replaceChildren(note(picker.tab === "window" ? "No windows are open. Open the app you want to show, then come back." : "No screen found."));
  } else {
    $("tiles").replaceChildren(...list.map((c) => {
      const key = `${c.kind}:${c.id}`;
      const tile = document.createElement("button");
      tile.type = "button";
      tile.className = "tile";
      tile.setAttribute("role", "option");
      tile.setAttribute("aria-selected", String(key === picker.picked));
      const frame = document.createElement("span");
      frame.className = "thumb";
      if (c.jpeg) {
        const img = document.createElement("img");
        img.alt = "";
        img.src = "data:image/jpeg;base64," + c.jpeg;
        frame.append(img);
      }
      const name = document.createElement("b");
      name.textContent = c.name;
      const detail = document.createElement("span");
      detail.className = "detail";
      detail.textContent = c.detail || "";
      tile.append(frame, name, detail);
      tile.addEventListener("click", () => { picker.picked = key; drawTiles(); });
      tile.addEventListener("dblclick", () => { picker.picked = key; pickerDone(); });
      return tile;
    }));
  }
  $("picker-go").disabled = !chosen();
}

function pickerDone() {
  const choice = chosen();
  if (!choice) return;
  shareTarget = { kind: choice.kind, id: choice.id, name: choice.kind === "window" ? choice.label || choice.name : choice.name };
  computerSound = $("computer-sound").checked;
  save("shareTarget", shareTarget);
  save("computerSound", computerSound);
  closePicker();
  showShareTarget();
  if (picker.mode === "share") send({ type: "share", target: shareTarget, sound: computerSound });
}

function status(html) {
  $("status").innerHTML = html;
}

function setPhase(next) {
  phase = next;
  const button = $("record");
  button.classList.toggle("stop", phase === "recording");
  button.setAttribute("aria-label", phase === "recording" ? "Stop" : phase === "countdown" ? "Call off the take" : "Record");
  button.disabled = phase === "finishing" || (phase === "idle" && !(opened.camera && opened.microphone && cameraAlive));
  $("timecode").classList.toggle("live", phase === "recording");
  for (const control of [$("camera"), $("mic"), $("video-title")]) control.disabled = phase !== "idle";
  for (const box of document.querySelectorAll("#extras input")) box.disabled = phase !== "idle";
  showShare();
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
$("share").addEventListener("click", () => openPicker("share"));
$("choose-screen").addEventListener("click", () => openPicker("choose"));
$("tab-screen").addEventListener("click", () => { picker.tab = "screen"; drawTiles(); });
$("tab-window").addEventListener("click", () => { picker.tab = "window"; drawTiles(); });
$("picker-cancel").addEventListener("click", closePicker);
$("picker-go").addEventListener("click", pickerDone);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !$("picker").hidden) closePicker();
});
$("camera").addEventListener("change", () => send({ type: "open", camera: $("camera").value, microphone: $("mic").value }));
$("mic").addEventListener("change", () => send({ type: "open", camera: $("camera").value, microphone: $("mic").value }));

const handlers = {
  devices(m) {
    // Asked for again every few seconds, so the lists are only rebuilt when something was plugged in or out.
    const same = JSON.stringify([m.cameras, m.microphones, m.screens]) === JSON.stringify([devices.cameras, devices.microphones, devices.screens]);
    devices = m;
    if (same) return;
    fill($("camera"), m.cameras || [], opened.camera);
    fill($("mic"), m.microphones || [], opened.microphone);
    showShareTarget();
    showExtras();
    if (!cameraAlive) reopenCamera();
  },
  opened(m) {
    opened = m;
    cameraAlive = true;
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
    if (typeof m.cameraOk === "boolean" && opened.camera && m.cameraOk !== cameraAlive) {
      cameraAlive = m.cameraOk;
      if (!cameraAlive && phase === "idle") {
        $("preview").hidden = true;
        $("picture-note").hidden = false;
        $("picture-note").textContent = "The camera stopped. Check it is plugged in, and that Settings, Privacy & security, Camera lets apps use it. Vidlark tries it again when it is plugged back in, or when you come back to this window.";
      }
      setPhase(phase);
    }
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
  "share-choices"(m) {
    picker.choices = m;
    // A window remembered from before has a new number now: find it again by its name.
    if (!chosen() && shareTarget && shareTarget.kind === "window") {
      const again = (m.windows || []).find((w) => w.label === shareTarget.name || w.name === shareTarget.name);
      if (again) picker.picked = `window:${again.id}`;
    }
    if (!chosen()) {
      const main = (m.screens || []).find((s) => s.primary) || (m.screens || [])[0];
      if (main && picker.tab === "screen") picker.picked = `screen:${main.id}`;
    }
    drawTiles();
  },
  take(m) {
    take = m;
    showShare();
  },
  sharing(m) {
    status(`Sharing ${escape(m.name)}…`);
  },
  shared(m) {
    status(`Recording ${escape(m.name)} too. The small box switches between Me and Screen.`);
  },
  "share-failed"(m) {
    status(`<span class="bad">${escape(m.message)}</span>`);
  },
  finished(m) {
    setPhase("idle");
    $("timecode").textContent = "00:00";
    const folder = m.folder;
    status(`${m.ok ? "" : '<span class="bad">'}${escape(m.message)}${m.ok ? "" : "</span>"}<br><button type="button" class="refresh" id="show-take">Show the take</button>`);
    $("show-take").addEventListener("click", () => send({ type: "show-take", folder }));
  },
};

// A camera that stopped (unplugged, or turned off in Windows' privacy settings) is opened again.
function reopenCamera() {
  if (phase === "idle" && opened.camera && devices.cameras && devices.cameras.length) send({ type: "open", camera: $("camera").value, microphone: $("mic").value });
}

function escape(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

if (bridge) {
  bridge.addEventListener("message", (event) => {
    const message = event.data;
    if (message && handlers[message.type]) handlers[message.type](message);
  });
  send({ type: "hello" });
  // A camera or microphone plugged in later shows up without opening Vidlark again.
  const refreshDevices = () => {
    if (phase === "idle" && document.visibilityState === "visible") send({ type: "devices" });
  };
  window.addEventListener("focus", () => {
    if (!cameraAlive) reopenCamera();
    refreshDevices();
  });
  setInterval(refreshDevices, 3000);
}
setPhase("idle");
