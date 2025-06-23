import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Tuple, Optional, Any

from .types import FileInfo, RepoInfo


class HugLock:
    """Lock file management."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.data = self._load()

    def _load(self) -> Dict[str, Any]:
        if not self.path.exists():
            return {"version": 1, "models": {}}

        try:
            with open(self.path) as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            raise ValueError(f"Invalid lock file {self.path}: {e}")

    def save(self) -> None:
        """Save lock file atomically."""
        from .utils import atomic_write_json
        from .shared import sorted_object

        # Use sorted_object for consistent serialization
        atomic_write_json(self.path, sorted_object(self.data), sorted_keys=True)

    def add_variant(
        self,
        repo_url: str,
        variant_key: str,
        hash_value: str,
        commit: str,
        tag_or_branch: str = "main",
        filters: Optional[Dict[str, Any]] = None,
        repo_files: Optional[Dict[str, FileInfo]] = None,
        store_path: Optional[str] = None,
    ) -> None:
        """Add or update a model variant."""
        if repo_url not in self.data["models"]:
            self.data["models"][repo_url] = {
                "repo": {"snapshots": {}, "refs": {}},
                "variants": {},
            }

        repo_data = self.data["models"][repo_url]

        # Ensure repo structure exists with correct format
        if "repo" not in repo_data:
            repo_data["repo"] = {"snapshots": {}, "refs": {}}
        if "snapshots" not in repo_data["repo"]:
            repo_data["repo"]["snapshots"] = {}
        if "refs" not in repo_data["repo"]:
            repo_data["repo"]["refs"] = {}
        if "variants" not in repo_data:
            repo_data["variants"] = {}

        # Update timestamps
        current_time = datetime.now(timezone.utc).isoformat() + "Z"

        # Update refs mapping (tag_or_branch -> commit)
        repo_data["repo"]["refs"][tag_or_branch] = commit

        # Add/update snapshot info (store all repo files here, indexed by commit)
        if commit not in repo_data["repo"]["snapshots"]:
            repo_data["repo"]["snapshots"][commit] = {
                "lastUpdated": current_time,
                "repo_files": repo_files or {},
            }
        elif repo_files:
            # Update repo_files if provided
            repo_data["repo"]["snapshots"][commit]["repo_files"] = repo_files
            repo_data["repo"]["snapshots"][commit]["lastUpdated"] = current_time

        if repo_files and filters:
            from .shared import apply_filters

            repo_info = {"files": repo_files}
            filtered_files, _, _ = apply_filters(repo_info, **filters)
        else:
            filtered_files = list(repo_files.keys()) if repo_files else []

        # Update repo-level lastUpdated
        repo_data["repo"]["lastUpdated"] = current_time

        # Add/update variant
        variant = {
            "hash": hash_value,
            "commit": commit,
            "tag_or_branch": tag_or_branch,
            "lastUpdated": current_time,
            "filtered_files": filtered_files,
        }

        if filters:
            variant["filters"] = filters

        if store_path:
            variant["storePath"] = store_path

        repo_data["variants"][variant_key] = variant

    def get_variant(self, repo_url: str, variant_key: str) -> Optional[Dict[str, Any]]:
        """Get variant data."""
        repo_data = self.data.get("models", {}).get(repo_url, {})
        return repo_data.get("variants", {}).get(variant_key)

    def has_tag_or_branch_data(self, repo_url: str, tag_or_branch: str) -> bool:
        """Check if a tag_or_branch exists for a repository."""
        return self.get_tag_or_branch_data(repo_url, tag_or_branch) is not None

    def get_tag_or_branch_data(
        self, repo_url: str, tag_or_branch: str
    ) -> Optional[Dict[str, Any]]:
        """Get tag_or_branch data."""
        repo_data = self.data.get("models", {}).get(repo_url, {})
        commit = repo_data.get("repo", {}).get("refs", {}).get(tag_or_branch)
        return repo_data.get("repo", {}).get("snapshots", {}).get(commit)

    def list_variants(self, repo_url: str) -> Dict[str, Dict[str, Any]]:
        """List all variants for a repository."""
        repo_data = self.data.get("models", {}).get(repo_url, {})
        return repo_data.get("variants", {})

    def get_variants_by_repo_commit(
        self, repo_url: str, commit: str
    ) -> List[Tuple[str, Dict[str, Any]]]:
        """Get all variants for a repo with matching commit that have storePath."""
        variants = self.list_variants(repo_url)
        matching_variants = []

        for variant_key, variant_data in variants.items():
            if (
                variant_data.get("commit") == commit
                and variant_data.get("storePath")
                and Path(variant_data["storePath"]).exists()
            ):
                matching_variants.append((variant_key, variant_data))

        return matching_variants

    def get_repo_files(self, repo_url: str, tag_or_branch: str) -> Dict[str, Any]:
        """Get repo_files for a specific tag_or_branch."""
        repo_data = self.data.get("models", {}).get(repo_url, {})
        commit = repo_data.get("repo", {}).get("refs", {}).get(tag_or_branch, "main")
        return (
            repo_data.get("repo", {})
            .get("snapshots", {})
            .get(commit, {})
            .get("repo_files", {})
        )

    def add_repo_info(
        self, repo_url: str, repo_info: RepoInfo, update_refs: bool = True
    ) -> None:
        """Add repo info to lock file."""
        if repo_url not in self.data["models"]:
            self.data["models"][repo_url] = {
                "repo": {"snapshots": {}, "refs": {}},
                "variants": {},
            }
        commit = repo_info["commit"]
        tag_or_branch = repo_info["tag_or_branch"]
        if update_refs:
            self.data["models"][repo_url]["repo"]["refs"][tag_or_branch] = commit
        self.data["models"][repo_url]["repo"]["snapshots"][commit] = repo_info

    def get_repo_info(self, repo_id: str, tag_or_branch: str = "main") -> RepoInfo:
        repo_data = self.data.get("models", {}).get(repo_id, {})
        commit = repo_data.get("repo", {}).get("refs", {}).get(tag_or_branch, "main")
        snapshot = repo_data.get("repo", {}).get("snapshots", {}).get(commit, {})
        return {
            "repo_id": repo_id,
            "commit": commit,
            "tag_or_branch": tag_or_branch,
            "files": {
                file: {
                    "size": data.get("size", 0),
                    "lfs": data.get("lfs", False),
                    "hash": data.get("hash", ""),
                }
                for file, data in snapshot.get("files", {}).items()
            },
        }
