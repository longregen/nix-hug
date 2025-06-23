#!/usr/bin/env python3
"""Shared utilities for nix-hug to ensure consistency between components."""

import base64
import hashlib
import json
import os
import re
import fnmatch
import subprocess
from typing import Optional, Dict, Tuple, List, Any, Union
from urllib.parse import urlparse

from huggingface_hub import HfApi
from huggingface_hub.utils import RepositoryNotFoundError

from .types import FileInfo, RepoInfo


def get_repo_info_from_api(repo_id: str, tag_or_branch: str = "main") -> RepoInfo:

    try:
        api = HfApi()
        info = api.repo_info(repo_id, revision=tag_or_branch, files_metadata=True)
        return {
            "repo_id": info.id,
            "commit": info.sha,
            "tag_or_branch": tag_or_branch,
            "files": {
                f.rfilename: {
                    "size": f.size,
                    "lfs": f.lfs,
                    "hash": f.blob_id,
                }
                for f in info.siblings
            },
        }
    except RepositoryNotFoundError as e:
        raise RuntimeError(
            f'Model "{repo_id}" not found (404).\nIf this is a private or gated model, you will need a proxy to download it.\nVisit https://huggingface.co/{repo_id} to validate the URL is correct.'
        )


def sorted_object(obj: Any) -> Any:
    """Recursively sort object for consistent serialization."""
    if isinstance(obj, dict):
        return {k: sorted_object(v) for k, v in sorted(obj.items())}
    elif isinstance(obj, list):
        return sorted(sorted_object(i) for i in obj)
    else:
        return obj


def generate_minihash(filters: Optional[Dict[str, Any]]) -> str:
    """Generate deterministic identifier for filter configuration.

    This is the canonical implementation used by both Nix and Python components.
    """
    if not filters:
        return "base"
    digest = hashlib.sha256(
        json.dumps(sorted_object(filters), separators=(",", ":")).encode()
    ).digest()
    key = base64.urlsafe_b64encode(digest)[:22].decode()
    return key


def parse_repo_url(url: str) -> str:
    """Parse various URL formats into canonical org/repo format.

    Handles edge cases and sub-paths correctly.
    """
    # Remove common prefixes
    url = re.sub(r"^https?://(www\.)?huggingface\.co/", "", url)
    url = re.sub(r"^hf:", "", url)

    # Parse URL to handle sub-paths correctly
    parsed = urlparse(f"https://example.com/{url}")
    path_parts = [p for p in parsed.path.strip("/").split("/") if p]

    if len(path_parts) < 2:
        raise ValueError(f"Invalid repository URL format: {url}")

    # Check for non-model repos by exact prefix match
    if path_parts[0] == "datasets":
        raise ValueError(
            f"Only model repositories are supported, not datasets/{path_parts[1]}"
        )
    elif path_parts[0] == "spaces":
        raise ValueError(
            f"Only model repositories are supported, {path_parts[1]} is a space."
        )

    # Extract exactly org/repo (first two components)
    org = path_parts[0]
    repo = path_parts[1]

    return f"{org}/{repo}"


def format_size(size_bytes: int, table_format: bool = False) -> str:
    """Format bytes to human readable size.

    Args:
        size_bytes: Size in bytes
        table_format: If True, use fixed-width formatting for tables
    """
    if size_bytes == 0:
        return "0   B" if table_format else "0 B"

    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    for unit in units:
        if size_bytes < 1000.0:
            if unit == "B":
                return (
                    f"{int(size_bytes):>3}  B"
                    if table_format
                    else f"{size_bytes:.0f} {unit}"
                )
            else:
                format_str = (
                    f"{size_bytes:>5.1f} {unit}"
                    if table_format
                    else f"{size_bytes:.1f} {unit}"
                )
                return format_str
        size_bytes /= 1024.0
    return f"{size_bytes:.1f} {units[-1]}"


def format_table_size(size_bytes: int) -> str:
    """Format bytes to human readable size for table output."""
    return format_size(size_bytes, table_format=True)


