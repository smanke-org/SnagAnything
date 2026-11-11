#!/bin/zsh
# Records the SnagAnything demo video (CAPTURELENS_DEBUG_DEMO, Sources/CaptureLens/DemoStage.swift)
# and mixes in the voiceover.
#
# Plays the scripted demo in a copy of the Debug build on the built-in display, on its own
# made-up library and settings, and records only that copy's windows with ScreenCaptureKit, so
# nothing else on screen gets in. The installed SnagAnything is left running and untouched.
#
# Needs: an optimized Debug build (xcodebuild … -configuration Debug -derivedDataPath
# .build/xcode-debug-opt SWIFT_OPTIMIZATION_LEVEL=-O build), the voiceover in
# ../SnagAnything-demo/vo (NN.wav + NN.json timings), ffmpeg, Screen Recording permission for
# the terminal, and the sandbox off.
#
# usage: Tools/demo/record_demo.sh [out.mp4]     (default: ../SnagAnything-demo/SnagAnything-demo.mp4)
set -u
HERE=${0:A:h}
SRC=${HERE:h:h}
DEMO="${SRC:h}/SnagAnything-demo"
OUT="${1:-$DEMO/SnagAnything-demo.mp4}"
WORK="${TMPDIR:-/tmp}/snaganything-demo"
APP_SRC="$SRC/.build/xcode-debug-opt/Build/Products/Debug/SnagAnything.app"
APP="$WORK/SnagAnythingDemo.app"
TRACE="$WORK/trace.txt"
RAW="$WORK/raw.mov"
LIB="$WORK/library"
SUITE=com.smanke.CaptureLens.demo

mkdir -p "$WORK" "${OUT:h}"
[ -d "$APP_SRC" ] || { echo "no Debug build at $APP_SRC"; exit 1; }
REC="$WORK/recorder"
if [ ! -x "$REC" ] || [ "$HERE/recorder.swift" -nt "$REC" ]; then
  swiftc -O -o "$REC" "$HERE/recorder.swift" || exit 1
fi

rm -rf "$APP" "$TRACE" "$TRACE.crop" "$RAW" "$LIB" "$WORK/rec.log" "$WORK/app.log"
defaults delete "$SUITE" >/dev/null 2>&1
ditto "$APP_SRC" "$APP"

CAPTURELENS_DEBUG_DEMO="$TRACE" CAPTURELENS_DEFAULTS_SUITE="$SUITE" CAPTURELENS_LIBRARY_FOLDER="$LIB" \
  CAPTURELENS_DEBUG_DEMO_VO="$DEMO/vo" CAPTURELENS_DEBUG_DEMO_LEAD=2 \
  "$APP/Contents/MacOS/SnagAnything" > "$WORK/app.log" 2>&1 &
PID=$!
for i in {1..450}; do /usr/bin/grep -q "stage ready" "$TRACE" 2>/dev/null && break; kill -0 $PID 2>/dev/null || break; sleep 0.2; done
echo "pid=$PID crop=$(cat "$TRACE.crop" 2>/dev/null)"
OK=0
if /usr/bin/grep -q "stage ready" "$TRACE" 2>/dev/null; then
  "$REC" "$PID" ${=$(cat "$TRACE.crop")} "$RAW" | tee "$WORK/rec.log" && OK=1
else
  echo "stage never came up"; cat "$TRACE" 2>/dev/null; kill $PID 2>/dev/null
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null
rm -rf "$APP"
defaults delete "$SUITE" >/dev/null 2>&1
[ $OK = 1 ] || exit 1
python3 -I "$HERE/mix.py" "$RAW" "$TRACE" "$WORK/rec.log" "$DEMO/vo" "$OUT"
