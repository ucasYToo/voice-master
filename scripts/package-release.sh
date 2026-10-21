#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then echo "Usage: $0 [path-to-app]" >&2; exit 2; fi
app_path="${1:-$project_dir/dist/Voice Master.app}"
if [[ ! -d "$app_path/Contents" ]]; then
    echo "Build the app first with scripts/build-app.sh." >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Invalid app version: $version" >&2; exit 1; fi
architecture="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/VoiceMaster")"
if [[ "$architecture" != "arm64" ]]; then echo "Expected arm64, got: $architecture" >&2; exit 1; fi
notes="$project_dir/docs/releases/v$version.md"
if [[ ! -f "$notes" ]]; then echo "Missing release notes: $notes" >&2; exit 1; fi
/usr/bin/codesign --verify --strict "$app_path"

output_dir="$project_dir/dist/releases/v$version"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
package_name="VoiceMaster-$version-macOS-arm64"
payload="$staging_dir/$package_name"
mkdir -p "$payload"
# Copy only the application and public instructions, never the entire dist directory.
/usr/bin/ditto "$app_path" "$payload/Voice Master.app"
cp "$notes" "$payload/README.md"
archive="$staging_dir/$package_name.zip"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$payload" "$archive"

# Verify the actual downloadable archive survives extraction with its signature intact.
/usr/bin/ditto -x -k "$archive" "$staging_dir/verify"
extracted_app="$staging_dir/verify/$package_name/Voice Master.app"
/usr/bin/codesign --verify --strict "$extracted_app"
if [[ ! -x "$extracted_app/Contents/MacOS/VoiceMaster" ]]; then echo "Archive lost executable permissions." >&2; exit 1; fi
mv "$archive" "$output_dir/$package_name.zip"
(
    cd "$output_dir"
    /usr/bin/shasum -a 256 "$package_name.zip" > SHA256SUMS.txt
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)
echo "Release package: $output_dir/$package_name.zip"
