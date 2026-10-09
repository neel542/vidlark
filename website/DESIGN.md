---
name: Vidlark website
description: A bright, colour-drenched home for a free Mac recorder, proven by acting out one real take.
colors:
  green: "#1fd17c"
  green-deep: "#0a7340"
  sun: "#ffd43d"
  sky: "#5d9cff"
  pink: "#ff74b0"
  lime: "#d6f64e"
  rec: "#f04e3e"
  ink: "#0e1f16"
  ink-soft: "#2c4036"
  paper: "#ffffff"
  mist: "#f0f7f2"
  line: "rgba(14, 31, 22, 0.12)"
  night: "#0e1110"
  sage: "#b9c9c0"
typography:
  display:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "clamp(2.7rem, 6.4vw, 5.6rem)"
    fontWeight: 800
    lineHeight: 1.02
    letterSpacing: "-0.035em"
    fontVariation: "'opsz' 96, 'wdth' 88"
  display-page:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "clamp(2.6rem, 6vw, 5rem)"
    fontWeight: 800
    lineHeight: 1.02
    letterSpacing: "-0.035em"
    fontVariation: "'opsz' 96, 'wdth' 88"
  headline:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "clamp(2.1rem, 4.4vw, 3.7rem)"
    fontWeight: 800
    lineHeight: 1.02
    letterSpacing: "-0.035em"
    fontVariation: "'opsz' 96, 'wdth' 88"
  headline-compact:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "clamp(1.8rem, 3.2vw, 2.5rem)"
    fontWeight: 800
    lineHeight: 1.02
    letterSpacing: "-0.035em"
    fontVariation: "'opsz' 96, 'wdth' 88"
  title:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "1.12rem"
    fontWeight: 800
    lineHeight: 1.15
    letterSpacing: "-0.02em"
    fontVariation: "'opsz' 24, 'wdth' 92"
  body-lead:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "1.2rem"
    fontWeight: 400
    lineHeight: 1.5
    fontVariation: "'opsz' 14"
  body:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 400
    lineHeight: 1.55
    fontVariation: "'opsz' 14"
  button:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "1.05rem"
    fontWeight: 800
    letterSpacing: "-0.01em"
  label:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "0.92rem"
    fontWeight: 700
  caption:
    fontFamily: "Bricolage Grotesque, system-ui, sans-serif"
    fontSize: "0.92rem"
    fontWeight: 600
  mono:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "0.86em"
    fontWeight: 400
rounded:
  pill: "999px"
  panel: "22px"
  tile: "16px"
  well: "14px"
  small: "12px"
  tag: "3px"
spacing:
  container: "1180px"
  gutter: "20px"
  band: "clamp(72px, 10vw, 128px)"
  column: "56px"
  split: "clamp(36px, 6vw, 80px)"
  cluster: "12px"
  chip: "8px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: "15px 22px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: "15px 22px"
  button-ghost-hover:
    backgroundColor: "rgba(14, 31, 22, 0.08)"
  button-nav:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.pill}"
    padding: "10px 16px"
  nav-link:
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "8px 12px"
  nav-link-hover:
    backgroundColor: "rgba(14, 31, 22, 0.08)"
  nav-link-current:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
  chip-fact:
    backgroundColor: "rgba(255, 255, 255, 0.55)"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "6px 12px 6px 9px"
  chip-free:
    backgroundColor: "{colors.sun}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "5px 11px"
  tile-promise:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.tile}"
    padding: "16px 18px"
  file-tag:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.small}"
    padding: "6px 9px"
  card-shot:
    backgroundColor: "{colors.night}"
    rounded: "{rounded.panel}"
  panel:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.panel}"
    padding: "22px"
  group-head:
    backgroundColor: "{colors.green}"
    textColor: "{colors.ink}"
    rounded: "20px"
    padding: "18px 20px"
  note:
    backgroundColor: "{colors.mist}"
    textColor: "{colors.ink}"
    rounded: "{rounded.well}"
    padding: "16px 18px"
  code-block:
    backgroundColor: "{colors.ink}"
    textColor: "#e9f3ed"
    rounded: "{rounded.well}"
    padding: "14px 88px 14px 16px"
  step-number:
    backgroundColor: "{colors.green}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    size: "36px"
  footer:
    backgroundColor: "{colors.ink}"
    textColor: "#dfe9e3"
