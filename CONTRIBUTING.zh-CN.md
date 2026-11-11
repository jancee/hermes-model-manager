# 贡献指南

[English](CONTRIBUTING.md) | 简体中文

欢迎提交错误修复、翻译和 Hermes 兼容性改进。Issue 和 Pull Request 可以使用英文或中文。

修改写入行为前，请先阅读[架构说明](docs/architecture.zh-CN.md)和[开发指南](docs/development.zh-CN.md)。保留无关配置、未知元数据和用户输入值。

提交贡献时：

1. 说明用户可见的问题和预期行为。使用虚构数据提供复现步骤，不使用真实配置。
2. 保持改动聚焦。为容易回归的行为增加有意义的覆盖，尤其是配置写入和偏好兼容性。
3. 运行开发指南中与改动相关的检查，并如实报告实际验证的内容。
4. 同步更新受影响 Markdown 文档的两种语言版本，以及变更记录。
5. 检查暂存区差异，排除凭证、个人路径、生成产物和含私人信息的截图。

不要修改贡献者的 Hermes 安装、自动重启它，或隐式切换全局模型。不要将凭证放入命令行参数、日志、测试样例或截图。

提交标题应清晰，例如 `fix: preserve selection when sorting` 或 `docs: clarify profile preferences`。界面源字符串使用英文，并提供匹配的中文资源。

安全漏洞请按[安全策略](SECURITY.zh-CN.md)报告，不要公开包含凭证的复现材料。
