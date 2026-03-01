#!/usr/bin/env python3
"""Generate required secrets in a dotenv file if missing."""

from __future__ import annotations

import argparse
import secrets
from pathlib import Path


def ensure_key(env_path: Path, key: str, length: int) -> bool:
    """Ensure key exists in dotenv file. Returns True when added."""
    lines: list[str] = []
    if env_path.exists():
        lines = env_path.read_text(encoding="utf-8").splitlines()

    if any(line.startswith(f"{key}=") for line in lines):
        return False

    value = secrets.token_urlsafe(length)
    with env_path.open("a", encoding="utf-8") as handle:
        if lines and lines[-1].strip():
            handle.write("\n")
        handle.write(f"{key}={value}\n")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--env-file",
        default=".generated.env",
        help="dotenv file path (default: .generated.env)",
    )
    parser.add_argument(
        "--key",
        action="append",
        default=["CODER_PG_PASSWORD"],
        help="dotenv key to ensure exists (can be passed multiple times)",
    )
    parser.add_argument(
        "--token-length",
        type=int,
        default=24,
        help="token_urlsafe length for generated values (default: 24)",
    )
    args = parser.parse_args()

    env_path = Path(args.env_file)
    for key in args.key:
        added = ensure_key(env_path, key, args.token_length)
        if added:
            print(f"Added {key} to {env_path}")
        else:
            print(f"{key} already present in {env_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
