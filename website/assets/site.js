// Vidlark website: the menu on phones, copy buttons, the take in the hero, and the sync demo.
(function () {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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
})();
