#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then
  printf '回归检查需要在安装了 Apple Command Line Tools 的 Mac 上运行。\n'
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  printf '请先运行 xcode-select --install 安装 Apple Command Line Tools。\n'
  exit 1
fi
bash "$project_dir/Tests/BuildShellRegression.sh"
bash "$project_dir/Tests/InstallerPackagingRegression.sh"
test_dir="$project_dir/.build/tests"
mkdir -p "$test_dir" "$project_dir/.build/module-cache"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
architecture="$(uname -m)"
# Core regression executables do not include AppKit controllers. Check the full
# application first, using the same SDK, target and frameworks as Build.command.
printf '检查：完整应用类型检查（含所有界面）\n'
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -typecheck \
  -target "$architecture-apple-macosx13.0" -sdk "$sdk_path" \
  -module-cache-path "$project_dir/.build/module-cache" \
  -framework AppKit -framework ApplicationServices -framework Security -framework Carbon \
  -framework NaturalLanguage -framework UniformTypeIdentifiers -framework AVFAudio \
  "$project_dir"/Sources/*.swift
for test_source in "$project_dir"/Tests/*.swift; do
  test_name="$(basename "$test_source" .swift)"
  printf '检查：%s\n' "$test_name"
  xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
    -target "$architecture-apple-macosx13.0" -sdk "$sdk_path" \
    -module-cache-path "$project_dir/.build/module-cache" -framework Security -framework NaturalLanguage -framework AVFAudio \
    "$project_dir/Sources/APIClient.swift" \
    "$project_dir/Sources/APIProfile.swift" \
    "$project_dir/Sources/AIPreset.swift" \
    "$project_dir/Sources/APIBalance.swift" \
    "$project_dir/Sources/BalanceDisplayState.swift" \
    "$project_dir/Sources/ChatMessage.swift" \
    "$project_dir/Sources/ChatWindowPlacement.swift" \
    "$project_dir/Sources/ConversationState.swift" \
    "$project_dir/Sources/ConversationMarkdown.swift" \
    "$project_dir/Sources/TranslationLanguage.swift" \
    "$project_dir/Sources/TranslationPreflight.swift" \
    "$project_dir/Sources/TranslationRequest.swift" \
    "$project_dir/Sources/TranslationStorage.swift" \
    "$project_dir/Sources/DictionaryEntry.swift" \
    "$project_dir/Sources/DictionaryService.swift" \
    "$project_dir/Sources/EnglishAccent.swift" \
    "$project_dir/Sources/EnglishSpeechController.swift" \
    "$project_dir/Sources/SelectionTextRange.swift" \
    "$project_dir/Sources/FocusedSelectionReader.swift" \
    "$project_dir/Sources/SettingsStore.swift" \
    "$test_source" -o "$test_dir/$test_name"
  "$test_dir/$test_name"
done
printf '完整应用类型检查与本地回归检查全部通过；没有发送网络请求或读取钥匙串。\n'
