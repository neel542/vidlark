---
title: How to record your camera and screen as separate files
seo_title: Record your camera and screen separately, free
description: Record your camera and screen separately in one take, free on Mac and Windows. See every file Vidlark saves, where it goes and how the files stay in sync.
date: 2026-10-09
updated: 2026-10-09
keyword: record your camera and screen separately
category: Guides
cover: /assets/img/blog/record-camera-and-screen-separately.webp
cover_alt: A green card that says How to record your camera and screen as separate files, with the file names video.mp4, camera.mov and chapters.txt
faq:
  - q: Does Vidlark still make one finished video?
    a: Yes. When you share your screen, Vidlark makes `video.mp4` after you stop. It follows your Me and Screen clicks, so it is ready to upload. The separate files are there for when you want to edit.
  - q: Do the separate files line up on their own?
    a: Yes. Every camera and mic hears the same voice, so after you stop, Vidlark uses that sound to line up every file. Put them in an editor and they start at the same moment.
  - q: Does this work on Windows too?
    a: Yes. The Windows beta is a free download for Windows 11 (64-bit). It records your camera, mics and screen as separate files and makes the finished video. The transcript and phones are on the Mac only for now.
related:
  - phone-as-webcam-on-mac
---

Most screen recorders bake your camera into the screen recording as one video. That is quick, but it leaves you stuck with it. If you want to record your camera and screen separately, so you can move your face, cut to the camera or fix the sound later, you need each one as its own file.

This guide shows how to get those files in one take with [Vidlark](/), a free, open source recorder for Mac and Windows. You press one button, and your camera, your mic and your screen are each saved on their own, lined up by sound.

## Why separate files help

One video with your face stuck in the corner is fine for a quick message. For a YouTube video you will edit, separate files give you room to change your mind:

- **Move or resize your face** in editing, or leave it out of a part.
- **Cut to your camera** for the intro and the ending, then back to the screen.
- **Use a better mic** under any picture, because every mic is its own file.
- **Fix one part without the others.** If the screen file has a problem, your camera and sound are still fine.

You still get a finished video too. Vidlark makes `video.mp4` from the same take, so you only edit when you want to.

## Record both in one take

You need Vidlark installed first. [How to use it](/how-to) has the steps for a Mac and for Windows, with a picture of every screen.

1. **Check the Sources list.** It shows your camera, mic and screen, each with a lamp. Green means ready.
2. **Press the red button.** It counts down 3, 2, 1, then your camera and mic start together. The countdown is not recorded.
3. **Share your screen when you are ready.** Press **Share screen** and pick **Entire screen** or **A window**. Every take starts on your camera, so you can say hello first.
4. **Switch with Me and Screen.** The recording box has two buttons. **Me** fills the video with your camera, and **Screen** goes back to the screen. The finished video follows these clicks.
5. **Press stop.** Vidlark lines up the files and makes the finished video. A long take takes a minute or two.

![The Vidlark panel after a take: Saved and finished. Transcript, chapters and retakes are in the folder. Open folder. Next video.](/assets/img/guide-done.webp "After you stop, every file is in the take's folder.")

The recording box and Vidlark's other windows never appear in the recording, so there is nothing to crop out afterwards.

## Every file in the take's folder

Each take gets its own folder. These are the files you will use most:

| File | What it is |
|---|---|
| `video.mp4` | The finished video, ready to upload. Made when you share your screen. |
| `camera.mov` | Your camera, with your voice. |
| `screen.mov` | Your screen from the moment you shared it, with your voice. |
| `camera-2.mov` | Each extra camera or phone, in its own file. |
| `mic-2.m4a` | Each extra microphone, in its own file. |
| `words.json` | The transcript, with the time of every word (on a Mac). |
| `chapters.txt` | YouTube chapters, ready to paste into a description (on a Mac). |
| `retakes.json` | Every time you said "retake", with its time (on a Mac). |

> **Good to know:** in a take where you never share your screen, `camera.mov` is your video.

[Where your files go](/how-to#files) lists every other file a take leaves, like the plain report of the take.

## Where the files go

Your recordings stay on your computer. Vidlark has no account and never uploads them. On a Mac, every take is in a folder all the Mac's users share:

```text
/Users/Shared/Vidlark Recordings/<date> <title>/recording-1/
```

On Windows, takes are in the Public Videos folder:

```text
C:\Users\Public\Videos\Vidlark Recordings\<date> <title>\recording-1\
```

After a take, **Open folder** on a Mac, or **Show the take** on Windows, takes you straight there.

## How the files stay in sync

Every camera and mic hears the same voice. After you stop, Vidlark uses that sound to line up every file, so they all start at the same moment. You do not need to clap or count in.

The files are also written in 2-second pieces while you record, so if the computer crashes, the take is kept up to the last 2 seconds.

Want a second angle? A phone can film over Wi-Fi as another camera, saved as `camera-2.mov` and lined up the same way. [Use your phone as a webcam](/blog/phone-as-webcam-on-mac) shows how.
