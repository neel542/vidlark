#!/usr/bin/env node
// Vidlark blog covers, rendered from HTML with Playwright in the website's colour-field style.
//
//   node Tools/blog_cover.js <slug> "<title>" "<category>"
//     writes website/assets/img/blog/<slug>.webp         1600x900, the post's cover
//            website/assets/img/blog/<slug>-social.jpg   1200x630, for link previews
//     and a .json beside each that says how it was made (the site's provenance rule).
//
//   node Tools/blog_cover.js --social <slug>
//     makes only <slug>-social.jpg, cropped from an existing cover (for a cover that is not
//     one of these cards, such as a photo or an illustration).
//
// The category picks the field colour: Guides green, Comparisons sky, Tutorials pink,
// Use cases sun, Behind the build lime. Needs Playwright (found in node_modules, or in
// ~/hyperframes-student-kit/node_modules, or set PLAYWRIGHT_DIR) and cwebp.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "website", "assets", "img", "blog");
const FIELDS = {
  "Guides": "#1fd17c",
  "Comparisons": "#5d9cff",
  "Tutorials": "#ff74b0",
  "Use cases": "#ffd43d",
  "Behind the build": "#d6f64e",
};

function loadPlaywright() {
  const tries = [
    process.env.PLAYWRIGHT_DIR,
    "playwright",
    path.join(os.homedir(), "hyperframes-student-kit", "node_modules", "playwright"),
  ].filter(Boolean);
  for (const t of tries) {
    try { return require(t); } catch (e) { /* try the next place */ }
  }
  console.error("Playwright was not found. Set PLAYWRIGHT_DIR to a folder that has it, for example\n" +
    "  PLAYWRIGHT_DIR=~/hyperframes-student-kit/node_modules/playwright node Tools/blog_cover.js ...");
  process.exit(1);
}

function cwebp() {
  for (const p of ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]) if (fs.existsSync(p)) return p;
  return "cwebp";
}

const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// One card. Every size is in units of s, so the same design renders at 1600x900 and 1200x630.
function cardHtml({ title, category, field, width, height }) {
  const s = width / 1600;
  const mark = fs.readFileSync(path.join(ROOT, "website", "assets", "mark.svg"), "utf8");
  const tags = [["#1fd17c", "video.mp4"], ["#ff74b0", "camera.mov"], ["#d6f64e", "chapters.txt"]];
  return `<!doctype html><html><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,400..800&family=JetBrains+Mono:wght@500&display=block" rel="stylesheet">
<style>
  * { box-sizing: border-box; margin: 0; }
  html, body { width: ${width}px; height: ${height}px; overflow: hidden; }
  body { background: ${field}; color: #0e1f16; font-family: "Bricolage Grotesque", sans-serif; -webkit-font-smoothing: antialiased; }
  .card { position: absolute; inset: 0; padding: ${76 * s}px ${96 * s}px ${72 * s}px; display: flex; flex-direction: column; }
  .top { display: flex; align-items: center; gap: ${22 * s}px; }
  .brand { display: flex; align-items: center; gap: ${16 * s}px; font-weight: 800; font-size: ${46 * s}px; letter-spacing: -0.02em; font-variation-settings: "opsz" 48; }
  .brand svg { width: ${64 * s}px; height: ${64 * s}px; }
  .cat { display: inline-flex; align-items: center; gap: ${12 * s}px; background: #fff; border: ${3 * s}px solid #0e1f16; border-radius: 999px;
    padding: ${9 * s}px ${24 * s}px ${9 * s}px ${18 * s}px; font-weight: 800; font-size: ${30 * s}px; letter-spacing: -0.01em; }
  .cat i { width: ${18 * s}px; height: ${18 * s}px; border-radius: ${5 * s}px; background: ${field}; border: ${2 * s}px solid #0e1f16; }
  .stage { flex: 1; display: flex; align-items: center; min-height: 0; padding: ${28 * s}px 0; }
  h1 { font-weight: 800; line-height: 1.0; letter-spacing: -0.026em; font-variation-settings: "opsz" 96, "wdth" 88;
    max-width: ${1340 * s}px; text-wrap: balance; overflow-wrap: break-word; }
  .bottom { display: flex; align-items: center; gap: ${12 * s}px; }
  .tag { display: inline-flex; align-items: center; gap: ${12 * s}px; background: #fff; border: ${3 * s}px solid #0e1f16; border-radius: ${16 * s}px;
    padding: ${10 * s}px ${16 * s}px; font-family: "JetBrains Mono", monospace; font-weight: 500; font-size: ${24 * s}px;
    box-shadow: 0 ${10 * s}px ${20 * s}px -${12 * s}px rgba(14, 31, 22, 0.6); }
  .tag i { width: ${16 * s}px; height: ${16 * s}px; border-radius: ${4 * s}px; }
  .site { margin-left: auto; font-weight: 800; font-size: ${30 * s}px; letter-spacing: -0.01em; }
</style></head><body>
<div class="card">
  <div class="top"><span class="brand">${mark}Vidlark</span><span class="cat"><i></i>${escapeHtml(category)}</span></div>
  <div class="stage"><h1 id="t">${escapeHtml(title)}</h1></div>
  <div class="bottom">${tags.map(([c, n]) => `<span class="tag"><i style="background:${c}"></i>${n}</span>`).join("")}<span class="site">vidlark.vercel.app</span></div>
</div>
<script>
  // The title takes the biggest size that fits in four lines without breaking a word.
  window.fit = () => {
    const h = document.getElementById("t"), stage = h.parentElement;
    let size = ${168 * s};
    const room = () => stage.clientHeight - ${56 * s};
    for (; size > ${60 * s}; size -= 2) {
      h.style.fontSize = size + "px";
      const lines = Math.round(h.offsetHeight / size);
      if (h.offsetHeight <= room() && lines <= 4 && h.scrollWidth <= h.clientWidth + 1) break;
    }
    return size;
  };
</script>
</body></html>`;
}

