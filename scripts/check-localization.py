"""Validate bilingual catalogs and the source strings that depend on them."""
import ast
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
errors = []


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            errors.append(f"Duplicate localization key: {key!r}")
        result[key] = value
    return result


catalogs = {
    language: json.loads((ROOT / f"Resources/Locales/{language}.json").read_text(), object_pairs_hook=unique_object)
    for language in ("en", "zh-Hans")
}
english, chinese = catalogs["en"], catalogs["zh-Hans"]
if english.keys() != chinese.keys():
    errors.append("English and Chinese catalogs have different keys")
for key, value in english.items():
    if key != value:
        errors.append(f"English key must equal its value: {key!r}")
    translation = chinese.get(key)
    if not isinstance(translation, str) or not translation.strip():
        errors.append(f"Missing Chinese translation: {key!r}")
        continue
    if sorted(re.findall(r"\{\d+\}", key)) != sorted(re.findall(r"\{\d+\}", translation)):
        errors.append(f"Placeholder mismatch: {key!r}")
    if key.count("\n") != translation.count("\n"):
        errors.append(f"Newline mismatch: {key!r}")

source_keys = set()
for path in (ROOT / "Sources").glob("*.swift"):
    source = path.read_text()
    for match in re.finditer(r'\bL\(\s*"((?:[^"\\]|\\.)*)"', source):
        try:
            source_keys.add(json.loads('"' + match.group(1) + '"'))
        except json.JSONDecodeError:
            errors.append(f"Use indexed placeholders in {path.name}, not Swift interpolation")
    if path.name != "Localization.swift" and re.search(r"[\u3400-\u9fff]", source):
        errors.append(f"Inline Chinese outside the language catalog: {path.name}")


def template(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        values, index = [], 0
        for value in node.values:
            if isinstance(value, ast.FormattedValue):
                values.append("{" + str(index) + "}")
                index += 1
            else:
                values.append(value.value)
        return "".join(values)
    return None


tree = ast.parse((ROOT / "Resources/bridge.py").read_text())
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Refused" and node.args:
        if text := template(node.args[0]):
            source_keys.add(text)
    if isinstance(node, ast.Dict):
        for key, value in zip(node.keys, node.values):
            if isinstance(key, ast.Constant) and key.value in ("message", "note", "error"):
                if text := template(value):
                    source_keys.add(text)

for key in sorted(source_keys - english.keys()):
    errors.append(f"Source string missing from catalogs: {key!r}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Localization checks passed: {len(english)} bilingual entries, {len(source_keys)} source strings")
