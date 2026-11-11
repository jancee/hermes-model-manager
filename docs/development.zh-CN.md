# 开发指南

[English](development.md) | 简体中文

## 环境配置

安装 Xcode Command Line Tools 和 Python 环境管理工具。在仓库根目录执行：

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements-dev.txt
```

构建脚本依次选择 `STUDIO_PYTHON`、项目中的 `.venv/bin/python`、PATH 中的 `python3`。解释器必须为 Python 3.10+，并已安装锁定版本的解析依赖。

## 检查

```bash
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python scripts/check-localization.py
.venv/bin/python scripts/check-project.py
bash scripts/check-ui.sh
bash scripts/build.sh
'dist/Hermes Model Studio.app/Contents/MacOS/HermesModelStudio' --self-test
```

- Python 测试使用临时 Hermes 目录和本地模拟服务器，检查校验、备份、引用、偏好兼容性、模型发现和批量行为。
- 本地化检查验证资源是否一致以及占位符是否匹配。原生检查覆盖消息翻译、用户输入值保留、排序、选择状态和末尾空格输入。
- 项目检查验证公开 Markdown 链接，并拒绝常见的私人文件或密钥误纳入情况。
- 打包后的自测通过临时目录验证编译后的 Swift 到 Python 调用链。

这些检查不会写入真实 Hermes 配置，也不会发出推理请求。在运行中的 Hermes 客户端进行人工验收，是单独的集成检查。

## 演示预览

使用示例数据渲染预览，不打开可见窗口，也不改变已保存的语言选择：

```bash
APP='dist/Hermes Model Studio.app/Contents/MacOS/HermesModelStudio'
"$APP" --language en --preview "$PWD/docs/assets/endpoints.en.png" --endpoints --sorted
"$APP" --language zh-Hans --preview "$PWD/docs/assets/endpoints.zh-CN.png" --endpoints --sorted
"$APP" --language en --preview "$PWD/docs/assets/models.en.png" --batch
```

其他预览选项包括 `--history`、`--provider-editor` 和 `--discovery`。预览通过不显示的 AppKit 宿主渲染，让原生输入框和滚动视图出现在输出中。修改布局时，请检查两种语言的预览。

## 构建与安装

`VERSION` 是版本号的来源。构建流程会写入应用包版本，按宿主机架构编译以支持 macOS 13 及以上版本，复制适配程序和语言资源，打包解析依赖及其许可证，生成图标，并应用临时签名（ad-hoc）。

```bash
bash scripts/build.sh
.venv/bin/python scripts/install.py
```

安装程序检查应用包身份和签名，在 `~/Applications` 中暂存新应用，并将旧应用保留在项目中已被 Git 忽略的 `backups/` 目录。它不会结束正在运行的应用；重新打开应用后才会加载已安装的版本。

可用 `STUDIO_ARCH=arm64` 或 `STUDIO_ARCH=x86_64` 覆盖编译目标。交叉编译不等于在相应架构上完成运行验收。本地开发构建使用外部解释器；[发布流程](releasing.zh-CN.md) 会内置 Python，并在对应架构的运行器上分别检查。目前未配置 Developer ID 签名与公证。

## 公开仓库内容检查

Git 中只应包含源码、虚构测试样例、文档、演示截图和许可证声明。`.gitignore` 排除了虚拟环境、生成的应用、本地笔记、备份、`.env` 文件和日志。不要强制添加这些目录。

发布前检查 `git diff --cached`，运行项目检查，并确认截图不含个人数据。基于模式的检查只能辅助审阅，不能证明所有敏感信息均已移除。行为变化时，同步维护英文和中文 Markdown 文档。
