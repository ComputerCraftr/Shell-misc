#!/usr/bin/env python3
import re
import subprocess
import sys

VERSION_REGEX = re.compile(r"-[0-9][A-Za-z0-9.+~]*_[0-9]+$")


def scrub_pkg(name: str) -> str:
    return VERSION_REGEX.sub("", name.strip())


def run_scrubbed_lines(cmd: list[str]) -> list[str]:
    try:
        out = subprocess.check_output(cmd, text=True)
    except subprocess.CalledProcessError:
        return []
    lines: list[str] = []
    for raw in out.splitlines():
        pkg = scrub_pkg(raw)
        if pkg:
            lines.append(pkg)
    return lines


def main() -> int:
    manual_pkgs = run_scrubbed_lines(["xbps-query", "-m"])
    manual_set = set(manual_pkgs)
    manual_order = {pkg: idx for idx, pkg in enumerate(manual_pkgs)}

    for pkg in manual_pkgs:
        deps = set(run_scrubbed_lines(["xbps-query", "-x", "--fulldeptree", pkg]))
        deps.discard(pkg)
        hits = deps & manual_set
        hits = sorted(hits, key=lambda dep: manual_order.get(dep, -1))
        for dep_pkg in hits:
            print(f"{pkg} depends on {dep_pkg}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
