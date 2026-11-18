"""Offline unit tests: never touch Supabase or OpenAI."""
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.abspath("tools"))
import recipe_cover_automation as covers


class CoverSafetyTests(unittest.TestCase):
    def test_only_empty_photo_arrays_are_candidates(self):
        rows = [
            {"id": "a", "photos": []},
            {"id": "b", "photos": [{"id": "existing"}]},
            {"id": "c", "photos": None},
        ]
        with patch.object(covers, "request", return_value=rows) as req:
            result = covers.candidates("https://example.supabase.co", "dummy", "owner")
        self.assertEqual([r["id"] for r in result], ["a"])
        self.assertIn("owner_id=eq.owner", req.call_args.args[1])

    def test_optimistic_write_only_if_no_cover(self):
        with patch.object(covers, "request", return_value=[]) as req:
            self.assertFalse(covers.attach_if_empty(
                "https://example.supabase.co", "dummy", "owner", "recipe", "photo", "owner/recipe/photo.png"))
        url = req.call_args.args[1]
        self.assertIn("photos=eq.%5B%5D", url)
        self.assertIn("owner_id=eq.owner", url)
        self.assertIn("deleted_at=is.null", url)

    def test_attach_payload_contains_one_photo(self):
        with patch.object(covers, "request", return_value=[{"id": "recipe"}]) as req:
            self.assertTrue(covers.attach_if_empty(
                "https://example.supabase.co", "dummy", "owner", "recipe", "photo", "owner/recipe/photo.png"))
        import json
        payload = json.loads(req.call_args.args[3])
        self.assertEqual(payload["photos"], [{"id": "photo", "remote_path": "owner/recipe/photo.png"}])

    def test_image_rejects_invalid_bytes(self):
        import base64
        with patch.dict(os.environ, {"OPENAI_API_KEY": "fake"}), patch.object(
                covers, "request", return_value={"data": [{"b64_json": base64.b64encode(b"not-an-image").decode()}]}):
            with self.assertRaisesRegex(RuntimeError, "valid PNG"):
                covers.generate_image({"title": "Polévka", "ingredients": []})

    def test_image_prompt_uses_recipe_ingredients(self):
        import base64
        fake_png = bytes([137, 80, 78, 71, 13, 10, 26, 10]) + b"test"
        with patch.dict(os.environ, {"OPENAI_API_KEY": "fake"}), patch.object(
                covers, "request", return_value={"data": [{"b64_json": base64.b64encode(fake_png).decode()}]}) as req:
            covers.generate_image({"title": "Kuře na paprice", "description": "Nepálivé",
                                   "ingredients": [{"name": "kuře"}, {"name": "paprika"}]})
        import json
        request_payload = json.loads(req.call_args.args[3])
        self.assertIn("paprika", request_payload["prompt"])
        self.assertIn("no collage", request_payload["prompt"])


    def test_apply_requires_explicit_write_flag(self):
        import io
        with patch.object(sys, "argv", ["covers", "--apply"]), \
             patch.dict(os.environ, {"HINK_COVER_WRITES_ENABLED": "false"}), \
             patch.object(covers, "config", return_value=("https://example.supabase.co", "dummy", "owner")), \
             patch.object(covers, "candidates") as candidates:
            with self.assertRaisesRegex(RuntimeError, "Writes disabled"):
                covers.main()
            candidates.assert_not_called()

    def test_limit_has_upper_bound(self):
        self.assertEqual(covers.MAX_IMAGES, 5)


if __name__ == "__main__":
    unittest.main()
