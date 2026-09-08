#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-debug}

case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "$repo_root"
scratch_path=${AGENTPAD_SCRATCH_PATH:-"$repo_root/.build"}
swift build --scratch-path "$scratch_path" --configuration "$configuration"
binary_dir=$(swift build --scratch-path "$scratch_path" --configuration "$configuration" --show-bin-path)
app_dir="$scratch_path/Clackwork.app"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_root/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$binary_dir/Clackwork" "$app_dir/Contents/MacOS/Clackwork"
cp "$repo_root/App/AgentPad13.icns" "$app_dir/Contents/Resources/AgentPad13.icns"
cp "$repo_root/App/AgentPad13MenuBarTemplate.png" "$app_dir/Contents/Resources/AgentPad13MenuBarTemplate.png"
cp "$repo_root/App/AgentPad13MenuBarTemplate@2x.png" "$app_dir/Contents/Resources/AgentPad13MenuBarTemplate@2x.png"
cp "$repo_root/App/ThirdPartyNotices.txt" "$app_dir/Contents/Resources/ThirdPartyNotices.txt"

echo "$app_dir"
