#!/bin/bash
set -euo pipefail

test_project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$test_project_dir/.build"
test_work_dir="$(mktemp -d "$test_project_dir/.build/huaci-build-tests.XXXXXX")"
trap 'rm -rf "$test_work_dir"' EXIT

# Exercise the actual exit handler without running a compiler or opening an app.
awk '/^has_terminal_input\(\)/ { copying = 1 } /^trap pause_on_exit EXIT/ { exit } copying { print }' \
  "$test_project_dir/Build.command" > "$test_work_dir/functions.sh"
bash -n "$test_project_dir/Build.command"

check_pause() {
  local name="$1" status="$2" interactive="$3" input="$4" expected_close="$5"
  local actual_status=0
  printf '%s' "$input" > "$test_work_dir/input"
  rm -f "$test_work_dir/close-request"
  bash -c '
    set -euo pipefail
    . "$1/functions.sh"
    # Functions receive no arguments from the handler; use a separate variable.
    test_interactive="$3"
    if [ "$test_interactive" != actual ]; then
      has_terminal_input() { [ "$test_interactive" = yes ]; }
    fi
    test_result_file="$1/close-request"
    queue_terminal_close() { printf requested > "$test_result_file"; }
    trap pause_on_exit EXIT
    exit "$2"
  ' bash "$test_work_dir" "$status" "$interactive" \
    < "$test_work_dir/input" > "$test_work_dir/output" 2>&1 || actual_status=$?
  [ "$actual_status" -eq "$status" ] || { printf 'FAIL exit code: %s\n' "$name"; exit 1; }
  if [ "$expected_close" = yes ]; then
    [ -f "$test_work_dir/close-request" ] || { printf 'FAIL missing close: %s\n' "$name"; exit 1; }
  else
    [ ! -e "$test_work_dir/close-request" ] || { printf 'FAIL unexpected close: %s\n' "$name"; exit 1; }
  fi
  if [ "$status" -ne 0 ]; then
    grep -q '保留报错' "$test_work_dir/output"
  fi
}

check_pause success-enter 0 yes $'\n' yes
check_pause success-eof 0 yes '' no
check_pause success-other-input 0 yes $'later\n' no
check_pause failed-enter 7 yes $'\n' no
check_pause failed-noninteractive 23 actual '' no
check_pause success-noninteractive 0 actual $'\n' no

# Capture the real queued command through a mock executable; it cannot reach
# Terminal. Waiting here also catches accidentally leaving the helper on stdin.
mkdir "$test_work_dir/bin"
cat > "$test_work_dir/bin/osascript" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "$HUACI_BUILD_TEST_DIR/arguments"
cat > "$HUACI_BUILD_TEST_DIR/closer.js"
MOCK
chmod +x "$test_work_dir/bin/osascript"
(
  . "$test_work_dir/functions.sh"
  export PATH="$test_work_dir/bin:$PATH"
  export HUACI_BUILD_TEST_DIR="$test_work_dir"
  export TERM_PROGRAM=Apple_Terminal
  tty() { printf '/dev/ttysHUACI\n'; }
  queue_terminal_close
  wait
  [ "$(cat "$test_work_dir/arguments")" = $'-l\nJavaScript\n-\n/dev/ttysHUACI' ]
  rm "$test_work_dir/arguments"
  TERM_PROGRAM=iTerm.app
  if queue_terminal_close; then exit 1; fi
  [ ! -e "$test_work_dir/arguments" ]
  TERM_PROGRAM=Apple_Terminal
  tty() { printf 'not a tty\n'; }
  if queue_terminal_close; then exit 1; fi
  [ ! -e "$test_work_dir/arguments" ]
)

if command -v node >/dev/null 2>&1; then
  node - "$test_work_dir/closer.js" <<'JAVASCRIPT'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const context = {};
vm.createContext(context);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context);

function scenario(options = {}) {
  const closed = [];
  const target = { tty: '/dev/ttysHUACI', busy: false, processes: ['zsh'], ...options.tab };
  const other = { tty: '/dev/ttysOTHER', busy: false, processes: [] };
  const specifier = tab => ({ tty: () => tab.tty, busy: () => tab.busy, processes: () => tab.processes });
  const targetWindow = {
    present: true, tabList: [target], id: () => 202,
    exists() { return this.present; },
    tabs() { return this.tabList.map(specifier); },
    close() { closed.push(202); }
  };
  const otherWindow = {
    id: () => 101, exists: () => true,
    tabs: () => [specifier(other)], close: () => closed.push(101)
  };
  if (options.multiple) targetWindow.tabList.push(other);
  let running = options.running !== false;
  const windows = () => [otherWindow, targetWindow];
  windows.byId = id => id === 202 ? targetWindow : otherWindow;
  const terminal = { running: () => running, windows };
  let waits = 0;
  context.closeCompletedBuildWindow(terminal, options.tty || target.tty, () => {
    waits++;
    if (options.onWait) options.onWait({ target, targetWindow, waits, stop: () => { running = false; } });
  });
  return { closed, waits };
}

assert.deepStrictEqual(scenario().closed, [202], 'manual shell: close only matching window');
assert.deepStrictEqual(scenario({tab: { processes: [] }}).closed, [202], 'completed Finder session');
assert.deepStrictEqual(scenario({tty: '/dev/ttysMISSING'}).closed, [], 'unknown tty');
assert.deepStrictEqual(scenario({multiple: true}).closed, [], 'shared window');
assert.deepStrictEqual(scenario({tab: {busy: true}}).closed, [], 'busy command');
assert.strictEqual(scenario({tab: {busy: true}}).waits, 30, 'bounded wait');
assert.deepStrictEqual(scenario({tab: {processes: ['zsh', 'sleep']}}).closed, [], 'background task');
assert.deepStrictEqual(scenario({tab: {processes: ['osascript']}}).closed, [], 'closer must detach');
assert.deepStrictEqual(scenario({running: false}).closed, [], 'do not launch Terminal');
assert.deepStrictEqual(scenario({onWait: ({target}) => { target.tty = '/dev/ttysNEW'; }}).closed, [], 'changed tty');
assert.deepStrictEqual(scenario({onWait: ({targetWindow}) => { targetWindow.present = false; }}).closed, [], 'closed window');
assert.deepStrictEqual(scenario({onWait: ({targetWindow, target}) => { targetWindow.tabList.push(target); }}).closed, [], 'new tab');
assert.deepStrictEqual(scenario({onWait: ({stop}) => stop()}).closed, [], 'Terminal exited');
assert.deepStrictEqual(scenario({tab: {busy: true}, onWait: ({target, waits}) => {
  if (waits === 3) target.busy = false;
}}).closed, [202], 'wait for build to finish');

let accessedTerminal = false;
context.ObjC = { bindFunction: (name, signature) => assert.strictEqual(name, 'setsid') };
context.$ = { setsid: () => -1 };
context.Application = () => { accessedTerminal = true; throw new Error('unexpected'); };
context.run(['/dev/ttysHUACI']);
assert.strictEqual(accessedTerminal, false, 'failed detach must not send close events');
console.log('Build terminal-selection regression checks passed (mocked JXA API).');
JAVASCRIPT
else
  printf 'Node 不可用：已检查 Shell 行为，跳过模拟 Terminal 对象检查。\n'
fi
printf 'Build Shell regression checks passed; no Terminal windows were opened or closed.\n'
