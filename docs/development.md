# 开发 Fishbook

## 构建

Fishbook 使用 SwiftUI、AppKit、PDFKit 和 WebKit，直接通过 `swiftc` 构建 `.app`，不需要本地服务或 Swift Package Manager 依赖。

```sh
zsh build.sh
```

输出 `build/Fishbook.app`，目标为 Apple Silicon / macOS 14。脚本先在临时目录编译、复制资源和签名，检查成功后才替换成品；上一份应用移到 `build/previous/`。

公开仓库只提供空文献目录与离线渲染资源。维护者本机如果存在未纳入 Git 的 `content/library.json`，普通构建会使用本地材料；**对外发布始终执行**：

```sh
zsh build.sh --public
```

输出 `build/public/Fishbook.app`，只打包 `content/public/` 和 `content/reader-vendor/`，不替换日常使用的应用。首次公开版本为 0.8.0，发布包为本机签名，未做 Developer ID 签名或 Apple 公证。

## 源码入口

| 位置 | 负责什么 |
| --- | --- |
| `Sources/App.swift`、`Workspace.swift` | 应用生命周期、阅读布局与操作流程 |
| `PDFReader.swift`、`PDFNavigationPane.swift` | PDF 选择、搜索、导航、大纲、缩略图和书签 |
| `PDFAnnotations.swift`、`PDFAnnotationPane.swift` | 标记生成、编辑入口与 PDF 副本导出 |
| `PDFColors.swift`、`ReaderWindow.swift` | 页面配色、全屏与布局变化后的阅读位置 |
| `Models.swift`、`LibraryStorage.swift` | 核心记录、PDF 导入、持久化、备份和恢复 |
| `Documents.swift`、`MarkdownView.swift` | 材料修订、本地资源与中文阅读器 |
| `LibraryFeatures.swift` | 队列、草稿、书签、复述与范围导出 |
| `Tests/` | 临时资料库、故障路径和原生阅读器检查 |

## 检查

需要 macOS、Swift 编译器和 Node.js。

```sh
zsh tools/check.sh --public
zsh tools/check.sh --public --pdf
zsh tools/check.sh --public --gui
```

公开模式覆盖空库启动、导入与重启、材料修订、存储故障、备份恢复、Markdown、沉浸状态机，以及可选的 PDF 批注、配色和 WebKit 流程。PDFKit/WebKit 检查需要可用的 macOS 图形会话。

部分历史测试核对维护者的本地论文集合，仅在这套集合和本地校验脚本同时存在时执行；它们不是公开仓库测试的前置条件。干净克隆会自动使用公开模式。

测试必须指定随机临时资料目录，不要读写正在使用的资料库。隔离 UI 检查可在测试包 Info.plist 中设置独立的 `FishbookDataDirectory`，并使用不同的 Bundle ID。

## 数据约定

- PDF 身份包含 SHA-256；记录不能在编辑时悄悄换绑论文版本或选区。
- `state.json` 保存核心记录和 PDF 位置，`documents.json` 保存材料与阅读位置，`workspace.json` 保存整理信息、草稿、书签和复述。
- 写入成功后才更新已提交状态及撤销记录；失败时保留用户输入。
- 中文材料更新产生新修订，已有笔记继续指向原修订。
- PDF 配色只影响显示；导出从原始字节生成副本。

## 发布

从干净克隆执行公开检查与 `zsh build.sh --public`。检查包内文献目录为空、没有个人路径或测试资料，再对 `.app` 压缩并计算 SHA-256。

`.gitignore` 采用发布白名单：研究原稿、论文 PDF、完整译稿、本机验收日志、应用构建和个人资料不进入仓库。新增顶层目录或工具时，确认它需要发布，再调整白名单。