def apply_filters(
    repo_info: RepoInfo,
    include: Optional[List[str]] = None,
    exclude: Optional[List[str]] = None,
    specific_files: Optional[List[str]] = None,
) -> Tuple[List[str], List[str], List[str]]:
    """Apply filters to file list with non-LFS override.

    Returns (included_files, excluded_files, included_anyways).
    Non-LFS files are always included regardless of filters.
    """
    all_files = list(repo_info["files"].keys())
    lfs_files_set = {f for f in all_files if repo_info["files"][f]["lfs"]}
    non_lfs_files = [f for f in all_files if f not in lfs_files_set]
    lfs_files = [f for f in all_files if f in lfs_files_set]

    if specific_files:
        return (
            [f for f in all_files if f in specific_files],
            [f for f in all_files if f not in specific_files],
            [],
        )

    if include:
        included_lfs = [
            f
            for f in lfs_files
            if any(fnmatch.fnmatch(f, pattern) for pattern in include)
        ]
        return (
            included_lfs + non_lfs_files,
            [f for f in lfs_files if f not in included_lfs],
            [
                f
                for f in non_lfs_files
                if not any(fnmatch.fnmatch(f, pattern) for pattern in include)
            ],
        )

    if exclude:
        excluded_lfs = [
            f
            for f in lfs_files
            if any(fnmatch.fnmatch(f, pattern) for pattern in exclude)
        ]
        return (
            [f for f in lfs_files if f not in excluded_lfs] + non_lfs_files,
            excluded_lfs,
            [
                f
                for f in non_lfs_files
                if any(fnmatch.fnmatch(f, pattern) for pattern in exclude)
            ],
        )

    return all_files, [], []


def check_nix_version() -> Optional[Tuple[int, int, int]]:
    """Check if Nix version is >= 2.26 for Git LFS support."""
    from .utils import run_command

    try:
        result = run_command(["nix", "--version"], check=False)
        if result.returncode != 0:
            return None

        # Parse version from output like "nix (Nix) 2.18.1"
        version_line = result.stdout.strip()
        match = re.search(r"(\d+)\.(\d+)\.(\d+)", version_line)
        if not match:
            return None

        major, minor, patch = map(int, match.groups())
        if major < 2 or (major == 2 and minor < 26):
            raise RuntimeError(format_nix_version_error((major, minor, patch)))
        return (major, minor, patch)
    except Exception:
        return None


def format_nix_version_error(current_version: Tuple[int, int, int]) -> str:
    """Format error message for old Nix version."""
    version_str = f"{current_version[0]}.{current_version[1]}.{current_version[2]}"
    return f"""error: the current version of nix is {version_str}. `nix-hug` requires at least 2.26, 
which is the first version with support for `git-lfs` (mandatory to access 
Hugging Face repositories).

There are many ways in which you can run a newer version of `nix`:

1. Run `nix-shell -p nixVersions.latest`, which is 2.28.3 since nixpkgs-25.05
2. Download the latest version from https://nixos.org/download
3. Set `nix.package = pkgs.nixVersions.latest` in your NixOS configuration."""


def build_fetch_model_expression(
    repo_url: str,
    hash_value: Optional[str] = None,
    commit: Optional[str] = None,
    tag_or_branch: Optional[str] = None,
    filters: Optional[Dict[str, Any]] = None,
) -> str:
    """Build Nix expression for fetchModel."""
    return f"""nix-hug.fetchModel {{
      url = "{repo_url}";
      hash = {f'"{hash_value}"' if hash_value else 'pkgs.lib.fakeHash'};
      {f'rev = "{commit}";' if commit else ''}
      {f'ref = "{tag_or_branch}";' if tag_or_branch and tag_or_branch != "main" else ''}
      {f'filters = {python_dict_to_nix(filters)};' if filters else ''}
    }}"""


