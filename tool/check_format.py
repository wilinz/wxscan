#!/usr/bin/env python3
"""Every Dart file is `dart format` clean, at its own package's language version.

`dart format` output depends on the language version of the package the file
belongs to: the style changed in 3.7 and again in 3.8, so the same file
formatted as 3.7 and as 3.13 differs. That version normally comes from
`.dart_tool/package_config.json`, which only exists after `pub get` — and with
no package config the formatter falls back to the latest version it knows.

So `dart format --set-exit-if-changed .` on a fresh checkout disagrees with the
same command on a developer's machine, and this repository holds packages at
three different language versions (3.7, 3.10, 3.11), which no single
`--language-version` can cover either.

This groups files by the version their own pubspec declares and formats each
group at that version. Same answer as a developer with dependencies resolved,
without resolving anything.
"""

import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# `sdk: ^3.7.0` and `sdk: ">=3.10.0 <4.0.0"` both mean a 3.7 / 3.10 floor.
SDK_FLOOR = re.compile(r'^\s*sdk:\s*["\']?[\^>=]*\s*(\d+)\.(\d+)')


def language_version(pubspec: Path) -> str | None:
    """The language version a package declares, as pub would derive it."""
    inside_environment = False
    for line in pubspec.read_text().splitlines():
        if line.startswith("environment:"):
            inside_environment = True
            continue
        if inside_environment:
            # A new top-level key ends the block.
            if line and not line[0].isspace():
                break
            match = SDK_FLOOR.match(line)
            if match:
                return f"{match.group(1)}.{match.group(2)}"
    return None


def owning_pubspec(file: Path) -> Path | None:
    """The nearest pubspec above [file].

    Nearest, not outermost: `packages/wxscan_live/example` is a package inside
    a package and is on a different language version from its parent.
    """
    for directory in file.parents:
        candidate = directory / "pubspec.yaml"
        if candidate.is_file():
            return candidate
        if directory == ROOT:
            break
    return None


def main() -> int:
    by_version: dict[str, list[Path]] = defaultdict(list)
    orphans: list[Path] = []

    for file in sorted(ROOT.rglob("*.dart")):
        relative = file.relative_to(ROOT)
        # Hidden directories hold generated code and vendored copies, and are
        # what `dart format .` itself skips.
        if any(part.startswith(".") for part in relative.parts):
            continue
        if "build" in relative.parts:
            continue

        pubspec = owning_pubspec(file)
        version = language_version(pubspec) if pubspec else None
        if version is None:
            orphans.append(relative)
        else:
            by_version[version].append(file)

    if orphans:
        print("No package language version for:")
        for path in orphans:
            print(f"  {path}")
        print("Every Dart file should sit under a pubspec with an sdk floor.")
        return 1

    failed = False
    for version, files in sorted(by_version.items()):
        result = subprocess.run(
            [
                "dart",
                "format",
                "--output=none",
                "--set-exit-if-changed",
                f"--language-version={version}",
                *[str(f) for f in files],
            ],
            capture_output=True,
            text=True,
        )
        changed = [
            line[len("Changed ") :]
            for line in result.stdout.splitlines()
            if line.startswith("Changed ")
        ]
        print(f"language {version}: {len(files)} files, {len(changed)} unformatted")
        for path in changed:
            relative = Path(path).resolve().relative_to(ROOT)
            print(f"::error file={relative}::{relative} is not formatted.")
            print(f"  {relative}")
        if result.returncode != 0:
            failed = True

    if failed:
        print("\nRun `dart format .` with dependencies resolved (`pub get`), "
              "or format the files above at the language version named.")
        return 1

    print("\nEverything is formatted.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
