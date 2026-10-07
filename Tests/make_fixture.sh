#!/bin/bash
# Builds synthetic recording folders under Tests/fixtures/out/ for vidlark-finish.
#   main        camera.mov + screen.mov (screen audio delayed by 0.35 s), three sections
#   truncated   a crash: both videos written in 2 s fragments and cut off part way through a fragment,
#               events.jsonl with no stop line, a cut-off last line and a short section
#   notranscribe  copy of main, for the --no-transcribe run
#   advanced    screen audio starts 0.5127 s into the speech, quieter, low-passed and with noise added,
#               chapters from app switches only
#   noscreen    no screen.mov, only two sections (so no chapters)
#   badcamera   camera.mov is not a video
# Known values are written to fixtures/out/expected.env.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/fixtures/out"
W="$OUT/work"

pick() { for d in /opt/homebrew/bin /usr/local/bin /usr/bin; do [ -x "$d/$1" ] && { echo "$d/$1"; return; }; done; command -v "$1"; }
FFMPEG="$(pick ffmpeg)"
FFPROBE="$(pick ffprobe)"

DELAY_MS=350
ADVANCE_S=0.5127
SECTION=15
TOTAL=45
VOICE=Samantha
say -v '?' | grep -q "^$VOICE " || VOICE=""

rm -rf "$OUT"
mkdir -p "$W"

speak() {
    if [ -n "$VOICE" ]; then say -v "$VOICE" -r 175 -o "$W/$1.aiff" "$2"; else say -r 175 -o "$W/$1.aiff" "$2"; fi
    "$FFMPEG" -v error -y -i "$W/$1.aiff" -ar 48000 -ac 1 -c:a pcm_s16le "$W/$1.wav"
}
dur() { "$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$1"; }

A="Welcome back to the channel. Today we are going to fix a suppressed Amazon listing in under ten minutes, and I will show you exactly where Seller Central hides the real reason."
B1="First, open the inventory page and look for the listing with the red banner. Click the status link and read the message carefully."
R="Retake."
B2="Let me say that again. Open the inventory page first."
C="Now fix the missing attribute, save the listing, and wait about fifteen minutes. The banner disappears and your listing is live again. If this helped, subscribe for more."

speak a "$A"; speak b1 "$B1"; speak r "$R"; speak b2 "$B2"; speak c "$C"

# Section one starts after 1 s of silence, sections two and three start at 15 s and 30 s.
LEN_A=$(echo "$(dur "$W/a.wav") + 1" | bc -l)
LEN_B=$(echo "$(dur "$W/b1.wav") + $(dur "$W/r.wav") + $(dur "$W/b2.wav")" | bc -l)
LEN_C=$(dur "$W/c.wav")
for L in "$LEN_A" "$LEN_B" "$LEN_C"; do
    if (( $(echo "$L > $SECTION - 0.3" | bc -l) )); then echo "a section is too long ($L s)" >&2; exit 1; fi
done

"$FFMPEG" -v error -y -i "$W/a.wav" -i "$W/b1.wav" -i "$W/r.wav" -i "$W/b2.wav" -i "$W/c.wav" -filter_complex \
"[0:a]adelay=1000:all=1,apad=whole_dur=$SECTION[s1];\
[1:a][2:a][3:a]concat=n=3:v=0:a=1,apad=whole_dur=$SECTION[s2];\
[4:a]apad=whole_dur=$SECTION[s3];\
[s1][s2][s3]concat=n=3:v=0:a=1,atrim=0:$TOTAL[out]" \
    -map "[out]" -c:a pcm_s16le "$W/speech.wav"

# Where the word "retake" starts in the speech: section two start + clip b1 + leading silence of clip r.
SD=$("$FFMPEG" -v info -i "$W/r.wav" -af silencedetect=noise=-40dB:d=0.01 -f null - 2>&1 || true)
FIRST_START=$(echo "$SD" | grep -o 'silence_start: [-0-9.e]*' | head -1 | awk '{print $2}')
FIRST_END=$(echo "$SD" | grep -o 'silence_end: [0-9.]*' | head -1 | awk '{print $2}')
R_LEAD=0
if [ -n "$FIRST_START" ] && [ -n "$FIRST_END" ] && (( $(echo "$FIRST_START < 0.005" | bc -l) )); then R_LEAD=$FIRST_END; fi
RETAKE_T=$(echo "$SECTION + $(dur "$W/b1.wav") + $R_LEAD" | bc -l)

video() { # pattern, audio filter, output
    "$FFMPEG" -v error -y -f lavfi -i "$1" -i "$W/speech.wav" -filter_complex "[1:a]$2[a]" \
        -map 0:v -map "[a]" -t $TOTAL -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -c:a aac -b:a 128k -ar 48000 "$3"
}

events_main() {
cat <<'EOF'
{"t":0,"type":"start","wall":"2026-10-04T10:00:00Z","title":"Fix a suppressed listing","targetMinutes":1,"camera":"camera.mov","screen":"screen.mov"}
{"t":0.6,"type":"card","index":0,"section":"Hook","text":"Welcome back to the channel."}
{"t":5.0,"type":"card","index":1,"section":"Hook","text":"Where Seller Central hides the reason."}
{"t":8.0,"type":"app","name":"Microsoft PowerPoint"}
{"t":15.0,"type":"card","index":2,"section":"Setup","text":"Open the inventory page."}
{"t":22.0,"type":"app","name":"Google Chrome"}
{"t":30.0,"type":"card","index":3,"section":"Payoff","text":"Fix the missing attribute."}
{"t":45.0,"type":"stop"}
EOF
}

