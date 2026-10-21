#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
# CLT ships Swift Testing outside the SDK search path and does not ship XCTest.
if [[ -d "$testing_frameworks/Testing.framework" ]]; then
    swift test --disable-xctest --enable-swift-testing \
        -Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib" "$@"
else
    swift test --disable-xctest --enable-swift-testing "$@"
fi
