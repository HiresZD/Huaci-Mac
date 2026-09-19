# Huaci · 划词助手

简洁的原生 macOS 划词翻译与 AI 助手。选中文字，点击「翻译」或「问 AI」，使用你自己的大模型 API。

**当前版本：1.3.7** · macOS 13+ · Apple Silicon / Intel · Swift + AppKit

## 功能

- **划词翻译**：自动识别源语言，支持中文、英语、日语、韩语、阿拉伯语等目标语言；源语言与目标语言相同时跳过翻译。
- **单词词典**：单个词汇展示原词、音标、词性、释义、常见搭配和例句；短语或句子直接翻译。英文单词可用系统语音发音，支持英式、美式口音。
- **连续问答**：点击「问 AI」立即提交选中文字，每次划词开始独立会话，窗口内可继续追问。「解释这段」「提炼要点」「润色表达」三个预设点击即发送，记录可清除或导出 Markdown。
- **轻量浮窗**：跟随选区显示；翻译窗口可固定，字号与高度随内容调整，长内容滚动查看。
- **多套 API**：支持 OpenAI 兼容 Chat Completions 接口，翻译和问答可使用不同配置，密钥保存在 macOS 钥匙串中。
- **缓存与历史**：内存缓存默认 200 条、5 MB，可调整；本地翻译历史支持搜索、收藏和 Markdown 导出。
- **简洁设置**：次要说明悬停显示，菜单栏图标可隐藏；DeepSeek 官方 API 可查询余额，OpenAI 官方 API 提供账单入口。

## 安装

在 [Releases 发布页](https://github.com/foreverdzx/Huaci-Mac/releases) 下载安装包或源码包：

- **Apple Silicon（M 系列）Mac**：下载 `Huaci-Installer-arm64-v1.3.7.dmg`，双击打开，将 Huaci 拖到「应用程序」。启动后配置 API，并授予辅助功能权限。
- **Intel Mac 或希望自行构建**：下载 `huaci-mac-source-1.3.7.zip`，按下面的步骤编译。构建脚本会生成适合当前 Mac 架构的应用和 DMG。

安装包需要 macOS 13 或更高版本；本次提供的 DMG 仅含 ARM64 应用。

从源码构建：

1. 下载或克隆本仓库。升级前先退出正在运行的 Huaci，新源码请放在独立文件夹，不要合并覆盖旧版源码目录。
2. 首次构建若尚未安装 Apple Command Line Tools，在终端运行 `xcode-select --install`，完成后继续。
3. 在项目文件夹中运行：

   ```bash
   bash Build.command
   ```

   也可在终端输入 `bash `，将 `Build.command` 拖入终端后按回车。
4. 检查与构建成功后会打开 `dist/Huaci-Installer.dmg`，把 Huaci 拖到「应用程序」并从那里启动。
5. 在设置中填写 API 地址、模型 ID 和密钥，保存后测试连接；在系统设置的「隐私与安全性 → 辅助功能」中允许当前安装的 Huaci。

无需完整 Xcode 或第三方包管理器。应用默认使用本地临时签名，未经过 Apple 公证；重新构建后可能需要重新授予辅助功能权限。详见 [安装、升级与权限排错](docs/USER_GUIDE.md)。

## 使用

选中文字后，点击鼠标附近的「翻译」或「问 AI」。翻译结果顶部可切换目标语言，图钉可固定窗口；问答支持输入追问并按 **⌘Return** 发送。

自动取词依赖原应用的辅助功能接口。在部分应用中无法取词时，开启「复制后显示划词选项（兼容模式）」并按 **⌘C**。兼容模式保留自动取词，也可使用 **Control + Option + 空格** 或菜单栏的剪贴板入口。本应用不含 OCR。

隐藏菜单栏图标后，重新打开 Huaci.app 即可进入设置。更多操作见 [完整使用说明](docs/USER_GUIDE.md)。

## API 配置

填写服务商提供的 HTTPS 接口地址、API Key 和当前可用的模型 ID。应用支持 OpenAI 兼容的 **Chat Completions** 接口，可填写基础地址或完整的 `/chat/completions` 端点。

DeepSeek 官方地址可填写 `https://api.deepseek.com`；模型可自行选择。OpenAI 官方地址可填写 `https://api.openai.com/v1`。其他兼容服务和中转站按其文档配置，不支持直接调用原生 Anthropic Messages、Gemini generateContent 或仅提供 Responses 的服务。

余额功能按接口域名识别：DeepSeek 官方服务显示账户余额；OpenAI 官方服务提供账单页面入口，**不显示剩余余额数字**。其他服务的余额接口需要单独适配。

## 数据与隐私

- API Key 保存在系统钥匙串，其他设置保存在本机。不要把自己的密钥加入源码或提交到仓库。
- 自动读取选区只显示操作入口。点击翻译、问答、预设、重试或连接测试时才按操作向配置的服务发送对应文字；聊天请求包含本次会话已完成的问答。打开设置或刷新余额也可能向 DeepSeek 官方发送余额查询。
- 翻译缓存和当前 AI 会话位于内存，退出后清空；翻译历史与收藏另行保存到本机，默认启用自动历史。可在设置中管理，导出文件由用户自行保存。
- 英文发音使用已安装的系统语音。应用没有自建中转服务器、统计服务或自动云同步。

大模型词典解释和音标可能有误，跨应用取词兼容性取决于原应用。完整的数据处理和功能限制见 [使用说明](docs/USER_GUIDE.md#数据处理)。

## 开发与验证

在装有 Apple Command Line Tools 的 Mac 上运行：

```bash
bash Test.command
```

脚本先检查完整 AppKit 应用的类型，再运行本地回归检查；不使用真实 API 密钥或发送接口请求。`Build.command` 会自动执行同一组检查。

1.3.7 已完成源码复核和打包检查。提供的 DMG 已核对内置应用版本为 1.3.7（构建号 22），架构为 ARM64，最低系统要求为 macOS 13。本次交付环境没有 macOS SDK，**未在此环境重新编译或实际运行该安装包，未验证代码签名和公证状态**。

| 目录 / 文件 | 用途 |
| --- | --- |
| `Sources/` | 应用、取词、翻译、对话与设置的 Swift 源码 |
| `Resources/` | 应用元信息、图标与安装窗口背景 |
| `Scripts/` | DMG 制作及 Finder 安装窗口布局 |
| `Tests/` | 本地回归检查 |
| `Build.command` / `Test.command` | 构建 / 验证入口 |
| [CHANGELOG.md](CHANGELOG.md) | 各版本更新日志 |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | 详细使用说明与排错 |

仓库暂未指定开源许可证。
