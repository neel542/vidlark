---
title: "Why I Built a Free Loom Replacement at 14"
seo_title: "Why I Built a Free Loom Replacement at 14 | Vidlark"
description: "I'm Neel, a grade 9 student. I built Vidlark, a free open source recorder, to film my mother's YouTube videos. Here is why, what broke, and what is next."
date: 2026-10-09
updated: 2026-10-09
keyword: "student built open source app"
category: "Behind the build"
cover: "/assets/img/blog/why-i-built-vidlark.webp"
cover_alt: "A desk at night lit by a laptop, with a sketchbook of interface boxes, a phone on a stand and a red record dot, seen from behind a young person"
faq:
  - q: "Who made Vidlark?"
    a: "Neel Madhav, a 14-year-old grade 9 student, built it with Claude Code, Anthropic's coding assistant. It started on 4 October 2026 as a recorder for his mother's YouTube videos."
  - q: "Is Vidlark really free?"
    a: "Yes. It is open source under the MIT licence. There is no paid version, no account, no watermark and no time limit."
  - q: "Can I download Vidlark for Mac?"
    a: "Not as a ready-made app yet. On a Mac you build it once from the code with Xcode and a free Apple Development certificate. Windows 11 has a beta zip on GitHub."
  - q: "How can I help?"
    a: "Try it and tell us what goes wrong on the feedback page, test the Windows beta on your PC, or send a change on GitHub. You do not need to code: Claude Code can make changes from plain words."
related: ["free-loom-alternatives", "open-source-loom-alternatives", "record-youtube-video-mac"]
draft: true
---

I'm Neel Madhav. I'm 14, in grade 9, and I built Vidlark, a free and open source app that records your camera, your mic and your screen with one button and hands you a finished video. I built it because my mother makes YouTube videos, I run the camera, and the tools we had were made for a different job.

This is the story of the first week: what we needed, what broke, and why it is free.

## The problem: filming my mother's YouTube videos

Our filming days look like this. My mother sits at the MacBook. An iPhone sits on top of a screen in front of her, back camera facing her, as the camera. Her wireless mic's receiver plugs into the Mac. The slides and websites she is talking about are on the screen being recorded.

I run everything else. I pick the script, check the setup, handle the lights, and press start and stop. She should only have to think about one thing: talking to the camera.

That sounds simple. In practice it meant juggling a recorder, a teleprompter, a script in another window, and a pile of files afterwards that never quite lined up.

## Why Loom stopped fitting

Loom is good at what it is built for: a quick video message with a link you send to a colleague. Its share links, comments and viewer counts are genuinely useful for teams, and Vidlark does not have any of them.

But we were making something else. Our videos aim for about 15 minutes, with a script, a hook read word for word, and an editor waiting for clean files at the end. Loom's free plan stops a recording at 5 minutes (our [Loom free plan limits](/blog/loom-free-plan-limits) post has the current numbers, and [Free Loom Alternatives With No Limit, No Catch](/blog/free-loom-alternatives) compares the other options). More importantly, we did not need a share link at all. We needed the files on our own Mac, in sync, ready to edit.

## What I wanted that nothing did

On 4 October 2026 I wrote down what a filming day needed. The list became the plan for Vidlark:

- **One start button.** Camera, mic and screen start and stop together.
- **A prompter under the lens** that is never recorded. The hook word for word, then one bullet at a time. One key moves it on, even while PowerPoint is in front.
- **Never lose a take.** If the Mac crashes at minute 14, we keep minute 14.
- **No pop-ups in the video.** A notification sliding in during a take ruins it.
- **Chapters and retakes for free.** If my mother stumbles, she says "retake" and carries on, and the edit finds the spot later.
- **Simple for the presenter.** She only ever sees the prompter.

Some tools did one or two of these. None did all of them, and none of the free ones did them without an account, a watermark or a time limit.

![The Vidlark window during a take: a camera picture marked REC, the prompter line underneath, the Sources list with a camera, a mic, a second camera and the screen, a Share screen card, and the timer at 07:42 of 15:00](/assets/img/wide-recording.webp)

## The first week: from idea to a working take

