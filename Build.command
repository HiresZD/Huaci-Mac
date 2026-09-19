#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_dir"

has_terminal_input() {
  [ -t 0 ]
}

queue_terminal_close() {
  # Finder opens .command files in Terminal. The profile may leave the finished
  # shell visible, so exit alone cannot close that window. Never close a shared
  # tab window or a session running other work.
  [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ] || return 1
  command -v osascript >/dev/null 2>&1 || return 1
  local build_tty
  build_tty="$(tty 2>/dev/null)" || return 1
  case "$build_tty" in /dev/tty*) ;; *) return 1 ;; esac

  # Detach before exiting: nohup alone retains the controlling tty and would
  # make Terminal see the closer itself as an active command. JXA calls setsid
  # before inspecting the session. The tty is an argument, never script text.
  nohup osascript -l JavaScript - "$build_tty" >/dev/null 2>&1 <<'JAVASCRIPT' &
function containsOnlyIdleShells(processNames) {
    var idleShells = ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "login", "-login"];
    return processNames.every(function (name) { return idleShells.indexOf(name) !== -1; });
}

function closeCompletedBuildWindow(terminal, buildTTY, wait) {
    if (!terminal.running()) return;
    var buildWindowID = null;
    var windows = terminal.windows();
    for (var i = 0; i < windows.length; i++) {
        var tabs = windows[i].tabs();
        for (var j = 0; j < tabs.length; j++) {
            if (tabs[j].tty() !== buildTTY) continue;
            if (tabs.length !== 1) return;
            buildWindowID = windows[i].id();
            break;
        }
        if (buildWindowID !== null) break;
    }
    if (buildWindowID === null) return;

    for (var attempt = 0; attempt < 30; attempt++) {
        wait(0.1);
        if (!terminal.running()) return;
        var buildWindow = terminal.windows.byId(buildWindowID);
        if (!buildWindow.exists()) return;
        var buildTabs = buildWindow.tabs();
        if (buildTabs.length !== 1 || buildTabs[0].tty() !== buildTTY) return;
        var buildTab = buildTabs[0];
        // Enter also authorizes closing an idle shell after a manual
        // "bash Build.command" invocation, but never another running job.
        if (!buildTab.busy() && containsOnlyIdleShells(buildTab.processes())) {
            buildWindow.close();
            return;
        }
    }
}

function run(arguments) {
    try {
        ObjC.bindFunction("setsid", ["int", []]);
        if ($.setsid() === -1) return;
        closeCompletedBuildWindow(Application("com.apple.Terminal"), arguments[0], delay);
    } catch (_) {
        // Automation may be denied, or the user may already have closed the
        // tab. The shell's visible message explains the manual Cmd-W fallback.
    }
}
JAVASCRIPT
}

pause_on_exit() {
  local result=$?
  trap - EXIT
  if [ "$result" -ne 0 ]; then
    printf '\n构建未完成。请保留报错以便排查；查看后可按 ⌘W 关闭。\n'
    exit "$result"
  fi
  if has_terminal_input; then
    local reply
    printf '\n按回车键结束并关闭此构建窗口…\n'
    printf '若使用其他终端、窗口有其他标签页/任务，或未允许自动关闭，请按 ⌘W 关闭当前标签页。\n'
    # EOF (for example Ctrl-D) is not an explicit request to close the window.
    if IFS= read -r reply && [ -z "$reply" ]; then
      queue_terminal_close || true
    fi
  fi
  exit "$result"
}
trap pause_on_exit EXIT

if [ "$(uname -s)" != "Darwin" ]; then
  printf '请在 macOS 13 或更新版本的 Mac 上运行此脚本。\n'
  exit 1
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$macos_major" -lt 13 ]; then
  printf '此版本需要 macOS 13 或更高版本。\n'
  exit 1
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  printf '需要 Apple Command Line Tools（免费的官方编译工具）。\n'
  printf '请在终端运行：xcode-select --install\n'
  printf '按系统提示安装完成后，再次运行 Build.command。\n'
  exit 1
fi

if /usr/bin/pgrep -x Huaci >/dev/null 2>&1; then
  printf '检测到划词助手仍在运行。请先从菜单栏或设置中退出所有 Huaci 副本，再构建和替换应用。\n'
  exit 1
fi

printf '正在生成划词助手，首次编译可能需要一分钟…\n'
bash "$project_dir/Test.command"
build_dir="$project_dir/dist"
mkdir -p "$build_dir" "$project_dir/.build/module-cache"
staging_dir="$(mktemp -d "$build_dir/.huaci-build.XXXXXX")"
app_path="$staging_dir/Huaci.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$project_dir/LICENSE" "$app_path/Contents/Resources/LICENSE.txt"

architecture="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O \
  -target "$architecture-apple-macosx13.0" \
  -sdk "$sdk_path" \
  -module-cache-path "$project_dir/.build/module-cache" \
  -framework AppKit -framework ApplicationServices -framework Security -framework Carbon -framework NaturalLanguage -framework UniformTypeIdentifiers -framework AVFAudio \
  "$project_dir"/Sources/*.swift \
  -o "$app_path/Contents/MacOS/Huaci"

plutil -lint "$app_path/Contents/Info.plist"
signing_identity="${HUACI_SIGNING_IDENTITY:--}"
if [ "$signing_identity" = "-" ]; then
  printf '使用临时签名：升级后系统可能保留旧权限记录，需要在 App 的「修复授权」中重新关联当前应用。\n'
else
  printf '使用指定的本机代码签名证书；签名失败会停止，不会退回临时签名。\n'
fi
codesign --force --sign "$signing_identity" "$app_path"
codesign --verify --strict "$app_path"

destination="$build_dir/Huaci.app"
if [ -e "$destination" ]; then
  backup="$build_dir/Huaci-previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$destination" "$backup"
  printf '之前的构建已保留为：%s\n' "$backup"
fi
mv "$app_path" "$destination"
rmdir "$staging_dir"
printf '\n已生成：%s\n' "$destination"
installer_path="$build_dir/Huaci-Installer.dmg"
printf '正在制作拖拽安装窗口…\n'
if bash "$project_dir/Scripts/CreateDMG.sh" "$destination" "$installer_path"; then
  printf '\n安装包已生成：%s\n' "$installer_path"
  printf '请在即将打开的窗口中，将左侧 Huaci 拖到右侧「应用程序」。\n'
  printf '复制完成后，从「应用程序」打开 Huaci，再推出安装磁盘。\n'
  if ! open "$installer_path"; then
    printf '未能自动打开安装窗口，请双击上面的 Huaci-Installer.dmg。\n'
    open -R "$installer_path" || true
  fi
else
  printf '\n应用已构建成功，但安装窗口未能生成；现有安装包未被替换。\n'
  printf '请将 dist 中的新 Huaci.app 拖到「应用程序」或用户「应用程序」文件夹，再打开。\n'
  open -R "$destination" || true
fi
printf '首次使用需在「隐私与安全性 → 辅助功能」中允许划词助手。\n'
printf '若系统已开启但 App 未获授权，使用设置里的「修复授权」定位并重新添加当前这份 Huaci。\n'