---

# Design System: Vidlark website

This file describes the marketing website in `website/` only. The native Mac app has its own, separate system in the repository's root `DESIGN.md`; the two worlds share the record red and nothing else should be carried across without a decision.

## Overview

**Creative North Star: "The Colour-Field Take"**

The site is a bright home for a free Mac recorder. Whole bands of the page are drenched in one saturated field colour each (signal green, sun yellow, sky blue, pink, lime) and the type sits on them in a dark green ink. Against all that colour the product appears only as itself: the app's own dark windows, framed like screens, and one drawn take that records, switches between Me and Screen, stops, and drops its files. The proof is the take, not a feature grid.

Density is generous and confident. Headlines are big, heavy and condensed; body text is plain and short. Each band has one job (a headline, one or two sentences, then a list of checked points or a product screen), so the page reads as a run of colour slides rather than a dashboard. Small details are borrowed from the app: the red record dot, the recording box, file names in mono, the green lamp that means ready.

The confirmed rejection is the category default this site was built against: a screenshot in a browser frame with a grid of icon cards under it.

**Key Characteristics:**
- One field colour per full-width band, with ink type on every field.
- One variable grotesque for everything, condensed and heavy at display sizes.
- The app's own dark screens as the only product imagery.
- 1.5px ink keylines on the solid objects that sit on colour.
- Pill-shaped actions; softly rounded containers.
- One authored motion: a take being recorded.

## Colors

Five saturated fields on a white page, all spoken over in one green-black ink, with a single red kept for recording.

