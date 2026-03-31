#!/usr/bin/env python3
import argparse
from collections import Counter
import json
import re
import shutil
import subprocess
import sys
from typing import Callable, TypedDict


APT_DEPENDENCY_FIELDS = {"Depends", "PreDepends"}
XBPS_VERSION_REGEX = re.compile(r"-[0-9][A-Za-z0-9.+~]*_[0-9]+$")


class Record(TypedDict):
    manager: str
    package: str
    dependency: str
    package_kind: str
    dependency_kind: str


class SummaryDependency(TypedDict):
    name: str
    kind: str


class SummaryPackage(TypedDict):
    manager: str
    package: str
    package_kind: str
    dependencies: list[SummaryDependency]


class DependencyTotal(TypedDict):
    manager: str
    dependency: str
    count: int


class ManagerTotal(TypedDict):
    manager: str
    count: int


class Summary(TypedDict):
    packages: list[SummaryPackage]
    dependency_totals: list[DependencyTotal]
    manager_totals: list[ManagerTotal]


def make_record(
    manager: str,
    package: str,
    dependency: str,
    package_kind: str = "package",
    dependency_kind: str = "package",
) -> Record:
    return {
        "manager": manager,
        "package": package,
        "dependency": dependency,
        "package_kind": package_kind,
        "dependency_kind": dependency_kind,
    }


def fail_command(cmd: list[str], exc: Exception) -> RuntimeError:
    detail = ""
    if isinstance(exc, subprocess.CalledProcessError):
        detail = (exc.stderr or "").strip()
    elif isinstance(exc, OSError):
        detail = str(exc).strip()
    return RuntimeError(
        f"command failed: {' '.join(cmd)}{': ' + detail if detail else ''}"
    )


