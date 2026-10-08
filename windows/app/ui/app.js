// The panel's side of the bridge: asks the C++ app what it can record from, and shows it.
const bridge = window.chrome && window.chrome.webview;

function source(label, devices, describe) {
  const li = document.createElement("li");
  li.className = "source";
  const lamp = document.createElement("span");
  lamp.className = "lamp " + (devices.length ? "ok" : "fail");
  const text = document.createElement("div");
  const title = document.createElement("b");
  title.textContent = label;
  const name = document.createElement("span");
  name.className = "name";
  name.textContent = devices.length ? describe(devices) : "None found";
  name.title = name.textContent;
  text.append(title, name);
  li.append(lamp, text);
  return li;
}

function more(list) {
  return list.length > 1 ? `, and ${list.length - 1} more` : "";
}

function showDevices(message) {
  const cameras = message.cameras || [];
  const mics = message.microphones || [];
  const screens = message.screens || [];
  const firstMic = mics.find((m) => m.default) || mics[0];
  const firstScreen = screens.find((s) => s.primary) || screens[0];
  document.getElementById("sources").replaceChildren(
    source("Camera", cameras, (list) => list[0].name + more(list)),
    source("Microphone", mics, (list) => firstMic.name + more(list)),
    source("Screen", screens, (list) => `${firstScreen.width} × ${firstScreen.height}` + more(list)),
  );
}

if (bridge) {
  bridge.addEventListener("message", (event) => {
    const message = event.data;
    if (message && message.type === "devices") showDevices(message);
  });
  bridge.postMessage({ type: "hello" });
  document.getElementById("refresh").addEventListener("click", () => bridge.postMessage({ type: "devices" }));
}
