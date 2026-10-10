# 7zip Mac

基于 [ip7z/7zip](https://github.com/ip7z/7zip) 官方 **26.04** 源码的原生 macOS 图形界面。AppKit 界面和 Finder 集成由本项目实现，压缩解压由官方 C/C++ 内核完成。

这是独立 GUI 项目，不是 Igor Pavlov 发布的官方 Mac GUI。软件“关于”页显示 7-Zip 作者、版本、上游仓库、官方网站和完整许可证入口。

## 项目位置与构建来源

项目位于 `/Users/tashima_meru/Develop/7zip mac gui`。原下载目录中的原始内核、手册、许可证以及开发中的代码已经一起迁移到这里。

- `Vendor/7zip`：官方仓库，固定版本 `26.04`，提交 `9128b80e3a471108678e2b3ec3c985861c8d7b0f`。
- `Sources/ArchiveCore`：进程管理、压缩命令、目录解析、解压检查、分割合并。
- `Sources/SevenZipMac`：原生文件管理界面、对话框、任务窗口、编辑回写、系统服务。
- `FinderExtension`：可选 Finder 右键子菜单扩展。
- `7zz`、`MANUAL`、`License.txt`：原始官方 26.04 下载包内容。
- `build/native-engine/SOURCE.txt`：本地编译内核的来源记录。

`scripts/build-engine.sh` 使用上游自带的 `cmpl_mac_arm64.mak` 和 `cmpl_mac_x64.mak` 编译**未经修改的源码**；`build-app.sh` 默认把该编译结果打包进 GUI。官方原始下载内核另存于 App 的 `Contents/Resources/Upstream/7zz`，便于核对原件。

## 本地构建

需要 macOS 13+、Apple Command Line Tools，以及 Swift 5.9+；本机已在 Swift 6.4 / macOS 27.0.1 上构建验证。无需第三方包管理器。

```sh
cd '/Users/tashima_meru/Develop/7zip mac gui'
./scripts/build-app.sh --universal --finder-extension
./scripts/test.sh
./build/'7zip Mac.app'/Contents/MacOS/SevenZipMac --ui-self-test
```

产物：`build/7zip Mac.app`。`--universal` 构建 Apple Silicon 和 Intel 双架构；省略时构建当前机器架构。首次编译内核需要较长时间，后续增量编译会复用中间产物。

安装到当前用户应用程序目录：

```sh
./scripts/install-app.sh
```

安装脚本仅替换具有相同 bundle identifier 的旧版本，并先保存备份。注册文件打开方式和 Services 不会替用户更改默认解压程序。

当前已安装：`/Users/tashima_meru/Applications/7zip Mac.app`。可携带的打包文件为 `build/7zip Mac-26.04.2.zip`，可用 `./scripts/package-app.sh` 重新生成。

## 使用

- 在主窗口打开文件夹或压缩包，双击进入目录或嵌套压缩包；搜索、排序和平铺视图可用于查找条目。
- **Add** 打开高级压缩设置，支持七种可创建格式、密码、文件名加密、分卷、更新模式和方法参数。
- **Extract** 可以解压全部或选定条目，选择路径模式及冲突处理。**Test** 检查压缩包完整性。
- **Tools** 包含校验和、SHA-256 清单、分割合并、比较文件、基准测试等。
- **Edit and Reimport** 提取待编辑文件；在编辑器保存后，明确选择回写才会更新原压缩包。
- **Create macOS Extractor App** 为当前压缩包生成包含原生解压器的 `.app`。
- **7zip Mac → 关于 7zip Mac** 查看上游声明和许可证。

密码不存入偏好设置；同一压缩包的修改操作避免并发覆盖。操作窗口支持实时日志、可适用操作的暂停、继续和取消。文件复制/移动的取消发生在文件项目边界。

## Finder 右键

启动 App 后，在 Finder 选中文件，使用 **右键 → 服务** 中的添加、快速压缩、解压、测试、校验等动作。如果系统隐藏了服务，在“系统设置 → 键盘 → 键盘快捷键 → 服务”启用。

可选 Finder 扩展提供独立的 `7zip Mac` 子菜单。在 App 的 **设置 → 集成设置 → 启用 Finder 子菜单** 中请求启用，也可在系统“扩展”设置中管理。本机已经启用，并实际从该子菜单完成了压缩包测试；其他机器是否加载仍由 macOS 决定。Apple 对 Finder Sync 的官方定位是同步应用，故保留通用 Services 入口。

## 验收与平台差异

功能目标和细项：[PARITY.md](docs/PARITY.md)。实际构建、测试、原生窗口、Finder 操作证据：[VALIDATION.md](docs/VALIDATION.md)。功能入口、真实文件回归、原生窗口、Finder 集成与分发签名分别验收；平台差异和语言覆盖范围在对照表中明确记录。

Windows 的 NTFS 数据流/安全描述符、注册表、PE `.exe` 自解压与 macOS 不同；本项目分别使用本地文件系统、Launch Services 和 `.app` 自解压。当前构建使用本地 ad-hoc 签名；对外分发的 Developer ID 签名、公证和跨机器验证是独立工作。

## 开源声明

This application uses **7-Zip 26.04**, Copyright (C) **1999–2026 Igor Pavlov**.

7-Zip 源码：[github.com/ip7z/7zip](https://github.com/ip7z/7zip)。官网：[7-zip.org](https://www.7-zip.org/)。主要代码按 GNU LGPL 许可，部分代码采用 BSD 许可，并包含 unRAR 限制；完整条款见随包 [License.txt](License.txt) 及上游 `DOC` 中的许可文件。
