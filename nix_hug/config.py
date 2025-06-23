#!/usr/bin/env python3
"""Configuration constants and environment variable handling for nix-hug."""

import os
import json
from typing import Dict, Any, Optional
from pathlib import Path


class EnvVars:
    """Environment variable names used by nix-hug."""

    REPO = "NIX_HUG_REPO"
    TAG_OR_BRANCH = "NIX_HUG_TAG_OR_BRANCH"
    FILTERS = "NIX_HUG_FILTERS"
    LOCK_FILE = "NIX_HUG_LOCK_FILE"
    VARIANT_KEY = "NIX_HUG_VARIANT_KEY"
    LOG_LEVEL = "NIX_HUG_LOG_LEVEL"


class Constants:
    """Shared constants used throughout nix-hug."""

    STORE_PATH_PATTERN = r"/nix/store/[a-z0-9]+-hf-model--[^/\s]+"
    DEFAULT_TAG_OR_BRANCH = "main"
    DEFAULT_VARIANT_KEY = "base"
    DEFAULT_LOG_LEVEL = "INFO"
    METADATA_FILENAME = ".nix-hug-metadata.json"

    # Filter presets for different model types
    FILTER_PRESETS = {
        "safetensors": {"include": ["*.safetensors", "*.json", "*.txt"]},
        "onnx": {"include": ["*.onnx", "*.json", "*.txt"]},
        "pytorch": {"include": ["*.bin", "*.json", "*.txt"]},
    }


def build_nix_env(
    repo_url: str,
    tag_or_branch: str,
    filters: Dict[str, Any],
    lock_file_path: Optional[str],
    variant_key: str,
    log_level: str = Constants.DEFAULT_LOG_LEVEL,
) -> Dict[str, str]:
    """Build environment dict for Nix execution."""
    # Ensure filters is properly serialized, defaulting to empty dict if None
    filters_json = json.dumps(filters if filters is not None else {})

    env = {
        "PATH": os.environ.get("PATH", ""),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "out": os.environ.get("out", ""),
        "NIX_PATH": os.environ.get("NIX_PATH", ""),
        EnvVars.LOG_LEVEL: log_level,
        EnvVars.REPO: repo_url,
        EnvVars.TAG_OR_BRANCH: tag_or_branch,
        EnvVars.FILTERS: filters_json,
        EnvVars.LOCK_FILE: lock_file_path or "",
        EnvVars.VARIANT_KEY: variant_key,
    }
    return env


def get_config_from_env() -> Dict[str, Any]:
    """Extract nix-hug configuration from environment variables."""
    repo_id = os.environ.get(EnvVars.REPO)
    if not repo_id or len(repo_id.split("/")) != 2:
        raise ValueError("NIX_HUG_REPO not set or invalid")

    tag_or_branch = os.environ.get(
        EnvVars.TAG_OR_BRANCH, Constants.DEFAULT_TAG_OR_BRANCH
    )
    filters_json = os.environ.get(EnvVars.FILTERS, "{}")
    lock_file_path = os.environ.get(EnvVars.LOCK_FILE)
    variant_key = os.environ.get(EnvVars.VARIANT_KEY, Constants.DEFAULT_VARIANT_KEY)
    log_level = os.environ.get(EnvVars.LOG_LEVEL, Constants.DEFAULT_LOG_LEVEL)

    try:
        filters = json.loads(filters_json)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON in {EnvVars.FILTERS}: {e}")

    return {
        "repo_id": repo_id,
        "tag_or_branch": tag_or_branch,
        "filters": filters,
        "lock_file_path": lock_file_path,
        "variant_key": variant_key,
        "log_level": log_level,
    }