def build_nix_expression(
    repo_url: str,
    hash_value: Optional[str] = None,
    commit: Optional[str] = None,
    tag_or_branch: Optional[str] = None,
    filters: Optional[Dict[str, Any]] = None,
    lock_file_path: Optional[str] = None,
) -> str:
    """Build Nix expression for fetchModel."""
    # Strategy for finding lib.nix:
    # 1. Check for local lib.nix (development)
    # 2. Use NIX_HUG_LIB_PATH environment variable (set by flake.nix)
    # 3. Fall back to error

    lib_path = None
    current_dir = os.getcwd()

    # Check current directory first (for development)
    if os.path.exists(os.path.join(current_dir, "lib.nix")):
        lib_path = os.path.abspath("./lib.nix")
    else:
        # Check parent directories up to 3 levels (for development)
        for i in range(3):
            parent_dir = os.path.join(current_dir, "../" * (i + 1))
            lib_candidate = os.path.join(parent_dir, "lib.nix")
            if os.path.exists(lib_candidate):
                lib_path = os.path.abspath(lib_candidate)
                break

    # If not found locally, use environment variable (set by flake.nix)
    if not lib_path:
        env_lib_path = os.environ.get("NIX_HUG_LIB_PATH")
        if env_lib_path and os.path.exists(env_lib_path):
            lib_path = env_lib_path

    if not lib_path:
        raise RuntimeError(
            "Could not find lib.nix. This usually means nix-hug is not properly installed. "
            "Try installing via: nix profile install github:longregen/nix-hug"
        )

    # Determine if we should pass lock file
    lock_file_arg = ""
    if lock_file_path and os.path.exists(lock_file_path):
        lock_file_arg = f" lockFile = {os.path.abspath(lock_file_path)};"

    return f"""
let
  pkgs = import <nixpkgs> {{}};
  nix-hug = import {lib_path} {{ inherit pkgs;{lock_file_arg} }};
in
  {build_fetch_model_expression(repo_url, hash_value, commit, tag_or_branch, filters)}
  """


def python_dict_to_nix(obj: Any) -> str:
    """Convert Python dict/list to Nix syntax."""
    if isinstance(obj, dict):
        items = []
        for k, v in obj.items():
            items.append(f"{k} = {python_dict_to_nix(v)}")
        return "{ " + "; ".join(items) + "; }"
    elif isinstance(obj, list):
        items = [python_dict_to_nix(item) for item in obj]
        return "[ " + " ".join(items) + " ]"
    elif isinstance(obj, str):
        return f'"{obj}"'
    elif isinstance(obj, bool):
        return "true" if obj else "false"
    elif isinstance(obj, (int, float)):
        return str(obj)
    else:
        return str(obj)


def extract_hash_from_nix_error(stderr: str) -> Optional[str]:
    """Extract actual hash from Nix build error."""
    for line in stderr.split("\n"):
        line = line.strip()
        if line.startswith("got:"):
            return line.split("got:")[1].strip()
    return None


def extract_store_path_from_nix_output(stdout: str, stderr: str) -> Optional[str]:
    """Extract store path from nix-build output."""
    from .config import Constants

    # First, look specifically for the builder output line (highest priority)
    for line in stderr.split("\n"):
        line = line.strip()
        match = re.search(f"Downloaded to: ({Constants.STORE_PATH_PATTERN})", line)
        if match:
            return match.group(1)

    # Second, look for successful build output in stdout
    for line in stdout.split("\n"):
        line = line.strip()
        if re.match(f"^{Constants.STORE_PATH_PATTERN}$", line):
            return line

    return None


def format_error_message(
    error_type: str, repo_url: str, details: Optional[Dict[str, str]] = None
) -> str:
    """Format user-friendly error messages."""
    if error_type == "not_found":
        token = os.environ.get("HF_TOKEN")
        if token:
            display_token = f"{token[:6]}***{token[-3:]}" if len(token) > 10 else "***"
            return f"""error: 403 unable to download {repo_url}

If this is a private or restricted repository, check that the current 
HF_TOKEN ({display_token}) corresponds to an account with access to it, or
try visiting https://huggingface.co/{repo_url}"""
        else:
            return f"""error: Model "{repo_url}" not found (404).

If this is a private or gated model, set your token:
  HF_TOKEN=hf_xxx nix-hug add {repo_url}

Try visiting https://huggingface.co/{repo_url} to validate the URL is correct."""

    elif error_type == "hash_mismatch":
        return f"""error: hash mismatch in fixed-output derivation
  specified: {details['expected']}
  got:       {details['actual']}

To update the hash, run:
  nix-hug update {repo_url}"""

    return f"error: {error_type}"
