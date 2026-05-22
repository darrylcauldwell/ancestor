"""Configuration loader — merges base config with local overrides.

Three layers:
  config.yaml       — regional reference data (committed, shareable)
  config.local.yaml — personal settings (gitignored)
  .env              — secrets/credentials (gitignored)

Local overrides base. Missing files are silently skipped.

Usage:
    from config import config

    config.region.county          # "Derbyshire"
    config.region.chapman_code    # "DBY"
    config.region.districts       # {"Belper": "722", ...}
    config.project.seed_profile   # "Cauldwell-100"
"""

from pathlib import Path

import yaml

ROOT = Path(__file__).parent
CONFIG_FILE = ROOT / "config.yaml"
LOCAL_FILE = ROOT / "config.local.yaml"
EXAMPLE_FILE = ROOT / "config.example.yaml"


def _deep_merge(base: dict, override: dict) -> dict:
    """Merge override into base. Override wins on conflicts.
    Dicts are merged recursively, other types are replaced."""
    merged = base.copy()
    for key, value in override.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


class _Region:
    def __init__(self, data: dict):
        self.county = data.get("county", "")
        self.chapman_code = data.get("chapman_code", "")
        self.country = data.get("country", "England")
        self.default_location = data.get("default_location", "")
        self.districts = data.get("districts", {})
        self.district_parishes = data.get("district_parishes", {})
        self.district_aliases = data.get("district_aliases", {})
        self.non_local_districts = data.get("non_local_districts", {})
        self.source_gaps = data.get("source_gaps", {})


class _Project:
    def __init__(self, data: dict):
        self.name = data.get("name", "")
        self.seed_profile = data.get("seed_profile", "")
        self._data_dir = data.get("data_dir", "")

    @property
    def data_dir(self) -> Path:
        """Root directory for all user data files.

        Defaults to project root. Multi-user deployments can set this
        per user to isolate twin, leads, and research state.
        """
        if self._data_dir:
            return Path(self._data_dir)
        return ROOT


class Config:
    def __init__(self):
        self.region = _Region({})
        self.project = _Project({})
        self._load()

    def _load(self):
        data = {}

        # Layer 1: example config (fallback defaults)
        if EXAMPLE_FILE.exists():
            with open(EXAMPLE_FILE) as f:
                data = yaml.safe_load(f) or {}

        # Layer 2: base config (committed, shareable regional data)
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE) as f:
                base = yaml.safe_load(f) or {}
            data = _deep_merge(data, base)

        # Layer 3: local overrides (gitignored, personal settings)
        if LOCAL_FILE.exists():
            with open(LOCAL_FILE) as f:
                local = yaml.safe_load(f) or {}
            data = _deep_merge(data, local)

        self.region = _Region(data.get("region", {}))
        self.project = _Project(data.get("project", {}))

    def reload(self):
        self._load()


# Singleton — loaded once on import
config = Config()
