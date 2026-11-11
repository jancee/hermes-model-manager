# Contributing

English | [简体中文](CONTRIBUTING.zh-CN.md)

Bug fixes, translations, and Hermes compatibility improvements are welcome. Issues and pull requests may be written in English or Chinese.

Read the [architecture](docs/architecture.md) and [development guide](docs/development.md) before changing write behavior. Preserve unrelated configuration, unknown metadata, and user-entered values.

For a contribution:

1. Describe the visible problem and expected behavior. Include a synthetic reproduction rather than a real configuration.
2. Keep changes focused. Add meaningful coverage for behavior that can regress, especially configuration writes and preference compatibility.
3. Run the relevant checks from the development guide and report what was actually tested.
4. Update both language editions of affected Markdown documents and the changelog.
5. Review the staged diff for credentials, personal paths, generated artifacts, and private screenshots.

Do not modify a contributor's Hermes installation, restart it automatically, or implicitly switch the global model. Do not place credentials in command-line arguments, logs, fixtures, or screenshots.

Use clear commit subjects such as `fix: preserve selection when sorting` or `docs: clarify profile preferences`. Interface source strings remain English and must have matching Chinese resources.

Report security vulnerabilities using the [security policy](SECURITY.md), not a public reproduction containing credentials.
