# Third-party notices

Hermes Model Studio's own source is licensed under the [MIT License](LICENSE).

| Project | Use | License notice |
| --- | --- | --- |
| [PyYAML](https://github.com/yaml/pyyaml) | YAML parsing; pure-Python modules are bundled | [MIT](licenses/PyYAML-LICENSE.txt) |
| [python-dotenv](https://github.com/theskumar/python-dotenv) | Local `.env` parsing and updates; bundled | [BSD](licenses/python-dotenv-LICENSE.txt) |
| [Hermes Agent](https://github.com/NousResearch/hermes-agent) | Upstream configuration and client-preference compatibility references | [MIT](licenses/hermes-agent-MIT.txt) |
| [Python / python-build-standalone](https://github.com/astral-sh/python-build-standalone) | Relocatable Python runtime in macOS release ZIPs | [Upstream notices](licenses/python-runtime/README.md) |

The build copies the parser dependencies' license notices into the application bundle. Release packages also preserve Python's included notices and the upstream dependency notice set under `Contents/Resources/licenses/python-runtime`. Runtime versions, source URLs, and checksums are recorded in `scripts/python-runtime.json`. Hermes Agent is not bundled. SwiftUI, AppKit, and system symbols are supplied under Apple's applicable terms.
