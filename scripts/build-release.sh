#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$release_root"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

release_output="$release_root/build/release/artifacts"
mkdir -p "$release_output"
release_assets=()
release_version=""
release_stage=""
trap 'if [[ -n "$release_stage" ]]; then rm -rf -- "$release_stage"; fi' EXIT

for release_arch in arm64 x86_64; do
    release_derived="$release_root/build/release/$release_arch"
    xcodebuild -quiet -project SlowQuit.xcodeproj -scheme SlowQuit \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$release_derived" \
        ARCHS="$release_arch" ONLY_ACTIVE_ARCH=NO build

    release_app="$release_derived/Build/Products/Release/SlowQuit.app"
    release_binary="$release_app/Contents/MacOS/SlowQuit"
    [[ "$(/usr/bin/lipo -archs "$release_binary")" == "$release_arch" ]]
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$release_app"
    [[ -f "$release_app/Contents/Resources/LICENSE" ]]
    [[ -f "$release_app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]

    release_app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_app/Contents/Info.plist")"
    if [[ -z "$release_version" ]]; then
        release_version="$release_app_version"
    fi
    [[ "$release_version" == "$release_app_version" ]]
    release_name="SlowQuit-$release_version-macos-$release_arch"

    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
        "$release_app" "$release_output/$release_name.zip"
    /usr/bin/unzip -tq "$release_output/$release_name.zip"

    release_stage="$(mktemp -d "$release_root/build/release/dmg-$release_arch.XXXXXX")"
    /usr/bin/ditto "$release_app" "$release_stage/SlowQuit.app"
    ln -s /Applications "$release_stage/Applications"
    cat > "$release_stage/安装说明.txt" <<EOF
SlowQuit $release_version ($release_arch) — macOS 14 或更高版本

1. 将 SlowQuit.app 拖入 Applications（应用程序）文件夹。
2. 从应用程序文件夹打开 SlowQuit。
3. 在系统设置 → 隐私与安全性 → 辅助功能中添加并开启 SlowQuit。

此版本使用本地 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。
如系统阻止打开，请在系统设置 → 隐私与安全性中为此应用选择“仍要打开”。

源码与使用说明：https://github.com/scplsy/SlowQuit
许可：GPL-2.0-or-later；完整许可和第三方声明位于应用的 Contents/Resources 中。
EOF
    /usr/bin/hdiutil create -ov -format UDZO \
        -volname "SlowQuit $release_version ($release_arch)" \
        -srcfolder "$release_stage" "$release_output/$release_name.dmg"
    /usr/bin/hdiutil verify "$release_output/$release_name.dmg"
    rm -rf -- "$release_stage"
    release_stage=""
    release_assets+=("$release_name.dmg" "$release_name.zip")
done

(
    cd "$release_output"
    /usr/bin/shasum -a 256 "${release_assets[@]}" > SHA256SUMS.txt
)
printf 'Release packages: %s\n' "$release_output"
