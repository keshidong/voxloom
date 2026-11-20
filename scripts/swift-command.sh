#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_path="$(xcode-select -p)"
frameworks="$developer_path/Library/Developer/Frameworks"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
cd "$project_root"

action="${1:-test}"
if [ "$#" -gt 0 ]; then shift; fi
options=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
if [ "$action" = test ]; then options+=(--disable-xctest); fi
if [ -d "$frameworks/Testing.framework" ]; then
    options+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$developer_path/Library/Developer/usr/lib")
fi
exec swift "$action" "${options[@]}" "$@"
