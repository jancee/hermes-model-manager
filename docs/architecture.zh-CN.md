# 架构说明

[English](architecture.md) | 简体中文

Hermes Model Studio 是一个 SwiftUI/AppKit 桌面应用，通过小型 Python 适配程序读写 Hermes 配置与偏好。它不加载或修改 Hermes 的 Python 包。

## 组件

| 组件 | 职责 |
| --- | --- |
| `Sources/main.swift` | 应用生命周期、菜单、预览和打包后的集成检查 |
| `Sources/StudioView.swift`、`ManagementViews.swift`、`Editors.swift` | 列表、表单和批量操作 |
| `Sources/StudioState.swift` | 选择状态、刷新、修改请求和用户确认 |
| `Sources/Models.swift` | 带类型的状态快照与子进程桥接 |
| `Sources/Sorting.swift` | 稳定的表格排序与排序设置保存 |
| `Sources/EndpointNameField.swift` | 保留末尾空格与光标位置的原生文本输入 |
| `Sources/Localization.swift`、`Resources/Locales/` | 英文和中文界面资源 |
| `Resources/bridge.py` | 校验、目录读取、配置写入和偏好更新 |

原生进程通过适配程序的标准输入发送一条 JSON 请求，并从标准输出接收一条 JSON 响应。新凭证不作为命令行参数传递。快照只表示密钥是否存在，不包含已有密钥的值。

## 存储边界

端点和模型编辑写入当前 Profile 的 `config.yaml`；API Key 写入该 Profile 的 `.env` 中由 `key_env` 引用的变量。收藏、可见性和推理预设使用 Hermes 机器级的 `ui-preferences.json`，选择其他 Profile 时也遵循这一规则。语言和表头排序属于桌面应用自身的 macOS 偏好。

适配程序保留无关配置和未知模型元数据。它识别 `providers` 条目，对旧版 `custom_providers` 条目仅提示存在，不进行迁移。内置端点的认证由 Hermes 处理。

## 写入与并发

配置写入会校验请求的修改和预期版本，将原文件保存为受限权限的备份，再执行原子替换和读回验证。批量操作先校验整批内容，再写入。默认模型、备用路由和任务引用可能阻止移除操作。

偏好写入遵循 Hermes 的目录锁、`generation` 和 `revision` 约定。历史记录清理只移除选定模型的收藏、可见性和预设记录，同时保持其他模型的实际可见性。修改这些文件前会创建备份。

配置锁用于协调本应用的写入。版本检查能够检测已观察到的外部变化，但无法消除不遵守锁机制的程序在最后一次检查与替换之间造成的竞争。请避免使用多个编辑器同时修改同一配置。

## 模型身份与目录行为

选择状态依据端点和模型的身份，而非行号，因此排序与筛选不会改变批量操作的目标。收藏遵循 Hermes 的菜单身份规则，包括所支持的快版或日期快照模型与基础型号之间的映射。

实时目录是补充信息。目录未列出某个手动配置 ID 时，该模型仍可管理；仅剩历史记录的条目仍可取消收藏、隐藏或清理。模型出现在目录中，并不能证明推理可用。

兼容性依赖 Hermes 的配置结构、客户端偏好格式和 `/api/model/options` 响应。上游格式变化时，需要更新本项目的测试样例并检查兼容性。

## 运行环境

应用使用 macOS 的 SwiftUI 和 AppKit，调用本机 Python 3.10+ 解释器，并内置 PyYAML 与 python-dotenv 的纯 Python 副本。构建时会记录解释器路径；运行时查找还支持 `STUDIO_PYTHON` 和常见的本机安装位置。应用不内嵌解释器本身。
