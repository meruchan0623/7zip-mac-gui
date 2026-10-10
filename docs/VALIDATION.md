# 7zip Mac 26.04.2 验收记录

日期：2026-10-10（Asia/Singapore）。环境：Apple Silicon、macOS 27.0.1、Swift 6.4 命令行工具。

## 交付与来源

- 项目：`/Users/tashima_meru/Develop/7zip mac gui`，已从原下载目录迁移。
- 安装：`/Users/tashima_meru/Applications/7zip Mac.app`。
- 构建：`build/7zip Mac.app`；安装包：`build/7zip Mac-26.04.2.zip`。
- 安装包 SHA256：`a64e1aaadf15ad8a132566e27286aed4e63d78cea598aa5a3600cf38f772fa1a`。
- 官方源码：`Vendor/7zip`，tag `26.04`，提交 `9128b80e3a471108678e2b3ec3c985861c8d7b0f`。上游受版本控制源码未经修改。
- 使用官方 arm64 / x64 macOS 构建入口编译 Universal 内核。来源记录：`build/native-engine/SOURCE.txt`。
- 原始下载内核 SHA256：`36ea959367d8f9ac51d47a56dc1f20bfb851f1cd22d6f206e85cb5cbc6ab4577`；App 保留同字节 `Resources/Upstream/7zz`。
- 关于窗口包含 7-Zip 26.04、Igor Pavlov、官方仓库和网站，以及完整许可证入口。LGPL、BSD、unRAR 相关原文随包提供。

## 最终自动检查

| 检查 | 结果 | 证据 |
|---|---|---|
| 官方内核驱动的核心测试 | 51 项、2 个套件通过 | `build/parity-final-tests.log` |
| 最新 GUI 构建 | 通过 | `build/parity-final-gui-build.log` |
| 最新 GUI 工作流检查 | 98 项通过 | `build/parity-final-ui-checks.log` |
| 安装包 arm64 工作流 | 98 项通过 | `build/parity-final-bundle-arm64.log` |
| 安装包 x86_64 工作流（Rosetta） | 98 项通过 | `build/parity-final-bundle-x86_64.log` |
| URL / Services 桥接 | 通过，含非法路由拒绝 | `build/parity-final-tests.log` |
| Universal App / 内核 / Finder 扩展 | 构建通过 | `build/parity-final-build.log` |
| 结构、许可证、原始内核哈希、签名、安装及打包 | 通过 | `build/parity-final-install.log`、`build/parity-final-package.log` |
| Finder 扩展注册 | 26.04.2 已注册并启用，路径为最终安装 App | `pluginkit` 当前读回 |

归档测试覆盖创建、加密、更新、字面与绝对成员名、无扩展名归档、冲突策略、取消、分卷、符号/硬链接、路径保护、时间戳/权限和编辑回写。新增回写检查覆盖 7z、ZIP（AES / ZipCrypto）、TAR（GNU / PAX / USTAR）、WIM、gzip、bzip2、xz，并检查注释、非目标成员、加密状态和失败/并发变更不发布。

GUI 工作流检查包含四种原生布局、排序、语言切换、完整属性、合并冲突及链接重写、取消保留源文件、实际目标路径映射，以及 `/var`、`/private/var`、Unicode 与新目标路径的修改互斥。检查数量不代表逐一人工操作数量。

## 本轮真实原生界面操作

在隔离 QA 应用及专用测试资料中，已实际操作：

- 简体中文菜单及大图标、小图标、列表、详细信息四种视图，截图：`build/native-ui-evidence/`。
- 中文高级压缩对话框，密码隐藏/显示及文件名加密选项。
- 将中文文件通过对话框压缩为加密 7z，再通过解压对话框解压，独立对比字节一致。
- 在归档内剪切中文成员，粘贴到文件系统目标；目标字节一致，原归档成员已删除。

上述实际操作发生于隔离 QA 快照。后续修复了进度标题的中文模板与移动完成后的剪贴板目标 URL，并重建最终安装包；最终包双架构自动检查通过。

**最终安装版原生验收尚未全部完成。** 用户开启权限后，部分 AX 操作曾成功；安装最终包后系统再次返回 `osascript 不允许辅助访问 (-25211)`。已请求用户重新检查授权。最终 About 显示、Finder 全部菜单动作、编辑回写和剪贴板目标 URL 的实际窗口复核仍待完成，不能以自动检查替代。

此前 26.04.1 曾实测 Finder Services 和直接子菜单的测试归档动作成功；这属于旧版证据，不计为本轮最终安装版全部菜单验收。

## 平台差异与交付限制

- 功能对照与实现边界见 [PARITY.md](PARITY.md)。Windows PE 自解压、NTFS 数据流/安全描述符及注册表采用明确的 macOS 对应方式，不能称为同一平台机制。
- 简体中文、繁体中文、英文界面；未移植 Windows 的全部 87 种语言。原始内核日志与文件名保持原文。
- 本地 ad-hoc 签名，尚未使用 Developer ID 签名或通过 Apple 公证。
- Intel 检查通过 Rosetta；实体 Intel Mac 和最低支持版本 macOS 13 尚未实测。
- 不安全路径、无法安全表示的链接及特定不支持回写的 TAR 元数据明确拒绝；取消提交阶段可能保留已完成目标文件。外部恶意进程并发改目录不受应用内修改互斥保护。