I built Vidlark with [Claude Code](https://claude.com/claude-code), Anthropic's coding assistant. I described what I wanted in plain words, decided how every screen should look and what every button should say, and tried each build on real takes. Claude wrote and tested the code with me. The git history keeps the dates honest:

- **4 October, evening.** The first version recorded the camera, the mic and the screen, then lined them up and made the files. By midnight it had a Recordings page, extra cameras, a live view page, and the Me and Screen switch that decides what the finished video shows.
- **5 October.** The Mac's sound from every app or only one, a prompter that scrolls by itself, and sharing one window instead of the whole screen.
- **6 October.** Phones as cameras over Wi-Fi with no app, then up to four phones at once, then more microphones, each saved as its own file.
- **7 October.** A website, and a new name. It started as a recorder for our own channel, and on 7 October it became Vidlark.
- **8 October.** The MIT licence, and the first Windows build, which went out as a beta zip the same night.

Being fast does not mean it is finished. The Windows version is a beta that has only been tried on a few PCs, and it does not have the transcript, phones, the prompter or the Recordings page yet.

## The bugs that taught me the most

Most of the first week went into finding out how many ways a recording can go wrong. Four bugs taught me the most.

### The camera picture that froze the recording

In the first version, the little previews of my mother's face (in the window, in the recording box and in the corner bubble) used the standard Mac way of showing a camera. It looked fine. Then we tested it: in 10 of 11 test takes, the camera file lost its picture within a second of starting. The preview was quietly fighting the recording for the camera.

The fix was to stop using that preview entirely. Now one part of the app takes the camera's pictures and hands copies to every preview. After the change, 6 of 6 test takes kept their picture, including a 90 second one. The lesson: test the file, not the screen. What you see while recording can look perfect while the file is broken.

### Low Power Mode

Some early takes stuttered. The camera file froze for between 0.1 and 2.3 seconds right after the screen was shared, and one take stopped itself. The camera was still sending 30 pictures a second. The cause turned out to be Low Power Mode, which the Mac switches on by itself on battery. Three takes on the charger were perfectly steady.

There is no clever fix for that one, so Vidlark warns you instead. If Low Power Mode is on, a note under the Sources list says the camera may freeze and offers a button to Battery settings.

### The certificate nobody tells you about

The first day, the camera and the mic recorded fine, but screen recording was refused, even after I switched Vidlark on in System Settings. macOS 15 and later refuse screen recording to apps that are not signed with a real certificate. The answer is a free Apple Development certificate from Xcode. It costs nothing, but it is the step most people miss, which is why the [install guide](/how-to#certificate) explains it one click at a time.

### Up to 44% of the camera file was empty

On 5 October I noticed the camera files were bigger than they should be. The Mac's camera writer starts every chunk on a fixed boundary and fills the gap with zeros, and in our takes that padding was 35% to 44% of the file. Vidlark now takes the padding out after each take without touching a single picture or sound.

![The Vidlark Recordings page: a grid of takes, each with a picture, a title, the date, Finished or Not finished, and its size on disk](/assets/img/recordings-wide.webp)

## Why it is free

I did not build Vidlark to sell it. I built it because we needed it, and once it worked, it seemed wrong to keep it to ourselves.

So it is free and open source under the MIT licence. You can use it, change it and share it, as long as the licence notice stays with the code. There is no account, no subscription, no watermark and no time limit, and your recordings stay on your computer. Phones connect straight to your Mac over your own Wi-Fi.

Open source also means you are not stuck with my choices. If you want a 5 second countdown, or your takes saved in your Movies folder, you can open the code in Claude Code and ask for it in plain words. The [Change it with Claude](/how-to#change) steps show how. If you want to compare it with other open source recorders first, [Open source Loom alternatives, compared honestly](/blog/open-source-loom-alternatives) says what Cap, Screenity and OBS do better.

## What is still missing

I would rather you hear the gaps from me:

- **No Mac download button yet.** On a Mac you build Vidlark once from the code, with Xcode and the free certificate. It needs Apple silicon (M1 or newer) and macOS 15 or later.
- **No share links.** You upload `video.mp4` yourself, to YouTube, Drive or wherever it goes. If your team lives on Loom's links and comments, Loom is still the better tool for that.
- **Windows is a beta.** It records the camera, mics and screen and makes the finished video, but phones, live view, the prompter, the transcript and the Recordings page are Mac only for now.
- **No editor.** Vidlark records and finishes the take. Cutting and polishing happen in an editor.

## What is next, and how to help

The next big steps are making Vidlark easier to install on a Mac, and getting the Windows beta tested on more real PCs. Both need people to try them.

If you make videos, here is how you can help:

1. **Try it.** The [step-by-step guide](/how-to) has a picture of every screen. If you are new to recording, [How to record a YouTube video on a Mac](/blog/record-youtube-video-mac) walks through a whole video.
2. **Tell us what goes wrong.** The [feedback page](/feedback) does not need a GitHub account. A screenshot helps.
3. **Test the Windows beta** from the [Releases page](https://github.com/neel542/vidlark/releases) and report what happens on your PC.
4. **Send a change.** The code is on [GitHub](https://github.com/neel542/vidlark), and CONTRIBUTING.md explains how.

And if you are a student wondering whether you can build something real: you can. Start with a problem in your own house. Mine was standing next to a camera.
