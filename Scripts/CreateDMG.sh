#!/bin/bash
set -euo pipefail

# Build an installer without modifying the supplied application or installing it.
# stdout contains only the finished DMG path. Progress and warnings use stderr.
if [ "$#" -ne 2 ]; then
  printf '用法：bash Scripts/CreateDMG.sh APP_PATH OUTPUT_DMG\n' >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/.." && pwd -P)"
background_path="$project_dir/Resources/InstallerBackground.png"
layout_script="$script_dir/LayoutInstaller.applescript"
app_argument=$1
output_argument=$2

fail() {
  printf '安装镜像：%s\n' "$1" >&2
  exit 1
}

[ -d "$app_argument/Contents" ] || fail '未找到有效的应用程序目录。'
app_path="$(cd -- "$app_argument" && pwd -P)"
output_dir="$(cd -- "$(dirname -- "$output_argument")" && pwd -P)" || fail '输出目录不存在。'
output_name="$(basename -- "$output_argument")"
case "$output_name" in
  *.dmg) ;;
  *) fail '输出文件名必须以 .dmg 结尾。' ;;
esac
output_path="$output_dir/$output_name"
case "$output_path" in
  "$app_path"|"$app_path"/*) fail '安装镜像不能写入原应用程序内部。' ;;
esac
[ ! -d "$output_path" ] || fail '输出路径已经是一个目录。'
[ -f "$background_path" ] || fail '缺少安装窗口背景图。'
[ -f "$layout_script" ] || fail '缺少安装窗口布局脚本。'
for required_tool in hdiutil ditto; do
  command -v "$required_tool" >/dev/null 2>&1 || fail "缺少 macOS 系统工具：$required_tool"
done

# Keeping the final image on the output filesystem makes publication one rename.
# A failed build never truncates or deletes an existing installer.
work_dir="$(mktemp -d "$output_dir/.huaci-installer.XXXXXX")"
mount_dir="$work_dir/mount"
mount_may_be_attached=0

detach_image() {
  [ "$mount_may_be_attached" -eq 1 ] || return 0
  if hdiutil detach "$mount_dir" >&2; then
    mount_may_be_attached=0
    return 0
  fi
  printf '正在卸载本次构建的临时安装镜像…\n' >&2
  if hdiutil detach -force "$mount_dir" >&2; then
    mount_may_be_attached=0
    return 0
  fi
  return 1
}

cleanup() {
  local result=$?
  trap - EXIT HUP INT TERM
  if ! detach_image; then
    # Never recursively remove a directory while it might contain a mounted
    # filesystem. Preserve it for manual eject/recovery instead.
    printf '临时镜像无法卸载，已保留：%s\n请先在访达中推出该镜像。\n' "$mount_dir" >&2
    [ "$result" -ne 0 ] || result=1
  else
    if ! rm -rf -- "$work_dir"; then
      printf '临时构建目录未能完全清理：%s\n' "$work_dir" >&2
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

stage_dir="$work_dir/stage"
mkdir -p "$stage_dir/.background" "$mount_dir"
ditto "$app_path" "$stage_dir/Huaci.app"
ln -s /Applications "$stage_dir/Applications"
cp "$background_path" "$stage_dir/.background/background.png"

# Reserve room for Finder metadata as well as the copied application. Explicit
# headroom avoids a nearly-full read/write image that cannot save .DS_Store.
stage_kb="$(du -sk "$stage_dir" | awk '{print $1}')"
case "$stage_kb" in ''|*[!0-9]*) fail '无法计算安装镜像大小。' ;; esac
image_kb=$((stage_kb + 32768))
if [ "$image_kb" -lt 65536 ]; then image_kb=65536; fi
readwrite_image="$work_dir/installer-readwrite.dmg"
finished_image="$work_dir/installer-finished.dmg"

printf '正在制作划词助手安装镜像…\n' >&2
hdiutil create -srcfolder "$stage_dir" -volname '划词助手安装' \
  -fs HFS+ -format UDRW -size "${image_kb}k" "$readwrite_image" >&2

# Set this before attaching so even an interrupted/partially successful attach
# attempts to eject this exact private mountpoint during cleanup.
mount_may_be_attached=1
hdiutil attach -nobrowse -noautoopen -mountpoint "$mount_dir" "$readwrite_image" >&2

layout_ready=0
if command -v osascript >/dev/null 2>&1; then
  printf '正在布置安装窗口。如 macOS 请求允许终端控制访达，可选择允许；拒绝时仍会生成带安装说明的镜像。\n' >&2
  if osascript "$layout_script" "$mount_dir" >&2; then
    # Finder normally writes metadata when its window closes. Briefly allow
    # that write to finish, rather than falsely reporting a styled installer.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if [ -f "$mount_dir/.DS_Store" ]; then
        layout_ready=1
        break
      fi
      sleep 0.1
    done
  fi
fi

if [ "$layout_ready" -ne 1 ]; then
  printf '访达未能保存安装窗口布局，改为生成带「安装说明.txt」的基础安装镜像。\n' >&2
  cat > "$mount_dir/安装说明.txt" <<'INSTRUCTIONS'
划词助手安装方法

1. 如果旧版划词助手正在运行，请先从菜单栏或设置中退出。
2. 将此窗口中的 Huaci.app 拖到旁边的 Applications（应用程序）文件夹。
3. 复制完成后，从「应用程序」打开 Huaci，再推出安装镜像。

如果系统提示替换旧版本，请确认已退出旧版后再替换。
请不要直接在安装镜像里运行 Huaci。

此镜像未能保存自定义安装窗口布局，但应用本身可正常复制安装。
INSTRUCTIONS
fi

# HFS+ can record which folder Finder should open when the image is mounted.
# This is cosmetic: newer macOS releases may decline to bless a non-bootable
# volume, so an unsupported/failed marker must not discard a usable installer.
if command -v bless >/dev/null 2>&1; then
  if ! bless --folder "$mount_dir" --openfolder "$mount_dir" >&2; then
    printf '未能设置安装镜像的自动打开标记；挂载后可在访达中打开「划词助手安装」。\n' >&2
  fi
fi

detach_image || fail '无法卸载临时镜像，未生成新的安装包。'
hdiutil convert "$readwrite_image" -format UDZO -imagekey zlib-level=9 \
  -o "$finished_image" >&2
[ -s "$finished_image" ] || fail '磁盘工具未生成完整的安装镜像。'
mv -f -- "$finished_image" "$output_path"
printf '%s\n' "$output_path"
