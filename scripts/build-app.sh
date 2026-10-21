#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
configuration=release
if [[ "${1:-}" == "--debug" ]]; then configuration=debug
elif [[ $# -gt 0 ]]; then echo "Usage: $0 [--debug]" >&2; exit 2; fi

swift build -c "$configuration" --product VoiceMaster
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.VoiceMaster.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_path="$staging_dir/Voice Master.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
"$project_dir/scripts/generate-icons.sh" "$app_path/Contents/Resources"
cp "$binary_dir/VoiceMaster" "$app_path/Contents/MacOS/VoiceMaster"
cp "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"
codesign --force --sign - --identifier local.voicemaster.app "$app_path"
codesign --verify --strict --verbose=2 "$app_path"
destination="$project_dir/dist/Voice Master.app"
if [[ -e "$destination" ]]; then rm -rf "$destination"; fi
mv "$app_path" "$destination"
echo "Built: $destination"
