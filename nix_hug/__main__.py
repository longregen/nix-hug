#!/usr/bin/env python3
"""Entry point for nix-hug when run as a module."""

from .cli import cli

if __name__ == "__main__":
    cli()
