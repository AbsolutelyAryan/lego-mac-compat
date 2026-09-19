#!/bin/sh
set -eu

# Enable loader, Steam, CoreAudio, timing, and hitch recording. High-volume
# display/GL traces are opt-in so the diagnostic run remains representative.

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/Compatibility.app" >&2
    exit 2
fi

app=$1
executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
if [ ! -x "$executable" ]; then
    echo "error: executable not found: $executable" >&2
    exit 1
fi

log_dir="${LP32_DIAGNOSTIC_DIR:-$HOME/Library/Logs/LEGOMarvelCompat}"
mkdir -p "$log_dir"
log_file="$log_dir/launch-$(date +%Y%m%d-%H%M%S)-$$.log"

export LP32_TRACE_AUDIO=1
export LP32_TRACE_AUDIO_LATENCY=1
export LP32_TRACE_STEAM=1
export LP32_TRACE_TIMING=1
export LP32_HITCH_LOG="$log_dir/hitches-$$.log"

# Display mode queries can log on nearly every frame in this game.
if [ "${LP32_VERBOSE_DISPLAY:-0}" = 1 ]; then
    export LP32_TRACE_DISPLAY=1
fi

# These switches log on nearly every frame.
if [ "${LP32_VERBOSE_GL:-0}" = 1 ]; then
    export LP32_TRACE_RESOLUTION=1
    export LP32_TRACE_GL_FRAMES=1
fi

echo "compat32: diagnostic launcher pid=$$ app=$app" | tee "$log_file"
echo "compat32: stderr log=$log_file" | tee -a "$log_file"
exec "$executable" >>"$log_file" 2>&1
