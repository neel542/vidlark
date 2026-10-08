// Vidlark website: the menu on phones, copy buttons, the take in the hero, the sync demo,
// the Mac and Windows tabs, the Windows download and the feedback form.
(function () {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // THE WINDOWS DOWNLOAD. While this is empty, every Windows download button says "coming soon".
  // When the Windows version is on GitHub Releases, paste its link here, for example
  // the release's Vidlark-Windows.zip download link,
  // and every Windows button, label and note on the site switches to "ready".
  const windowsDownload = "https://github.com/neel542/vidlark/releases/download/windows-v0.2/Vidlark-Windows.zip";

  if (windowsDownload) {
    document.querySelectorAll("[data-windows-download]").forEach((link) => {
      link.href = windowsDownload;
      link.removeAttribute("aria-disabled");
      const label = link.querySelector("span");
      if (label) label.textContent = "Download for Windows (beta)";
    });
    document.querySelectorAll("[data-windows-status]").forEach((chip) => {
      chip.textContent = "Beta";
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
      panels.forEach((panel) => {
        const show = panel.dataset.platform === name;
        if (show && panel.hidden) {
          panel.classList.add("entering");
          panel.addEventListener("animationend", () => panel.classList.remove("entering"), { once: true });
        }
        panel.hidden = !show;
      });
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

  // Motion. Things are recorded into view: screens open from a circle, lists land one by one, and
  // each band acts out its claim. Nothing is hidden unless this runs, and none of it runs for anyone
  // who asked for less motion. Loops run only while they can be seen.
  const motion = !still && "IntersectionObserver" in window;
  const whileSeen = (element, start, stop) => {
    let on = false;
    new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting && !on) { on = true; start(); }
      if (!e.isIntersecting && on) { on = false; stop(); }
    }), { threshold: 0.25 }).observe(element);
  };

  if (motion) {
    document.documentElement.classList.add("motion");

    const heading = document.querySelector(".hero h1");
    if (heading) {
      const words = heading.textContent.trim().split(/\s+/);
      heading.setAttribute("aria-label", heading.textContent.trim());
      heading.replaceChildren(...words.flatMap((word, i) => {
        const span = document.createElement("span");
        span.className = "w";
        span.setAttribute("aria-hidden", "true");
        span.style.setProperty("--i", i);
        span.textContent = word;
        return i < words.length - 1 ? [span, document.createTextNode(" ")] : [span];
      }));
    }

    // A screen clipped to a dot does not count as seen, so a screen is watched through its parent.
    const reveals = new Map();
    const seen = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      (reveals.get(e.target) || [e.target]).forEach((element) => element.classList.add("in"));
      seen.unobserve(e.target);
    }), { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
    const watch = (selector, kind) => document.querySelectorAll(selector).forEach((element) => {
      if (element.closest(".hero")) return;
      element.classList.add(kind);
      if (kind !== "iris") return seen.observe(element);
      const parent = element.parentElement;
      reveals.set(parent, [...(reveals.get(parent) || []), element]);
      seen.observe(parent);
    });
    watch(".band h2:not(.panel-title), .head > p, .page-head > .wrap > p, .close p, .close .actions, .maker-mark", "rise");
    watch(".shot, .demo, .sync", "iris");
    watch(".mic-strip", "rise");
    document.querySelectorAll(".iris").forEach((element) => {
      element.addEventListener("transitionend", (e) => {
        if (e.propertyName === "clip-path" && element.classList.contains("in")) element.classList.add("settled");
      });
    });
    // List items land in order, at most eight steps of delay, so long lists do not keep you waiting.
    [".filegrid > li", ".no-list > li", ".facts-row > li", ".points > li", ".feat-list > li", ".steps > li", ".get > .get-card"].forEach((selector) => {
      document.querySelectorAll(selector).forEach((item) => {
        const index = [...item.parentElement.children].indexOf(item);
        item.style.setProperty("--i", Math.min(index, 8));
        item.classList.add("land");
        seen.observe(item);
      });
    });
  }

  // Me and Screen: the four face shapes take turns.
  const shapes = document.querySelector(".shape-row");
  if (shapes && motion) {
    const all = [...shapes.querySelectorAll(".shape")];
    let at = 0, timer = null;
    const step = () => { all.forEach((shape, i) => shape.classList.toggle("on", i === at)); at = (at + 1) % all.length; };
    whileSeen(shapes, () => { shapes.classList.add("cycling"); step(); timer = setInterval(step, 1500); },
                      () => { clearInterval(timer); shapes.classList.remove("cycling"); all.forEach((s) => s.classList.remove("on")); });
  }

  // Phones: the frame switches between Wide 16:9 and Tall 9:16.
  const aspect = document.querySelector(".aspect");
  if (aspect && motion) {
    let timer = null;
    whileSeen(aspect, () => { timer = setInterval(() => aspect.classList.toggle("tall"), 2600); },
                      () => { clearInterval(timer); });
  }

  // Microphones: three live meters, each with its own voice. Held at fixed levels for less motion.
  document.querySelectorAll(".mic-strip").forEach((strip) => {
    const meters = [...strip.querySelectorAll(".mic-meter")].map((meter) => {
      const segments = Array.from({ length: 14 }, (_, i) => {
        const segment = document.createElement("i");
        if (i >= 11) segment.className = "amber";
        meter.appendChild(segment);
        return segment;
      });
      return segments;
    });
    const show = (levels) => meters.forEach((segments, m) => segments.forEach((s, i) => s.classList.toggle("on", i < levels[m])));
    if (!motion) { show([9, 6, 4]); return; }
    let t = 0, timer = null;
    const voice = (phase, loud) => Math.max(0, Math.round(loud * Math.abs(Math.sin(t / 3.3 + phase) * Math.sin(t / 7.9 + phase * 2)) + Math.random() * 2.2));
    whileSeen(strip, () => { timer = setInterval(() => { t++; show([voice(0, 12), voice(1.7, 9), voice(3.1, 7)]); }, 110); },
                     () => { clearInterval(timer); show([0, 0, 0]); });
  });

  // Open source: a request is typed to Claude Code, the files it edits appear, and the timer it
  // added starts counting down. Shown finished for less motion or without JavaScript.
  document.querySelectorAll(".chat").forEach((chat) => {
    if (!motion) return;
    const typed = chat.querySelector(".chat-typed");
    const text = typed.dataset.text;
    const lines = [...chat.querySelectorAll(".chat-claude > *")];
    const time = chat.querySelector(".rec-time");
    const ring = chat.querySelector(".rec-ring");
    let timers = [];
    const later = (ms, run) => timers.push(setTimeout(run, ms));
    const reset = () => {
      timers.forEach(clearTimeout); timers.forEach(clearInterval); timers = [];
      chat.classList.remove("typing", "result", "playing");
      lines.forEach((line) => line.classList.remove("shown", "past"));
      typed.textContent = "";
      time.textContent = "10:00";
      ring.style.setProperty("--used", 0);
    };
    const play = () => {
      reset();
      chat.classList.add("typing", "playing");
      [...text].forEach((_, i) => later(300 + i * 38, () => { typed.textContent = text.slice(0, i + 1); }));
      const typedAt = 300 + text.length * 38 + 350;
      later(typedAt, () => chat.classList.remove("typing"));
      [0, 900, 1500, 2200, 3700].forEach((delay, i) => later(typedAt + delay, () => {
        lines[i].classList.add("shown");
        lines.slice(0, i).forEach((line) => line.classList.add("past"));
      }));
      later(typedAt + 4300, () => {
        chat.classList.add("result");
        let left = 600;
        timers.push(setInterval(() => {
          left -= 1;
          time.textContent = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`;
          ring.style.setProperty("--used", (276.5 * (600 - left) / 600).toFixed(1));
        }, 1000));
      });
    };
    let loop = null;
    whileSeen(chat, () => { play(); loop = setInterval(play, 16000); },
                    () => { clearInterval(loop); reset(); });
  });
})();
