#!/bin/bash
# Builds the iPhone app for the iOS Simulator, installs it on a simulator and captures every screen in demo mode
# (a temporary archive with sample entries; nothing real is touched). Screenshots go to .logs/ios/, the log to
# .logs/ios.log. Usage: bash Scripts/ios-check.sh [simulator name, default: newest available iPhone]
set -u
cd "$(dirname "$0")/.."
mkdir -p .logs
LOG=.logs/ios.log
SHOTS=.logs/ios
BUNDLE_ID=tech.feki.mneme
DERIVED=build/ios

run() {
  echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"

  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
wanted = sys.argv[1] if len(sys.argv) > 1 else ""
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in devices:
        name = device["name"]
        if (wanted and name != wanted) or (not wanted and not name.startswith("iPhone")):
            continue
        # Prefer the newest iOS, then a Pro model (the size used in App Store screenshots).
        key = (version, "Pro" in name and "Max" not in name, name)
        if best is None or key > best[0]:
            best = (key, device["udid"], name, runtime)
if best:
    print(best[1])
    print("simulator: %s (%s)" % (best[2], best[3]), file=sys.stderr)
' "${1:-}")
  if [ -z "$udid" ]; then
    echo "RESULT: FAIL (no iPhone simulator available)"
    return 1
  fi

  echo
  echo "== xcodebuild (iOS Simulator, Debug)"
  local app="$DERIVED/Build/Products/Debug-iphonesimulator/Mneme.app"
  rm -rf "$app"
  xcodebuild \
    -project iOS/Mneme.xcodeproj \
    -scheme Mneme \
    -configuration Debug \
    -destination "id=$udid" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)|\*\* " | grep -v "appintentsmetadataprocessor"
  if [ ! -d "$app" ]; then
    echo "RESULT: FAIL (build failed)"
    return 1
  fi

  echo
  echo "== simulator"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>/dev/null || true
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$udid" "$app" || { echo "RESULT: FAIL (install failed)"; return 1; }

  rm -rf "$SHOTS"
  mkdir -p "$SHOTS"
  local failed=0
  local appearance screen
  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance" 2>/dev/null || true
    for screen in list entry note review recorder settings search onboarding; do
      if [ "$appearance" = dark ] && [ "$screen" != list ] && [ "$screen" != entry ]; then
        continue
      fi
      xcrun simctl terminate "$udid" "$BUNDLE_ID" > /dev/null 2>&1 || true
      if ! xcrun simctl launch "$udid" "$BUNDLE_ID" -demo -screen "$screen" > /dev/null; then
        echo "launch failed: $screen"
        failed=1
        continue
      fi
      sleep 6
      # The app must still be running: a crash during launch or navigation fails the check.
      if ! xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
        echo "the app is not running after opening: $screen ($appearance)"
        failed=1
      fi
      xcrun simctl io "$udid" screenshot "$SHOTS/$screen-$appearance.png" > /dev/null 2>&1 || failed=1
      echo "captured $screen ($appearance)"
    done
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" > /dev/null 2>&1 || true
  xcrun simctl ui "$udid" appearance light 2>/dev/null || true

  if [ $failed -eq 0 ]; then
    echo "RESULT: PASS"
    return 0
  fi
  echo "RESULT: FAIL (see above)"
  return 1
}

run "$@" > "$LOG" 2>&1
status=$?
grep -E "error:|RESULT:" "$LOG" | tail -n 15
exit $status
