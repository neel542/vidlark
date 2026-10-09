#!/usr/bin/env node
// The 1200x630 link-preview cards for the website's main pages, rendered from HTML with
// Playwright in the site's colour-field style. Each page's card uses that page's head field.
//
//   node Tools/og_cards.js            writes website/assets/img/og/<page>.jpg (and a .json each)
//
// Blog posts get their own cards from Tools/blog_cover.js. Needs Playwright (see that file).

const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const IMG = path.join(ROOT, "website", "assets", "img");
const OUT = path.join(IMG, "og");

const PAGES = [
  { name: "home", field: "#1fd17c", title: "Record your face, voice and screen. Free.",
    sub: "The free, open source Loom alternative for Mac and Windows.", shot: "wide-recording.webp" },
  { name: "features", field: "#5d9cff", title: "Every feature. All free.",
    sub: "Camera, screen, phones, mics, transcript and YouTube chapters.", shot: "sources-angles.webp" },
  { name: "how-to", field: "#ff74b0", title: "How to use Vidlark",
    sub: "Install it free on a Mac or a Windows PC, then record your first video.", shot: "guide-share-picker.webp" },
  { name: "feedback", field: "#ffd43d", title: "Tell us what to make better.",
    sub: "A bug, an idea or a question about Vidlark. It goes straight to Neel.", shot: "recording-box.webp" },
  { name: "blog", field: "#ffd43d", title: "The Vidlark blog",
    sub: "Guides to recording videos with your camera, mic and screen.", shot: null },
];

function loadPlaywright() {
  for (const t of [process.env.PLAYWRIGHT_DIR, "playwright", path.join(os.homedir(), "hyperframes-student-kit", "node_modules", "playwright")].filter(Boolean)) {
    try { return require(t); } catch (e) { /* next */ }
  }
  console.error("Playwright was not found. Set PLAYWRIGHT_DIR to a folder that has it.");
  process.exit(1);
}

function html(page) {
  const mark = fs.readFileSync(path.join(ROOT, "website", "assets", "mark.svg"), "utf8");
  let shot = "";
  if (page.shot) {
    const data = fs.readFileSync(path.join(IMG, page.shot)).toString("base64");
    shot = `<div class="shot ${page.shot.startsWith("sources") || page.shot.startsWith("recording-box") ? "narrow" : ""}"><img src="data:image/webp;base64,${data}"></div>`;
  }
  const tags = [["#1fd17c", "video.mp4"], ["#ff74b0", "camera.mov"], ["#5d9cff", "screen.mov"], ["#ffd43d", "words.json"], ["#d6f64e", "chapters.txt"]];
  return `<!doctype html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,400..800&family=JetBrains+Mono:wght@500&display=block" rel="stylesheet">
<style>
  * { box-sizing: border-box; margin: 0; }
  html, body { width: 1200px; height: 630px; overflow: hidden; }
  body { background: ${page.field}; color: #0e1f16; font-family: "Bricolage Grotesque", sans-serif; position: relative; -webkit-font-smoothing: antialiased; }
  .text { position: absolute; left: 72px; top: 60px; bottom: 60px; width: ${page.shot ? 560 : 1000}px; display: flex; flex-direction: column; }
  .brand { display: flex; align-items: center; gap: 12px; font-weight: 800; font-size: 34px; letter-spacing: -0.02em; }
  .brand svg { width: 48px; height: 48px; }
  .brand b { margin-left: 8px; font-size: 20px; background: ${page.field === "#ffd43d" ? "#fff" : "#ffd43d"}; border: 2px solid #0e1f16; border-radius: 999px; padding: 3px 12px; }
  .mid { flex: 1; display: flex; flex-direction: column; justify-content: center; }
  h1 { font-weight: 800; font-size: ${page.shot ? 76 : 110}px; line-height: 1.0; letter-spacing: -0.03em; font-variation-settings: "opsz" 96, "wdth" 88; text-wrap: balance; }
  p { margin-top: 22px; font-size: 27px; line-height: 1.3; font-weight: 600; max-width: 30ch; font-variation-settings: "opsz" 24; }
  .tags { display: flex; flex-wrap: wrap; gap: 8px; }
  .tag { display: inline-flex; align-items: center; gap: 8px; background: #fff; border: 2px solid #0e1f16; border-radius: 12px; padding: 6px 11px;
    font-family: "JetBrains Mono", monospace; font-weight: 500; font-size: 17px; box-shadow: 0 8px 16px -10px rgba(14, 31, 22, 0.6); }
  .tag i { width: 11px; height: 11px; border-radius: 3px; }
  .shot { position: absolute; right: 64px; top: 72px; width: 500px; background: #0e1110; border: 2px solid rgba(14, 31, 22, 0.9); border-radius: 22px; overflow: hidden;
    box-shadow: 0 34px 70px -34px rgba(14, 31, 22, 0.8); }
  .shot.narrow { width: 400px; right: 92px; }
  .shot img { display: block; width: 100%; }
</style></head><body>
<div class="text">
  <div class="brand">${mark}Vidlark<b>Free</b></div>
  <div class="mid"><h1>${page.title}</h1><p>${page.sub}</p></div>
  <div class="tags">${tags.slice(0, page.shot ? 3 : 5).map(([c, n]) => `<span class="tag"><i style="background:${c}"></i>${n}</span>`).join("")}</div>
</div>
${shot}
</body></html>`;
}

(async () => {
  const { chromium } = loadPlaywright();
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const today = new Date().toISOString().slice(0, 10);
  for (const page of PAGES) {
    const tab = await browser.newPage({ viewport: { width: 1200, height: 630 } });
    await tab.setContent(html(page), { waitUntil: "networkidle" });
    await tab.evaluate(() => document.fonts.ready);
    if (!(await tab.evaluate(() => document.fonts.check('800 80px "Bricolage Grotesque"')))) {
      throw new Error("The Bricolage Grotesque font did not load (is the computer online?).");
    }
    const file = path.join(OUT, `${page.name}.jpg`);
    await tab.screenshot({ path: file, type: "jpeg", quality: 88 });
    await tab.close();
    const from = page.shot ? ` The screen on it is ${page.shot}, a real capture of the app already on the site.` : "";
    fs.writeFileSync(file + ".json", JSON.stringify({
      prompt: `Origin: not generated by an image model. A 1200x630 link-preview card for the ${page.name} page, rendered from HTML by Tools/og_cards.js with Playwright (Chromium) on ${today}, in the website's colour-field style.${from}`,
      createdAt: new Date().toISOString(),
    }, null, 2) + "\n");
    console.log(`Wrote ${path.relative(ROOT, file)} (${Math.round(fs.statSync(file).size / 1024)} KB)`);
  }
  await browser.close();
})().catch((e) => { console.error(e.message || e); process.exit(1); });
