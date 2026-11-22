#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mobile_dir="$repo_dir/apps/mobile"
output="${1:-$repo_dir/dist/心灵港湾-Mock.apk}"
flutter="${FLUTTER:-flutter}"

(
  cd "$mobile_dir"
  "$flutter" build apk --release --dart-define=HARBOR_OFFLINE=true
)

mkdir -p -- "$(dirname -- "$output")"
cp -- "$mobile_dir/build/app/outputs/flutter-apk/app-release.apk" "$output"
printf 'Mock APK 已导出到 %s\n' "$output"