# main
mkdir -p "$OUT/main"
video "testsrc2=size=640x360:rate=30" "anull" "$OUT/main/camera.mov"
video "smptehdbars=size=1280x720:rate=30" "adelay=$DELAY_MS:all=1,atrim=0:$TOTAL" "$OUT/main/screen.mov"
events_main > "$OUT/main/events.jsonl"
printf '# Fix a suppressed listing\n\n## Hook\n%s\n\n## Setup\n%s\n\n## Payoff\n%s\n' "$A" "$B1" "$C" > "$OUT/main/script.md"
printf '%s %s %s %s %s\n' "$A" "$B1" "$R" "$B2" "$C" > "$OUT/spoken.txt"

# truncated: crash during a recording, with a 4 s "Oops" section that must merge away
mkdir -p "$OUT/truncated"
cp -c "$OUT/main/script.md" "$OUT/truncated/"
for n in camera screen; do
    "$FFMPEG" -v error -y -i "$OUT/main/$n.mov" -c copy \
        -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 2000000 "$W/frag_$n.mov"
done
cut_at() { head -c $(( $(stat -f %z "$1") * $2 / 100 )) "$1" > "$3"; }
cut_at "$W/frag_camera.mov" 93 "$OUT/truncated/camera.mov"
cut_at "$W/frag_screen.mov" 90 "$OUT/truncated/screen.mov"
cat > "$OUT/truncated/events.jsonl" <<'EOF'
{"t":0,"type":"start","wall":"2026-10-04T11:00:00Z","title":"Crashed take","targetMinutes":1,"camera":"camera.mov","screen":"screen.mov"}
{"t":0.6,"type":"card","index":0,"section":"Hook","text":"Welcome back to the channel."}
{"t":15.0,"type":"card","index":1,"section":"Setup","text":"Open the inventory page."}
{"t":20.0,"type":"card","index":2,"section":"Oops","text":"Wrong card."}
{"t":24.0,"type":"card","index":3,"section":"Setup","text":"Back to setup."}
{"t":30.0,"type":"card","index":4,"section":"Payoff","text":"Fix the missing attribute."}
EOF
printf '{"t":44.1,"type":"app","na' >> "$OUT/truncated/events.jsonl"

# notranscribe: same as main
mkdir -p "$OUT/notranscribe"
cp -c "$OUT/main/camera.mov" "$OUT/main/screen.mov" "$OUT/main/events.jsonl" "$OUT/main/script.md" "$OUT/notranscribe/"

# advanced: the screen recording started 0.5127 s after the camera and its sound path differs
mkdir -p "$OUT/advanced"
cp -c "$OUT/main/camera.mov" "$OUT/advanced/"
video "smptehdbars=size=1280x720:rate=30" \
    "atrim=start=$ADVANCE_S,asetpts=PTS-STARTPTS,volume=0.5,lowpass=f=6000[v];anoisesrc=color=pink:amplitude=0.01:sample_rate=48000[n];[v][n]amix=inputs=2:duration=first:normalize=0" \
    "$OUT/advanced/screen.mov"
cat > "$OUT/advanced/events.jsonl" <<'EOF'
{"t":0,"type":"start","wall":"2026-10-04T12:00:00Z","title":"App chapters","targetMinutes":1,"camera":"camera.mov","screen":"screen.mov"}
{"t":0.2,"type":"app","name":"Microsoft PowerPoint"}
{"t":12.0,"type":"app","name":"Google Chrome"}
{"t":14.0,"type":"app","name":"Microsoft PowerPoint"}
{"t":25.0,"type":"app","name":"Safari"}
{"t":35.0,"type":"app","name":"Finder"}
{"t":45.0,"type":"stop"}
EOF

# noscreen: no screen.mov, two sections only
mkdir -p "$OUT/noscreen"
cp -c "$OUT/main/camera.mov" "$OUT/noscreen/"
cat > "$OUT/noscreen/events.jsonl" <<'EOF'
{"t":0,"type":"start","wall":"2026-10-04T13:00:00Z","title":"Camera only","targetMinutes":1,"camera":"camera.mov","screen":"screen.mov"}
{"t":0.6,"type":"card","index":0,"section":"Hook","text":"Hello."}
{"t":20.0,"type":"card","index":1,"section":"Setup","text":"Setup."}
{"t":45.0,"type":"stop"}
EOF

# badcamera: camera.mov is junk
mkdir -p "$OUT/badcamera"
head -c 4096 /dev/urandom > "$OUT/badcamera/camera.mov"
events_main > "$OUT/badcamera/events.jsonl"

cat > "$OUT/expected.env" <<EOF
EXPECTED_OFFSET_MAIN=$(printf '%.4f' "$(echo "-$DELAY_MS / 1000" | bc -l)")
EXPECTED_OFFSET_ADVANCED=$ADVANCE_S
RETAKE_T=$(printf '%.3f' "$RETAKE_T")
EOF

echo "fixtures written to $OUT"
cat "$OUT/expected.env"