async function shoot(browser, html, width, height, file, type) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
  await page.setContent(html, { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts.ready);
  const loaded = await page.evaluate(() => document.fonts.check('800 80px "Bricolage Grotesque"'));
  if (!loaded) throw new Error("The Bricolage Grotesque font did not load (is the computer online?). No cover was written.");
  await page.evaluate(() => window.fit && window.fit());
  await page.screenshot(type === "jpeg" ? { path: file, type: "jpeg", quality: 88 } : { path: file, type: "png" });
  await page.close();
}

function provenance(file, text) {
  fs.writeFileSync(file + ".json", JSON.stringify({ prompt: text, createdAt: new Date().toISOString() }, null, 2) + "\n");
}

async function main() {
  const args = process.argv.slice(2);
  const today = new Date().toISOString().slice(0, 10);
  fs.mkdirSync(OUT, { recursive: true });

  if (args[0] === "--social") {
    const slug = args[1];
    if (!slug) { console.error("Usage: node Tools/blog_cover.js --social <slug>"); process.exit(1); }
    const src = ["webp", "jpg", "jpeg", "png"].map((e) => path.join(OUT, `${slug}.${e}`)).find((f) => fs.existsSync(f));
    if (!src) { console.error(`No cover found for ${slug} in website/assets/img/blog/`); process.exit(1); }
    const { chromium } = loadPlaywright();
    const browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
    const data = fs.readFileSync(src).toString("base64");
    const type = path.extname(src).slice(1).replace("jpg", "jpeg");
    await page.setContent(`<html><body style="margin:0"><img src="data:image/${type};base64,${data}" style="width:1200px;height:630px;object-fit:cover;display:block"></body></html>`);
    await page.waitForFunction(() => document.images[0].complete);
    const out = path.join(OUT, `${slug}-social.jpg`);
    await page.screenshot({ path: out, type: "jpeg", quality: 88 });
    await browser.close();
    provenance(out, `Origin: cropped by Tools/blog_cover.js on ${today} from ${path.basename(src)}, the post's cover, to 1200x630 for link previews.`);
    console.log(`Wrote ${path.relative(ROOT, out)}`);
    return;
  }

  const [slug, title, category = "Guides"] = args;
  if (!slug || !title) {
    console.error('Usage: node Tools/blog_cover.js <slug> "<title>" "<category>"\n       node Tools/blog_cover.js --social <slug>');
    process.exit(1);
  }
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) { console.error("The slug must be lowercase letters, numbers and hyphens."); process.exit(1); }
  const field = FIELDS[category];
  if (!field) { console.error(`The category must be one of: ${Object.keys(FIELDS).join(", ")}`); process.exit(1); }

  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const png = path.join(os.tmpdir(), `vidlark-cover-${slug}-${process.pid}.png`);
  const webp = path.join(OUT, `${slug}.webp`);
  const social = path.join(OUT, `${slug}-social.jpg`);
  try {
    await shoot(browser, cardHtml({ title, category, field, width: 1600, height: 900 }), 1600, 900, png, "png");
    const r = spawnSync(cwebp(), ["-quiet", "-q", "88", "-m", "6", png, "-o", webp], { stdio: "inherit" });
    if (r.status !== 0) throw new Error("cwebp failed. Install it with: brew install webp");
    await shoot(browser, cardHtml({ title, category, field, width: 1200, height: 630 }), 1200, 630, social, "jpeg");
  } finally {
    await browser.close();
    fs.rmSync(png, { force: true });
  }
  const how = `Origin: not generated by an image model. A cover card rendered from HTML by Tools/blog_cover.js with Playwright (Chromium) on ${today}, in the website's colour-field style (${category}, ${field}). Title: "${title}".`;
  provenance(webp, how + " Converted to WebP with cwebp.");
  provenance(social, how + " The 1200x630 version for link previews, saved as JPEG.");
  console.log(`Wrote ${path.relative(ROOT, webp)} (${Math.round(fs.statSync(webp).size / 1024)} KB) and ${path.relative(ROOT, social)}`);
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
