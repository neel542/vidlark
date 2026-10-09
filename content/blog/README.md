# Writing a post for the Vidlark blog

Every post is one Markdown file in this folder. `python3 Tools/blog.py` turns them into pages on
the website at `vidlark.neelmadhav.dev/blog`. The pages it writes are committed, because Vercel serves
the `website/` folder as it is, with no build step.

## Add a post in four steps

1. **Make the file** `content/blog/<slug>.md`. The file name is the web address: the post above is
   at `/blog/<slug>`. Lowercase letters, numbers and hyphens only, under 70 characters, built around
   the search phrase (for example `free-loom-alternative-for-mac.md`). Never rename a published post:
   its old address would stop working.
2. **Make the cover** if you have no image of your own:

   ```bash
   node Tools/blog_cover.js <slug> "<title>" "<category>"
   ```

   It writes `website/assets/img/blog/<slug>.webp` (1600x900, the cover), `<slug>-social.jpg`
   (1200x630, for link previews) and a `.json` beside each that says how it was made. Or run
   `python3 Tools/blog.py --covers` to make one for every post whose cover file is missing.
3. **Build and check:**

   ```bash
   python3 Tools/blog.py
   ```

   It writes the post's page, the blog's list, the RSS feed, the sitemap and the home page's
   "From the blog" strip, then checks the whole site. Fix every `ERROR` (nothing is written while
   there are errors). Read every `WARNING`: each one is something a reader or Google will notice.
   `python3 Tools/blog.py --check` checks without writing; add `--strict` to fail on warnings too.
4. **Look at it**, then commit the `.md`, the images and everything the script changed in `website/`.

## The front matter

The file starts with these fields between two `---` lines, then the post's words.

```yaml
---
title: How to record your camera and screen as separate files
seo_title: Record your camera and screen separately, free
description: Record your camera and screen separately in one take, free on Mac and Windows. See every file Vidlark saves, where it goes and how the files stay in sync.
date: 2026-10-09
updated: 2026-10-09
keyword: record your camera and screen separately
category: Guides
cover: /assets/img/blog/record-camera-and-screen-separately.webp
cover_alt: A green card that says How to record your camera and screen as separate files
faq:
  - q: Does Vidlark still make one finished video?
    a: Yes. When you share your screen, Vidlark makes `video.mp4` after you stop.
  - q: Does this work on Windows too?
    a: Yes. The Windows beta records your camera, mics and screen as separate files.
related:
  - phone-as-webcam-on-mac
---
```

| Field | Needed | What it is |
|---|---|---|
| `title` | Yes | The page's heading (its only h1). Under 60 characters. |
| `seo_title` | No | The browser tab and Google's blue link, when it should differ from `title`. Under 60 characters. " \| Vidlark" is added when it fits. |
| `description` | Yes | Google's grey text under the link, and the text on cards and link previews. 140 to 160 characters, with the keyword in it. |
| `date` | Yes | The day it is published, as `YYYY-MM-DD`. Posts are listed newest first. |
| `updated` | No | The day it last changed in a way a reader would care about. Shown as "Updated" when it differs from `date`. |
| `keyword` | Yes | The one search phrase the post is for. Put it in the title or `seo_title`, the description and the first paragraph. |
| `category` | Yes | Exactly one of `Guides`, `Comparisons`, `Tutorials`, `Use cases`, `Behind the build`. It picks the colour: green, sky, pink, sun, lime. |
| `cover` | Yes | A path under `/assets/img/blog/`. |
| `cover_alt` | Yes | What the cover shows, in plain words, for people who cannot see it. |
| `faq` | No | Questions and answers shown at the end of the post and marked up for Google. Each item has `q:` and `a:`. Answers can use `code` and [links](/how-to). Only real questions the post answers. |
| `related` | No | Up to three slugs of other posts to show under "Keep reading". The rest is filled from the same category, then the newest posts. |
| `draft` | No | `draft: true` keeps the post off the site until you remove it. |

The front matter is simple YAML: one `key: value` per line. A long value can carry on to the next
line if that line is indented. Put a value in double quotes if it starts with a quote mark, a `[`,
or contains ` #`. Lists are lines that start with `  - `.

## What the words can use

Markdown, with these parts (anything else shows as plain text, and HTML is shown as text, never run):

- `## Section` and `### Smaller heading` (and `####`). Never `#`: the title is the page's only h1.
  A post with three or more `##` sections and 700 or more words gets a table of contents.
- Paragraphs, **bold**, *italic*, `code`, [links](/features) and plain web addresses in `<https://...>`.
- Lists with `-` or `1.`, and lists inside lists (indent them by two spaces, or three under `1.`).
- Code blocks between three backticks, with a language name if you like: ```` ```bash ````.
  They get a Copy button.
- Quotes with `>`. They show as a note box, so they suit tips: `> **Good to know:** ...`
- Simple tables with `|` and a `|---|---|` line under the header. Put `\|` for a `|` inside a cell.
- Images, on a line of their own: `![What the picture shows](/assets/img/guide-done.webp "A caption")`.

Links to other pages on the site start with `/` (`/how-to#files`, `/blog/<slug>`). The script stops
if one goes nowhere, so a broken link never ships.

## Images

- **Alt text on every image.** Say what is in it, as you would to someone on the phone. The script
  stops on an image without alt text.
- **Covers are 1600x900 WebP, under 300 KB**, in `website/assets/img/blog/<slug>.webp`. Use
  `Tools/blog_cover.js` for a branded card. For any other cover (a picture you made), save it at
  1600x900 as WebP with `cwebp -q 85 in.png -o website/assets/img/blog/<slug>.webp`, write a
  `<slug>.webp.json` beside it that says where it came from, then run
  `node Tools/blog_cover.js --social <slug>` to make its link-preview version.
- **Pictures inside a post** can be the app's real screens already in `website/assets/img/`
  (`guide-*.webp`, `recording-box.webp`, `sources-mics.webp`, `wide-recording.webp` and others;
  the `.json` beside each says what it shows), or new files in `website/assets/img/blog/`, named
  `<slug>-<what>.webp`, at most 1600 wide, each with its `.json`.
- Every picture of the app must be a real capture of Vidlark, never a mock-up. Never put a
  person's private details, a real email address or anything from someone else's account in a picture.

## How it should read

- Plain words, short sentences, sentence case. Write for someone who has never heard of Vidlark.
- **No em dashes, anywhere.** Use a comma, a colon, a full stop or brackets. The script stops on one.
- Only true facts about Vidlark. Check them against `README.md` and the website. Say plainly what
  is Mac only (the transcript, phones, live view and the prompter are not in the Windows beta yet).
- Be fair to other apps. Say what they do well, and only state what you can check today.
- The author shown is Neel Madhav. Do not add other personal details.
- Every post ends with a "Get Vidlark free" box by itself, so the words do not need their own.
