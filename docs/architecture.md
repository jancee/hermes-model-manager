# Architecture

English | [简体中文](architecture.zh-CN.md)

Hermes Model Studio is a SwiftUI/AppKit desktop application with a small Python adapter for Hermes configuration and preferences. It does not load or modify Hermes's Python packages.

## Components

| Component | Responsibility |
| --- | --- |
| `Sources/main.swift` | Application lifecycle, menus, previews, and packaged integration check |
| `Sources/StudioView.swift`, `ManagementViews.swift`, `Editors.swift` | Lists, forms, and batch operations |
| `Sources/StudioState.swift` | Selection, refresh, mutation requests, and user confirmations |
| `Sources/Models.swift` | Typed snapshots and the subprocess bridge |
| `Sources/Sorting.swift` | Stable table sorting and saved sort choices |
| `Sources/EndpointNameField.swift` | Native text entry that preserves trailing spaces and caret position |
| `Sources/Localization.swift`, `Resources/Locales/` | English and Chinese interface resources |
| `Resources/bridge.py` | Validation, catalog reads, configuration writes, and preference updates |

The native process sends one JSON request on the adapter's standard input and receives one JSON response on standard output. New credentials are not passed as command-line arguments. Snapshots expose whether a key exists, not the existing key value.

## Storage boundaries

Endpoint and model edits target the active profile's `config.yaml`; API keys target the variable referenced by `key_env` in its `.env`. Favorites, visibility, and reasoning presets use Hermes's machine-level `ui-preferences.json`, including when a profile is selected. Language and table sort settings belong to the desktop app's macOS preferences.

The adapter preserves unrelated configuration and unknown model metadata. It recognizes `providers` entries and reports legacy `custom_providers` entries without migrating them. It leaves built-in endpoint authentication to Hermes.

## Writes and concurrency

Configuration writes validate the requested edit and expected revision, preserve the original file in a restricted backup, replace it atomically, and read it back. Batch operations validate the whole batch before writing. Default-model, fallback-route, and task references can prevent removal.

Preference writes use Hermes's directory-lock, generation, and revision conventions. History cleanup removes the selected favorite, visibility, and preset records while preserving other models' effective visibility. Backups are created before changing these files.

The configuration lock coordinates this application's writers. Revision checks detect observed external changes, but cannot eliminate a race with another program that ignores locking between the last check and replacement. Avoid simultaneous editors for the same configuration.

## Model identity and catalog behavior

Selections use provider/model identities rather than row positions, so sorting and filtering do not change batch targets. Favorites follow Hermes's menu identities, including family mappings for supported fast or dated model variants.

The live catalog is supplementary. Manually configured IDs remain manageable when omitted from the catalog; history-only records remain available for unstar, hide, or cleanup. Catalog presence does not prove that inference works.

Compatibility depends on Hermes's configuration schema, client preference format, and `/api/model/options` response. Changes to these upstream formats require fixtures and compatibility review here.

## Runtime

The app uses macOS SwiftUI and AppKit. It runs a local Python 3.10+ interpreter and bundles pure-Python copies of PyYAML and python-dotenv. A build records its interpreter path; runtime lookup also supports `STUDIO_PYTHON` and common local installations. The interpreter itself is not bundled.
