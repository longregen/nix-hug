#!/usr/bin/env python3
"""Type definitions for nix-hug."""

from typing import Dict, TypedDict


class FileInfo(TypedDict):
    """Type definition for file information in a repository."""

    size: int
    lfs: bool
    hash: str


class RepoInfo(TypedDict):
    """Type definition for repository information."""

    repo_id: str
    commit: str
    tag_or_branch: str
    files: Dict[str, FileInfo]
