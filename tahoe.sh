#!/bin/bash
# Recolor and install the macOS Tahoe wallpaper videos. Run without arguments for usage.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
videos="$HOME/Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Application Support/Videos"
originals="$HOME/Pictures/Tahoe-original-videos"
custom="$HOME/Pictures/Tahoe-custom"
# Temporal layers + deep B-pyramid let the wallpaper slow down and pause smoothly; long GOP stops grain "boiling" at keyframes.
x265="aq-mode=3:keyint=1200:min-keyint=240:no-sao=1:temporal-layers=5:bframes=15:b-pyramid=1:b-adapt=0:log-level=error"

usage() {
	cat <<EOF
usage: $0 list
       $0 make <degrees|#rrggbb> <variant> [pivot]   render a recolored variant into $custom
       $0 set <file.mov> <variant>                  install a video as that variant
       $0 restore [variant]                         put Apple's originals back (all variants if none given)

variant: "Dark Landscape", "Light Landscape", "Dark Portrait" or "Light Portrait"
EOF
	exit 1
}

die() { echo "$*" >&2; exit 1; }

# Copy Apple's videos aside once, before anything overwrites them.
backup() {
	[ -d "$videos" ] || die "no wallpaper videos at $videos (pick a Tahoe wallpaper in System Settings first)"
	mkdir -p "$originals"
	for f in "$videos"/*.mov; do
		[ -e "$originals/${f##*/}" ] || cp "$f" "$originals/"
	done
}

# The wallpaper only picks up a new file after a restart; the log line confirms the video decoded.
reload() {
	killall NeptuneOneWallpaper WallpaperAgent 2>/dev/null || true
	sleep 6
	if /usr/bin/log show --last 8s --style compact \
		--predicate 'subsystem == "com.apple.wallpaper" AND category BEGINSWITH "video-player"' 2>/dev/null |
		grep -q "startReading callback: success"; then
		echo "wallpaper reloaded"
	else
		echo "warning: no successful video load in the log; check the wallpaper" >&2
	fi
}

# Compile once: interpreted Swift is far too slow for 4K at 240 fps.
build() {
	mkdir -p "$here/.build"
	for s in recolor remux; do
		[ "$here/.build/$s" -nt "$here/$s.swift" ] || swiftc -O "$here/$s.swift" -o "$here/.build/$s"
	done
}

case "${1:-}" in
list)
	ls -1 "$videos"
	[ -d "$custom" ] && { echo; ls -1 "$custom"; }
	;;
make)
	[ $# -ge 3 ] || usage
	command -v ffmpeg >/dev/null || die "needs ffmpeg with libx265 (brew install ffmpeg)"
	backup
	src="$originals/Tahoe $3.mov"
	[ -f "$src" ] || die "unknown variant: $3"
	build
	size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$src")
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	mkdir -p "$custom"
	out="$custom/Tahoe $3 - $2.mov"
	echo "rendering $out (takes a while; x265 uses every core)"
	"$here/.build/recolor" "$2" "$src" - ${4:+"$4"} |
		ffmpeg -loglevel error -f rawvideo -pix_fmt yuv420p10le -s "$size" -r 240 -i - \
			-c:v libx265 -preset medium -crf 16 -pix_fmt yuv420p10le \
			-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
			-x265-params "$x265" "$tmp/x265.mkv"
	ffmpeg -loglevel error -i "$tmp/x265.mkv" -c copy -tag:v hvc1 "$tmp/x265.mov"
	"$here/.build/remux" "$tmp/x265.mov" "$out"
	echo "install with: $0 set \"$out\" \"$3\""
	;;
set)
	[ $# -eq 3 ] || usage
	[ -f "$2" ] || die "no such file: $2"
	backup
	[ -f "$videos/Tahoe $3.mov" ] || die "unknown variant: $3"
	cp "$2" "$videos/Tahoe $3.mov"
	reload
	;;
restore)
	[ -d "$originals" ] || die "no originals saved in $originals"
	if [ $# -ge 2 ]; then
		[ -f "$originals/Tahoe $2.mov" ] || die "unknown variant: $2"
		cp "$originals/Tahoe $2.mov" "$videos/"
	else
		cp "$originals"/*.mov "$videos/"
	fi
	reload
	;;
*) usage ;;
esac
