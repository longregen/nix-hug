#!/usr/bin/env python3
"""FOD builder script for fetching HuggingFace models.

This runs inside the Fixed Output Derivation with network access.
"""

import shutil
import os
import sys
import json
import logging
import traceback
from pathlib import Path
from typing import Dict, List, Any, Optional

from huggingface_hub import snapshot_download
from .shared import get_repo_info_from_api, apply_filters, sorted_object
from .HugLock import HugLock
from .types import RepoInfo


def clean_huggingface_download(output_path: Path) -> None:
    """Remove HuggingFace cache directory from output."""
    hf_cache = output_path / ".huggingface"
    if hf_cache.exists():
        shutil.rmtree(hf_cache)


def make_all_files_timestamp_1970(output_path: Path) -> None:
    """Set all file timestamps to 1970 for reproducibility."""
    for root, dirs, files in os.walk(output_path):
        root_path = Path(root)
        for item in dirs + files:
            item_path = root_path / item
            if item_path.exists():
                os.utime(item_path, (0, 0))


def get_config_from_environment() -> Dict[str, Any]:
    """Extract configuration from environment variables."""
    from .config import get_config_from_env
    from .utils import safe_json_loads

    try:
        config = get_config_from_env()
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    repo_id = config["repo_id"]
    tag_or_branch = config["tag_or_branch"]
    filters = config["filters"]
    lock_file_path = config["lock_file_path"]
    variant_key = config["variant_key"]
    log_level = config["log_level"]

    # Set up logging if debug
    if log_level == "DEBUG":
        logging.basicConfig(level=logging.DEBUG)
        hf_logger = logging.getLogger("huggingface_hub")
        hf_logger.setLevel(logging.DEBUG)

    # Handle lock file
    has_lock_file = lock_file_path and Path(lock_file_path).exists()
    hug_lock = None
    lock_has_data = False
    if has_lock_file:
        hug_lock = HugLock(Path(lock_file_path))
        lock_has_data = hug_lock.has_tag_or_branch_data(repo_id, tag_or_branch)

    return {
        "repo_id": repo_id,
        "tag_or_branch": tag_or_branch,
        "filters": filters,
        "lock_file_path": lock_file_path,
        "variant_key": variant_key,
        "hug_lock": hug_lock,
        "lock_has_data": lock_has_data,
    }


def download_files(
    repo_id: str, tag_or_branch: str, files_to_download: List[str]
) -> Path:
    """Download files from HuggingFace repository."""
    try:
        output_path = os.environ.get("out", ".")

        # If we have specific files, use allow_patterns with exact filenames
        # If no files specified, download everything
        download_kwargs = {
            "repo_id": repo_id,
            "revision": tag_or_branch,
            "local_dir": output_path,
        }

        if files_to_download:
            download_kwargs["allow_patterns"] = files_to_download

        print(f"Downloading {repo_id} to {output_path} with kwargs: {download_kwargs}")
        snapshot_download(**download_kwargs)
        return Path(output_path)
    except Exception as e:
        print(f"Error downloading {repo_id}:\n\t{e}", file=sys.stderr)
        traceback.print_exc()
        sys.exit(1)


def clean_and_make_reproducible(
    output_path: Path,
    repo_info: RepoInfo,
    variant_key: str,
    repo_id: str,
    tag_or_branch: str,
    filters: Dict[str, Any],
) -> None:
    """Clean up the output path and make it reproducible."""
    try:
        output_path = Path(output_path)

        # Ensure output directory exists
        output_path.mkdir(parents=True, exist_ok=True)

        metadata = {
            "repo_info": repo_info,
            "variant_key": variant_key,
            "repo_id": repo_id,
            "tag_or_branch": tag_or_branch,
            "filters": filters,
        }

        from .utils import atomic_write_json
        from .config import Constants

        metadata_path = output_path / Constants.METADATA_FILENAME
        atomic_write_json(metadata_path, metadata, sorted_keys=True)
        clean_huggingface_download(output_path)
        make_all_files_timestamp_1970(output_path)

    except Exception as e:
        print(
            f"Error cleaning up {repo_id} for reproducibility:\n\t{e}", file=sys.stderr
        )
        traceback.print_exc()
        sys.exit(1)


def main() -> None:
    """Main FOD builder entry point."""
    config = get_config_from_environment()
    repo_id = config["repo_id"]
    tag_or_branch = config["tag_or_branch"]
    filters = config["filters"]
    variant_key = config["variant_key"]
    lock_has_data = config["lock_has_data"]
    hug_lock = config["hug_lock"]

    repo_info = (
        hug_lock.get_repo_info(repo_id, tag_or_branch)
        if lock_has_data
        else get_repo_info_from_api(repo_id, tag_or_branch)
    )

    files_to_download, _, _ = apply_filters(
        repo_info,
        filters.get("include", []),
        filters.get("exclude", []),
        filters.get("files", []),
    )
    output_path = download_files(repo_id, tag_or_branch, files_to_download)
    clean_and_make_reproducible(
        output_path, repo_info, variant_key, repo_id, tag_or_branch, filters
    )


if __name__ == "__main__":
    main()
