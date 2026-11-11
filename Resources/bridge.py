#!/usr/bin/env python3
"""Local, stdin/stdout-only Hermes configuration adapter. Never launches Hermes."""
from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import tempfile
import time
from contextlib import contextmanager
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).parent / "vendor"))
import yaml
from dotenv import dotenv_values

FAVORITES = "hermes.desktop.favorite-models"
VISIBLE = "hermes.desktop.visible-models"
KNOWN = "hermes.desktop.known-models"
PRESETS = "hermes.desktop.model-presets"
MODES = ("", "chat_completions", "codex_responses", "responses", "anthropic_messages")


class Refused(Exception):
    pass


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str) or key in result:
            raise Refused("The configuration contains duplicate or non-text keys. Fix the YAML first; nothing was saved.")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def parse_config(raw):
    try:
        value = yaml.load(raw, Loader=UniqueLoader)
    except yaml.YAMLError:
        raise Refused("Could not parse config.yaml. The operation was stopped to protect the original file.")
    if not isinstance(value, dict):
        raise Refused("The root of config.yaml must be a mapping.")
    if not isinstance(value.get("providers", {}), dict):
        raise Refused("providers must be a mapping.")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_bytes(path, missing=False):
    try:
        return path.read_bytes()
    except FileNotFoundError:
        if missing:
            return b""
        raise Refused("The local Hermes configuration file was not found.")
    except OSError:
        raise Refused("Could not read the local file. Check its access permissions.")


