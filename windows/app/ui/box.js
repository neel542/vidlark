// The small recording box while the screen is shared: Me or Screen, the time and level, Stop, her face
// in the video or not, the computer's sound, and the way back to the Vidlark window. It is kept out of
// the video. The C++ side does the work; this only sends clicks and shows the take's state.
const bridge = window.chrome && window.chrome.webview;
const $ = (id) => document.getElementById(id);
const send = (message) => bridge && bridge.postMessage(message);
let take = {};

const segments = Array.from({ length: 12 }, (_, i) => {
  const segment = document.createElement("i");
  if (i >= 8) segment.className = i >= 10 ? "red" : "amber";
  $("meter").append(segment);
  return segment;
});

function timecode(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const pad = (n) => String(n).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
}

function show() {
  const ready = !!take.hasScreen;
  const screen = take.showing === "screen";
  $("me").setAttribute("aria-pressed", String(!screen));
  $("screen").setAttribute("aria-pressed", String(screen));
  $("bubble").setAttribute("aria-pressed", String(take.bubble !== false));
  $("sound").setAttribute("aria-pressed", String(!!take.sound));
  for (const id of ["me", "screen", "sound"]) $(id).disabled = !ready;
  $("stop").disabled = !take.recording;
  if (take.sharing) $("note").textContent = "Starting the screen…";
  else if (ready && take.hearsComputer === false && take.sound) $("note").textContent = "This PC has no sound to record.";
  else if ($("note").textContent === "Starting the screen…") $("note").textContent = "";
}

$("me").addEventListener("click", () => send({ type: "show", what: "camera" }));
$("screen").addEventListener("click", () => send({ type: "show", what: "screen" }));
$("bubble").addEventListener("click", () => send({ type: "bubble", on: take.bubble === false }));
$("sound").addEventListener("click", () => send({ type: "sound", on: !take.sound }));
$("back").addEventListener("click", () => send({ type: "back" }));
$("stop").addEventListener("click", () => send({ type: "stop" }));

const handlers = {
  take(m) {
    take = m;
    show();
  },
  tick(m) {
    if (typeof m.seconds === "number") $("time").textContent = timecode(m.seconds);
    const level = typeof m.level === "number" ? m.level : -160;
    const lit = Math.round(Math.max(0, Math.min(1, (level + 60) / 60)) * segments.length);
    segments.forEach((segment, i) => segment.classList.toggle("on", i < lit));
  },
  "share-failed"(m) {
    $("note").textContent = m.message;
  },
};

if (bridge) {
  bridge.addEventListener("message", (event) => {
    const message = event.data;
    if (message && handlers[message.type]) handlers[message.type](message);
  });
  send({ type: "take" });
}
show();
