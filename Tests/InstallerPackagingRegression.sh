#!/bin/bash
set -euo pipefail

test_project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$test_project_dir/.build"
test_work_dir="$(mktemp -d "$test_project_dir/.build/huaci-installer-tests.XXXXXX")"
trap 'rm -rf "$test_work_dir"' EXIT
bash -n "$test_project_dir/Scripts/CreateDMG.sh"

# The real packaging script runs against fake macOS tools. Nothing is mounted,
# no Apple Event is sent, and the fixture app is never executed.
mkdir -p "$test_work_dir/bin"
export HUACI_INSTALLER_REAL_MV="$(command -v mv)"
export HUACI_INSTALLER_REAL_CP="$(command -v cp)"
cat > "$test_work_dir/bin/ditto" <<'MOCK'
#!/bin/bash
set -euo pipefail
[ "$#" -eq 2 ]
"$HUACI_INSTALLER_REAL_CP" -R "$1" "$2"
MOCK
cat > "$test_work_dir/bin/osascript" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\0' "$@" > "$HUACI_INSTALLER_STATE/layout.args"
if [ "$HUACI_INSTALLER_MODE" = layout-failure ]; then
  printf 'Not authorized to send Apple events to Finder. (-1743)\n' >&2
  exit 1
fi
[ "$HUACI_INSTALLER_MODE" != layout-no-metadata ] || exit 0
mount_dir="$(cat "$HUACI_INSTALLER_STATE/mountpoint")"
printf 'mock Finder layout\n' > "$mount_dir/.DS_Store"
MOCK
cat > "$test_work_dir/bin/hdiutil" <<'MOCK'
#!/bin/bash
set -euo pipefail
operation="$1"
shift
printf '%s\0' "$operation" "$@" >> "$HUACI_INSTALLER_STATE/hdiutil.args"
case "$operation" in
  create)
    image_path="${!#}"
    source_dir=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -srcfolder ]; then source_dir="$2"; shift; fi
      shift
    done
    [ -d "$source_dir/Huaci.app" ]
    [ "$(readlink "$source_dir/Applications")" = /Applications ]
    [ -f "$source_dir/.background/background.png" ]
    printf '%s' "$source_dir" > "$HUACI_INSTALLER_STATE/stage"
    [ "$HUACI_INSTALLER_MODE" != create-failure ] || exit 41
    printf 'writable image\n' > "$image_path"
    ;;
  attach)
    mount_dir=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -mountpoint ]; then mount_dir="$2"; shift; fi
      shift
    done
    [ -n "$mount_dir" ]
    # The mount directory must belong to the same private workspace as stage.
    [ "$(dirname "$mount_dir")" = "$(dirname "$(cat "$HUACI_INSTALLER_STATE/stage")")" ]
    printf '%s' "$mount_dir" > "$HUACI_INSTALLER_STATE/mountpoint"
    [ "$HUACI_INSTALLER_MODE" != attach-failure ] || exit 42
    "$HUACI_INSTALLER_REAL_CP" -R "$(cat "$HUACI_INSTALLER_STATE/stage")/." "$mount_dir/"
    touch "$HUACI_INSTALLER_STATE/mounted"
    ;;
  detach)
    mount_dir="$(cat "$HUACI_INSTALLER_STATE/mountpoint")"
    matched=no
    forced=no
    for arg in "$@"; do
      case "$arg" in
        "$mount_dir") matched=yes ;;
        -force) forced=yes ;;
        -quiet) ;;
        *) printf 'Unexpected detach target: %s\n' "$arg" >&2; exit 90 ;;
      esac
    done
    [ "$matched" = yes ]
    printf '%s\n' "$forced" >> "$HUACI_INSTALLER_STATE/detaches"
    if [ "$HUACI_INSTALLER_MODE" = detach-failure ]; then exit 43; fi
    if [ "$HUACI_INSTALLER_MODE" = detach-retry ] && [ "$forced" = no ]; then exit 43; fi
    if [ -d "$mount_dir" ]; then
      mkdir -p "$HUACI_INSTALLER_STATE/snapshot"
      "$HUACI_INSTALLER_REAL_CP" -R "$mount_dir/." "$HUACI_INSTALLER_STATE/snapshot/"
    fi
    rm -f "$HUACI_INSTALLER_STATE/mounted"
    ;;
  convert)
    [ ! -e "$HUACI_INSTALLER_STATE/mounted" ]
    # Conversion may not overwrite the existing deliverable in place.
    [ "$(cat "$HUACI_INSTALLER_OUTPUT")" = 'previous usable image' ]
    output_path=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -o ]; then output_path="$2"; shift; fi
      shift
    done
    [ -n "$output_path" ]
    [ "$output_path" != "$HUACI_INSTALLER_OUTPUT" ]
    printf 'new compressed image\n' > "$output_path"
    [ "$HUACI_INSTALLER_MODE" != convert-failure ] || exit 44
    touch "$HUACI_INSTALLER_STATE/converted"
    ;;
  *) printf 'Unexpected hdiutil operation: %s\n' "$operation" >&2; exit 91 ;;