def run_lines(cmd: list[str]) -> list[str]:
    try:
        proc = subprocess.run(cmd, check=True, text=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise fail_command(cmd, exc) from exc
    return [raw.rstrip() for raw in proc.stdout.splitlines() if raw.strip()]


def run_json(cmd: list[str]) -> dict[str, object]:
    try:
        proc = subprocess.run(cmd, check=True, text=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise fail_command(cmd, exc) from exc
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON from command: {' '.join(cmd)}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError(f"unexpected JSON payload from command: {' '.join(cmd)}")
    return payload


def parse_dependency_target(text: str) -> str | None:
    candidate = text.strip().lstrip("|").strip()
    if not candidate or candidate.startswith("<"):
        return None
    return candidate.split()[0]


def apt_extract_deps(lines: list[str], root_pkg: str) -> set[str]:
    if not lines or lines[0] != root_pkg:
        raise RuntimeError(f"unexpected apt-cache output for {root_pkg!r}")

    deps: set[str] = set()
    for line in lines[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        if not line[:1].isspace():
            deps.add(stripped)
            continue
        if ":" not in stripped:
            continue
        field, target = stripped.split(":", 1)
        if field not in APT_DEPENDENCY_FIELDS:
            continue
        dep = parse_dependency_target(target)
        if dep:
            deps.add(dep)
    return deps


def xbps_scrub_pkg(name: str) -> str:
    return XBPS_VERSION_REGEX.sub("", name.strip())


def xbps_run_scrubbed_lines(cmd: list[str]) -> list[str]:
    return [pkg for raw in run_lines(cmd) if (pkg := xbps_scrub_pkg(raw))]


def ordered_selected_overlaps(
    deps: set[str], selected: set[str], order: dict[str, int], pkg: str
) -> list[str]:
    deps.discard(pkg)
    return sorted(deps & selected, key=order.__getitem__)


def iter_selected_hits(
    manager: str,
    selected_pkgs: list[str],
    load_deps: Callable[[str], set[str]],
    empty_message: str,
) -> list[Record]:
    if not selected_pkgs:
        raise RuntimeError(empty_message)

    selected_set = set(selected_pkgs)
    selected_order = {pkg: idx for idx, pkg in enumerate(selected_pkgs)}
    hits: list[Record] = []

    for pkg in selected_pkgs:
        deps = load_deps(pkg)
        for dep_pkg in ordered_selected_overlaps(
            deps, selected_set, selected_order, pkg
        ):
            hits.append(make_record(manager, pkg, dep_pkg))

    return hits


def apt_iter_hits() -> list[Record]:
    apt_depends_prefix = [
        "apt-cache",
        "depends",
        "--recurse",
        "--no-recommends",
        "--no-suggests",
        "--no-conflicts",
        "--no-breaks",
        "--no-replaces",
        "--no-enhances",
    ]

    def load_apt_deps(pkg: str) -> set[str]:
        dep_lines = run_lines([*apt_depends_prefix, pkg])
        return apt_extract_deps(dep_lines, pkg)

    return iter_selected_hits(
        "apt",
        run_lines(["apt-mark", "showmanual"]),
        load_apt_deps,
        "apt-mark showmanual returned no packages",
    )


def xbps_iter_hits() -> list[Record]:
    xbps_depends_prefix = ["xbps-query", "-x", "--fulldeptree"]

    def load_xbps_deps(pkg: str) -> set[str]:
        return set(xbps_run_scrubbed_lines([*xbps_depends_prefix, pkg]))

    return iter_selected_hits(
        "xbps",
        xbps_run_scrubbed_lines(["xbps-query", "-m"]),
        load_xbps_deps,
        "xbps-query -m returned no packages",
    )


def pkg_iter_hits() -> list[Record]:
    def load_pkg_deps(pkg: str) -> set[str]:
        return set(run_lines(["pkg", "query", "%dn", pkg]))

    return iter_selected_hits(
        "pkg",
        run_lines(["pkg", "query", "-e", "%a = 0", "%n"]),
        load_pkg_deps,
        "pkg query returned no manually installed packages",
    )


def brew_installed_on_request(formula: dict[str, object]) -> bool:
    installed = formula.get("installed")
    if not isinstance(installed, list):
        return False
    return any(
        isinstance(item, dict) and item.get("installed_on_request")
        for item in installed
    )


def brew_runtime_dependency_names(formula: dict[str, object]) -> set[str]:
    deps: set[str] = set()
    installed_entries = formula.get("installed")
    if not isinstance(installed_entries, list):
        return deps

    for installed in installed_entries:
        if not isinstance(installed, dict):
            continue
        runtime_deps = installed.get("runtime_dependencies", [])
        if not isinstance(runtime_deps, list):
            continue
        for dep in runtime_deps:
            if not isinstance(dep, dict):
                continue
            name = dep.get("full_name") or dep.get("name")
            if name:
                deps.add(name)
    return deps


def as_name_set(value: object) -> set[str]:
    if isinstance(value, str):
        return {value}
    if isinstance(value, list):
        return {item for item in value if isinstance(item, str)}
    return set()


def brew_cask_dependency_names(cask: dict[str, object]) -> set[str]:
    depends_on = cask.get("depends_on")
    if not isinstance(depends_on, dict):
        return set()

    deps: set[str] = set()
    for key in ("formula", "formulae", "cask", "casks"):
        deps.update(as_name_set(depends_on.get(key)))
    return deps


def walk_deps(pkg: str, dep_map: dict[str, set[str]]) -> set[str]:
    seen: set[str] = set()
    stack = list(dep_map.get(pkg, ()))
    while stack:
        dep = stack.pop()
        if dep in seen:
            continue
        seen.add(dep)
        stack.extend(dep_map.get(dep, ()))
    return seen


def brew_iter_hits() -> list[Record]:
    info = run_json(["brew", "info", "--json=v2", "--installed"])
    formulae = info.get("formulae", [])
    casks = info.get("casks", [])
    if not isinstance(formulae, list) or not isinstance(casks, list):
        raise RuntimeError("unexpected brew info payload")

    manual_formulae = [
        formula["name"]
        for formula in formulae
        if isinstance(formula, dict)
        and isinstance(formula.get("name"), str)
        and brew_installed_on_request(formula)
    ]
    installed_casks = [
        cask["token"]
        for cask in casks
        if isinstance(cask, dict)
        and isinstance(cask.get("token"), str)
        and cask.get("installed")
    ]
    audit_pkgs = manual_formulae + installed_casks
    if not audit_pkgs:
        raise RuntimeError(
            "brew info --json=v2 --installed returned no auditable packages"
        )

    audit_set = set(audit_pkgs)
    audit_order = {pkg: idx for idx, pkg in enumerate(audit_pkgs)}
    formula_name_set = set(manual_formulae)
    dep_map = {
        formula["name"]: brew_runtime_dependency_names(formula)
        for formula in formulae
        if isinstance(formula, dict) and isinstance(formula.get("name"), str)
    }
    dep_map.update(
        {
            cask["token"]: brew_cask_dependency_names(cask)
            for cask in casks
            if isinstance(cask, dict) and isinstance(cask.get("token"), str)
        }
    )

    transitive_dep_cache: dict[str, set[str]] = {}

    def walk_deps_cached(pkg: str) -> set[str]:
        cached = transitive_dep_cache.get(pkg)
        if cached is not None:
            return cached
        deps = walk_deps(pkg, dep_map)
        transitive_dep_cache[pkg] = deps
        return deps

    hits: list[Record] = []
    for pkg in audit_pkgs:
        deps = walk_deps_cached(pkg)
        package_kind = "formula" if pkg in formula_name_set else "cask"
        for dep_pkg in ordered_selected_overlaps(deps, audit_set, audit_order, pkg):
            dependency_kind = "formula" if dep_pkg in formula_name_set else "cask"
            hits.append(
                make_record("brew", pkg, dep_pkg, package_kind, dependency_kind)
            )
    return hits


BACKENDS = {
    "apt": ("apt-mark", apt_iter_hits),
    "brew": ("brew", brew_iter_hits),
    "pkg": ("pkg", pkg_iter_hits),
    "xbps": ("xbps-query", xbps_iter_hits),
}


def detect_manager() -> str:
    available = [name for name, (cmd, _) in BACKENDS.items() if shutil.which(cmd)]
    if len(available) == 1:
        return available[0]
    if "brew" in available and sys.platform == "darwin":
        return "brew"
    if "apt" in available and sys.platform.startswith("linux"):
        return "apt"
    if "xbps" in available and sys.platform.startswith("linux"):
        return "xbps"
    if "pkg" in available and sys.platform.startswith("freebsd"):
        return "pkg"
    if not available:
        raise RuntimeError("no supported package manager found")
    raise RuntimeError(
        f"multiple supported package managers found: {', '.join(available)}; use --manager"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Find manually installed packages that depend on other installed packages."
    )
    parser.add_argument(
        "--manager",
        choices=("auto", "apt", "brew", "pkg", "xbps"),
        default="auto",
        help="package manager backend to use",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json", "jsonl", "json-summary", "tsv"),
        default="text",
        help="output format",
    )
    return parser.parse_args()


def build_summary(records: list[Record]) -> Summary:
    package_map: dict[tuple[str, str], SummaryPackage] = {}
    package_dependency_seen: dict[tuple[str, str], set[tuple[str, str]]] = {}
    dependency_counts: Counter[tuple[str, str]] = Counter()
    manager_counts: Counter[str] = Counter()

    for record in records:
        key = (record["manager"], record["package"])
        package_entry = package_map.setdefault(
            key,
            {
                "manager": record["manager"],
                "package": record["package"],
                "package_kind": record["package_kind"],
                "dependencies": [],
            },
        )
        dependency_seen = package_dependency_seen.setdefault(key, set())

        dependency_key = (record["dependency"], record["dependency_kind"])
        if dependency_key not in dependency_seen:
            dependency_seen.add(dependency_key)
            dependency_entry: SummaryDependency = {
                "name": record["dependency"],
                "kind": record["dependency_kind"],
            }
            package_entry["dependencies"].append(dependency_entry)

        dependency_counts[(record["manager"], record["dependency"])] += 1
        manager_counts[record["manager"]] += 1

    packages = sorted(
        package_map.values(), key=lambda item: (item["manager"], item["package"])
    )
    dependency_totals: list[DependencyTotal] = [
        {"manager": manager, "dependency": dependency, "count": count}
        for (manager, dependency), count in sorted(dependency_counts.items())
    ]
    manager_totals: list[ManagerTotal] = [
        {"manager": manager, "count": count}
        for manager, count in sorted(manager_counts.items())
    ]

    return {
        "packages": packages,
        "dependency_totals": dependency_totals,
        "manager_totals": manager_totals,
    }


def emit_records(records: list[Record], output_format: str) -> None:
    if output_format == "json":
        json.dump(records, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return

    if output_format == "json-summary":
        json.dump(build_summary(records), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return

    if output_format == "jsonl":
        for record in records:
            sys.stdout.write(json.dumps(record, sort_keys=True))
            sys.stdout.write("\n")
        return

    if output_format == "tsv":
        sys.stdout.write(
            "manager\tpackage\tdependency\tpackage_kind\tdependency_kind\n"
        )
        for record in records:
            sys.stdout.write(
                f"{record['manager']}\t{record['package']}\t{record['dependency']}\t"
                f"{record['package_kind']}\t{record['dependency_kind']}\n"
            )
        return

    for record in records:
        sys.stdout.write(f"{record['package']} depends on {record['dependency']}\n")


def main() -> int:
    args = parse_args()
    manager = detect_manager() if args.manager == "auto" else args.manager
    cmd, backend = BACKENDS[manager]
    if not shutil.which(cmd):
        raise RuntimeError(f"package manager command not found for {manager}: {cmd}")

    emit_records(backend(), args.format)
    return 0


if __name__ == "__main__":
    sys.exit(main())
