import concurrent.futures
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).parents[1] / "Resources/bridge.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

CONFIG = '''# user comment
model:
  provider: other
  default: main-model
providers:
  "openai-key.person@example.com":
    name: Personal endpoint # keep this comment
    api: https://example.com/v1
    base_url: https://example.com/v1
    key_env: PERSONAL_KEY
    model: model-a
    default_model: model-a
    discover_models: false
    extra_headers:
      X-Special: preserved
    models:
      model-a:
        context_length: 100000
        custom_metadata: keep
      model-b: {}
  other:
    name: Other
    base_url: http://localhost:9999/v1
    models: {main-model: {}}
# keep tail exactly
auxiliary:
  arbitrary: [1, 2, 3]
security:
  redact_secrets: true
'''


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        (self.home / "config.yaml").write_text(CONFIG)
        (self.home / ".env").write_text("# unrelated credential\nPERSONAL_KEY='old-secret'\nUNRELATED=untouched\n")
        self.doc = {"version": 1, "generation": "existing-generation", "revision": 7,
                    "values": {"hermes-desktop-theme-v2": "dark", b.FAVORITES: '["other::main-model"]',
                               b.KNOWN: '["openai-key.person@example.com::model-a"]', b.VISIBLE: '[]'}}
        (self.home / "ui-preferences.json").write_text(json.dumps(self.doc))
        self.store = b.Store(self.home)

    def tearDown(self):
        self.temp.cleanup()

    def call(self, action, **kw):
        req = {"action": action, "revision": self.store.snapshot({})["revision"],
               "provider": "openai-key.person@example.com", **kw}
        return b.dispatch(self.home, req)

    def provider_request(self, **kw):
        return dict(name="Personal endpoint", baseURL="https://new.example/v1", apiMode="responses",
                    defaultModel="model-a", keyEnv="PERSONAL_KEY", discover=False, context="500000", **kw)

    def test_model_edit_preserves_metadata_and_outside_bytes(self):
        self.call("save_model", model="model-a", context="234567")
        result = self.store.config()[1]
        expected = b.parse_config(CONFIG)
        expected["providers"]["openai-key.person@example.com"]["models"]["model-a"]["context_length"] = 234567
        self.assertEqual(result, expected)
        output = (self.home / "config.yaml").read_text()
        self.assertTrue(output.startswith("# user comment\n"))
        self.assertIn("# keep this comment", output)
        self.assertEqual(output.split("  other:")[1], CONFIG.split("  other:")[1])
        self.assertEqual(len(list(self.store.backup_dir.iterdir())), 1)

    def test_provider_aliases_update_together_and_preserve_comments(self):
        self.call("save_provider", **self.provider_request())
        p = self.store.config()[1]["providers"]["openai-key.person@example.com"]
        self.assertEqual(p["api"], p["base_url"])
        self.assertEqual(p["api_mode"], "responses")
        self.assertEqual(p["context_length"], 500000)
        self.assertEqual(p["extra_headers"], {"X-Special": "preserved"})
        self.assertIn("# keep this comment", (self.home / "config.yaml").read_text())

    def test_create_provider_dot_at_and_delete(self):
        self.call("save_provider", provider="new.key@mail.com", create=True, **self.provider_request())
        self.assertIn("new.key@mail.com", self.store.config()[1]["providers"])
        self.call("delete_provider", provider="new.key@mail.com")
        self.assertEqual(self.store.config()[1], b.parse_config(CONFIG))

    def test_new_model_default_model_and_metadata(self):
        self.call("save_model", model="new-model", context="", create=True)
        self.assertEqual(self.store.config()[1]["providers"]["openai-key.person@example.com"]["models"]["new-model"], {})
        self.call("delete_model", model="new-model")
        with self.assertRaises(b.Refused):
            self.call("delete_model", model="model-a")
        with self.assertRaises(b.Refused):
            self.call("save_model", model="rename", originalModel="model-a")

    def test_stale_config_refused_without_writes(self):
        revision = self.store.snapshot({})["revision"]
        (self.home / "config.yaml").write_text(CONFIG + "\n# concurrent edit\n")
        with self.assertRaises(b.Refused):
            self.call("save_model", model="model-a", context="200000", revision=revision)
        self.assertTrue((self.home / "config.yaml").read_text().endswith("# concurrent edit\n"))
        self.assertFalse(self.store.backup_dir.exists())

    def test_duplicate_yaml_keys_and_bad_prefs_fail_closed(self):
        (self.home / "config.yaml").write_text("providers: {}\nproviders: {}\n")
        with self.assertRaises(b.Refused):
            self.store.snapshot({})
        (self.home / "config.yaml").write_text(CONFIG)
        (self.home / "ui-preferences.json").write_text("{bad")
        with self.assertRaises(b.Refused):
            self.call("preference", field="favorite", slug="other", model="model-a", enabled=True)
        self.assertEqual((self.home / "ui-preferences.json").read_text(), "{bad")

    def test_preference_merge_revision_identity_and_unfavorite(self):
        self.call("preference", field="favorite", slug="custom:openai-key.person@example.com", model="model-b", enabled=True)
        doc = b.pref_doc(self.store.prefs_path)
        self.assertEqual(doc["generation"], self.doc["generation"])
        self.assertEqual(doc["revision"], 8)
        self.assertEqual(doc["values"]["hermes-desktop-theme-v2"], "dark")
        self.assertEqual(b.pref_list(doc, b.FAVORITES), ["other::main-model", "custom:openai-key.person@example.com::model-b"])
        self.call("preference", field="favorite", slug="custom:openai-key.person@example.com", model="model-b", enabled=False)
        self.assertEqual(b.pref_list(b.pref_doc(self.store.prefs_path), b.FAVORITES), ["other::main-model"])

    def test_concurrent_preference_writers_do_not_lose_changes(self):
        def add(i):
            return b.Store(self.home).change_preference({"field": "favorite", "slug": "other", "model": f"model-{i}", "enabled": True})
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
            list(ex.map(add, range(16)))
        self.assertEqual(len(b.pref_list(b.pref_doc(self.store.prefs_path), b.FAVORITES)), 17)

    def test_visibility_hiding_unknown_and_showing_sentinel(self):
        self.call("preference", field="visible", slug="openai-key.person@example.com", model="model-b", enabled=False)
        rows = self.store.snapshot({})["models"]
        self.assertFalse(next(r for r in rows if r["modelID"] == "model-b")["visible"])
        self.call("preference", field="visible", slug="openai-key.person@example.com", model="model-b", enabled=True)
        doc = b.pref_doc(self.store.prefs_path)
        self.assertNotIn("openai-key.person@example.com::", b.pref_list(doc, b.VISIBLE))
        self.assertIn("openai-key.person@example.com::model-b", b.pref_list(doc, b.KNOWN))

    def test_live_slug_wins_over_legacy_favorites(self):
        snapshot = self.store.snapshot({"catalog": [{"slug": "custom:openai-key.person@example.com", "name": "Personal", "custom": True, "models": ["extra-model"]}]})
        p = next(p for p in snapshot["providers"] if p["editable"])
        self.assertEqual(p["slug"], "custom:openai-key.person@example.com")
        self.assertFalse(any(r["modelID"] == "extra-model" for r in snapshot["models"]))

    def test_empty_visibility_means_everything_hidden(self):
        self.assertTrue(all(not row["visible"] for row in self.store.snapshot({})["models"]))

    def test_hiding_one_default_keeps_other_default_models(self):
        doc = copy.deepcopy(self.doc)
        doc["values"][b.VISIBLE] = '["other::main-model"]'
        (self.home / "ui-preferences.json").write_text(json.dumps(doc))
        self.call("preference", field="visible", slug="openai-key.person@example.com", model="model-b", enabled=False)
        rows = self.store.snapshot({})["models"]
        self.assertTrue(next(r for r in rows if r["modelID"] == "model-a")["visible"])
        self.assertFalse(next(r for r in rows if r["modelID"] == "model-b")["visible"])

    def test_fast_variant_shares_client_menu_identity(self):
        self.call("save_model", model="model-a-fast", context="", create=True)
        self.call("preference", field="favorite", slug="openai-key.person@example.com", model="model-a", enabled=True)
        row = next(r for r in self.store.snapshot({})["models"] if r["modelID"] == "model-a-fast")
        self.assertEqual(row["preferenceModel"], "model-a")
        self.assertTrue(row["favorite"])

    def test_orphan_favorite_preserved_and_marked(self):
        self.store.change_preference({"field": "favorite", "slug": "gone", "model": "old", "enabled": True})
        row = next(r for r in self.store.snapshot({})["models"] if r["id"] == "gone::old")
        self.assertTrue(row["favorite"])
        self.assertFalse(row["available"])

    def test_unlisted_model_can_be_hidden_and_unstarred(self):
        self.call("preference", field="favorite", slug="gone", model="old", enabled=True)
        self.call("preference", field="visible", slug="gone", model="old", enabled=False)
        row = next(r for r in self.store.snapshot({})["models"] if r["id"] == "gone::old")
        self.assertFalse(row["available"])
        self.assertFalse(row["visible"])
        self.call("preference", field="favorite", slug="gone", model="old", enabled=False)
        self.assertFalse(any(r["id"] == "gone::old" for r in self.store.snapshot({})["models"]))

    def test_forget_history_removes_only_target_and_preserves_configuration(self):
        doc = copy.deepcopy(self.doc)
        for field in (b.FAVORITES, b.VISIBLE, b.KNOWN):
            doc["values"][field] = json.dumps(["gone::old", "other::main-model"])
        doc["values"][b.PRESETS] = json.dumps({"gone::old": {"effort": "high"}, "other::main-model": {"effort": "xhigh"}})
        self.store.prefs_path.write_text(json.dumps(doc))
        config, env = self.store.config_path.read_bytes(), (self.home / ".env").read_bytes()
        self.call("forget_models", items=[{"slug": "gone", "model": "old"}])
        after = b.pref_doc(self.store.prefs_path)
        for field in (b.FAVORITES, b.VISIBLE, b.KNOWN):
            self.assertNotIn("gone::old", b.pref_list(after, field))
            self.assertIn("other::main-model", b.pref_list(after, field))
        self.assertEqual(b.model_presets(after), {"other::main-model": {"effort": "xhigh"}})
        self.assertEqual(after["generation"], doc["generation"])
        self.assertEqual(after["revision"], doc["revision"] + 1)
        self.assertEqual(after["values"]["hermes-desktop-theme-v2"], "dark")
        self.assertEqual(self.store.config_path.read_bytes(), config)
        self.assertEqual((self.home / ".env").read_bytes(), env)
        self.assertEqual(len(list(self.store.backup_dir.iterdir())), 1)
        self.call("forget_models", items=[{"slug": "gone", "model": "old"}])
        self.assertEqual(len(list(self.store.backup_dir.iterdir())), 1)

    def test_forget_rejects_mixed_configured_and_history_atomically(self):
        self.call("preference", field="favorite", slug="gone", model="old", enabled=True)
        before = self.store.prefs_path.read_bytes()
        with self.assertRaises(b.Refused):
            self.call("forget_models", items=[{"slug": "gone", "model": "old"}, {"slug": "openai-key.person@example.com", "model": "model-a"}])
        self.assertEqual(self.store.prefs_path.read_bytes(), before)

    def test_forget_does_not_reenable_hidden_models_in_same_endpoint(self):
        slug = "openai-key.person@example.com"
        doc = copy.deepcopy(self.doc)
        doc["values"][b.FAVORITES] = json.dumps([slug + "::removed"])
        doc["values"][b.VISIBLE] = json.dumps([slug + "::removed", "other::main-model"])
        doc["values"][b.KNOWN] = json.dumps([slug + "::removed", slug + "::model-a", slug + "::model-b"])
        self.store.prefs_path.write_text(json.dumps(doc))
        before = {r["id"]: r["visible"] for r in self.store.snapshot({})["models"] if r["configured"]}
        self.call("forget_models", items=[{"slug": slug, "model": "removed"}])
        after = {r["id"]: r["visible"] for r in self.store.snapshot({})["models"] if r["configured"]}
        self.assertEqual(before, after)

    def test_forget_preserves_never_customized_visibility(self):
        doc = copy.deepcopy(self.doc)
        doc["values"].pop(b.VISIBLE)
        doc["values"][b.FAVORITES] = '["gone::old"]'
        self.store.prefs_path.write_text(json.dumps(doc))
        self.call("forget_models", items=[{"slug": "gone", "model": "old"}])
        self.assertNotIn(b.VISIBLE, b.pref_doc(self.store.prefs_path)["values"])

    def test_raw_fast_favorite_does_not_duplicate_row_and_can_be_cancelled(self):
        self.call("save_model", model="model-a-fast", context="", create=True)
        self.call("preference", field="favorite", slug="openai-key.person@example.com", model="model-a-fast", enabled=True)
        rows = [r for r in self.store.snapshot({})["models"] if r["modelID"] == "model-a-fast"]
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["favorite"])
        self.call("preference", field="favorite", enabled=False, items=[{"slug": rows[0]["slug"], "model": m} for m in [rows[0]["modelID"], rows[0]["preferenceModel"]]])
        self.assertFalse(next(r for r in self.store.snapshot({})["models"] if r["modelID"] == "model-a-fast")["favorite"])

    def test_api_key_special_chars_and_no_echo(self):
        secret = "new'\\secret$(never-run)`untouched`"
        result = self.call("save_key", secret=secret)
        self.assertEqual(self.store.env()["PERSONAL_KEY"], secret)
        self.assertEqual(self.store.env()["UNRELATED"], "untouched")
        self.assertNotIn(secret, json.dumps(result))
        self.assertNotIn(secret, json.dumps(self.store.snapshot({})))

    def test_profile_writes_machine_preferences(self):
        profile = self.home / "profiles" / "work"
        profile.mkdir(parents=True)
        (profile / "config.yaml").write_text(CONFIG)
        s = b.Store(profile)
        self.assertEqual(s.prefs_path, self.store.prefs_path)

    def test_reference_blocks_provider_deletion(self):
        with self.assertRaises(b.Refused):
            self.call("delete_provider", provider="other")

    def test_reference_blocks_nondefault_model_deletion(self):
        config = CONFIG.replace("  provider: other", "  provider: openai-key.person@example.com").replace("  default: main-model", "  default: model-b")
        (self.home / "config.yaml").write_text(config)
        with self.assertRaises(b.Refused):
            self.call("delete_model", model="model-b")
        self.assertEqual((self.home / "config.yaml").read_text(), config)

    def test_duplicate_route_identity_refused(self):
        with self.assertRaises(b.Refused):
            self.call("save_provider", provider="OTHER", create=True, **self.provider_request())

    def test_flow_mapping_and_empty_providers(self):
        (self.home / "config.yaml").write_text("model: {default: x}\nproviders: {}\n# tail\n")
        self.call("save_provider", provider="new", create=True, **self.provider_request())
        self.call("save_model", provider="new", model="additional", context="100")
        self.assertIn("additional", self.store.config()[1]["providers"]["new"]["models"])
        self.assertTrue((self.home / "config.yaml").read_text().endswith("# tail\n"))

    def test_batch_add_is_single_write_and_preserves_existing_metadata(self):
        self.call("batch_models", operation="add", models=["model-a", "model-c", "model-c", "model-d"])
        models = self.store.config()[1]["providers"]["openai-key.person@example.com"]["models"]
        self.assertEqual(set(models), {"model-a", "model-b", "model-c", "model-d"})
        self.assertEqual(models["model-a"]["custom_metadata"], "keep")
        self.assertEqual(len(list(self.store.backup_dir.iterdir())), 1)

    def test_batch_add_invalid_item_makes_no_changes(self):
        with self.assertRaises(b.Refused):
            self.call("batch_models", operation="add", models=["valid-new", "bad::id"])
        self.assertEqual((self.home / "config.yaml").read_text(), CONFIG)
        self.assertFalse(self.store.backup_dir.exists())

    def test_batch_remove_default_refuses_entire_batch(self):
        with self.assertRaises(b.Refused):
            self.call("batch_models", operation="remove", models=["model-b", "model-a"])
        self.assertEqual((self.home / "config.yaml").read_text(), CONFIG)

    def test_batch_remove_success_retains_preferences(self):
        prefs = (self.home / "ui-preferences.json").read_bytes()
        self.call("batch_models", operation="remove", models=["model-b"])
        self.assertNotIn("model-b", self.store.config()[1]["providers"]["openai-key.person@example.com"]["models"])
        self.assertEqual((self.home / "ui-preferences.json").read_bytes(), prefs)

    def test_pin_models_disables_discovery_and_updates_both_defaults(self):
        self.call("batch_models", operation="pin", models=["model-a", "new-remote"], defaultModel="new-remote")
        p = self.store.config()[1]["providers"]["openai-key.person@example.com"]
        self.assertFalse(p["discover_models"])
        self.assertEqual(set(p["models"]), {"model-a", "new-remote"})
        self.assertEqual(p["models"]["model-a"]["custom_metadata"], "keep")
        self.assertEqual(p["model"], "new-remote")
        self.assertEqual(p["default_model"], "new-remote")

    def test_pin_referenced_model_refuses_all(self):
        config = CONFIG + '\nfallback_providers:\n- provider: openai-key.person@example.com\n  model: model-b\n'
        (self.home / "config.yaml").write_text(config)
        with self.assertRaises(b.Refused):
            self.call("batch_models", operation="pin", models=["model-a"], defaultModel="model-a")
        self.assertEqual((self.home / "config.yaml").read_text(), config)

    def test_set_endpoint_default_does_not_change_global_default(self):
        before = self.store.config()[1]["model"]
        self.call("batch_models", operation="default", models=["new-model"])
        cfg = self.store.config()[1]
        self.assertEqual(cfg["model"], before)
        self.assertEqual(cfg["providers"]["openai-key.person@example.com"]["default_model"], "new-model")

    def test_timeout_fields_use_correct_provider_and_model_names(self):
        self.call("save_provider", requestTimeout="900", staleTimeout="300", **self.provider_request())
        self.call("save_model", model="model-a", context="100000", requestTimeout="1200", staleTimeout="600")
        p = self.store.config()[1]["providers"]["openai-key.person@example.com"]
        self.assertEqual(p["request_timeout_seconds"], 900)
        self.assertEqual(p["models"]["model-a"]["timeout_seconds"], 1200)
        self.assertEqual(p["models"]["model-a"]["stale_timeout_seconds"], 600)
        self.call("save_model", model="model-a", context="100000", requestTimeout="", staleTimeout="")
        self.assertNotIn("timeout_seconds", self.store.config()[1]["providers"]["openai-key.person@example.com"]["models"]["model-a"])

    def test_invalid_timeout_refuses_without_writing(self):
        with self.assertRaises(b.Refused):
            self.call("save_model", model="model-a", context="200000", requestTimeout="NaN")
        self.assertEqual((self.home / "config.yaml").read_text(), CONFIG)

    def test_batch_favorites_single_revision_and_preserves_theme(self):
        items = [{"slug": "p", "model": "a"}, {"slug": "q", "model": "b"}]
        self.call("preference", items=items, field="favorite", enabled=True)
        doc = b.pref_doc(self.store.prefs_path)
        self.assertEqual(doc["revision"], 8)
        self.assertEqual(b.pref_list(doc, b.FAVORITES), ["other::main-model", "p::a", "q::b"])
        self.assertEqual(doc["values"]["hermes-desktop-theme-v2"], "dark")
        self.call("preference", items=items, field="favorite", enabled=False)
        self.assertEqual(b.pref_list(b.pref_doc(self.store.prefs_path), b.FAVORITES), ["other::main-model"])

    def test_batch_visibility_all_hidden_and_show_one(self):
        slug = "openai-key.person@example.com"
        items = [{"slug": slug, "model": "model-a"}, {"slug": slug, "model": "model-b"}]
        self.call("preference", items=items, field="visible", enabled=True)
        self.call("preference", items=items, field="visible", enabled=False)
        doc = b.pref_doc(self.store.prefs_path)
        self.assertIn(slug + "::", b.pref_list(doc, b.VISIBLE))
        self.assertIn(slug + "::model-b", b.pref_list(doc, b.KNOWN))
        self.call("preference", items=[items[0]], field="visible", enabled=True)
        rows = self.store.snapshot({})["models"]
        self.assertTrue(next(r for r in rows if r["modelID"] == "model-a")["visible"])
        self.assertFalse(next(r for r in rows if r["modelID"] == "model-b")["visible"])

    def test_preset_merge_reset_and_snapshot(self):
        doc = copy.deepcopy(self.doc)
        doc["values"][b.PRESETS] = json.dumps({"other::main-model": {"effort": "high"}, "p::m": {"futureField": 42, "effort": "low"}})
        self.store.prefs_path.write_text(json.dumps(doc))
        self.call("save_preset", slug="p", model="m", effort="xhigh", tier="priority")
        presets = b.model_presets(b.pref_doc(self.store.prefs_path))
        self.assertEqual(presets["p::m"], {"futureField": 42, "effort": "xhigh", "serviceTier": "priority", "fast": True})
        self.assertEqual(presets["other::main-model"], {"effort": "high"})
        self.call("save_preset", slug="p", model="m", effort="", tier="")
        self.assertEqual(b.model_presets(b.pref_doc(self.store.prefs_path))["p::m"], {"futureField": 42})

    def test_endpoint_discovery_and_atomic_import_with_mock_server(self):
        observed = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                observed.append((self.path, self.headers.get("Authorization"), self.headers.get("x-api-key")))
                body = json.dumps({"data": [{"id": "discovered-a"}, {"id": "discovered-b"}, {"id": "discovered-a"}]}).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            def log_message(self, *args):
                pass
        server = HTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            req = self.provider_request()
            req.update(baseURL=f"http://127.0.0.1:{server.server_port}/v1", apiMode="chat_completions")
            self.call("save_provider", **req)
            result = self.call("discover")
            self.assertEqual(result["models"], ["discovered-a", "discovered-b"])
            self.assertEqual(observed[-1], ("/v1/models", "Bearer old-secret", None))
            self.call("batch_models", operation="add", models=result["models"])
            self.assertEqual(len(self.store.config()[1]["providers"]["openai-key.person@example.com"]["models"]), 4)
            req["apiMode"] = "anthropic_messages"
            self.call("save_provider", **req)
            self.call("discover")
            self.assertEqual(observed[-1], ("/v1/models", None, "old-secret"))
        finally:
            server.shutdown(); worker.join(); server.server_close()


if __name__ == "__main__":
    unittest.main()