esac
MOCK
cat > "$test_work_dir/bin/mv" <<'MOCK'
#!/bin/bash
set -euo pipefail
target="${!#}"
if [ "$target" = "$HUACI_INSTALLER_OUTPUT" ]; then
  [ -e "$HUACI_INSTALLER_STATE/converted" ]
  [ ! -e "$HUACI_INSTALLER_STATE/mounted" ]
  [ "$(cat "$target")" = 'previous usable image' ]
  [ "$HUACI_INSTALLER_MODE" != commit-failure ] || exit 45
  touch "$HUACI_INSTALLER_STATE/committed"
fi
exec "$HUACI_INSTALLER_REAL_MV" "$@"
MOCK
cat > "$test_work_dir/bin/bless" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\0' "$@" > "$HUACI_INSTALLER_STATE/bless.args"
mount_dir="$(cat "$HUACI_INSTALLER_STATE/mountpoint")"
[ "$#" -eq 4 ]
[ "$1" = --folder ]
[ "$2" = "$mount_dir" ]
[ "$3" = --openfolder ]
[ "$4" = "$mount_dir" ]
touch "$HUACI_INSTALLER_STATE/bless-target-verified"
[ "$HUACI_INSTALLER_MODE" != bless-failure ]
MOCK
chmod +x "$test_work_dir/bin/ditto" "$test_work_dir/bin/osascript" \
  "$test_work_dir/bin/hdiutil" "$test_work_dir/bin/mv" "$test_work_dir/bin/bless"

fail() { printf 'FAIL installer packaging: %s\n' "$*" >&2; exit 1; }

