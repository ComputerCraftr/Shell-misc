import importlib.util
from pathlib import Path
import runpy
import subprocess
import sys
from types import ModuleType

from pytest import CaptureFixture, MonkeyPatch


MODULE_PATH = Path(__file__).resolve().parents[1] / "packages" / "dependency_dupes.py"


def load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("deps_dupes", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deps_dupes = load_module()


def test_fail_command_includes_stderr() -> None:
    exc = subprocess.CalledProcessError(1, ["demo"], stderr="boom\n")
    err = deps_dupes.fail_command(["demo"], exc)

    assert str(err) == "command failed: demo: boom"

    os_err = deps_dupes.fail_command(["demo"], OSError("missing binary"))
    assert str(os_err) == "command failed: demo: missing binary"


def test_run_lines_filters_blanks_and_raises_on_failure(
    monkeypatch: MonkeyPatch,
) -> None:
    class Proc:
        stdout = "a\n\nb \n"

    monkeypatch.setattr(deps_dupes.subprocess, "run", lambda *args, **kwargs: Proc())
    assert deps_dupes.run_lines(["demo"]) == ["a", "b"]

    def raise_called_process_error(*args: object, **kwargs: object) -> object:
        raise subprocess.CalledProcessError(1, ["demo"], stderr="nope")

    monkeypatch.setattr(deps_dupes.subprocess, "run", raise_called_process_error)
    try:
        deps_dupes.run_lines(["demo"])
    except RuntimeError as exc:
        assert str(exc) == "command failed: demo: nope"
    else:
        raise AssertionError("expected RuntimeError")


def test_run_json_validates_payload(monkeypatch: MonkeyPatch) -> None:
    class Proc:
        def __init__(self, stdout: str) -> None:
            self.stdout = stdout

    monkeypatch.setattr(
        deps_dupes.subprocess, "run", lambda *args, **kwargs: Proc('{"ok": true}')
    )
    assert deps_dupes.run_json(["demo"]) == {"ok": True}

    monkeypatch.setattr(
        deps_dupes.subprocess, "run", lambda *args, **kwargs: Proc("[]")
    )
    try:
        deps_dupes.run_json(["demo"])
    except RuntimeError as exc:
        assert str(exc) == "unexpected JSON payload from command: demo"
    else:
        raise AssertionError("expected RuntimeError")

    monkeypatch.setattr(
        deps_dupes.subprocess, "run", lambda *args, **kwargs: Proc("not-json")
    )
    try:
        deps_dupes.run_json(["demo"])
    except RuntimeError as exc:
        assert str(exc) == "invalid JSON from command: demo"
    else:
        raise AssertionError("expected RuntimeError")

    def raise_os_error(*args: object, **kwargs: object) -> object:
        raise OSError("missing")

    monkeypatch.setattr(deps_dupes.subprocess, "run", raise_os_error)
    try:
        deps_dupes.run_json(["demo"])
    except RuntimeError as exc:
        assert str(exc) == "command failed: demo: missing"
    else:
        raise AssertionError("expected RuntimeError")


def test_apt_extract_deps_parses_relationship_lines_and_recursive_nodes() -> None:
    lines = [
        "rootpkg",
        "  Depends: dep1",
        "  PreDepends: dep2",
        " |Depends: dep3",
        "  Suggests: ignored",
        "dep4",
        "  Depends: <virtual>",
    ]

    assert deps_dupes.apt_extract_deps(lines, "rootpkg") == {"dep1", "dep2", "dep4"}


def test_apt_extract_deps_skips_blank_virtual_and_malformed_lines() -> None:
    lines = [
        "rootpkg",
        "",
        "  ",
        "  Depends: <virtual>",
        "  malformed",
        "dep1",
    ]

    assert deps_dupes.apt_extract_deps(lines, "rootpkg") == {"dep1"}


def test_apt_extract_deps_rejects_unexpected_root() -> None:
    try:
        deps_dupes.apt_extract_deps(["wrong"], "rootpkg")
    except RuntimeError as exc:
        assert str(exc) == "unexpected apt-cache output for 'rootpkg'"
    else:
        raise AssertionError("expected RuntimeError")


def test_apt_iter_hits_uses_manual_order(monkeypatch: MonkeyPatch) -> None:
    responses = {
        ("apt-mark", "showmanual"): ["alpha", "beta", "gamma"],
        (
            "apt-cache",
            "depends",
            "--recurse",
            "--no-recommends",
            "--no-suggests",
            "--no-conflicts",
            "--no-breaks",
            "--no-replaces",
            "--no-enhances",
            "alpha",
        ): ["alpha", "  Depends: gamma", "beta"],
        (
            "apt-cache",
            "depends",
            "--recurse",
            "--no-recommends",
            "--no-suggests",
            "--no-conflicts",
            "--no-breaks",
            "--no-replaces",
            "--no-enhances",
            "beta",
        ): ["beta"],
        (
            "apt-cache",
            "depends",
            "--recurse",
            "--no-recommends",
            "--no-suggests",
            "--no-conflicts",
            "--no-breaks",
            "--no-replaces",
            "--no-enhances",
            "gamma",
        ): ["gamma", "  Depends: beta"],
    }
    monkeypatch.setattr(deps_dupes, "run_lines", lambda cmd: responses[tuple(cmd)])

    assert deps_dupes.apt_iter_hits() == [
        deps_dupes.make_record("apt", "alpha", "beta"),
        deps_dupes.make_record("apt", "alpha", "gamma"),
        deps_dupes.make_record("apt", "gamma", "beta"),
    ]


def test_apt_iter_hits_rejects_empty_manual_list(monkeypatch: MonkeyPatch) -> None:
    monkeypatch.setattr(deps_dupes, "run_lines", lambda cmd: [])
    try:
        deps_dupes.apt_iter_hits()
    except RuntimeError as exc:
        assert str(exc) == "apt-mark showmanual returned no packages"
    else:
        raise AssertionError("expected RuntimeError")


def test_xbps_helpers_and_iter_hits_use_real_void_version_shapes(
    monkeypatch: MonkeyPatch,
) -> None:
    assert deps_dupes.xbps_scrub_pkg("7zip-26.00_1") == "7zip"
    assert deps_dupes.xbps_scrub_pkg("linux6.12-6.12.77_1") == "linux6.12"
    assert deps_dupes.xbps_scrub_pkg("cross-i686-linux-musl-0.37_4") == (
        "cross-i686-linux-musl"
    )
    assert deps_dupes.xbps_scrub_pkg("ca-certificates-20250419+3.121_1") == (
        "ca-certificates"
    )
    assert deps_dupes.xbps_scrub_pkg("sudo-1.9.17p1_1") == "sudo"
    assert deps_dupes.xbps_scrub_pkg("libstdc++-14.2.1+20250405_4") == "libstdc++"
    assert deps_dupes.xbps_scrub_pkg("plain") == "plain"

    responses = {
        ("xbps-query", "-m"): [
            "7zip-26.00_1",
            "base-system-0.114_2",
            "ca-certificates-20250419+3.121_1",
        ],
        ("xbps-query", "-x", "--fulldeptree", "7zip"): [
            "libstdc++-14.2.1+20250405_4",
            "libgcc-14.2.1+20250405_4",
            "glibc-2.41_1",
            "ca-certificates-20250419+3.121_1",
            "7zip-26.00_1",
        ],
        ("xbps-query", "-x", "--fulldeptree", "base-system"): [
            "linux-6.12_1",
            "ca-certificates-20250419+3.121_1",
            "base-system-0.114_2",
        ],
        ("xbps-query", "-x", "--fulldeptree", "ca-certificates"): [],
    }
    monkeypatch.setattr(deps_dupes, "run_lines", lambda cmd: responses[tuple(cmd)])

    assert deps_dupes.xbps_run_scrubbed_lines(["xbps-query", "-m"]) == [
        "7zip",
        "base-system",
        "ca-certificates",
    ]
    assert deps_dupes.xbps_iter_hits() == [
        deps_dupes.make_record("xbps", "7zip", "ca-certificates"),
        deps_dupes.make_record("xbps", "base-system", "ca-certificates"),
    ]


def test_xbps_iter_hits_rejects_empty_manual_list(monkeypatch: MonkeyPatch) -> None:
    monkeypatch.setattr(deps_dupes, "run_lines", lambda cmd: [])
    try:
        deps_dupes.xbps_iter_hits()
    except RuntimeError as exc:
        assert str(exc) == "xbps-query -m returned no packages"
    else:
        raise AssertionError("expected RuntimeError")


def test_xbps_iter_hits_sorts_by_manual_package_order_not_set_order(
    monkeypatch: MonkeyPatch,
) -> None:
    responses = {
        ("xbps-query", "-m"): [
            "ca-certificates-20250419+3.121_1",
            "base-system-0.114_2",
            "7zip-26.00_1",
        ],
        ("xbps-query", "-x", "--fulldeptree", "ca-certificates"): [],
        ("xbps-query", "-x", "--fulldeptree", "base-system"): [
            "7zip-26.00_1",
            "ca-certificates-20250419+3.121_1",
        ],
        ("xbps-query", "-x", "--fulldeptree", "7zip"): [],
    }
    monkeypatch.setattr(deps_dupes, "run_lines", lambda cmd: responses[tuple(cmd)])

    assert deps_dupes.xbps_iter_hits() == [
        deps_dupes.make_record("xbps", "base-system", "ca-certificates"),
        deps_dupes.make_record("xbps", "base-system", "7zip"),
    ]


def test_brew_iter_hits_includes_formula_and_cask_dependencies(
    monkeypatch: MonkeyPatch,
) -> None:
    payload = {
        "formulae": [
            {
                "name": "alpha",
                "installed": [
                    {
                        "installed_on_request": True,
                        "runtime_dependencies": [{"full_name": "beta"}],
                    }
                ],
            },
            {
                "name": "beta",
                "installed": [
                    {
                        "installed_on_request": True,
                        "runtime_dependencies": [],
                    }
                ],
            },
            {
                "name": "gamma",
                "installed": [
                    {
                        "installed_on_request": False,
                        "runtime_dependencies": [],
                    }
                ],
            },
        ],
        "casks": [
            {
                "token": "visualizer",
                "installed": "1.0",
                "depends_on": {"formula": "beta", "cask": "helper-app"},
            },
            {
                "token": "helper-app",
                "installed": "1.0",
                "depends_on": {"macos": {">=": ["14"]}},
            },
        ],
    }
    monkeypatch.setattr(deps_dupes, "run_json", lambda cmd: payload)

    assert deps_dupes.brew_iter_hits() == [
        {
            "manager": "brew",
            "package": "alpha",
            "dependency": "beta",
            "package_kind": "formula",
            "dependency_kind": "formula",
        },
        {
            "manager": "brew",
            "package": "visualizer",
            "dependency": "beta",
            "package_kind": "cask",
            "dependency_kind": "formula",
        },
        {
            "manager": "brew",
            "package": "visualizer",
            "dependency": "helper-app",
            "package_kind": "cask",
            "dependency_kind": "cask",
        },
    ]


def test_brew_helpers_cover_non_list_shapes() -> None:
    assert deps_dupes.brew_installed_on_request({"installed": "bad"}) is False
    assert deps_dupes.brew_runtime_dependency_names({"installed": "bad"}) == set()
    assert deps_dupes.brew_runtime_dependency_names(
        {
            "installed": [
                {"runtime_dependencies": "bad"},
                "skip",
                {"runtime_dependencies": [1, {"name": "x"}]},
            ]
        }
    ) == {"x"}
    assert deps_dupes.as_name_set("alpha") == {"alpha"}
    assert deps_dupes.as_name_set(["alpha", 1, "beta"]) == {"alpha", "beta"}
    assert deps_dupes.as_name_set({"bad": True}) == set()
    assert deps_dupes.brew_cask_dependency_names({"depends_on": "bad"}) == set()
    assert deps_dupes.walk_deps("a", {"a": {"b"}, "b": {"c"}, "c": {"b"}}) == {"b", "c"}


def test_brew_iter_hits_rejects_bad_payloads(monkeypatch: MonkeyPatch) -> None:
    monkeypatch.setattr(
        deps_dupes, "run_json", lambda cmd: {"formulae": {}, "casks": []}
    )
    try:
        deps_dupes.brew_iter_hits()
    except RuntimeError as exc:
        assert str(exc) == "unexpected brew info payload"
    else:
        raise AssertionError("expected RuntimeError")

    monkeypatch.setattr(
        deps_dupes, "run_json", lambda cmd: {"formulae": [], "casks": []}
    )
    try:
        deps_dupes.brew_iter_hits()
    except RuntimeError as exc:
        assert (
            str(exc) == "brew info --json=v2 --installed returned no auditable packages"
        )
    else:
        raise AssertionError("expected RuntimeError")


def test_brew_iter_hits_reuses_cached_transitive_walks(
    monkeypatch: MonkeyPatch,
) -> None:
    payload = {
        "formulae": [
            {
                "name": "alpha",
                "installed": [
                    {"installed_on_request": True, "runtime_dependencies": []}
                ],
            },
            {
                "name": "alpha",
                "installed": [
                    {"installed_on_request": True, "runtime_dependencies": []}
                ],
            },
        ],
        "casks": [],
    }
    calls: list[str] = []

    def fake_walk_deps(pkg: str, dep_map: dict[str, set[str]]) -> set[str]:
        calls.append(pkg)
        return set(dep_map.get(pkg, set()))

    monkeypatch.setattr(deps_dupes, "run_json", lambda cmd: payload)
    monkeypatch.setattr(deps_dupes, "walk_deps", fake_walk_deps)

    assert deps_dupes.brew_iter_hits() == []
    assert calls == ["alpha"]


def test_emit_records_jsonl_and_tsv(capsys: CaptureFixture[str]) -> None:
    records = [
        {
            "manager": "brew",
            "package": "alpha",
            "dependency": "beta",
            "package_kind": "formula",
            "dependency_kind": "formula",
        }
    ]

    deps_dupes.emit_records(records, "jsonl")
    jsonl_out = capsys.readouterr().out
    assert '"manager": "brew"' in jsonl_out
    assert '"package": "alpha"' in jsonl_out

    deps_dupes.emit_records(records, "tsv")
    tsv_out = capsys.readouterr().out.splitlines()
    assert tsv_out[0] == "manager\tpackage\tdependency\tpackage_kind\tdependency_kind"
    assert tsv_out[1] == "brew\talpha\tbeta\tformula\tformula"


def test_emit_records_json_and_text(capsys: CaptureFixture[str]) -> None:
    records = [deps_dupes.make_record("apt", "alpha", "beta")]

    deps_dupes.emit_records(records, "json")
    json_out = capsys.readouterr().out
    assert '"package": "alpha"' in json_out
    assert '"dependency": "beta"' in json_out

    deps_dupes.emit_records(records, "text")
    text_out = capsys.readouterr().out
    assert text_out == "alpha depends on beta\n"


def test_build_summary_groups_by_package_and_counts_dependencies() -> None:
    records = [
        {
            "manager": "brew",
            "package": "alpha",
            "dependency": "beta",
            "package_kind": "formula",
            "dependency_kind": "formula",
        },
        {
            "manager": "brew",
            "package": "alpha",
            "dependency": "gamma",
            "package_kind": "formula",
            "dependency_kind": "cask",
        },
        {
            "manager": "brew",
            "package": "delta",
            "dependency": "beta",
            "package_kind": "cask",
            "dependency_kind": "formula",
        },
        {
            "manager": "apt",
            "package": "pkg-a",
            "dependency": "dep-a",
            "package_kind": "package",
            "dependency_kind": "package",
        },
    ]

    assert deps_dupes.build_summary(records) == {
        "packages": [
            {
                "manager": "apt",
                "package": "pkg-a",
                "package_kind": "package",
                "dependencies": [{"name": "dep-a", "kind": "package"}],
            },
            {
                "manager": "brew",
                "package": "alpha",
                "package_kind": "formula",
                "dependencies": [
                    {"name": "beta", "kind": "formula"},
                    {"name": "gamma", "kind": "cask"},
                ],
            },
            {
                "manager": "brew",
                "package": "delta",
                "package_kind": "cask",
                "dependencies": [{"name": "beta", "kind": "formula"}],
            },
        ],
        "dependency_totals": [
            {"manager": "apt", "dependency": "dep-a", "count": 1},
            {"manager": "brew", "dependency": "beta", "count": 2},
            {"manager": "brew", "dependency": "gamma", "count": 1},
        ],
        "manager_totals": [
            {"manager": "apt", "count": 1},
            {"manager": "brew", "count": 3},
        ],
    }


def test_emit_records_json_summary(capsys: CaptureFixture[str]) -> None:
    records = [
        {
            "manager": "brew",
            "package": "alpha",
            "dependency": "beta",
            "package_kind": "formula",
            "dependency_kind": "formula",
        }
    ]

    deps_dupes.emit_records(records, "json-summary")
    out = capsys.readouterr().out
    assert '"packages"' in out
    assert '"dependency_totals"' in out
    assert '"manager_totals"' in out


def test_detect_manager_prefers_brew_on_darwin(monkeypatch: MonkeyPatch) -> None:
    monkeypatch.setattr(
        deps_dupes.shutil,
        "which",
        lambda cmd: "/usr/bin/" + cmd if cmd in {"brew", "xbps-query"} else None,
    )
    monkeypatch.setattr(deps_dupes.sys, "platform", "darwin")

    assert deps_dupes.detect_manager() == "brew"


def test_detect_manager_other_branches(monkeypatch: MonkeyPatch) -> None:
    monkeypatch.setattr(
        deps_dupes.shutil,
        "which",
        lambda cmd: f"/usr/bin/{cmd}" if cmd in {"apt-mark", "xbps-query"} else None,
    )
    monkeypatch.setattr(deps_dupes.sys, "platform", "linux")
    assert deps_dupes.detect_manager() == "apt"

    monkeypatch.setattr(
        deps_dupes.shutil,
        "which",
        lambda cmd: f"/usr/bin/{cmd}" if cmd == "xbps-query" else None,
    )
    assert deps_dupes.detect_manager() == "xbps"

    monkeypatch.setattr(deps_dupes.shutil, "which", lambda cmd: None)
    try:
        deps_dupes.detect_manager()
    except RuntimeError as exc:
        assert str(exc) == "no supported package manager found"
    else:
        raise AssertionError("expected RuntimeError")


def test_detect_manager_prefers_xbps_on_linux_when_apt_is_unavailable(
    monkeypatch: MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        deps_dupes.shutil,
        "which",
        lambda cmd: f"/usr/bin/{cmd}" if cmd in {"brew", "xbps-query"} else None,
    )
    monkeypatch.setattr(deps_dupes.sys, "platform", "linux")

    assert deps_dupes.detect_manager() == "xbps"

    monkeypatch.setattr(
        deps_dupes.shutil,
        "which",
        lambda cmd: f"/usr/bin/{cmd}" if cmd in {"apt-mark", "brew"} else None,
    )
    monkeypatch.setattr(deps_dupes.sys, "platform", "win32")
    try:
        deps_dupes.detect_manager()
    except RuntimeError as exc:
        assert (
            str(exc)
            == "multiple supported package managers found: apt, brew; use --manager"
        )
    else:
        raise AssertionError("expected RuntimeError")


def test_parse_args_and_main(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        deps_dupes.sys,
        "argv",
        ["deps-dupes.py", "--manager", "apt", "--format", "json"],
    )
    args = deps_dupes.parse_args()
    assert args.manager == "apt"
    assert args.format == "json"

    monkeypatch.setattr(
        deps_dupes,
        "parse_args",
        lambda: type("Args", (), {"manager": "auto", "format": "text"})(),
    )
    monkeypatch.setattr(deps_dupes, "detect_manager", lambda: "apt")
    monkeypatch.setattr(deps_dupes.shutil, "which", lambda cmd: "/usr/bin/apt-mark")
    monkeypatch.setattr(
        deps_dupes,
        "apt_iter_hits",
        lambda: [deps_dupes.make_record("apt", "alpha", "beta")],
    )
    monkeypatch.setitem(
        deps_dupes.BACKENDS, "apt", ("apt-mark", deps_dupes.apt_iter_hits)
    )
    assert deps_dupes.main() == 0
    assert capsys.readouterr().out == "alpha depends on beta\n"

    monkeypatch.setattr(
        deps_dupes,
        "parse_args",
        lambda: type("Args", (), {"manager": "brew", "format": "text"})(),
    )
    monkeypatch.setattr(deps_dupes.shutil, "which", lambda cmd: None)
    try:
        deps_dupes.main()
    except RuntimeError as exc:
        assert str(exc) == "package manager command not found for brew: brew"
    else:
        raise AssertionError("expected RuntimeError")


def test_module_main_invokes_sys_exit(monkeypatch: MonkeyPatch) -> None:
    def fake_run(cmd: list[str], *args: object, **kwargs: object) -> object:
        class Proc:
            stdout = ""

        if cmd == ["apt-mark", "showmanual"]:
            Proc.stdout = "alpha\n"
            return Proc()
        if cmd[:2] == ["apt-cache", "depends"]:
            Proc.stdout = "alpha\n"
            return Proc()
        raise AssertionError(f"unexpected command: {cmd}")

    monkeypatch.setattr(sys, "argv", ["dependency_dupes.py", "--manager", "apt"])
    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr("shutil.which", lambda cmd: "/usr/bin/apt-mark")

    try:
        runpy.run_path(str(MODULE_PATH), run_name="__main__")
    except SystemExit as exc:
        assert exc.code == 0
    else:
        raise AssertionError("expected SystemExit")
