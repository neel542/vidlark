#!/bin/bash
# Speaks Tests/follow/speech.txt with an Indian English voice into one file for the follow test,
# and prints when each part starts and ends. Rishi by default: Tara garbles "your money goes".
#   [VOICE=Tara] bash Tests/follow/make_audio.sh [out.wav]
#   "dist/Vidlark.app/Contents/MacOS/Vidlark" --test-follow <out.wav> Examples/sample-script.md
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../fixtures/out/follow/speech.wav}"
W="$(mktemp -d)"
FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"
FFPROBE="$(command -v ffprobe || echo /opt/homebrew/bin/ffprobe)"
VOICE="${VOICE:-Rishi}"
say -v '?' | grep -q "^$VOICE " || VOICE=Samantha
mkdir -p "$(dirname "$OUT")"

n=0; list="$W/list.txt"; : > "$list"
silence() { "$FFMPEG" -v error -y -f lavfi -i anullsrc=r=48000:cl=mono -t "$1" -c:a pcm_s16le "$W/s$n.wav"; echo "file '$W/s$n.wav'" >> "$list"; n=$((n + 1)); }
silence 1
t=1
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^\[pause\ ([0-9.]+)\]$ ]]; then silence "${BASH_REMATCH[1]}"; t=$(echo "$t + ${BASH_REMATCH[1]}" | bc -l); continue; fi
    say -v "$VOICE" -r 165 -o "$W/p$n.aiff" "$line"
    "$FFMPEG" -v error -y -i "$W/p$n.aiff" -ar 48000 -ac 1 -c:a pcm_s16le "$W/p$n.wav"
    d=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$W/p$n.wav")
    printf "%6.1f to %6.1f s  %s\n" "$t" "$(echo "$t + $d" | bc -l)" "$line"
    t=$(echo "$t + $d" | bc -l)
    echo "file '$W/p$n.wav'" >> "$list"; n=$((n + 1))
done < "$HERE/speech.txt"
"$FFMPEG" -v error -y -f concat -safe 0 -i "$list" -c:a pcm_s16le "$OUT"
rm -rf "$W"
echo "wrote $OUT ($VOICE)"
