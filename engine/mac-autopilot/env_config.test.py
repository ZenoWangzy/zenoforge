#!/usr/bin/env python3
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from env_config import zf_env


class EnvironmentConfigTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR")))
        self.config_root = self.root / ".zenoforge"
        self.config_root.mkdir()
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        os.environ["ZF_CONFIG_ROOT"] = str(self.config_root)

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.root)

    def set_prefix(self):
        (self.config_root / "config.json").write_text(
            json.dumps({"env_prefix": "DEPLOY_"}), encoding="utf-8"
        )

    def test_no_config_uses_engine_default(self):
        self.assertEqual(zf_env("SAMPLE", "engine-default"), "engine-default")

    def test_no_config_uses_public_spelling(self):
        os.environ["ZF_SAMPLE"] = "public"
        self.assertEqual(zf_env("SAMPLE", "engine-default"), "public")

    def test_prefixed_value_wins(self):
        self.set_prefix()
        os.environ["DEPLOY_SAMPLE"] = "deployment"
        os.environ["ZF_SAMPLE"] = "public"
        self.assertEqual(zf_env("SAMPLE", "engine-default"), "deployment")

    def test_public_value_is_fallback_when_prefix_is_configured(self):
        self.set_prefix()
        os.environ["ZF_SAMPLE"] = "public"
        self.assertEqual(zf_env("SAMPLE", "engine-default"), "public")

    def test_present_empty_value_stays_empty(self):
        self.set_prefix()
        os.environ["DEPLOY_SAMPLE"] = ""
        os.environ["ZF_SAMPLE"] = "public"
        self.assertEqual(zf_env("SAMPLE", "engine-default"), "")

    def test_product_config_is_found_from_repo_setting(self):
        self.set_prefix()
        os.environ.pop("ZF_CONFIG_ROOT")
        os.environ["ZF_REPO_DIR"] = str(self.root)
        os.environ["DEPLOY_SAMPLE"] = "from-product-config"
        os.environ["ZF_SAMPLE"] = "public"
        self.assertEqual(zf_env("SAMPLE", "engine-default"), "from-product-config")


if __name__ == "__main__":
    unittest.main()
