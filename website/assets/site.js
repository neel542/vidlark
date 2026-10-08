// Vidlark website: the menu on phones, copy buttons, the take in the hero, the sync demo,
// the Mac and Windows tabs, the Windows download and the feedback form.
(function () {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // THE WINDOWS DOWNLOAD. While this is empty, every Windows download button says "coming soon".
  // When the Windows version is on GitHub Releases, paste its link here, for example
  // "https://github.com/neel542/vidlark/releases/latest/download/Vidlark-Windows.zip",
  // and every Windows button, label and note on the site switches to "ready".
  const windowsDownload = "";

  if (windowsDownload) {
    document.querySelectorAll("[data-windows-download]").forEach((link) => {
      link.href = windowsDownload;
      link.removeAttribute("aria-disabled");
      const label = link.querySelector("span");
      if (label) label.textContent = "Download for Windows";
    });
    document.querySelectorAll("[data-windows-status]").forEach((chip) => {
      chip.textContent = "Ready now";
      chip.classList.remove("soon");
    });
    document.querySelectorAll("[data-windows-soon]").forEach((note) => { note.hidden = true; });
  }

  // Menu on narrow screens.
  const nav = document.querySelector(".nav");
  const toggle = document.querySelector(".nav-toggle");
  if (nav && toggle) {
    toggle.addEventListener("click", () => {
      const open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", String(open));
    });
  }

  // Copy buttons on the commands in How to use it.
  document.querySelectorAll(".code").forEach((block) => {
    const button = document.createElement("button");
    button.className = "copy";
    button.type = "button";
    button.textContent = "Copy";
    button.addEventListener("click", async () => {
      const text = block.querySelector("code").innerText;
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
        button.classList.add("done");
      } catch (e) {
        button.textContent = "Select and copy";
      }
      setTimeout(() => { button.textContent = "Copy"; button.classList.remove("done"); }, 1800);
    });
    block.appendChild(button);
  });

  // The take: recording, Me, Screen, Stop, and the files the take leaves. It plays only while
  // it can be seen, and holds still for anyone who asked for less motion.
  const take = document.querySelector(".take");
  if (take) {
    const time = take.querySelector(".rtime");
    const meter = take.querySelectorAll(".rmeter i");
    const caption = take.querySelector(".take-caption");
    const say = (words) => { if (caption) caption.textContent = words; };
    if (still) {
      // Held still: the take just ended, with its files below.
      take.classList.add("stopped", "done");
      time.textContent = "05:12";
      say("When you stop, the take's folder has every file.");
    } else {
      let timer = null, levels = null, seconds = 0, visible = true, cycle = null;
      const tick = () => {
        seconds++;
        time.textContent = "00:" + String(seconds).padStart(2, "0");
      };
      const wobble = () => {
        const lit = 3 + Math.floor(Math.random() * 6);
        meter.forEach((m, i) => m.classList.toggle("on", i < lit));
      };
      const steps = [
        [0, () => { take.classList.remove("me", "stopped"); seconds = 0; time.textContent = "00:00";
          clearInterval(timer); clearInterval(levels); timer = setInterval(tick, 1000); levels = setInterval(wobble, 140);
          say("Recording the screen, the camera and the mic."); }],
        [3200, () => { take.classList.add("me"); say("Me: the camera grows to fill the screen."); }],
        [6400, () => { take.classList.remove("me"); say("Screen: it shrinks back into the circle."); }],
        [9200, () => { clearInterval(timer); clearInterval(levels); meter.forEach((m) => m.classList.remove("on"));
          take.classList.add("stopped"); say("Stop. The take's folder has every file."); }],
      ];
      const play = () => {
        steps.forEach(([at, run]) => setTimeout(() => { if (visible) run(); }, at));
      };
      const start = () => { play(); cycle = setInterval(play, 14000); };
      const stop = () => { clearInterval(cycle); clearInterval(timer); clearInterval(levels); };
      new IntersectionObserver((entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting && !visible) { visible = true; start(); }
          if (!e.isIntersecting && visible) { visible = false; stop(); }
        });
      }, { threshold: 0.2 }).observe(take);
      start();
    }
  }

  // Sync by sound: the phone's waveform slides until it lines up with the camera's.
  document.querySelectorAll(".sync").forEach((sync) => {
    // One made-up voice pattern, drawn twice; the second is the same sound arriving later.
    const pattern = [];
    let seed = 7;
    const rand = () => { seed = (seed * 9301 + 49297) % 233280; return seed / 233280; };
    for (let i = 0; i < 140; i++) {
      const word = Math.sin(i / 3.1) * Math.sin(i / 11.7);
      pattern.push(Math.max(0.08, Math.min(1, Math.abs(word) * 0.9 + rand() * 0.25)));
    }
    sync.querySelectorAll(".bars-wave").forEach((row) => {
      pattern.forEach((h) => {
        const bar = document.createElement("i");
        bar.style.height = Math.round(h * 44) + "px";
        row.appendChild(bar);
      });
    });
    if (still) { sync.classList.add("aligned"); return; }
    let loop = null;
    const run = () => {
      sync.classList.remove("aligned");
      setTimeout(() => sync.classList.add("aligned"), 1400);
    };
    new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting && !loop) { run(); loop = setInterval(run, 6000); }
        if (!e.isIntersecting && loop) { clearInterval(loop); loop = null; }
      });
    }, { threshold: 0.4 }).observe(sync);
  });

  // How to use it: the Mac and Windows tabs. Without JavaScript both guides show, one after the other.
  const tabs = [...document.querySelectorAll(".platform[data-tab]")];
  if (tabs.length) {
    const panels = [...document.querySelectorAll("[data-platform]")];
    document.documentElement.classList.add("js-tabs");
    const choose = (name) => {
      tabs.forEach((tab) => {
        const on = tab.dataset.tab === name;
        tab.setAttribute("aria-selected", String(on));
        tab.tabIndex = on ? 0 : -1;
      });
      panels.forEach((panel) => { panel.hidden = panel.dataset.platform !== name; });
    };
    // A link to /how-to#windows, or to any heading inside a guide, opens that guide.
    const fromHash = () => {
      const id = decodeURIComponent(location.hash.slice(1));
      const target = id && document.getElementById(id);
      const panel = target && target.closest("[data-platform]");
      return panel ? panel.dataset.platform : "mac";
    };
    const follow = () => {
      choose(fromHash());
      const id = decodeURIComponent(location.hash.slice(1));
      const target = id && document.getElementById(id);
      if (target) target.scrollIntoView();
    };
    tabs.forEach((tab, i) => {
      tab.addEventListener("click", () => {
        choose(tab.dataset.tab);
        history.replaceState(null, "", "#" + tab.dataset.tab);
      });
      tab.addEventListener("keydown", (e) => {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        const next = tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
        next.focus();
        next.click();
      });
    });
    window.addEventListener("hashchange", follow);
    follow();
  }

  // Feedback: a screenshot can be chosen, dropped or pasted. It shows a preview and must be an image
  // under 10 MB, FormSubmit's limit. After sending, FormSubmit brings people back with ?sent=1.
  const form = document.getElementById("feedback-form");
  if (form) {
    if (new URLSearchParams(location.search).has("sent")) {
      form.hidden = true;
      document.getElementById("sent").hidden = false;
    }
    form.querySelector('input[name="_next"]').value = location.origin + location.pathname + "?sent=1";

    const input = form.querySelector('input[type="file"]');
    const drop = document.getElementById("drop");
    const preview = drop.querySelector(".drop-preview");
    const image = preview.querySelector("img");
    const name = preview.querySelector(".drop-name");
    const shotError = document.getElementById("shot-error");
    const limit = 10 * 1024 * 1024;

    const clear = () => {
      input.value = "";
      preview.hidden = true;
      drop.classList.remove("has-file");
      if (image.src) URL.revokeObjectURL(image.src);
      image.removeAttribute("src");
    };
    const show = () => {
      const file = input.files[0];
      shotError.textContent = "";
      if (!file) return clear();
      if (!file.type.startsWith("image/")) { clear(); shotError.textContent = "That file is not an image. Pick a screenshot."; return; }
      if (file.size > limit) { clear(); shotError.textContent = "That image is over 10 MB. Pick a smaller one."; return; }
      if (image.src) URL.revokeObjectURL(image.src);
      image.src = URL.createObjectURL(file);
      name.textContent = file.name + ", " + (file.size / 1048576).toFixed(1) + " MB";
      preview.hidden = false;
      drop.classList.add("has-file");
    };
    const use = (file) => {
      const list = new DataTransfer();
      list.items.add(file);
      input.files = list.files;
      show();
    };
    input.addEventListener("change", show);
    preview.querySelector(".drop-remove").addEventListener("click", () => { clear(); input.focus(); });
    drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("over"); });
    drop.addEventListener("dragleave", () => drop.classList.remove("over"));
    drop.addEventListener("drop", (e) => {
      e.preventDefault();
      drop.classList.remove("over");
      const file = e.dataTransfer.files[0];
      if (file) use(file);
    });
    // Paste a screenshot anywhere on the page. Pasted text still goes where it was pasted.
    document.addEventListener("paste", (e) => {
      if (form.hidden) return;
      const item = [...(e.clipboardData ? e.clipboardData.items : [])].find((it) => it.kind === "file" && it.type.startsWith("image/"));
      if (!item) return;
      e.preventDefault();
      const blob = item.getAsFile();
      use(new File([blob], "screenshot." + (blob.type.split("/")[1] || "png"), { type: blob.type }));
    });

    form.addEventListener("submit", (e) => {
      const sendError = document.getElementById("send-error");
      if (form.action.includes("__FORM_KEY__")) {
        e.preventDefault();
        sendError.textContent = "Feedback is not switched on yet. Please try again soon.";
        return;
      }
      const button = form.querySelector('button[type="submit"]');
      button.disabled = true;
      button.querySelector("span").textContent = "Sending";
    });
    // Coming back with the browser's Back button after sending: make the button usable again.
    window.addEventListener("pageshow", () => {
      const button = form.querySelector('button[type="submit"]');
      button.disabled = false;
      button.querySelector("span").textContent = "Send feedback";
    });
  }
})();
