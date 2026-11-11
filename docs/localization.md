# Localization

English | [简体中文](localization.zh-CN.md)

The interface defaults to English even on a Chinese-language system. Users can switch between English and Simplified Chinese from the sidebar or application Language menu. The selection is saved in the app's macOS preferences; previews can override it without saving.

## Resources

- `Resources/Locales/en.json`: canonical English keys and values.
- `Resources/Locales/zh-Hans.json`: the same keys with Simplified Chinese values.
- `Sources/Localization.swift`: language selection, resource loading, formatting, and fallback behavior.

Use `L("English source text")` for interface strings. For dynamic values, use indexed placeholders: `L("Add {0} models", count)`. A translation may reorder placeholders, but must preserve their indexes. Unknown strings fall back to English. Endpoint names, model IDs, paths, and other user values must remain unchanged.

The Python adapter returns canonical English messages. The native interface translates known messages and formatted templates when displaying them, allowing an existing status or error to change language with the interface. It does not run free-form translation on user data.

## Updating strings

1. Add or update the English source string and both JSON catalogs.
2. Preserve placeholder indexes, newlines, and meaning. Use **endpoint / 端点**, **model / 模型**, and **favorite / 收藏** consistently.
3. Include menus, alerts, tooltips, validation messages, and accessibility labels.
4. Run `scripts/check-localization.py` with the project Python and `bash scripts/check-ui.sh`.
5. Inspect demo previews in both languages for clipping, wrapping, and readable controls.

Language changes must not recreate the editor's state or clear selections. Native text fields update their placeholders and accessibility labels while preserving the current input and caret.

To add another language, add an `AppLanguage` case and catalog, extend the formatted adapter-message lookup to that language, and extend the parity and behavioral checks. The current dynamic-template lookup supports the English/Chinese pair.

## Markdown documentation

English is the default at `README.md` and the unqualified files under `docs/`. Chinese counterparts use `.zh-CN.md` and link to each other at the top. Update both editions with each behavior change. License texts retain their authoritative upstream wording.