run_case() {
  local name="$1" expected="$2"
  local case_dir="$test_work_dir/$name spaces ' and \" quotes"
  local source_app="$case_dir/source ' app \".app"
  local output_dir="$case_dir/dist ' and \""
  local output_image="$output_dir/Huaci ' install \".dmg"
  mkdir -p "$source_app/Contents/MacOS" "$output_dir" "$case_dir/state"
  printf 'original application\n' > "$source_app/Contents/MacOS/Huaci"
  printf 'previous usable image\n' > "$output_image"
  export HUACI_INSTALLER_STATE="$case_dir/state"
  export HUACI_INSTALLER_MODE="$name"
  export HUACI_INSTALLER_OUTPUT="$output_image"
  local status=0
  PATH="$test_work_dir/bin:$PATH" bash "$test_project_dir/Scripts/CreateDMG.sh" \
    "$source_app" "$output_image" > "$case_dir/stdout" 2> "$case_dir/stderr" || status=$?
  [ "$(cat "$source_app/Contents/MacOS/Huaci")" = 'original application' ] || fail "$name changed source app"

  if [ "$expected" = success ]; then
    [ "$status" -eq 0 ] || { cat "$case_dir/stderr" >&2; fail "$name exited $status"; }
    [ "$(cat "$output_image")" = 'new compressed image' ] || fail "$name did not publish compressed image"
    [ "$(cat "$case_dir/stdout")" = "$output_image" ] || fail "$name stdout is not the final path"
    [ -e "$case_dir/state/committed" ] || fail "$name bypassed final commit"
    [ -e "$case_dir/state/bless-target-verified" ] || fail "$name did not restrict bless to its private mountpoint"
    [ ! -e "$case_dir/state/mounted" ] || fail "$name left mounted image"
    local layout_script='' layout_mount='' layout_extra=''
    {
      IFS= read -r -d '' layout_script
      IFS= read -r -d '' layout_mount
      IFS= read -r -d '' layout_extra || true
    } < "$case_dir/state/layout.args"
    [ "$layout_script" = "$test_project_dir/Scripts/LayoutInstaller.applescript" ] || fail "$name layout script argument"
    [ "$layout_mount" = "$(cat "$case_dir/state/mountpoint")" ] || fail "$name lost quoting in mount argument"
    [ -z "$layout_extra" ] || fail "$name unexpected layout argument"
    [ ! -e "$(dirname "$layout_mount")" ] || fail "$name leaked private work directory"
    [ "$(readlink "$case_dir/state/snapshot/Applications")" = /Applications ] || fail "$name lost Applications link"
    if [ "$name" = layout-failure ] || [ "$name" = layout-no-metadata ]; then
      [ -s "$case_dir/state/snapshot/安装说明.txt" ] || fail 'Finder permission refusal lost install instructions'
      [ ! -e "$case_dir/state/snapshot/.DS_Store" ] || fail 'mock unexpectedly created Finder layout'
    else
      [ -s "$case_dir/state/snapshot/.DS_Store" ] || fail "$name did not preserve layout"
    fi
    if [ "$name" = detach-retry ]; then
      [ "$(cat "$case_dir/state/detaches")" = $'no\nyes' ] || fail 'detach retry was not limited to own mountpoint'
    fi
  else
    [ "$status" -ne 0 ] || fail "$name unexpectedly succeeded"
    [ "$(cat "$output_image")" = 'previous usable image' ] || fail "$name destroyed old DMG"
    [ ! -e "$case_dir/state/committed" ] || fail "$name committed partial image"
    [ ! -s "$case_dir/stdout" ] || fail "$name printed a success path"
    if [ "$name" = detach-failure ]; then
      local mount_dir="$(cat "$case_dir/state/mountpoint")"
      [ -e "$mount_dir/Huaci.app/Contents/MacOS/Huaci" ] || fail 'cleanup deleted contents of a still-mounted image'
      [ -e "$case_dir/state/mounted" ] || fail 'detach failure not modeled'
    elif [ -e "$case_dir/state/stage" ]; then
      [ ! -e "$(dirname "$(cat "$case_dir/state/stage")")" ] || fail "$name leaked unmounted work directory"
    fi
  fi
}

run_case success success
run_case layout-failure success
run_case layout-no-metadata success
run_case bless-failure success
run_case detach-retry success
run_case create-failure failure
run_case attach-failure failure
run_case detach-failure failure
run_case convert-failure failure
run_case commit-failure failure

# Input rejection must precede staging or platform tooling. In particular an
# accidental output path inside the user's application must never modify it.
validation_dir="$test_work_dir/argument validation"
mkdir -p "$validation_dir/source.app/Contents" "$validation_dir/state" "$validation_dir/directory.dmg"
printf 'original nested file\n' > "$validation_dir/source.app/existing.dmg"
export HUACI_INSTALLER_STATE="$validation_dir/state"
export HUACI_INSTALLER_MODE=validation
expect_rejected() {
  local status=0
  PATH="$test_work_dir/bin:$PATH" bash "$test_project_dir/Scripts/CreateDMG.sh" "$@" \
    > "$validation_dir/stdout" 2> "$validation_dir/stderr" || status=$?
  [ "$status" -ne 0 ] || fail 'invalid packaging arguments succeeded'
  [ ! -s "$validation_dir/stdout" ] || fail 'invalid arguments printed a success path'
  [ ! -e "$validation_dir/state/hdiutil.args" ] || fail 'invalid arguments reached disk tools'
}
expect_rejected
expect_rejected "$validation_dir/source.app"
expect_rejected "$validation_dir/missing.app" "$validation_dir/output.dmg"
expect_rejected "$validation_dir/source.app" "$validation_dir/directory.dmg"
expect_rejected "$validation_dir/source.app" "$validation_dir/output.zip"
expect_rejected "$validation_dir/source.app" "$validation_dir/source.app/existing.dmg"
[ "$(cat "$validation_dir/source.app/existing.dmg")" = 'original nested file' ] || fail 'invalid output modified source app'
printf 'Installer packaging regression checks passed (mocked macOS tools; no disk images mounted).\n'
