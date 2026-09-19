# Huaci 1.3.7

原生 macOS 划词翻译与 AI 助手，支持自带 OpenAI 兼容 API、单词词典、系统发音、连续问答、翻译历史和收藏。

本版更新：

- 修正音标旁小喇叭的位置，按文字基线对齐，长音标换行时跟随第一行。
- 翻译结果滚动条常态显示为 3 pt 淡细线，鼠标移入或拖动时变为 6 pt 并加深；无需滚动时隐藏。
- 为正文与滚动条预留间距，避免遮挡译文及滚动条显隐引起的重新折行。

本次同时整理项目首页、完整更新日志和使用说明，不改变应用功能或版本号。

## 安装

| 下载文件 | 适用方式 |
| --- | --- |
| `Huaci-Installer-arm64-v1.3.7.dmg` | Apple Silicon（M 系列）Mac 直接安装，需要 macOS 13+ |
| `huaci-mac-source-mit-1.3.7.zip` | 含 MIT 许可证的完整源码，支持在 Apple Silicon 或 Intel Mac 上构建对应架构的应用 |

**DMG 安装**：先退出旧版，双击 DMG，将 Huaci 拖到「应用程序」。启动后配置 API，并在系统设置中允许辅助功能访问。本次安装包仅含 ARM64 应用，Intel Mac 请使用源码构建。

**源码构建**：解压源码包到独立文件夹，在 Mac 上运行 `bash Build.command`。需要 macOS 13+ 和 Apple Command Line Tools；构建成功后将生成的 DMG 中的 Huaci 拖到「应用程序」。

已检查所提供 DMG 的封装、内置应用版本 1.3.7（构建号 22）、ARM64 架构和最低系统要求。未在本次交付环境中实际运行安装包，也未验证其代码签名或公证状态。源码构建脚本默认使用本地临时签名，会先执行完整类型检查和本地回归检查。

DMG 的 SHA-256：`eb5c1d34bd2142ac45a3e617923ce0a099700050443153c33e15202909df0a1e`。

## MIT 许可证

Huaci 1.3.7 采用 MIT 许可证，Copyright (c) 2026 HiresZD。允许使用、修改、分发及商业使用，再分发时须保留版权声明和完整许可证文本。软件按原样提供，不作担保。完整条款见本页附件 `LICENSE.txt` 或[仓库许可证](https://github.com/HiresZD/Huaci-Mac/blob/main/LICENSE)。

新增的 `huaci-mac-source-mit-1.3.7.zip` 包含许可证和更新后的安装文档，构建脚本会在签名前将许可证放入应用资源目录；应用功能与版本号不变。

原 DMG 和 `huaci-mac-source-1.3.7.zip` 保留不变，同样适用上述 MIT 授权。它们内部尚未包含许可证文件，重新打包或分发时请一并附上 `LICENSE.txt`。
