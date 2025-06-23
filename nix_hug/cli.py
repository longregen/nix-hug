#!/usr/bin/env python3
"""nix-hug CLI - Declarative Hugging Face model management for Nix."""

import os
import sys
import subprocess
import tempfile
import logging
from pathlib import Path

import click
from huggingface_hub.utils import RepositoryNotFoundError

from .HugLock import HugLock
from .types import RepoInfo
from .config import build_nix_env, Constants
from .utils import run_command
from .cli_utils import (
    format_size,
    handle_cli_error,
    validate_filter_args,
    display_file_list,
)
from .shared import (
    parse_repo_url,
    generate_minihash,
    extract_hash_from_nix_error,
    extract_store_path_from_nix_output,
    check_nix_version,
    build_nix_expression,
    build_fetch_model_expression,
    apply_filters,
    get_repo_info_from_api,
)

# Setup logging
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=getattr(logging, log_level, logging.INFO))
logger = logging.getLogger(__name__)


@click.group()
@click.option(
    "--lock-file", default="hug.lock", type=click.Path(), help="Path to lock file"
)
@click.pass_context
def cli(ctx, lock_file):
    """nix-hug - Declarative Hugging Face model management for Nix."""
    ctx.ensure_object(dict)
    ctx.obj["lock_file"] = Path(lock_file)


def get_filters(include, exclude, files, filter_preset):
    """Get filters and description from CLI arguments."""
    # Use utility function for validation
    validate_filter_args(include, exclude, files, filter_preset)

    # Build filters
    filters = {}
    filter_description = ""

    if files:
        filters = {"files": list(files)}
        filter_description = f"Files: {list(files)}"
    elif include:
        filters = {"include": list(include)}
        filter_description = f"Filters: include={list(include)}"
    elif exclude:
        filters = {"exclude": list(exclude)}
        filter_description = f"Filters: exclude={list(exclude)}"
    elif filter_preset:
        # Use centralized filter presets
        filters = Constants.FILTER_PRESETS.get(filter_preset)
        if not filters:
            available = ", ".join(Constants.FILTER_PRESETS.keys())
            raise ValueError(
                f"Unknown filter preset: {filter_preset} (choose from {available})"
            )
        filter_description = f"with {filter_preset} filter"

    return filters, filter_description


