# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI app; not one of the schema's four values, recorded as fact)

## Stack

Delegated: Swift 6.3 + SwiftUI, AVFoundation for the camera and mic, ScreenCaptureKit for the screen. A native app is needed because the prompter key has to work while PowerPoint is in front, and the app's own windows have to be kept out of the recording.

## Users

- **Neel (operator).** Runs the app on the MacBook. He picks the video, checks the setup, presses Start and Stop, and handles the lighting. He is not technical and wants zero fiddling.
- **The presenter (on camera).** The face of AVA INC. She sits at the MacBook, reads the prompter, clicks through PowerPoint or Seller Central, and presses one key to move the prompter forward. She only ever looks at the prompter.

## Product Purpose

Film the presenter's YouTube videos without paying for Loom. Face, voice and screen are recorded in one take, the prompter keeps her on script, and the files land ready for the `video-edit` skill. Success means a filmed video in the folder with no manual steps between Stop and editing.

## Operating Context

- The iPhone 15 stands on a tripod behind or beside the screens, rear camera facing the presenter, connected as a Continuity Camera. The prompter goes on whichever screen edge is closest to the lens, and Neel can drag it there.
- There are two screens: the MacBook Air (2560x1664) and a Samsung 1920x1080 monitor. One shows the content and is recorded. The other holds the prompter and the operator panel.
- The mic receiver plugs into the Mac.
- Long-form videos run about 15 minutes. The script has a hook (word for word), body bullets, and a call to action.
- Filming can be a batch day: several videos in a row with one setup.

## Capabilities and Constraints

- See PLAN.md for the feature list and the recording folder contract.
- Not building: a Shorts cutter, iPhone remote control, or in-recorder blurring (Seller Central data is blurred in editing).
- Open: Continuity Camera needs the iPhone and Mac on the same Apple ID. The plan is a second Mac user account for the presenter, which is why recordings go to /Users/Shared.

## Brand Commitments

- Neel wants it "very beautiful, very minimalistic, very clean", and green.
- No em dashes anywhere, including UI copy.
- AVA INC's video brand accent (#FF9900 orange) belongs to the edited videos, not this tool.

## Evidence on Hand

None needed. The product is internal.

## Product Principles

1. the presenter's attention belongs to the lens. Nothing on her screen competes with the current line.
2. One obvious action at a time for Neel: check, start, stop.
3. Never lose a take. Safety is silent and automatic.
4. Plain words, no settings jargon.