### Primary
- **Signal Green** (#1fd17c): the brand's own field. The home hero band, the step numbers on How to use it, the active Me or Screen segment in the recording box, the sync lamp once files are lined up, the finished video's file tag, and the home page's browser theme colour.
- **Deep Leaf** (#0a7340): check icons on white tiles and white-washed chips, the current page in the phone menu, the scrollbar thumb. It reads at 5.4 to 5.9:1 on paper and mist but only 2.2 to 3:1 on green, sky and pink, so it never sits directly on those fields.

### Secondary
The four companion fields. Each owns whole bands and also serves as a small square tag.
- **Sun Yellow** (#ffd43d): the Free pill in the header, the free note in the page sidebars, the Me and Screen band on Home, sound and transcript file tags.
- **Sky Blue** (#5d9cff): the Features page head (and its theme colour), the phone camera band on Home, screen file tags.
- **Candy Pink** (#ff74b0): the How to use it page head (and its theme colour), the microphones band on Home, camera file tags.
- **Lime Zest** (#d6f64e): the closing free band on every page, chapters and retakes file tags, text selection, link hover in the footer.

Each page claims one field for its head band and sets its browser theme colour to match: Home green, Features sky, How to use it pink, Feedback sun. Every field is now claimed, so a new page shares one and still closes on lime.

### Tertiary
- **Record Red** (#f04e3e): the record dot and the stop square in the drawn recording box, and the centre of the site mark. It is the same red the app uses, and it means recording.

### Neutral
- **Forest Ink** (#0e1f16): all text on paper and on every field, primary buttons, the current nav pill, keylines, the dark "safe and light" band, code blocks and the footer.
- **Moss Ink** (#2c4036): secondary text (notes under screens, captions, lead copy in quiet bands, feature descriptions).
- **Paper** (#ffffff): the page, tiles and panels that sit on fields, and text on ink.
- **Mint Mist** (#f0f7f2): the quiet band (the demo slot), notes, the scrollbar track, sidebar link hover.
- **Hairline** (12% ink): dividers in lists and tables, the bottom edge of the header.
- **Screen Night** (#0e1110): the frame behind every app capture, the drawn laptop's bezel, the demo slot.
- **Sage** (#b9c9c0): secondary text on ink (the dark band and the footer copy).

### Named Rules
**The One Field Per Band Rule.** A band is one colour: a field, paper, mist or ink. Fields never gradient into each other and never share a band. Inside a band, other field colours appear only as small square tags (file and contents markers) or inside the drawn screen of the take.

**The Ink On Colour Rule.** Text on any field is Forest Ink. White text belongs only on ink and night. On sky and pink, secondary text stays full ink, because Moss Ink falls to 4 to 4.4:1 there.

**The Red Means Recording Rule.** Record Red is the record dot and the stop square, and nothing else. It is never an error colour, a link, a highlight or a button.

## Typography

**Display Font:** Bricolage Grotesque (with system-ui, sans-serif)
**Body Font:** Bricolage Grotesque at text optical size (same fallback)
**Label/Mono Font:** JetBrains Mono (with ui-monospace, monospace)

**Character:** One variable grotesque does both jobs, pulled heavy and condensed at display sizes and relaxed at reading sizes, so headlines shout and body text stays friendly. Mono appears only where the app itself would print something.

### Hierarchy
- **Display** (800, clamp(2.7rem, 6.4vw, 5.6rem), 1.02): the home hero headline, held to about 11 characters a line.
- **Display Page** (800, clamp(2.6rem, 6vw, 5rem), 1.02): the head band headline on inner pages, held to about 14 characters a line.
- **Headline** (800, clamp(2.1rem, 4.4vw, 3.7rem), 1.02): one per band.
- **Headline Compact** (800, clamp(1.8rem, 3.2vw, 2.5rem), 1.02): feature group heads and How to use it sections. The How to use it sections currently run a hair larger (clamp(1.9rem, 3.4vw, 2.6rem)); new work uses the token.
- **Title** (800, 1.12rem, 1.15, titles at opsz 24 and wdth 92): each feature's name in the Features lists. Footer column heads step down to 0.95rem.
- **Body Lead** (400, 1.2rem, 1.5): the sentence under a headline, 34 to 58 characters wide. Hero and page heads run at 1.22rem, the same step.
- **Body** (400, 18px, 1.55): reading text; long pages hold to 70 characters.
- **Button** (800, 1.05rem, -0.01em): every button label.
- **Label** (700, 0.92rem): fact chips, face shape names, sidebar links (at 0.98rem).
- **Caption** (600, 0.92rem, Moss Ink): notes under screens, the requirements line, the take's live caption. Existing captions sit between 0.88 and 0.95rem; that is one step.
- **Mono** (400 or 500, 0.86em): file names, paths, terminal commands and the recording timer (with tabular figures).

### Named Rules
**The Condensed Shout Rule.** Every heading is weight 800 at display optical size and condensed width (opsz 96, wdth 88; titles at opsz 24, wdth 92), tracked tight, with line height near 1 and balanced wrapping. Contrast comes from size and width, never from a second display face.

**The Filename Rule.** Mono is for real file names, paths, commands and the timer. Never for labels, numbers in prose or decoration.

## Layout

A centred container of 1180px with a 20px gutter on each side, inside full-bleed bands. Bands breathe at clamp(72px, 10vw, 128px) top and bottom. The sticky header is 68px tall.

- **Hero:** two columns, text and the take (1fr to 1.18fr, the take larger), 56px apart, stacking below 980px.
- **Split band:** two equal columns, clamp(36px, 6vw, 80px) apart, text on one side and a screen or demo on the other. Consecutive splits alternate sides. They stack below 900px with the text first.
- **Docs and features:** a 230px sticky sidebar of contents beside the content, 56px apart, collapsing below 900px into a wrapping grid of links above the content. Long text holds to 70 characters.
- **Lists of facts:** checked points are rows separated by rules, not cards. The four facts on the dark band are columns divided by thin light rules, going to two columns below 900px and one below 520px.
- **Clusters:** buttons sit 12px apart; fact chips 8px apart.

Breakpoints that matter: 980px (hero stacks), 900px (splits and sidebars stack), 760px (the header becomes a menu button and the footer goes to two columns), 520px (single column for everything).

## Elevation & Depth

A hybrid. The bands are flat colour; depth belongs only to objects resting on them. Every shadow is soft, tinted with ink rather than black, pulled in with a negative spread and dropped straight down, so objects look like they sit a little above the colour.

### Shadow Vocabulary
- **Button** (`box-shadow: 0 10px 22px -12px rgba(14, 31, 22, 0.7)`, hover `0 16px 28px -14px rgba(14, 31, 22, 0.75)`): primary buttons. Ghost buttons have none.
- **Small lift** (`box-shadow: 0 8px 16px -10px rgba(14, 31, 22, 0.6)`): file tags (the face shape samples use a near twin).
- **Ambient** (`box-shadow: 0 18px 40px -18px rgba(14, 31, 22, 0.45), 0 4px 12px -4px rgba(14, 31, 22, 0.18)`): white panels on a band, the phone menu, the maker tile.
- **Product** (`box-shadow: 0 34px 70px -34px rgba(14, 31, 22, 0.8)`): app captures and the demo slot.
- **Device** (`box-shadow: 0 40px 80px -30px rgba(14, 31, 22, 0.75)`): the drawn laptop in the hero, the deepest object on the site.

The header is the one translucent surface: paper at 88% (green at 90% on Home) with a 14px blur.

### Named Rules
**The Lift What Sits On The Field Rule.** Bands never cast or carry shadows. Only objects resting on a field are lifted, and only with the soft vocabulary above. Never a hard offset shadow.

## Shapes

Actions are full pills: buttons, nav links, the Free pill, fact chips, step numbers. Containers are softly rounded and get rounder as they get bigger: 22px for app captures, panels and the demo slot, 20px for feature group heads, 16px for promise tiles and face shapes, 14px for code blocks and notes, 12px for file tags. Colour tags are tiny rounded squares (3 to 4px radius) and never circles; circles are kept for the record dot, lamps, the face and the step numbers.

### Named Rules
**The Ink Keyline Rule.** Solid objects that sit on colour (buttons, the Free pill, promise tiles, file tags, group heads and their icon chips, the sync panel, step numbers) carry a 1.5px Forest Ink border. Dividers inside lists are hairlines (1px at 12% ink, or 1.5px at 18% ink on a field). The translucent fact chips carry no keyline. The heavier lines are deliberate: a 2px ink rule under table headers and the 10px night bezel of the drawn laptop.

## Components

### Buttons
Bold, inked and a little springy.
- **Shape:** full pill (999px), 1.5px ink keyline, 20px icon leading or trailing with a 10px gap.
- **Primary:** ink fill, paper text, Button type, 15px by 22px padding, button shadow. The main action is always "Get it on GitHub" with the GitHub icon.
- **Hover / Focus:** lifts 2px with a deeper shadow over 0.25s on the soft ease-out; returns on press. Focus is a 3px ink outline offset 3px, on paper and on the fields, and a lime outline on ink (the footer, the ink band and the code blocks).
- **Ghost:** transparent with ink text and keyline, an 8% ink wash on hover, a trailing arrow. It always pairs with a primary, never stands alone.
- **In the header:** the same primary at 10px by 16px and 0.95rem.

### Chips
- **Fact chips:** white wash (55%) pills on the head field with a Deep Leaf check, Label type. They state what is free: Free, No account, No watermark, No time limit.
- **Free pill:** sun fill, ink keyline, 800 at 0.82rem, beside the brand in the header. Hidden on phones.
- **Promise tiles:** paper tiles on the lime band, 16px radius, ink keyline, 800 at 1.1rem, a Deep Leaf check. Two columns, one below 480px.

### Cards / Containers
- **App captures:** Screen Night behind, 22px radius, a 1.5px near-ink edge, product shadow, full-width image. Tall captures cap at 420px wide. A caption may sit under in Caption type, centred.
- **Panels:** paper, 22px radius, ink keyline, ambient shadow, 22px padding. Used for the sound line-up.
- **Feature group heads:** a bar in the group's field colour, 20px radius, ink keyline, with a 50px paper icon chip (15px radius, ink keyline, 25px icon) and a Headline Compact.
- **Notes:** mist, 14px radius, a faint 1.5px border in the hairline tint, 16px by 18px padding; may open with a bold phrase.

### Navigation
- **Header:** sticky, 68px, translucent paper (translucent green on Home, matching the hero) with a hairline bottom edge. Brand mark and name at 800, the Free pill, then links pushed right.
- **Links:** 600 at 0.98rem, pill padding 8px by 12px, an 8% ink wash on hover. The current page is an ink pill with paper text.
- **Phones (below 760px):** a 44 by 40px menu button with an ink keyline opens a paper panel under the header; links become full-width rows divided by hairlines, the current page turns Deep Leaf, and the GitHub button runs full width at the bottom.
- **Contents sidebar:** sticky at 92px from the top, links at 700 with a 10px colour square, a mist wash on hover, the field colours cycling in order (green, sky, pink, sun, lime). It ends with a sun note that everything is free.

### Steps
Numbered rows divided by hairlines. Each number is a 36px Signal Green circle with an ink keyline and an 800 numeral. The step opens with a bold instruction, then plain explanation, then any command.

On How to use it, a step carries the app's own screen for that moment, cropped to what the step is about, in the Screen Night frame at a 16px radius. Tall crops sit in a 300px column beside the words on wide screens; wide ones run under them; everything stacks below 1120px. Every step has an id so it can be linked. Supporting pieces: a before and after pair captioned with status chips (sun Before, green After); a click path of paper chips with ink keylines and small chevrons, for where to click in Xcode, System Settings or Windows Settings; keys as small paper keycaps; smaller numbered sub-steps in paper circles (the certificate); a parts list of hairline rows naming each control on a screen; and an If something goes wrong list of problem headings, each with its fix.

### Code Blocks
Ink wells with light text in mono at 0.88rem, 14px radius, wrapping long lines rather than scrolling. A small Copy button sits top right (dark green, turning Signal Green with "Copied" for under two seconds). Selection inside turns Signal Green.

### Tables
Full width, left aligned, a 2px ink rule under the header row and hairlines between rows. File names in mono.

### Footer
Ink, three columns (brand and one line, Pages, Get it), Sage copy, links turning lime on hover, a legal line under a faint rule.

### File Tags (signature)
How the site talks about output. A file name in mono beside a small rounded colour square, either as a white keyline tag landing under the take or as a row in the files grid. The colour means what the file holds and stays the same everywhere: green for the finished video, pink for any camera, sky for the screen, sun for extra mics and the transcript, lime for chapters and retakes.

### Mac and Windows
- **Platform tabs:** How to use it's head band holds two paper tiles (20px radius, ink keyline, soft lift): an icon, the platform name with a status chip, one line. They are the page's tabs; the chosen one turns ink with paper text. Each guide is a panel with its own contents sidebar; without JavaScript both panels show with a visible "On a Mac" / "On Windows" title.
- **Status chips:** small full pills with an ink keyline: green "Ready now", sun "Coming soon".
- **Get Vidlark cards (Home, mist band):** one paper card per platform, 22px radius, ink keyline, a heading with icon and status chip, one sentence, a primary and a ghost button.
- **A download that is not out yet:** the button keeps its shape with a dashed ink outline, Moss Ink label, no shadow, and cannot be pressed. `windowsDownload` at the top of site.js switches every Windows button, chip and note to ready in one place.

### Open source band (Home, ink)
The second ink band: "Open source. Make it yours." with ink-band points (lime checks, white hairlines), a lime primary button and a light ghost button. Beside it, a night card titled "Claude Code" acts out one change: a request types into a lime bubble, the files Claude edits land as rows with a green "Edited" chip, spinners turn into rings as each step finishes, then a 10 minute timer appears on a record button and counts down. It loops every 16 s only while on screen and shows its finished state for less motion or without JavaScript. How to use it closes with a mist "Change it with Claude" band: steps plus example requests as paper speech chips.

### Feedback form
- **Panel:** a paper panel, 22px radius, ink keyline, soft lift, at most 760px wide, fields 34px apart.
- **Choices:** radio buttons drawn as full pills with an ink keyline; the picked one fills Signal Green. The 1 to 5 rating uses 52px pills with Poor and Great under the ends.
- **Text fields:** 14px radius, 1.5px ink border, Body type.
- **Screenshot box:** a mist box with a dashed ink outline; the whole box opens the file picker, takes a dropped image, and Command-V or Ctrl-V anywhere pastes one. A picked image shows a small preview with Remove. Errors are 700 weight in a dark red (#a3261b, readable on paper), never the record red.
- **Sent:** a Signal Green panel replaces the form after FormSubmit sends people back with `?sent=1`.

### The Take (signature)
The site's one authored motion, in the home hero. A drawn laptop shows a slide; the camera view sits clipped to a face circle at the bottom right; a dark recording box shows Me and Screen, a red dot, a mono timer and a level meter. It records, grows the camera to fill the screen (Me), shrinks it back (Screen), stops under a dark veil, and the file tags land underneath one after another, every 14 seconds. It moves only transform, opacity and clip-path (0.5s on the in-out ease for the camera, 0.4 to 0.5s for the files, staggered by 0.1s), plays only while on screen, and with reduced motion shows its final frame with the files already landed.

### The Sound Line-Up
A smaller supporting demo inside a panel: waveforms for each source, the late ones sliding into line over 1.2s, a grey lamp turning Signal Green with "Lined up". It loops only while visible and holds the lined-up state for reduced motion.

### Motion across the page
One material idea: things are recorded into view. The app's screens (product shots, the demo slot, the sync panel) open from a circle once, like the record dot and the face circle, then drop the clip. Lists (files, promises, facts, points, features, steps, Get Vidlark cards) land one by one, at most eight steps of 70 ms. Band headings rise once. Each band also acts out its own claim, only while it is on screen: the four face shapes take turns (sun band), one frame switches between Wide 16:9 and Tall 9:16 with the same cover crop as the phone page (sky band), and a dark strip of three live mic meters rests on the Sources screenshot (pink band). A thin ink line under the nav fills with scroll where `animation-timeline` is supported. Feedback answers back: a picked choice pops, Send shows a blinking lime dot while it works, the chosen How to use it guide slides in. Everything is visible without JavaScript; the `.motion` class turns motion on only when reduced motion is not asked for, and then the loops hold still (meters at fixed levels, shapes and frame static).

## Do's and Don'ts

### Do:
- **Do** give each band one colour and keep every word on it in Forest Ink (#0e1f16).
- **Do** show the product only as real captures of the app's dark windows, in the Screen Night frame (22px radius, 1.5px ink edge, product shadow), with alt text that names what is on screen.
- **Do** make the main action an ink pill with a 1.5px ink keyline that lifts 2px on hover, and pair it with at most one ghost pill.
- **Do** colour file tags by what the file holds: green finished video, pink camera, sky screen, sun sound and transcript, lime chapters and retakes.
- **Do** give each page a head field, set its theme colour to match, and close the page on the lime free band.
- **Do** set file names, paths, commands and the timer in JetBrains Mono, and nothing else.
- **Do** move things with transform, opacity and clip-path only, play motion only while it is on screen, and hold the final frame for reduced motion.
- **Do** write in plain English, in sentence case.

### Don't:
- **Don't** put white text on any field, Moss Ink text on sky or pink, or Deep Leaf directly on green, sky or pink.
- **Don't** blend fields with gradients or put two fields side by side in one band.
- **Don't** use Record Red for anything but recording.
- **Don't** frame app captures in a fake browser window or lay features out as a grid of icon cards.
- **Don't** put uppercase or letterspaced labels above headings; a heading stands on its own.
- **Don't** use hard offset shadows or black shadows; shadows are soft, ink tinted and drop straight down.
- **Don't** add another full-stage animation; the take is the one performance, and supporting demos stay small inside a panel.
- **Don't** use AVA INC's orange video accent (#FF9900); it belongs to the edited videos, not this tool.
- **Don't** use em dashes anywhere in the copy.
