# 发布指南

[English](releasing.md) | 简体中文

仅打包 macOS 应用。Apple Silicon 与 Intel 分别提供 ZIP；GitHub 还会自动提供标准源码压缩包。

## 构建安装包

使用 macOS、Xcode Command Line Tools 和项目的 Python 3.12+ 环境：

```bash
.venv/bin/python scripts/package-macos.py --arch arm64
.venv/bin/python scripts/package-macos.py --arch x86_64
```

在对应架构的 Mac 上分别执行，或使用 GitHub Actions 的 **Package macOS** 工作流。打包脚本会拒绝与宿主机不同的架构，确保发布检查使用原生执行、不依赖 Rosetta。交叉编译成功本身不等于运行验证。

脚本在临时目录构建应用，校验固定版本的 Python 下载，内置解释器和许可证，然后为嵌套二进制与应用签名。生成 ZIP 后，会解压到不同路径，在空白用户目录、不带开发环境的条件下运行打包集成检查，并明确要求使用内置解释器。执行后再次检查签名，以发现对应用包内部的意外写入。

产物位于 `dist/releases/`：

- `Hermes-Model-Studio-VERSION-macOS-arm64.zip`
- `Hermes-Model-Studio-VERSION-macOS-x86_64.zip`
- 对应的 `.zip.sha256` 文件。

每个应用会检查架构一致性、指向包外的符号链接、开发目录路径和非系统绝对路径库依赖。ZIP 仅包含应用，不包含 Hermes 配置或凭证。

## GitHub Release

1. 更新 `VERSION`、两种语言的变更记录及带版本的下载链接，审阅并提交源码差异。
2. 推送已审阅源码，为该提交所在分支运行 **Package macOS**。工作流在对应的 arm64 和 Intel 运行器上执行适配程序、本地化、文档与原生检查，然后上传安装包。
3. 确认两个任务均通过，且运行记录对应预期提交。用 `gh run download` 下载两份产物，验证 SHA-256 文件。
4. 根据对应版本的变更记录准备双语发布说明，包含安装方法和签名状态，保存为 UTF-8 文件。
5. 为已测试的提交创建并推送带说明的版本标签。用 `gh release create --verify-tag --draft --notes-file` 创建草稿，仅附加 macOS ZIP 和校验和文件。
6. 读回已上传附件，检查大小与摘要。发布草稿，并确认 Release 和下载可以公开访问。

不要移动已有公开标签，也不要静默替换已发布安装包。需要修正时，使用新的补丁版本。

## 运行环境更新与签名

`scripts/python-runtime.json` 固定上游 Python 版本、发布批次、压缩包地址、SHA-256 和许可证来源提交。更新时应同步修改，并在 `licenses/python-runtime/` 保留对应上游许可声明。不要将个人虚拟环境复制到公开发布包。

发布包采用临时签名（ad-hoc），目前未配置 Developer ID 证书或公证凭据。README 提供 Apple 的单应用打开说明。签名校验成功只能证明应用包完整，不能代表 Apple 公证或用户验收。