def atomic_write(path, data, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise Refused("The target file is a symbolic link. Saving was stopped to avoid replacing the link.")
    if mode is None:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, name = tempfile.mkstemp(prefix="." + path.name + ".studio-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextmanager
def file_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+b") as stream:
        deadline = time.monotonic() + 3
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Refused("Another program is saving. Try again shortly.")
                time.sleep(0.02)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


@contextmanager
def preference_lock(path):
    """Same mkdir/owner protocol as Hermes Python and Electron preferences writers."""
    lock = path.with_name(path.name + ".lock")
    owner = lock / "owner"
    token = f"{os.getpid()}-{secrets.token_hex(8)}"
    deadline = time.monotonic() + 3
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            try:
                if time.time() - lock.stat().st_mtime > 10:
                    owner.unlink(missing_ok=True)
                    lock.rmdir()
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise Refused("Hermes is saving UI preferences. Try again shortly.")
            time.sleep(0.02)
    try:
        owner.write_text(token)
        yield lambda: owner.exists() and owner.read_text() == token
    finally:
        try:
            if owner.read_text() == token:
                owner.unlink()
                lock.rmdir()
        except OSError:
            pass


def pref_doc(path):
    raw = read_bytes(path, missing=True)
    if not raw:
        if path.exists():
            raise Refused("The client preferences file is empty. It was not overwritten.")
        return {"version": 1, "generation": secrets.token_hex(8), "revision": 0, "values": {}}
    try:
        doc = json.loads(raw)
        if not isinstance(doc, dict) or doc.get("version", 1) != 1:
            raise ValueError()
        if not isinstance(doc.get("values"), dict) or type(doc.get("revision")) is not int:
            raise ValueError()
        return doc
    except (ValueError, TypeError):
        raise Refused("The client preferences file is damaged or uses an unsupported version. It was not overwritten.")


def pref_list(doc, key):
    raw = doc["values"].get(key)
    if raw is None:
        return None
    try:
        items = json.loads(raw)
        if not isinstance(items, list) or not all(isinstance(x, str) for x in items):
            raise ValueError()
        return list(dict.fromkeys(items))
    except (ValueError, TypeError):
        raise Refused("The model preferences format is invalid. No changes were made.")


def clean_identifier(value, title):
    if not isinstance(value, str) or not value.strip() or len(value) > 512:
        raise Refused(title + " must not be empty or too long.")
    value = value.strip()
    if any(ord(c) < 32 for c in value) or "::" in value:
        raise Refused(title + " must not contain control characters or a double colon.")
    return value


def valid_url(value):
    if not isinstance(value, str):
        raise Refused("The endpoint URL must not be empty.")
    p = urlsplit(value.strip())
    if p.scheme not in ("http", "https") or not p.hostname or p.username or p.password or p.query or p.fragment:
        raise Refused("Enter a complete HTTP(S) base URL without a password, query parameters, or fragment.")
    return value.strip().rstrip("/")


def context_value(value):
    if value in (None, "", 0):
        return None
    try:
        if isinstance(value, bool):
            raise ValueError()
        n = int(value)
        if n < 1 or n > 100000000:
            raise ValueError()
        return n
    except (ValueError, TypeError):
        raise Refused("Context length must be an integer from 1 to 100,000,000. Leave blank for automatic.")


def set_timeout(target, field, value):
    if value in (None, ""):
        target.pop(field, None)
        return
    try:
        number = float(value)
        if isinstance(value, bool) or not 0 < number <= 86400:
            raise ValueError()
    except (ValueError, TypeError):
        raise Refused("Timeout must be greater than 0 and no more than 86,400 seconds. Leave blank to inherit.")
    target[field] = int(number) if number.is_integer() else number


def model_ids(values):
    if not isinstance(values, list) or not values or len(values) > 1000:
        raise Refused("Select between 1 and 1,000 models.")
    return list(dict.fromkeys(clean_identifier(x, "Model ID") for x in values))


def model_presets(doc):
    try:
        value = json.loads(doc["values"].get(PRESETS, "{}"))
        if not isinstance(value, dict) or any(not isinstance(v, dict) for v in value.values()):
            raise ValueError()
        return value
    except (ValueError, TypeError):
        raise Refused("The client reasoning preset format is invalid. No changes were made.")


def entry_models(entry):
    value = entry.get("models", {})
    if isinstance(value, dict):
        return copy.deepcopy(value)
    if isinstance(value, list) and all(isinstance(x, str) for x in value):
        return {x: {} for x in value}
    raise Refused("This endpoint's models format is not supported.")


def route_references_model(obj, aliases, model, inherited_provider=""):
    if isinstance(obj, dict):
        provider = obj.get("provider") or inherited_provider
        if isinstance(provider, str) and provider in aliases and (obj.get("model") == model or obj.get("default") == model):
            return True
        return any(route_references_model(v, aliases, model, inherited_provider) for v in obj.values())
    if isinstance(obj, list):
        return any(route_references_model(v, aliases, model, inherited_provider) for v in obj)
    return False


def node_at(node, keys):
    for key in keys:
        if not isinstance(node, yaml.MappingNode):
            return None
        node = next((v for k, v in node.value if k.value == key), None)
        if node is None:
            return None
    return node


def splice_value(raw, keys, value, delete=False):
    """Patch one YAML value; untouched bytes (including all other sections) survive."""
    root = yaml.compose(raw, Loader=UniqueLoader)
    parent = node_at(root, keys[:-1])
    if not isinstance(parent, yaml.MappingNode):
        raise Refused("The target configuration structure is not supported. Nothing was saved.")
    match = next(((k, v) for k, v in parent.value if k.value == keys[-1]), None)
    if parent.flow_style:
        # Only re-serialize the smallest flow-style parent, not the entire file.
        current = yaml.load(raw[parent.start_mark.index:parent.end_mark.index], Loader=UniqueLoader)
        if delete:
            current.pop(keys[-1], None)
        else:
            current[keys[-1]] = value
        rendered = yaml.safe_dump(current, allow_unicode=True, sort_keys=False, default_flow_style=True, width=100000).strip()
        return raw[:parent.start_mark.index] + rendered + raw[parent.end_mark.index:]
    if match:
        keynode, valnode = match
        if delete:
            start = raw.rfind("\n", 0, keynode.start_mark.index) + 1
            end = valnode.end_mark.index
            if isinstance(valnode, yaml.ScalarNode) or valnode.flow_style:
                end = raw.find("\n", end)
                end = len(raw) if end < 0 else end + 1
            return raw[:start] + raw[end:]
        if isinstance(value, (dict, list)):
            # Flow style keeps the surrounding key/comment boundaries intact.
            rendered = yaml.safe_dump(value, allow_unicode=True, sort_keys=False, default_flow_style=True, width=100000).strip()
        else:
            rendered = yaml.safe_dump(value, allow_unicode=True, default_flow_style=True, width=100000).strip()
            if rendered.endswith("\n..."):
                rendered = rendered[:-4]
        end = valnode.end_mark.index
        # A block mapping/sequence ends at the next sibling indentation.
        if isinstance(valnode, (yaml.MappingNode, yaml.SequenceNode)) and not valnode.flow_style:
            rendered += "\n" + " " * valnode.end_mark.column
        return raw[:valnode.start_mark.index] + rendered + raw[end:]
    indent = parent.value[0][0].start_mark.column if parent.value else (len(keys) - 1) * 2
    rendered = yaml.safe_dump({keys[-1]: value}, allow_unicode=True, sort_keys=False, width=100000)
    rendered = "".join(" " * indent + line if line.strip() else line for line in rendered.splitlines(keepends=True))
    # Insert after the last value's physical line; never eat the next key's indentation.
    if not parent.value:
        raise Refused("Represent the empty configuration block as {} first.")
    last = parent.value[-1][1]
    end = last.end_mark.index
    if isinstance(last, yaml.ScalarNode) or last.flow_style:
        newline = raw.find("\n", end)
        end = len(raw) if newline < 0 else newline + 1
    else:
        end -= last.end_mark.column
    prefix = "" if end == 0 or raw[end - 1] == "\n" else "\n"
    return raw[:end] + prefix + rendered + raw[end:]


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise Refused("The endpoint returned a redirect. Enter the final URL directly and try again.")


def fetch_json(url, headers, timeout=5):
    try:
        with build_opener(NoRedirect).open(Request(url, headers=headers), timeout=timeout) as response:
            raw = response.read(8 * 1024 * 1024 + 1)
            if len(raw) > 8 * 1024 * 1024:
                raise Refused("The endpoint response is too large.")
            return json.loads(raw)
    except HTTPError as e:
        raise Refused(f"The endpoint returned HTTP {e.code}. Check the URL and credentials.")
    except (URLError, TimeoutError, OSError):
        raise Refused("Could not connect to the endpoint. Check the network and URL, then try again.")
    except ValueError:
        raise Refused("The endpoint did not return valid JSON.")


class Store:
    def __init__(self, home):
        self.home = Path(home).expanduser().absolute()
        self.root = self.home.parent.parent if self.home.parent.name.lower() == "profiles" else self.home
        self.config_path = self.home / "config.yaml"
        self.prefs_path = self.root / "ui-preferences.json"
        self.backup_dir = self.home / "backups" / "model-studio"

    def config(self):
        raw = read_bytes(self.config_path)
        return raw, parse_config(raw.decode("utf-8-sig"))

    def backup(self, path, raw):
        self.backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        name = time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(4) + "-" + path.name.lstrip(".")
        dest = self.backup_dir / name
        atomic_write(dest, raw, 0o600)
        return str(dest)

    def env(self):
        try:
            return {k: v or "" for k, v in dotenv_values(self.home / ".env", interpolate=False).items()}
        except Exception:
            raise Refused("Could not read the Hermes credentials file.")

    def live_catalog(self, cfg):
        extra = cfg.get("platforms", {}).get("api_server", {}).get("extra", {})
        port = extra.get("port", 8642)
        if not isinstance(port, int) or not 1 <= port <= 65535:
            raise Refused("The local Hermes API port is invalid.")
        key = self.env().get("API_SERVER_KEY") or extra.get("key", "")
        headers = {"Authorization": "Bearer " + key} if key else {}
        result = fetch_json(f"http://127.0.0.1:{port}/api/model/options", headers, 3)
        rows = result.get("providers")
        if not isinstance(rows, list):
            raise Refused("The model catalog format returned by Hermes is not supported.")
        # Only non-secret catalog fields cross the process boundary.
        return [{"slug": r["slug"], "name": r.get("name", r["slug"]),
                 "models": [m for m in r.get("models", []) if isinstance(m, str)],
                 "featured_models": r.get("featured_models") or [],
                 "custom": bool(r.get("is_user_defined"))} for r in rows if isinstance(r.get("slug"), str)]

    def snapshot(self, req):
        raw, cfg = self.config()
        doc = pref_doc(self.prefs_path)
        favorites = pref_list(doc, FAVORITES) or []
        known = pref_list(doc, KNOWN) or []
        visible = pref_list(doc, VISIBLE)
        catalog = req.get("catalog", [])
        live = False
        note = "Loaded local configuration and client preferences"
        if req.get("live", False):
            try:
                catalog = self.live_catalog(cfg)
                live = True
                note = "Loaded the running Hermes model catalog"
            except Refused:
                note = "The Hermes catalog is unavailable. Local configuration and existing favorites can still be edited."
        env = self.env()
        allkeys = set(favorites + known + (visible or []))
        providers, rows = [], []
        matched = set()
        for key, entry in cfg.get("providers", {}).items():
            if not isinstance(entry, dict):
                continue
            bare = key.strip().lower().replace(" ", "-")
            aliases = [bare, "custom:" + bare]
            current = next((r for r in catalog if r.get("slug") in aliases and r.get("custom")), None)
            slug = current["slug"] if current else max(aliases, key=lambda a: sum(k.startswith(a + "::") for k in allkeys))
            models = entry_models(entry)
            p = {"id": key, "slug": slug, "name": str(entry.get("name") or key),
                 "baseURL": str(entry.get("base_url") or entry.get("url") or entry.get("api") or ""),
                 "apiMode": str(entry.get("api_mode") or entry.get("transport") or ""),
                 "defaultModel": str(entry.get("model") or entry.get("default_model") or ""),
                 "discover": entry.get("discover_models", True) is not False,
                 "context": str(entry.get("context_length") or ""),
                 "keyEnv": str(entry.get("key_env") or entry.get("api_key_env") or ""),
                 "hasKey": bool(entry.get("api_key") or env.get(entry.get("key_env", "")) or os.environ.get(entry.get("key_env", ""))),
                 "requestTimeout": str(entry.get("request_timeout_seconds") or ""),
                 "staleTimeout": str(entry.get("stale_timeout_seconds") or ""),
                 "editable": True, "configuredCount": len(models)}
            providers.append(p)
            ids = list(models)
            if current:
                matched.add(slug)
                if p["discover"]:
                    ids += [m for m in current["models"] if m not in models]
            for index, mid in enumerate(ids):
                meta = models.get(mid) or {}
                listed = not (current and p["discover"]) or mid in current["models"]
                rows.append(self.row(p, mid, index, meta, mid in models, listed, doc, current, ids))
        # Built-in providers are available for starring and visibility, not endpoint rewrites.
        for r in catalog:
            if r["slug"] in matched or r.get("custom") or not r["models"]:
                continue
            p = {"id": "builtin:" + r["slug"], "slug": r["slug"], "name": r["name"], "baseURL": "",
                 "apiMode": "", "defaultModel": "", "discover": True, "context": "", "keyEnv": "",
                 "hasKey": False, "editable": False, "configuredCount": 0, "requestTimeout": "", "staleTimeout": ""}
            providers.append(p)
            rows += [self.row(p, m, i, {}, False, True, doc, r, r["models"]) for i, m in enumerate(r["models"])]
        present = {r["id"] for r in rows} | {r["slug"] + "::" + r["preferenceModel"] for r in rows}
        for key in favorites:
            if key in present or "::" not in key:
                continue
            slug, mid = key.split("::", 1)
            if not mid:
                continue
            p = next((p for p in providers if p["slug"] == slug), None)
            if not p:
                p = {"id": "history:" + slug, "slug": slug, "name": slug, "baseURL": "", "apiMode": "",
                     "defaultModel": "", "discover": False, "context": "", "keyEnv": "", "hasKey": False,
                     "editable": False, "configuredCount": 0, "requestTimeout": "", "staleTimeout": ""}
                providers.append(p)
            rows.append(self.row(p, mid, 999, {}, False, False, doc, None))
        return {"home": str(self.home), "root": str(self.root), "revision": digest(raw),
                "preferencesRevision": doc["revision"], "providers": providers, "models": rows,
                "favorites": favorites, "catalog": catalog, "live": live, "note": note,
                "defaultProvider": str(cfg.get("model", {}).get("provider", "")),
                "defaultModel": str(cfg.get("model", {}).get("default", "")),
                "legacyCount": len(cfg.get("custom_providers") or [])}

    @staticmethod
    def row(p, mid, index, meta, configured, available, doc, catalog, all_ids=None):
        all_ids = all_ids or [mid]
        def canonical(model):
            base = re.sub(r"(?:-fast|-\d{8})$", "", model, flags=re.I)
            return base if base != model and base in all_ids else model
        families = [m for m in all_ids if canonical(m) == m]
        preference_model = canonical(mid)
        key = p["slug"] + "::" + preference_model
        preset = model_presets(doc).get(p["slug"] + "::" + mid, {})
        visible = pref_list(doc, VISIBLE)
        known = pref_list(doc, KNOWN)
        featured = (catalog or {}).get("featured_models") or []
        default = preference_model in featured if featured else preference_model in families[:50]
        if visible is None:
            shown = default
        elif not visible:
            shown = False
        elif p["slug"] + "::" in visible:
            shown = key in visible
        else:
            has_stored_provider = any(v.startswith(p["slug"] + "::") and not v.endswith("::") for v in visible)
            shown = key in visible or (default and (not has_stored_provider or (known is not None and key not in known)))
        return {"id": p["slug"] + "::" + mid, "preferenceModel": preference_model,
                "providerID": p["id"], "providerName": p["name"], "slug": p["slug"],
                "modelID": mid, "context": str(meta.get("context_length") or "") if isinstance(meta, dict) else "",
                "requestTimeout": str(meta.get("timeout_seconds") or "") if isinstance(meta, dict) else "",
                "staleTimeout": str(meta.get("stale_timeout_seconds") or "") if isinstance(meta, dict) else "",
                "presetEffort": str(preset.get("effort") or ""),
                "presetTier": str(preset.get("serviceTier") or ("priority" if preset.get("fast") else "normal" if "fast" in preset else "")),
                "favorite": key in (pref_list(doc, FAVORITES) or []) or (p["slug"] + "::" + mid) in (pref_list(doc, FAVORITES) or []), "visible": shown,
                "configured": configured, "available": available, "editable": p["editable"],
                "isDefault": mid == p["defaultModel"]}

    def change_preference(self, req):
        items = req.get("items") or [{"slug": req.get("slug"), "model": req.get("model")}]
        if not isinstance(items, list) or len(items) > 1000:
            raise Refused("You can manage up to 1,000 models at a time.")
        keys = list(dict.fromkeys(clean_identifier(x.get("slug"), "Endpoint ID") + "::" + clean_identifier(x.get("model"), "Model ID") for x in items))
        field = req.get("field")
        if field not in ("favorite", "visible") or type(req.get("enabled")) is not bool:
            raise Refused("The preference operation parameters are invalid.")
        self.root.mkdir(parents=True, exist_ok=True)
        with preference_lock(self.prefs_path) as owns:
            doc = pref_doc(self.prefs_path)
            before = copy.deepcopy(doc)
            storage_key = FAVORITES if field == "favorite" else VISIBLE
            values = pref_list(doc, storage_key)
            values = values or []
            if field == "visible":
                # Hermes toggles its resolved working set, including defaults for uncurated providers.
                effective = [r["slug"] + "::" + r["preferenceModel"] for r in self.snapshot({"catalog": req.get("catalog", [])})["models"] if r["visible"]]
                values = list(dict.fromkeys(values + effective))
            key_set = set(keys)
            values = [v for v in values if v not in key_set]
            if req["enabled"]:
                values += keys
            if field == "visible":
                for slug in {k.split("::", 1)[0] for k in keys}:
                    sentinel = slug + "::"
                    if req["enabled"]:
                        values = [v for v in values if v != sentinel]
                    elif not any(v.startswith(sentinel) and v != sentinel for v in values):
                        values = list(dict.fromkeys(values + [sentinel]))
                known = pref_list(doc, KNOWN) or []
                doc["values"][KNOWN] = json.dumps(list(dict.fromkeys(known + keys)), ensure_ascii=False)
            doc["values"][storage_key] = json.dumps(values, ensure_ascii=False)
            if len(doc["values"]) > 512 or any(len(v) > 256 * 1024 for v in doc["values"].values()) or sum(len(k) + len(v) for k, v in doc["values"].items()) > 2 * 1024 * 1024:
                raise Refused("Client preferences have reached the Hermes storage limit. Nothing was saved.")
            if before["values"] == doc["values"]:
                return {"message": "The preferences already match this state."}
            doc["revision"] += 1
            doc.setdefault("generation", secrets.token_hex(8))
            if not owns():
                raise Refused("The preferences lock changed. Refresh and try again.")
            raw = read_bytes(self.prefs_path, missing=True)
            backup = self.backup(self.prefs_path, raw) if raw else ""
            atomic_write(self.prefs_path, (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode())
            actual = pref_doc(self.prefs_path)
            if actual["values"].get(storage_key) != doc["values"][storage_key]:
                raise Refused("Another client updated the preferences. Refresh to check the current state.")
        return {"message": "Favorites saved to Hermes client preferences." if field == "favorite" else "Visibility settings saved to Hermes client preferences.", "backup": backup}

    def save_preset(self, req):
        key = clean_identifier(req.get("slug"), "Endpoint ID") + "::" + clean_identifier(req.get("model"), "Model ID")
        effort, tier = req.get("effort", ""), req.get("tier", "")
        if effort not in ("", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra") or tier not in ("", "normal", "priority", "flex"):
            raise Refused("Unsupported reasoning preset.")
        with preference_lock(self.prefs_path) as owns:
            doc = pref_doc(self.prefs_path)
            presets = model_presets(doc)
            existing = copy.deepcopy(presets.get(key, {}))
            preset = dict(existing)
            for field, value in [("effort", effort), ("serviceTier", tier)]:
                if value:
                    preset[field] = value
                else:
                    preset.pop(field, None)
            if tier:
                preset["fast"] = tier != "normal"
            else:
                preset.pop("fast", None)
            if preset == existing:
                return {"message": "The reasoning preset is unchanged."}
            if preset:
                presets[key] = preset
            else:
                presets.pop(key, None)
            value = json.dumps(presets, ensure_ascii=False)
            if len(value) > 256 * 1024:
                raise Refused("Reasoning presets exceed the Hermes storage limit.")
            doc["values"][PRESETS] = value
            doc["revision"] += 1
            doc.setdefault("generation", secrets.token_hex(8))
            if not owns():
                raise Refused("The preferences lock changed. Refresh and try again.")
            raw = read_bytes(self.prefs_path, missing=True)
            backup = self.backup(self.prefs_path, raw) if raw else ""
            atomic_write(self.prefs_path, (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode())
            if model_presets(pref_doc(self.prefs_path)).get(key, {}) != preset:
                raise Refused("Another client updated the preset. Refresh to review it.")
        return {"message": "Reasoning preset saved. Hermes will apply it the next time this model is selected. Support depends on the endpoint.", "backup": backup}

    def forget_models(self, req):
        items = req.get("items")
        if not isinstance(items, list) or not 1 <= len(items) <= 1000 or any(not isinstance(x, dict) for x in items):
            raise Refused("Select between 1 and 1,000 historical models.")
        keys = {clean_identifier(x.get("slug"), "Endpoint ID") + "::" + clean_identifier(x.get("model"), "Model ID") for x in items}
        with preference_lock(self.prefs_path) as owns:
            # Re-read configuration under the operation; a stale UI must not treat a newly
            # configured model as a record-only deletion. Configuration itself is never written.
            snapshot = self.snapshot({"catalog": req.get("catalog", [])})
            rows = {r["id"]: r for r in snapshot["models"]}
            for key in keys:
                row = rows.get(key)
                if row and row["configured"]:
                    raise Refused("A selected model is still in the manual configuration. Use “Remove from configuration” instead.")
                if row and row["available"]:
                    raise Refused("A selected model is still in the current catalog. You can unstar it or hide it.")
            doc = pref_doc(self.prefs_path)
            before = copy.deepcopy(doc["values"])
            tracked = set().union(*(pref_list(doc, field) or [] for field in (FAVORITES, VISIBLE, KNOWN)), model_presets(doc))
            if not keys.intersection(tracked):
                return {"message": "These history records no longer exist."}
            affected = {k.split("::", 1)[0] for k in keys}
            for field in (FAVORITES, VISIBLE, KNOWN):
                values = pref_list(doc, field)
                if values is None:
                    continue
                if field == VISIBLE:
                    # Keep the effective visibility of other models in the affected providers.
                    # Removing the last stored key must not reset that provider to visible defaults.
                    effective = [r["slug"] + "::" + r["preferenceModel"] for r in rows.values() if r["slug"] in affected and r["visible"]]
                    values = list(dict.fromkeys(values + effective))
                values = [v for v in values if v not in keys]
                if field == VISIBLE:
                    for slug in affected:
                        sentinel = slug + "::"
                        if not any(v.startswith(sentinel) for v in values):
                            values.append(sentinel)
                doc["values"][field] = json.dumps(values, ensure_ascii=False)
            if PRESETS in doc["values"]:
                presets = model_presets(doc)
                for key in keys:
                    presets.pop(key, None)
                doc["values"][PRESETS] = json.dumps(presets, ensure_ascii=False)
            if doc["values"] == before:
                return {"message": "These history records no longer exist."}
            if len(doc["values"]) > 512 or any(len(v) > 256 * 1024 for v in doc["values"].values()) or sum(len(k) + len(v) for k, v in doc["values"].items()) > 2 * 1024 * 1024:
                raise Refused("Client preferences have reached the storage limit. Nothing was saved.")
            doc["revision"] += 1
            doc.setdefault("generation", secrets.token_hex(8))
            if not owns():
                raise Refused("The preferences lock changed. Refresh and try again.")
            raw = read_bytes(self.prefs_path, missing=True)
            backup = self.backup(self.prefs_path, raw) if raw else ""
            atomic_write(self.prefs_path, (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode())
            check = pref_doc(self.prefs_path)
            if any(keys.intersection(pref_list(check, field) or []) for field in (FAVORITES, VISIBLE, KNOWN)) or keys.intersection(model_presets(check)):
                raise Refused("Another client updated the history records. Refresh to check the current state.")
        return {"message": f"Forgot history for {len(keys)} models. Endpoint and model configurations are unchanged.", "backup": backup}

    def assert_model_removable(self, cfg, provider, model, protect_default=True):
        entry = cfg["providers"][provider]
        if protect_default and model in (entry.get("model"), entry.get("default_model")):
            raise Refused("The selection includes the endpoint's default model. Choose another default first.")
        aliases = {provider, "custom:" + provider, provider.lower(), "custom:" + provider.lower()}
        routes = {k: v for k, v in cfg.items() if k not in ("providers", "custom_providers")}
        inherited = cfg.get("model", {}).get("provider", "")
        if route_references_model(routes, aliases, model, inherited):
            raise Refused("A selected model is referenced by the main model, a fallback, or another task. Update those references first.")
        jobs = self.home / "cron" / "jobs.json"
        if jobs.exists() and route_references_model(json.loads(read_bytes(jobs)), aliases, model, inherited):
            raise Refused("A scheduled task still references a selected model. Update the task first.")

    def batch_models(self, cfg, key, req):
        entry = cfg["providers"].get(key)
        if not isinstance(entry, dict):
            raise Refused("Select a custom endpoint.")
        models = entry_models(entry)
        ids = model_ids(req.get("models"))
        operation = req.get("operation")
        if operation == "add":
            for mid in ids:
                models.setdefault(mid, {})
        elif operation == "remove":
            if any(mid not in models for mid in ids):
                raise Refused("The selection includes models that are not in the manual configuration. Use the visibility toggle to hide catalog models.")
            for mid in ids:
                self.assert_model_removable(cfg, key, mid)
            for mid in ids:
                models.pop(mid)
        elif operation == "pin":
            default = clean_identifier(req.get("defaultModel"), "Default model")
            if default not in ids:
                raise Refused("Choose an endpoint default from the models being kept.")
            for mid in set(models) - set(ids):
                self.assert_model_removable(cfg, key, mid, protect_default=False)
            models = {mid: models.get(mid, {}) for mid in ids}
            entry["discover_models"] = False
            entry["model"] = default
            if "default_model" in entry:
                entry["default_model"] = default
        elif operation == "default" and len(ids) == 1:
            models.setdefault(ids[0], {})
            entry["model"] = ids[0]
            if "default_model" in entry:
                entry["default_model"] = ids[0]
        else:
            raise Refused("Unknown batch model operation.")
        entry["models"] = models

    def mutate_config(self, req):
        with file_lock(self.home / ".model-studio.lock"):
            raw, cfg = self.config()
            if req.get("revision") != digest(raw):
                raise Refused("Another program changed the configuration. Close the editor, refresh, and try saving again. Your changes have not overwritten the original file.")
            original = copy.deepcopy(cfg)
            key = clean_identifier(req.get("provider"), "Endpoint ID")
            existing = copy.deepcopy(cfg.get("providers", {}).get(key))
            action = req["action"]
            if action == "save_provider":
                if req.get("create") and existing is not None:
                    raise Refused("This endpoint ID already exists.")
                if req.get("create"):
                    normalize = lambda name: name.lower().replace(" ", "-").removeprefix("custom:")
                    if any(normalize(other) == normalize(key) for other in cfg.get("providers", {})):
                        raise Refused("This endpoint ID conflicts with an existing routing identity. Use a different ID.")
                if not req.get("create") and not isinstance(existing, dict):
                    raise Refused("This endpoint no longer exists. Refresh the list.")
                entry = copy.deepcopy(existing or {})
                name = clean_identifier(req.get("name"), "Endpoint name")
                url = valid_url(req.get("baseURL"))
                mode = req.get("apiMode", "")
                if mode not in MODES and mode != entry.get("transport"):
                    raise Refused("Unsupported API protocol.")
                entry["name"] = name
                entry["base_url"] = url
                for alias in ("api", "url"):
                    if alias in entry:
                        entry[alias] = url
                if mode:
                    entry["api_mode"] = mode
                    if "transport" in entry:
                        entry["transport"] = mode
                else:
                    entry.pop("api_mode", None)
                    entry.pop("transport", None)
                if type(req.get("discover")) is not bool:
                    raise Refused("The automatic discovery setting is invalid.")
                entry["discover_models"] = req["discover"]
                default = req.get("defaultModel", "").strip()
                models = entry_models(entry)
                if default:
                    default = clean_identifier(default, "Default model")
                    models.setdefault(default, {})
                entry["models"] = models
                entry["model"] = default
                if "default_model" in entry:
                    entry["default_model"] = default
                context = context_value(req.get("context"))
                if context is None:
                    entry.pop("context_length", None)
                else:
                    entry["context_length"] = context
                key_env = req.get("keyEnv", "").strip() or "HERMES_CUSTOM_" + re.sub(r"[^A-Z0-9]+", "_", key.upper()).strip("_") + "_API_KEY"
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key_env):
                    raise Refused("The key variable name must use letters, digits, and underscores.")
                entry["key_env"] = key_env
                for request_field, config_field in [("requestTimeout", "request_timeout_seconds"), ("staleTimeout", "stale_timeout_seconds")]:
                    if request_field in req:
                        set_timeout(entry, config_field, req[request_field])
                cfg.setdefault("providers", {})[key] = entry
            elif action == "batch_models":
                self.batch_models(cfg, key, req)
            elif action in ("save_model", "delete_model"):
                if not isinstance(existing, dict):
                    raise Refused("Only models in local custom endpoints can be edited.")
                entry = cfg["providers"][key]
                models = entry_models(entry)
                mid = clean_identifier(req.get("model"), "Model ID")
                old = req.get("originalModel") or mid
                if action == "delete_model":
                    if mid in (entry.get("model"), entry.get("default_model")):
                        raise Refused("This is the endpoint's default model. Choose another default in endpoint settings first.")
                    if mid not in models:
                        raise Refused("This model is not in the configuration. Hide discovered models or disable automatic discovery.")
                    aliases = {key, "custom:" + key, key.lower(), "custom:" + key.lower()}
                    routes = {k: v for k, v in cfg.items() if k not in ("providers", "custom_providers")}
                    inherited = cfg.get("model", {}).get("provider", "")
                    if route_references_model(routes, aliases, mid, inherited):
                        raise Refused("The main model, a fallback, or another task still references this model. Update those references first.")
                    jobs = self.home / "cron" / "jobs.json"
                    if jobs.exists() and route_references_model(json.loads(read_bytes(jobs)), aliases, mid, inherited):
                        raise Refused("A scheduled task still references this model. Update the task first.")
                    models.pop(mid)
                else:
                    if req.get("create") and mid in models:
                        raise Refused("This model already exists. Edit the existing entry.")
                    if old != mid:
                        raise Refused("The model ID identifies API requests. To change it, add a new entry and then remove the old one.")
                    metadata = copy.deepcopy(models.get(mid) or {})
                    if not isinstance(metadata, dict):
                        raise Refused("This model's metadata format is not supported.")
                    value = context_value(req.get("context"))
                    if value is None:
                        metadata.pop("context_length", None)
                    else:
                        metadata["context_length"] = value
                    for request_field, config_field in [("requestTimeout", "timeout_seconds"), ("staleTimeout", "stale_timeout_seconds")]:
                        if request_field in req:
                            set_timeout(metadata, config_field, req[request_field])
                    models[mid] = metadata
                entry["models"] = models
            elif action == "delete_provider":
                if not isinstance(existing, dict):
                    raise Refused("This endpoint no longer exists.")
                aliases = {key, "custom:" + key, key.lower(), "custom:" + key.lower()}
                others = copy.deepcopy(cfg)
                others["providers"].pop(key)
                def referenced(obj):
                    if isinstance(obj, dict):
                        return any(referenced(v) for v in obj.values())
                    if isinstance(obj, list):
                        return any(referenced(v) for v in obj)
                    return isinstance(obj, str) and obj in aliases
                if referenced(others):
                    raise Refused("The main model, a fallback, or another configuration still references this endpoint. Update those references first.")
                jobs = self.home / "cron" / "jobs.json"
                if jobs.exists() and referenced(json.loads(read_bytes(jobs))):
                    raise Refused("A scheduled task still references this endpoint. Update the task first.")
                cfg["providers"].pop(key)
            else:
                raise Refused("Unknown configuration operation.")
            if cfg == original:
                return {"message": "The configuration is unchanged."}
            text = raw.decode("utf-8-sig")
            target = cfg["providers"].get(key)
            if "providers" not in original:
                text += "\n" + yaml.safe_dump({"providers": {key: target}}, allow_unicode=True, sort_keys=False)
            elif existing is None or target is None:
                text = splice_value(text, ["providers", key], target, delete=target is None)
            else:
                for field in dict.fromkeys(list(existing) + list(target)):
                    if field not in target:
                        text = splice_value(text, ["providers", key, field], None, delete=True)
                    elif field not in existing or target[field] != existing[field]:
                        text = splice_value(text, ["providers", key, field], target[field])
            if parse_config(text) != cfg:
                raise Refused("Configuration validation failed. The original file was not changed.")
            # External tools may ignore our lock. Refuse an observed stale read immediately before replace.
            if read_bytes(self.config_path) != raw:
                raise Refused("A concurrent save was detected. Refresh and try again.")
            backup = self.backup(self.config_path, raw)
            atomic_write(self.config_path, text.encode("utf-8"))
            if self.config()[1] != cfg:
                raise Refused("The configuration changed after saving. Refresh to review it; the original file was backed up.")
            return {"message": "Configuration saved and verified. Hermes will use it in a new session or after reloading.", "backup": backup}

    def save_key(self, req):
        raw_config, cfg = self.config()
        if req.get("revision") and req["revision"] != digest(raw_config):
            raise Refused("The endpoint configuration changed. Close the key editor, refresh, and try again.")
        entry = cfg.get("providers", {}).get(req.get("provider"))
        if not isinstance(entry, dict):
            raise Refused("Save the endpoint before setting its API key.")
        name = entry.get("key_env")
        if not name or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise Refused("Set a valid API key variable name for the endpoint first.")
        if entry.get("api_key"):
            raise Refused("This endpoint still has an inline API key. Migrate it first to avoid conflicting credentials.")
        secret = req.get("secret", "")
        if not isinstance(secret, str) or not secret.strip() or any(c in secret for c in "\r\n\x00"):
            raise Refused("The API key must not be empty or contain line breaks.")
        path = self.home / ".env"
        with file_lock(path.with_name(".env.lock")):
            if read_bytes(self.config_path) != raw_config:
                raise Refused("The endpoint configuration changed. Refresh and try again.")
            raw = read_bytes(path, missing=True)
            text = raw.decode("utf-8")
            # dotenv single-quote escaping; no shell is used at any stage.
            quoted = "'" + secret.replace("\\", "\\\\").replace("'", "\\'") + "'"
            pattern = re.compile(r"^(?:export\s+)?" + re.escape(name) + r"\s*=.*$", re.M)
            matches = list(pattern.finditer(text))
            if len(matches) > 1:
                raise Refused("This key variable is defined more than once. Fix .env first.")
            if matches:
                start, end = matches[0].span()
                # Refuse multiline quoted values instead of leaving a trailing credential fragment.
                current_line = matches[0].group().split("=", 1)[1].strip()
                if current_line.startswith(("'", '"')) and not current_line.endswith(current_line[0]):
                    raise Refused("This variable has a multiline value, which cannot be replaced in this tool yet.")
                output = text[:start] + name + "=" + quoted + text[end:]
            else:
                output = text + ("\n" if text and not text.endswith("\n") else "") + name + "=" + quoted + "\n"
            from io import StringIO
            if dotenv_values(stream=StringIO(output), interpolate=False).get(name) != secret:
                raise Refused("Credential serialization validation failed. Nothing was saved.")
            if read_bytes(path, missing=True) != raw:
                raise Refused("Another program changed the credentials file. Try again.")
            backup = self.backup(path, raw) if raw else ""
            atomic_write(path, output.encode())
            if self.env().get(name) != secret:
                raise Refused("The saved credentials did not match when read back. Refresh to check them.")
        return {"message": "The API key was saved to the local Hermes credentials file.", "backup": backup}

    def discover(self, req):
        _, cfg = self.config()
        p = cfg.get("providers", {}).get(req.get("provider"))
        if not isinstance(p, dict):
            raise Refused("Save the custom endpoint first.")
        url = valid_url(p.get("base_url") or p.get("url") or p.get("api"))
        env = self.env()
        key = p.get("api_key") or env.get(p.get("key_env", "")) or os.environ.get(p.get("key_env", ""), "")
        headers = {"Accept": "application/json"}
        if key:
            if (p.get("api_mode") or p.get("transport")) in ("anthropic_messages", "anthropic"):
                headers["x-api-key"] = key
                headers["anthropic-version"] = "2023-06-01"
            else:
                headers["Authorization"] = "Bearer " + key
        for k, v in (p.get("extra_headers") or {}).items():
            if isinstance(v, str):
                headers[k] = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: env.get(m[1]) or os.environ.get(m[1], ""), v)
        data = fetch_json(url + "/models", headers, 8)
        if not isinstance(data, dict) or not isinstance(data.get("data"), list):
            raise Refused("The endpoint did not return an OpenAI-compatible model list.")
        models = list(dict.fromkeys(r["id"] for r in data["data"] if isinstance(r, dict) and isinstance(r.get("id"), str)))
        return {"models": models, "message": f"Fetched {len(models)} endpoint models. Select the models you want to add."}


def dispatch(home, req):
    store = Store(home)
    action = req.get("action", "snapshot")
    if action == "snapshot":
        return store.snapshot(req)
    if action == "preference":
        return store.change_preference(req)
    if action == "save_key":
        return store.save_key(req)
    if action == "save_preset":
        return store.save_preset(req)
    if action == "forget_models":
        return store.forget_models(req)
    if action == "discover":
        return store.discover(req)
    return store.mutate_config(req)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", default=str(Path.home() / ".hermes"))
    args = parser.parse_args()
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict):
            raise Refused("Invalid request format.")
        result = dispatch(args.home, request)
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
    except Refused as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
    except Exception:
        # Parser/network exceptions can carry full config lines or Authorization values.
        print(json.dumps({"ok": False, "error": "The operation could not be completed. Check the file format and access permissions, then refresh and try again."}, ensure_ascii=False))


if __name__ == "__main__":
    main()
