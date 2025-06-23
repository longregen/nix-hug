#!/usr/bin/env python3
"""CLI-specific utilities that depend on click and other CLI-only dependencies."""

import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import click

from .types import RepoInfo


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


def handle_cli_error(e: Exception, exit_code: int = 1) -> None:
    """Display error message and exit.

    Args:
        e: Exception to display
        exit_code: Exit code to use
    """
    click.echo(f"error: {e}", err=True)
    sys.exit(exit_code)


def echo_section(title: str, blank_after: bool = True) -> None:
    """Echo a section title with optional blank line.

    Args:
        title: Section title to display
        blank_after: Whether to add blank line after title
    """
    click.echo(title)
    if blank_after:
        click.echo()


def display_file_list(
    files: List[str], repo_info: Dict[str, Any], col_width: int = 30, indent: str = "  "
) -> None:
    """Display a list of files with size and LFS information.

    Args:
        files: List of file names to display
        repo_info: Repository information containing file metadata
        col_width: Column width for file names
        indent: Indentation string for each line
    """
    for file in sorted(files):
        size_str = format_table_size(repo_info["files"][file]["size"])
        lfs_str = "   [LFS]" if repo_info["files"][file]["lfs"] else ""
        click.echo(f"{indent}{file:<{col_width}} {size_str:>8}{lfs_str}")


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
            "Cannot use both --include and --exclude filters\n\n"
            "Choose either:\n"
            "  --include to specify large files to download\n"
            "  --exclude to specify large files to skip"
        )
