#!/usr/bin/env python3
import subprocess
import sys


def run_lines(cmd: list[str]) -> list[str]:
    try:
        out = subprocess.check_output(cmd, text=True)
    except subprocess.CalledProcessError:
        return []
    lines: list[str] = []
    for raw in out.splitlines():
        if not raw.strip():
            continue
        lines.append(raw.rstrip())
    return lines


def extract_deps(lines: list[str]) -> list[str]:
    deps: list[str] = []
    for line in lines:
        dep = line.split()[0]
        if line[:1].isspace() or (dep.startswith("<") and dep.endswith(">")):
            continue
        deps.append(dep)
    return deps


def main() -> int:
    manual_pkgs = run_lines(["apt-mark", "showmanual"])
    manual_set = set(manual_pkgs)
    manual_order = {pkg: idx for idx, pkg in enumerate(manual_pkgs)}

    for pkg in manual_pkgs:
        dep_lines = run_lines(
            [
                "apt-cache",
                "depends",
                "--recurse",
                "--no-recommends",
                "--no-suggests",
                "--no-conflicts",
                "--no-breaks",
                "--no-replaces",
                "--no-enhances",
                pkg,
            ]
        )
        deps = set(extract_deps(dep_lines))
        deps.discard(pkg)
        hits = deps & manual_set
        hits = sorted(hits, key=lambda dep: manual_order.get(dep, -1))
        for dep_pkg in hits:
            print(f"{pkg} depends on {dep_pkg}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
