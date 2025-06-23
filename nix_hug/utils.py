#!/usr/bin/env python3
"""Utility functions for nix-hug to reduce code duplication."""

import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Union

from .types import RepoInfo
from .config import Constants


def atomic_write_json(path: Path, data: Any, sorted_keys: bool = True) -> None:
    """Atomically write JSON data to a file.

    Args:
        path: Target file path
        data: Data to write as JSON
        sorted_keys: Whether to sort keys in output
    """
    # Ensure parent directory exists
    path.parent.mkdir(parents=True, exist_ok=True)

    # Write to temporary file first
    tmp_path = path.with_suffix(".tmp")
    with open(tmp_path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=sorted_keys)

    # Atomic replace
    tmp_path.replace(path)


def run_command(
    cmd: List[str],
    check: bool = True,
    capture_output: bool = True,
    text: bool = True,
    env: Optional[Dict[str, str]] = None,
) -> subprocess.CompletedProcess[str]:
    """Run command with standard options and error handling.

    Args:
        cmd: Command and arguments to run
        check: If True, raise exception on non-zero exit
        capture_output: If True, capture stdout/stderr
        text: If True, return text instead of bytes
        env: Environment variables for the process

    Returns:
        CompletedProcess result

    Raises:
        subprocess.CalledProcessError: If check=True and command fails
    """
    result = subprocess.run(cmd, capture_output=capture_output, text=text, env=env)

    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, result.stdout, result.stderr
        )

    return result


def prepare_filters(
    include: Tuple[str, ...],
    exclude: Tuple[str, ...],
    files: Tuple[str, ...],
    filter_preset: Optional[str],
) -> Tuple[Dict[str, Any], str, str]:
    """Prepare filters, description, and variant key.

    Args:
        include: Include patterns
        exclude: Exclude patterns
        files: Specific files
        filter_preset: Filter preset name

    Returns:
        Tuple of (filters_dict, description, variant_key)
    """
    from .shared import generate_minihash
    from .cli import get_filters  # Import here to avoid circular imports

    filters, description = get_filters(include, exclude, files, filter_preset)
    variant_key = generate_minihash(filters)
    return filters, description, variant_key


def validate_filter_args(
    include: Tuple[str, ...],
    exclude: Tuple[str, ...],
    files: Tuple[str, ...],
    filter_preset: Optional[str],
) -> None:
    """Validate that only one type of filter is specified.

    Args:
        include: Include patterns
        exclude: Exclude patterns
        files: Specific files
        filter_preset: Filter preset name

    Raises:
        ValueError: If multiple filter types are specified
    """
    filter_count = sum(bool(x) for x in [include, exclude, files, filter_preset])
    if filter_count > 1:
        raise ValueError(
            "Cannot use multiple filter options together\n\n"
            "Choose one of:\n"
            "  --include to specify patterns to download\n"
            "  --exclude to specify patterns to skip\n"
            "  --file to specify exact files\n"
            "  --filter to use a preset filter"
        )


def get_unified_repo_info(
    repo_id: str, tag_or_branch: str, lock: Optional["HugLock"] = None
) -> RepoInfo:
    """Get repo info from lock file if available, otherwise from API.

    Args:
        repo_id: Repository identifier (org/repo)
        tag_or_branch: Git tag or branch
        lock: Optional lock file instance

    Returns:
        Repository information
    """
    from .shared import get_repo_info_from_api  # Import here to avoid circular imports

    if lock and lock.has_tag_or_branch_data(repo_id, tag_or_branch):
        return lock.get_repo_info(repo_id, tag_or_branch)
    return get_repo_info_from_api(repo_id, tag_or_branch)


def ensure_parent_dir(path: Path) -> None:
    """Ensure parent directory exists for a file path.

    Args:
        path: File path whose parent should exist
    """
    path.parent.mkdir(parents=True, exist_ok=True)


def safe_json_loads(json_str: str, context: str = "JSON") -> Any:
    """Safely parse JSON with better error messages.

    Args:
        json_str: JSON string to parse
        context: Context for error messages

    Returns:
        Parsed JSON data

    Raises:
        ValueError: If JSON is invalid
    """
    try:
        return json.loads(json_str)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid {context}: {e}")