def run_nix_build_with_tempfile(
    nix_expr: str, env: dict, stream_output: bool = True
) -> subprocess.CompletedProcess:
    """Run nix-build with a temporary file and clean up."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".nix", delete=False) as f:
        f.write(nix_expr)
        f.flush()

        try:
            if stream_output and not logger.isEnabledFor(logging.DEBUG):
                # Stream output in real-time for download progress
                process = subprocess.Popen(
                    ["nix-build", "--impure", "--no-out-link", f.name],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    env=env,
                    bufsize=1,
                    universal_newlines=True,
                )

                output_lines = []
                last_progress_line = None
                for line in process.stdout:
                    # Filter out debug lines but show download progress
                    if any(
                        keyword in line
                        for keyword in [
                            "Fetching",
                            "files:",
                            "%",
                            "MB/s",
                            "KB/s",
                            "B/s",
                        ]
                    ):
                        # Clear previous line and show current progress
                        if last_progress_line:
                            click.echo(
                                "\r" + " " * len(last_progress_line) + "\r", nl=False
                            )
                        click.echo(line.rstrip(), nl=False)
                        last_progress_line = line.rstrip()
                    output_lines.append(line)

                # Add final newline after progress is complete
                if last_progress_line:
                    click.echo()

                process.wait()

                # Create a result object similar to subprocess.run
                class StreamResult:
                    def __init__(self, returncode, stdout, stderr=""):
                        self.returncode = returncode
                        self.stdout = stdout
                        self.stderr = stderr

                return StreamResult(process.returncode, "".join(output_lines))
            else:
                # Use regular capture for debug mode or when streaming is disabled
                result = subprocess.run(
                    ["nix-build", "--impure", "--no-out-link", f.name],
                    capture_output=True,
                    text=True,
                    env=env,
                )
                return result
        finally:
            os.unlink(f.name)


def convert_nix_hash_to_sri(store_hash: str) -> str:
    """Convert nix-store hash format to SRI format."""
    if not store_hash.startswith("sha256:"):
        raise ValueError(f"Unexpected hash format: {store_hash}")

    nix_hash = store_hash[7:]  # Remove 'sha256:' prefix
    convert_result = run_command(
        ["nix", "hash", "convert", "--to", "sri", f"sha256:{nix_hash}"]
    )
    return convert_result.stdout.strip()


def get_hash_from_store_path(store_path: str) -> str:
    """Get actual hash from a store path."""
    hash_result = run_command(["nix-store", "--query", "--hash", store_path])
    store_hash = hash_result.stdout.strip()
    return convert_nix_hash_to_sri(store_hash)


def handle_successful_build(
    result: subprocess.CompletedProcess, nix_expr: str, env: dict
) -> tuple[str, str]:
    """Handle successful build case - get hash from store."""
    store_path = result.stdout.strip()

    # If no store path in stdout, try to get it by evaluating the expression again
    if not store_path:
        try:
            eval_result = run_command(
                ["nix", "eval", "--impure", "--raw", "--expr", f"({nix_expr}).outPath"],
                env=env,
                check=False,
            )
            if eval_result.returncode == 0:
                store_path = eval_result.stdout.strip()
        except Exception:
            pass

    if not store_path:
        raise Exception("Could not determine store path")

    actual_hash = get_hash_from_store_path(store_path)
    return actual_hash, store_path


def handle_hash_mismatch(
    result: subprocess.CompletedProcess,
    repo_url: str,
    commit: str,
    tag_or_branch: str,
    filters: dict,
    lock_file_path: str,
    env: dict,
) -> tuple[str, str]:
    """Handle hash mismatch case - extract hash and rebuild with correct hash."""
    # Try stderr first, then stdout (for streaming output)
    actual_hash = extract_hash_from_nix_error(result.stderr or result.stdout)
    if not actual_hash:
        raise Exception("Failed to extract hash from nix-build output")

    # Build again with the correct hash to get permanent store path
    click.echo(f"Hash: {actual_hash}")
    nix_expr_correct = build_nix_expression(
        repo_url=repo_url,
        hash_value=actual_hash,
        commit=commit,
        tag_or_branch=tag_or_branch,
        filters=filters,
        lock_file_path=lock_file_path,
    )

    result2 = run_nix_build_with_tempfile(nix_expr_correct, env)

    if result2.returncode == 0:
        store_path = result2.stdout.strip()
    else:
        # Fallback to extracting from first build
        store_path = extract_store_path_from_nix_output(result.stdout, result.stderr)
        if not store_path:
            store_path = "Nix store (path not found in output)"

    return actual_hash, store_path


def run_nix_build_for_hash(
    nix_expr: str,
    env: dict,
    repo_url: str,
    commit: str,
    tag_or_branch: str,
    filters: dict,
    lock_file_path: str,
) -> tuple[str, str]:
    """Run nix-build and return (actual_hash, store_path)."""
    result = run_nix_build_with_tempfile(nix_expr, env)

    # Show the build output only in debug mode
    if logger.isEnabledFor(logging.DEBUG):
        click.echo("🔍 Build output (stderr):")
        click.echo(result.stderr if result.stderr else "(empty)")
        click.echo("🔍 Build output (stdout):")
        click.echo(result.stdout if result.stdout else "(empty)")

    if result.returncode == 0:
        # Successful build - this can happen when using builtins.fetchGit without filters
        actual_hash, store_path = handle_successful_build(result, nix_expr, env)
        click.echo(f"Downloaded to {store_path}")
        return actual_hash, store_path

    elif "hash mismatch" in (result.stderr or result.stdout):
        # Expected case - extract the actual hash (could be in stdout due to streaming)
        actual_hash, store_path = handle_hash_mismatch(
            result, repo_url, commit, tag_or_branch, filters, lock_file_path, env
        )
        click.echo(f"Downloaded to {store_path}")
        return actual_hash, store_path

    else:
        click.echo("error: Unexpected nix-build result", err=True)
        click.echo(result.stderr or result.stdout, err=True)
        sys.exit(1)


def fetch_model_with_nix(
    repo_url: str,
    repo_info: dict,
    filters: dict,
    tag_or_branch: str,
    lock_file_path: str = None,
    save_to_lock: bool = False,
) -> tuple[str, str]:
    """Shared function to fetch a model using Nix and optionally save to lock file."""
    variant_key = generate_minihash(filters)

    # Build the model with Nix to get the hash
    nix_expr = build_nix_expression(
        repo_url=repo_url,
        commit=repo_info["commit"],
        tag_or_branch=tag_or_branch or repo_info["tag_or_branch"],
        filters=filters,
        lock_file_path=lock_file_path,
    )

    env = build_nix_env(
        repo_url=repo_url,
        tag_or_branch=tag_or_branch,
        filters=filters,
        lock_file_path=lock_file_path,
        variant_key=variant_key,
        log_level=log_level,
    )

    # Debug: print the filters environment variable
    if logger.isEnabledFor(logging.DEBUG):
        click.echo(
            f"🔍 NIX_HUG_FILTERS env var: '{env.get('NIX_HUG_FILTERS', 'NOT_SET')}'"
        )
        click.echo(f"🔍 filters dict: {filters}")

    actual_hash, store_path = run_nix_build_for_hash(
        nix_expr=nix_expr,
        env=env,
        repo_url=repo_url,
        commit=repo_info["commit"],
        tag_or_branch=tag_or_branch or repo_info["tag_or_branch"],
        filters=filters,
        lock_file_path=lock_file_path or "",
    )

    if save_to_lock and lock_file_path:
        lock = HugLock(Path(lock_file_path))
        lock.add_variant(
            repo_url=repo_url,
            variant_key=variant_key,
            hash_value=actual_hash,
            commit=repo_info["commit"],
            tag_or_branch=tag_or_branch or "main",
            filters=filters,
            repo_files=repo_info["files"],
            store_path=store_path,
        )
        lock.save()

    return actual_hash, store_path, variant_key


def check_for_updates(
    repo_url: str, lock: HugLock, variant_key: str, update: bool = False
):
    existing = lock.get_repo_info(repo_url)
    if not existing:
        return

    # Check if this specific variant already exists
    existing_variant = lock.get_variant(repo_url, variant_key)
    if existing_variant and not update:
        click.echo(f"Variant '{variant_key}' for {repo_url} already exists in hug.lock")
        click.echo(f"Hash: {existing_variant['hash']}")
        click.echo(f"Store path: {existing_variant.get('storePath', 'N/A')}")
        click.echo("Use --update to update this variant")
        sys.exit(0)

    new_info = get_repo_info_from_api(repo_url, existing["tag_or_branch"])
    if update:
        click.echo(f"Model {repo_url} already in hug.lock")
        click.echo(f"Current commit: {existing['commit']}")
        click.echo("Checking for updates...")

        current_commit = existing["commit"]
        latest_commit = new_info["commit"]

        if current_commit == latest_commit:
            click.echo("No updates available.")
            sys.exit(0)
        else:
            click.echo(f"New commit available: {latest_commit}")
            lock.add_repo_info(repo_url, new_info, update_refs=True)
            click.echo("Updating...")


def retrieve_from_lock_or_api(
    repo_url, tag_or_branch, lock, variant_key, update, filter_description
):
    repo_info = None

    if lock and lock.has_tag_or_branch_data(repo_url, tag_or_branch):
        check_for_updates(repo_url, lock, variant_key, update)
        repo_info = lock.get_repo_info(repo_url, tag_or_branch)

    if not repo_info or not repo_info.get("files"):
        click.echo(f"Fetching {repo_url} info...")
        if filter_description:
            click.echo(f"  {filter_description}")
        try:
            repo_info = get_repo_info_from_api(repo_url, tag_or_branch)
            lock.add_repo_info(repo_url, repo_info)
        except RuntimeError as e:
            raise e  # Re-raise to be caught by the main exception handler
    return repo_info


@cli.command()
@click.argument("url")
@click.option("--update", is_flag=True, help="Update existing model")
@click.option("--include", multiple=True, help="Include file patterns")
@click.option("--exclude", multiple=True, help="Exclude file patterns")
@click.option("--file", "files", multiple=True, help="Specific files to download")
@click.option(
    "--filter", "filter_preset", help="Use filter preset (safetensors, onnx, pytorch)"
)
@click.option("--tag-or-branch", help="Git tag or branch", default="main")
@click.pass_context
def add(ctx, url, update, include, exclude, files, filter_preset, tag_or_branch):
    """Add model to lock file."""
    try:
        check_nix_version()
        repo_url = parse_repo_url(url)
        filters, filter_description = get_filters(
            include, exclude, files, filter_preset
        )
        variant_key = generate_minihash(filters)
        lock = HugLock(ctx.obj["lock_file"])
        repo_info = retrieve_from_lock_or_api(
            repo_url, tag_or_branch, lock, variant_key, update, filter_description
        )
    except (RuntimeError, ValueError) as e:
        handle_cli_error(e)

    try:
        actual_hash, store_path, variant_key = fetch_model_with_nix(
            repo_url=repo_url,
            repo_info=repo_info,
            filters=filters,
            tag_or_branch=tag_or_branch,
            lock_file_path=str(ctx.obj["lock_file"]),
            save_to_lock=True,
        )

        # Use "base" for no filters, otherwise use the generated key
        display_variant = "base" if not filters else variant_key
        click.echo(
            f'Added variant "{display_variant}" to hug.lock with hash {actual_hash}'
        )

    except (RuntimeError, ValueError, Exception) as e:
        handle_cli_error(e)


@cli.command()
@click.argument("url")
@click.option("--include", multiple=True, help="Include file patterns")
@click.option("--exclude", multiple=True, help="Exclude file patterns")
@click.option("--filter", "filter_preset", help="Use filter preset")
@click.pass_context
def ls(ctx, url, include, exclude, filter_preset):
    """List repository contents."""
    try:
        repo_url = parse_repo_url(url)
        repo_info = get_repo_info_from_api(repo_url, "main")
    except (RuntimeError, ValueError) as e:
        handle_cli_error(e)

    # Apply filters if specified
    filters_dict = {}
    if include:
        filters_dict = {"include": list(include)}
    elif exclude:
        filters_dict = {"exclude": list(exclude)}
    elif filter_preset:
        filters_dict = Constants.FILTER_PRESETS.get(filter_preset, {})

    if filters_dict:
        included_files, excluded_files, non_lfs_override = apply_filters(
            repo_info, **filters_dict
        )

        display_filtered_files(
            repo_url,
            repo_info,
            included_files,
            excluded_files,
            non_lfs_override,
        )
    else:
        # No filters - show all files
        all_files = list(repo_info["files"].keys())
        total_size = sum(repo_info["files"][f]["size"] for f in all_files)
        lfs_files = [f for f in all_files if repo_info["files"][f]["lfs"]]
        lfs_size = sum(repo_info["files"][f]["size"] for f in lfs_files)

        click.echo(f"Files in {repo_url}:")
        display_file_list(all_files, repo_info)

        click.echo()
        if lfs_files:
            click.echo(
                f"Total: {format_size(total_size)} ({len(lfs_files)} LFS files: {format_size(lfs_size)})"
            )
        else:
            click.echo(f"Total: {format_size(total_size)}")


@cli.command()
@click.argument("url")
@click.pass_context
def update(ctx, url):
    """Update specific model (alias for add --update)."""
    ctx.invoke(add, url=url, update=True)


@cli.command()
@click.argument("url")
@click.option("--include", multiple=True, help="Include file patterns")
@click.option("--exclude", multiple=True, help="Exclude file patterns")
@click.option("--file", "files", multiple=True, help="Specific files to download")
@click.option("--filter", "filter_preset", help="Use filter preset")
@click.option("--tag-or-branch", help="Git tag or branch", default="main")
@click.pass_context
def fetch(ctx, url, include, exclude, files, filter_preset, tag_or_branch):
    """Fetch without updating lock file."""
    check_nix_version()
    repo_url = parse_repo_url(url)
    filters, filter_description = get_filters(include, exclude, files, filter_preset)

    click.echo(f"Fetching {repo_url}...")
    if filter_description:
        click.echo(f"  {filter_description}")

    repo_info = get_repo_info_from_api(repo_url, tag_or_branch)

    try:
        actual_hash, store_path, variant_key = fetch_model_with_nix(
            repo_url=repo_url,
            repo_info=repo_info,
            filters=filters,
            tag_or_branch=tag_or_branch,
            lock_file_path=None,  # Don't save to lock file
            save_to_lock=False,
        )

        # Show complete usage information as per cli.md
        click.echo("Usage:")
        click.echo(
            f"  {build_fetch_model_expression(
            repo_url=repo_url,
            hash_value=actual_hash,
            commit=repo_info['commit'],
            tag_or_branch=tag_or_branch or repo_info['tag_or_branch'],
            filters=filters
        )}"
        )

    except Exception as e:
        handle_cli_error(e)


@cli.command()
@click.argument("url")
@click.pass_context
def variants(ctx, url):
    """List variants for a repository."""
    repo_url = parse_repo_url(url)

    # Load lock file
    lock = HugLock(ctx.obj["lock_file"])
    variants = lock.list_variants(repo_url)

    if not variants:
        click.echo(f"No variants found for {repo_url} in {ctx.obj['lock_file']}")
        sys.exit(0)

    click.echo(f"Variants for {repo_url} in {ctx.obj['lock_file']}:")
    click.echo()

    for variant_key, variant_data in variants.items():
        if variant_key == "base":
            click.echo("base:")
            click.echo(f"  Hash: {variant_data['hash']}")
            click.echo(f"  Rev: {variant_data['commit']}")
            click.echo(f"  Ref: {variant_data['tag_or_branch']}")
            click.echo("  Files: All files")
            click.echo(f"  Store Path: {variant_data.get('storePath', 'N/A')}")
        else:
            filters = variant_data.get("filters", {})
            click.echo(f"{variant_key}:")
            click.echo(f"  Hash: {variant_data['hash']}")
            click.echo(f"  Rev: {variant_data['commit']}")
            click.echo(f"  Ref: {variant_data['tag_or_branch']}")

            if "files" in filters:
                click.echo(f"  Files: {filters['files']}")
            elif "include" in filters:
                click.echo(f"  Filters: include={filters['include']}")
                # Show descriptive files format as per cli.md
                if variant_data.get("filtered_files"):
                    main_files = [
                        f
                        for f in variant_data["filtered_files"]
                        if any(
                            f.endswith(ext.replace("*", ""))
                            for ext in filters["include"]
                        )
                    ]
                    auto_files = len(variant_data["filtered_files"]) - len(main_files)
                    if main_files and auto_files > 0:
                        click.echo(
                            f"  Files: {', '.join(main_files)} + {auto_files} auto-included files"
                        )
                    else:
                        click.echo(
                            f"  Files: {len(variant_data['filtered_files'])} files"
                        )
            elif "exclude" in filters:
                click.echo(f"  Filters: exclude={filters['exclude']}")

            click.echo(f"  Store Path: {variant_data.get('storePath', 'N/A')}")

        click.echo()


def display_filtered_files(
    repo_url: str,
    repo_info: RepoInfo,
    included_files: list,
    excluded_files: list,
    included_anyway: list,
):
    """Display filtered file listing with proper formatting."""
    all_files = list(repo_info["files"].keys())
    max_filename_len = max(len(f) for f in all_files) if all_files else 30
    col_width = max(30, max_filename_len + 2)

    # Separate explicitly matched files from auto-included files
    explicitly_matched = [f for f in included_files if f not in included_anyway]
    auto_included = included_anyway

    total_included_size = sum(repo_info["files"][f]["size"] for f in included_files)
    excluded_size = sum(repo_info["files"][f]["size"] for f in excluded_files)

    click.echo(f"Files in {repo_url} (filtered):")
    click.echo()

    click.echo(
        f"Included ({len(included_files)} file{'s' if len(included_files) != 1 else ''}, {format_size(total_included_size)}):"
    )

    if explicitly_matched:
        explicit_size = sum(repo_info["files"][f]["size"] for f in explicitly_matched)
        click.echo(
            f"  Explicitly ({len(explicitly_matched)} file{'s' if len(explicitly_matched) != 1 else ''}, {format_size(explicit_size)}):"
        )
        display_file_list(explicitly_matched, repo_info, col_width, "    ")

    if auto_included:
        auto_size = sum(repo_info["files"][f]["size"] for f in auto_included)
        click.echo(
            f"  Automatically ({len(auto_included)} file{'s' if len(auto_included) != 1 else ''}, {format_size(auto_size)}):"
        )
        display_file_list(auto_included, repo_info, col_width, "    ")

    if excluded_files:
        click.echo()
        click.echo(
            f"Excluded ({len(excluded_files)} file{'s' if len(excluded_files) != 1 else ''}, {format_size(excluded_size)}):"
        )
        display_file_list(excluded_files, repo_info, col_width, "    ")


def main():
    """Main entry point for the CLI."""
    cli()


if __name__ == "__main__":
    main()
