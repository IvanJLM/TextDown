#!/bin/zsh
# Measures TextDown's memory, threads and idle activity with real documents.
# Usage: ./scripts/benchmark.sh [path/to/TextDown.app]   (default: a fresh Release build)
# Compare the numbers with the table in README.md after any change to rendering.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-}"
if [[ -z "$APP" ]]; then
  command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
  xcodegen generate --quiet
  xcodebuild -project TextDown.xcodeproj -scheme TextDown -configuration Release -derivedDataPath build/DD -quiet build
  APP="build/DD/Build/Products/Release/TextDown.app"
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

DOCS="build/bench-docs"
rm -rf "$DOCS"; mkdir -p "$DOCS"
cp Tests/Fixtures/Sample.md Tests/Fixtures/Image.png "$DOCS/"
for i in {1..800}; do cat Tests/Fixtures/Sample.md; echo; done > "$DOCS/Big.md"      # about 1 MB
for i in {1..12000}; do echo "Line $i of a plain text file, long enough to look like real prose."; done > "$DOCS/Big.txt"
for i in {1..25}; do cp Tests/Fixtures/Sample.md "$DOCS/Copy$i.md"; done

pid_of() { pgrep -f "$APP/Contents/MacOS/TextDown" | head -1; }
quit_app() { pkill -f "$APP/Contents/MacOS/TextDown" 2>/dev/null || true; while pid_of >/dev/null; do sleep 0.2; done; sleep 1; }
footprint_mb() { footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ { v=$2; u=$3; if (u=="KB") v/=1024; if (u=="GB") v*=1024; printf "%.0f MB", v; exit }'; }
threads() { ps -M -p "$1" | tail -n +2 | wc -l | tr -d ' '; }
idle_cpu() { top -l 3 -s 2 -pid "$1" -stats cpu,idlew | tail -1 | awk '{ printf "%s %% CPU, %s wake-ups", $1, $2 }'; }

measure() {
  local label="$1"; shift
  quit_app
  local start=$(date +%s.%N)
  open -a "$APP" "$@"
  until pid_of >/dev/null; do sleep 0.05; done
  sleep 3
  local pid=$(pid_of)
  local memory=$(footprint_mb $pid) cpu=$(idle_cpu $pid)
  sleep 10 # threads started while opening finish their work and exit
  printf "%-28s %8s   %2s threads   %s\n" "$label" "$memory" "$(threads $pid)" "$cpu"
}

defaults write com.ivanjlm.textdown AskedToBecomeDefault -bool true
# A first launch registers the app and fills system caches; do not count it.
open -a "$APP" "$DOCS/Sample.md"; sleep 3; quit_app

echo "TextDown $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"), app size $(du -sh "$APP" | cut -f1)"
measure "Sample.md (formatted)" "$DOCS/Sample.md"
measure "Big.md, 1 MB (formatted)" "$DOCS/Big.md"
measure "Big.txt, 0.8 MB (editor)" "$DOCS/Big.txt"
measure "25 windows" "$DOCS"/Copy*.md
quit_app
