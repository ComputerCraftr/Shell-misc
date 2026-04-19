#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shlex
import signal
import subprocess
import time
from dataclasses import dataclass
from typing import Optional

import cv2
import shutil
import tempfile
from pathlib import Path
import numpy as np


# X11 + dialog-layout based auto reconnect watcher for Sober/Roblox.
#
# This version handles more of the real X11 failure modes:
# - Sober on another virtual desktop
# - Sober minimized/hidden
# - Sober not focused
# - screen blanked / screensaver overlay / session lock checks
# - safer window-state restore after reconnect attempt
#
# Detection strategy:
# 1. Find the Sober top-level X11 window.
# 2. Recover window visibility if needed:
#    - wake display if DPMS off
#    - skip if session appears locked
#    - switch to Sober's desktop if needed
#    - unminimize/activate Sober
# 3. Capture only that window.
# 4. Search a normalized center ROI where the popup appears.
# 5. Inside that ROI, look for a large mid-dark modal panel.
# 6. Score candidates using popup layout cues:
#    - centered dark panel
#    - bright title text band near top
#    - horizontal separator line
#    - two bottom buttons
#    - brighter filled right button (Reconnect)
# 7. Derive the click point from the detected reconnect button geometry.
# 8. Optionally restore the previous desktop/focus after a successful click.
#
# No hard-coded full screenshot template is required.
# The popup can appear over different game scenes and window sizes.


@dataclass
class WindowInfo:
    wid: str
    title: str
    x: int
    y: int
    w: int
    h: int


@dataclass
class Rect:
    x: int
    y: int
    w: int
    h: int

    @property
    def x2(self) -> int:
        return self.x + self.w

    @property
    def y2(self) -> int:
        return self.y + self.h

    @property
    def cx(self) -> float:
        return self.x + self.w / 2.0

    @property
    def cy(self) -> float:
        return self.y + self.h / 2.0


@dataclass
class Detection:
    modal: Rect
    reconnect_button: Rect
    score: float
    panel_score: float
    title_score: float
    separator_score: float
    buttons_score: float


@dataclass
class SessionState:
    current_desktop: Optional[int]
    active_window: Optional[str]


class X11ToolsError(RuntimeError):
    pass


class WindowCaptureUnavailable(X11ToolsError):
    pass


@dataclass
class WindowState:
    hidden_or_minimized: bool
    off_current_desktop: bool
    target_desktop: Optional[int]
    current_desktop: Optional[int]


@dataclass
class ProbeResult:
    state: WindowState
    capture_ok: bool
    detection: Optional[Detection]
    reason: Optional[str] = None


def run(cmd: list[str], check: bool = True) -> str:
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if check and proc.returncode != 0:
        raise X11ToolsError(
            f"Command failed: {' '.join(shlex.quote(c) for c in cmd)}\n{proc.stderr.strip()}"
        )
    return proc.stdout.strip()


def run_ok(cmd: list[str]) -> bool:
    proc = subprocess.run(
        cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
    )
    return proc.returncode == 0


def log(msg: str) -> None:
    print(msg, flush=True)


def list_windows() -> list[tuple[str, str]]:
    out = run(["wmctrl", "-lp"], check=True)
    rows: list[tuple[str, str]] = []
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        rows.append((parts[0], parts[4]))
    return rows


def find_window(title_substring: str) -> Optional[str]:
    needle = title_substring.lower()
    matches: list[tuple[str, str]] = []
    for wid, title in list_windows():
        if needle in title.lower():
            matches.append((wid, title))
    if not matches:
        return None
    matches.sort(key=lambda x: (len(x[1]), x[1]))
    return matches[0][0]


def get_window_info(wid: str) -> WindowInfo:
    out = run(["xwininfo", "-id", wid], check=True)
    title = ""
    x = y = w = h = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("xwininfo: Window id:"):
            q = s.find('"')
            if q != -1 and s.endswith('"'):
                title = s[q + 1 : -1]
        elif s.startswith("Absolute upper-left X:"):
            x = int(s.split(":", 1)[1].strip())
        elif s.startswith("Absolute upper-left Y:"):
            y = int(s.split(":", 1)[1].strip())
        elif s.startswith("Width:"):
            w = int(s.split(":", 1)[1].strip())
        elif s.startswith("Height:"):
            h = int(s.split(":", 1)[1].strip())
    if x is None or y is None or w is None or h is None:
        raise X11ToolsError(f"Could not parse xwininfo for window {wid}")

    x_i: int = x
    y_i: int = y
    w_i: int = w
    h_i: int = h
    return WindowInfo(wid=wid, title=title, x=x_i, y=y_i, w=w_i, h=h_i)


def get_active_window() -> Optional[str]:
    try:
        out = run(["xprop", "-root", "_NET_ACTIVE_WINDOW"], check=True)
    except Exception:
        return None
    m = re.search(r"window id # (0x[0-9a-fA-F]+)", out)
    if not m:
        return None
    wid = m.group(1).lower()
    if wid == "0x0":
        return None
    return wid


def get_current_desktop() -> Optional[int]:
    try:
        out = run(["wmctrl", "-d"], check=True)
    except Exception:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "*":
            try:
                return int(parts[0])
            except ValueError:
                return None
    return None


def get_window_desktop(wid: str) -> Optional[int]:
    try:
        out = run(["xprop", "-id", wid, "_NET_WM_DESKTOP"], check=True)
    except Exception:
        return None
    m = re.search(r"=\s*(-?\d+)", out)
    if not m:
        return None
    try:
        return int(m.group(1))
    except ValueError:
        return None


def get_window_state_atoms(wid: str) -> set[str]:
    try:
        out = run(["xprop", "-id", wid, "_NET_WM_STATE"], check=True)
    except Exception:
        return set()
    atoms = set()
    for atom in re.findall(r"_NET_WM_STATE_[A-Z_]+", out):
        atoms.add(atom)
    return atoms


def is_window_hidden_or_minimized(wid: str) -> bool:
    atoms = get_window_state_atoms(wid)
    return "_NET_WM_STATE_HIDDEN" in atoms or "_NET_WM_STATE_SHADED" in atoms


def is_session_locked() -> bool:
    # Try loginctl first.
    if os.environ.get("XDG_SESSION_ID"):
        try:
            out = run(
                [
                    "loginctl",
                    "show-session",
                    os.environ["XDG_SESSION_ID"],
                    "-p",
                    "LockedHint",
                ],
                check=True,
            )
            if "LockedHint=yes" in out:
                return True
        except Exception:
            pass

    # Fallback for xscreensaver.
    try:
        out = run(["xscreensaver-command", "-time"], check=True)
        low = out.lower()
        if "screen locked" in low or "locked since" in low:
            return True
    except Exception:
        pass

    return False


def wake_display() -> None:
    # Best effort. Harmless if unsupported.
    run_ok(["xset", "dpms", "force", "on"])
    run_ok(["xset", "s", "reset"])


def activate_window(wid: str) -> None:
    run_ok(["xdotool", "windowactivate", "--sync", wid])


def switch_desktop(n: int) -> None:
    run_ok(["wmctrl", "-s", str(n)])


def unminimize_window(wid: str) -> None:
    # Remove HIDDEN if the WM honors it, and map/activate.
    run_ok(["wmctrl", "-i", "-r", wid, "-b", "remove,hidden"])
    run_ok(["xdotool", "windowmap", wid])
    activate_window(wid)


def get_mouse_pos() -> tuple[int, int]:
    out = run(["xdotool", "getmouselocation", "--shell"], check=True)
    vals: dict[str, str] = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            vals[k] = v
    return int(vals["X"]), int(vals["Y"])


def click_window_relative(
    win: WindowInfo, rel_x: int, rel_y: int, restore_mouse: bool = True
) -> None:
    # Use a window-targeted click path when possible so the motion/click is scoped to the window.
    # xdotool still uses XTEST underneath, but this avoids global absolute coordinates.
    old = None
    if restore_mouse:
        old = get_mouse_pos()

    run_ok(["xdotool", "windowactivate", "--sync", win.wid])
    run_ok(["xdotool", "mousemove", "--window", win.wid, str(rel_x), str(rel_y)])
    run_ok(["xdotool", "mousedown", "1"])
    run_ok(["xdotool", "mouseup", "1"])

    if old is not None:
        run_ok(["xdotool", "mousemove", str(old[0]), str(old[1])])


def save_session_state() -> SessionState:
    return SessionState(
        current_desktop=get_current_desktop(),
        active_window=get_active_window(),
    )


def restore_session_state(state: SessionState, delay: float = 0.08) -> None:
    if state.current_desktop is not None:
        switch_desktop(state.current_desktop)
        time.sleep(delay)
    if state.active_window:
        activate_window(state.active_window)
        time.sleep(delay)


def recover_window_for_detection(
    wid: str, aggressive: bool, debug: bool = False
) -> bool:
    if is_session_locked():
        if debug:
            log("session appears locked; skipping")
        return False

    wake_display()

    if not aggressive:
        return True

    state = get_window_state(wid)
    if (
        state.off_current_desktop
        and state.target_desktop is not None
        and state.current_desktop is not None
    ):
        if debug:
            log(f"switching desktop {state.current_desktop} -> {state.target_desktop}")
        switch_desktop(state.target_desktop)
        time.sleep(0.18)

    if state.hidden_or_minimized:
        if debug:
            log("unminimizing/activating window")
        unminimize_window(wid)
        time.sleep(0.22)
    else:
        activate_window(wid)
        time.sleep(0.10)

    return True

    target_desktop = get_window_desktop(wid)
    current_desktop = get_current_desktop()

    if (
        target_desktop is not None
        and target_desktop >= 0
        and current_desktop is not None
        and target_desktop != current_desktop
    ):
        if debug:
            log(f"switching desktop {current_desktop} -> {target_desktop}")
        switch_desktop(target_desktop)
        time.sleep(0.18)

    if is_window_hidden_or_minimized(wid):
        if debug:
            log("unminimizing/activating window")
        unminimize_window(wid)
        time.sleep(0.22)
    else:
        activate_window(wid)
        time.sleep(0.10)

    return True


def _find_image_converter() -> Optional[list[str]]:
    # Convert XWD into a format OpenCV can read. Prefer ImageMagick 7, then legacy convert.
    if shutil.which("magick"):
        return ["magick"]
    if shutil.which("convert"):
        return ["convert"]
    return None


def grab_window_bgr(win: WindowInfo) -> np.ndarray:
    if not shutil.which("xwd"):
        raise WindowCaptureUnavailable(
            "xwd is required for true X11 window capture. Install xwd/xorg-xwd."
        )

    converter = _find_image_converter()
    if converter is None:
        raise WindowCaptureUnavailable(
            "ImageMagick is required to convert xwd output for OpenCV. Install 'magick' or 'convert'."
        )

    with tempfile.TemporaryDirectory(prefix="sober-reconnect-") as tmpdir:
        xwd_path = Path(tmpdir) / "window.xwd"
        png_path = Path(tmpdir) / "window.png"

        xwd_cmd = ["xwd", "-silent", "-id", win.wid, "-out", str(xwd_path)]
        try:
            run(xwd_cmd, check=True)
        except X11ToolsError as exc:
            msg = str(exc)
            if "BadMatch" in msg or "X_GetImage" in msg:
                raise WindowCaptureUnavailable(
                    "X_GetImage unavailable for this window state"
                ) from exc
            raise

        if converter[0] == "magick":
            convert_cmd = ["magick", str(xwd_path), str(png_path)]
        else:
            convert_cmd = ["convert", str(xwd_path), str(png_path)]
        run(convert_cmd, check=True)

        img = cv2.imread(str(png_path), cv2.IMREAD_COLOR)
        if img is None:
            raise WindowCaptureUnavailable(
                "Failed to decode converted X window capture image"
            )
        return img


def clamp_rect(rect: Rect, w: int, h: int) -> Rect:
    x = max(0, min(rect.x, w - 1))
    y = max(0, min(rect.y, h - 1))
    x2 = max(x + 1, min(rect.x2, w))
    y2 = max(y + 1, min(rect.y2, h))
    return Rect(x, y, x2 - x, y2 - y)


def rect_sub(rect: Rect, rx: float, ry: float, rw: float, rh: float) -> Rect:
    return Rect(
        rect.x + int(round(rect.w * rx)),
        rect.y + int(round(rect.h * ry)),
        max(1, int(round(rect.w * rw))),
        max(1, int(round(rect.h * rh))),
    )


def center_roi_for_window(win_w: int, win_h: int) -> Rect:
    # Search a fixed-size area around the window center instead of sizing the
    # ROI from the whole window or from a template.
    #
    # The disconnect dialog is always centered, but its size should not scale
    # with the entire Sober window. Keep the search box center-anchored and
    # large enough to contain a range of plausible dialog sizes.
    cx = win_w // 2
    cy = win_h // 2

    roi_w = min(win_w, 1800)
    roi_h = min(win_h, 1200)

    roi = Rect(
        x=int(round(cx - roi_w / 2)),
        y=int(round(cy - roi_h / 2)),
        w=roi_w,
        h=roi_h,
    )
    return clamp_rect(roi, win_w, win_h)


def gray_blur(img_bgr: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    return cv2.GaussianBlur(gray, (5, 5), 0)


def mean_gray(gray: np.ndarray, rect: Rect) -> float:
    r = clamp_rect(rect, gray.shape[1], gray.shape[0])
    patch = gray[r.y : r.y2, r.x : r.x2]
    if patch.size == 0:
        return 0.0
    return float(np.mean(patch))


def std_gray(gray: np.ndarray, rect: Rect) -> float:
    r = clamp_rect(rect, gray.shape[1], gray.shape[0])
    patch = gray[r.y : r.y2, r.x : r.x2]
    if patch.size == 0:
        return 0.0
    return float(np.std(patch))


def edge_density(gray: np.ndarray, rect: Rect) -> float:
    r = clamp_rect(rect, gray.shape[1], gray.shape[0])
    patch = gray[r.y : r.y2, r.x : r.x2]
    if patch.size == 0:
        return 0.0
    edges = cv2.Canny(patch, 60, 160)
    return float(np.count_nonzero(edges)) / float(edges.size)


def title_band_score(gray: np.ndarray, modal: Rect) -> float:
    panel_mean = mean_gray(gray, modal)
    title = rect_sub(modal, 0.18, 0.03, 0.64, 0.16)
    title_mean = mean_gray(gray, title)
    title_edges = edge_density(gray, title)
    contrast = max(0.0, (title_mean - panel_mean) / 255.0)
    texture = min(1.0, title_edges * 18.0)
    return 0.55 * contrast + 0.45 * texture


def separator_line_score(gray: np.ndarray, modal: Rect) -> float:
    band = rect_sub(modal, 0.05, 0.18, 0.90, 0.05)
    band = clamp_rect(band, gray.shape[1], gray.shape[0])
    patch = gray[band.y : band.y2, band.x : band.x2]
    if patch.size == 0:
        return 0.0
    row_means = patch.mean(axis=1)
    baseline = float(np.mean(row_means))
    peak = float(np.max(row_means))
    return max(0.0, min(1.0, (peak - baseline) / 24.0))


def button_geometry_score(gray: np.ndarray, modal: Rect) -> tuple[float, Rect, Rect]:
    left_btn = rect_sub(modal, 0.05, 0.76, 0.44, 0.14)
    right_btn = rect_sub(modal, 0.51, 0.76, 0.44, 0.14)
    left_btn = clamp_rect(left_btn, gray.shape[1], gray.shape[0])
    right_btn = clamp_rect(right_btn, gray.shape[1], gray.shape[0])

    panel_mean = mean_gray(gray, modal)
    left_mean = mean_gray(gray, left_btn)
    right_mean = mean_gray(gray, right_btn)
    left_edges = edge_density(gray, left_btn)
    right_edges = edge_density(gray, right_btn)

    right_brightness = max(0.0, (right_mean - panel_mean) / 255.0)
    right_vs_left = max(0.0, (right_mean - left_mean) / 255.0)
    edge_shape = min(1.0, (left_edges + right_edges) * 7.0)

    score = 0.45 * right_brightness + 0.35 * right_vs_left + 0.20 * edge_shape
    return score, left_btn, right_btn


def panel_shape_score(gray: np.ndarray, modal: Rect, roi_rect: Rect) -> float:
    roi_center_x = roi_rect.w / 2.0
    roi_center_y = roi_rect.h / 2.0
    modal_center_x = modal.cx - roi_rect.x
    modal_center_y = modal.cy - roi_rect.y

    center_dx = abs(modal_center_x - roi_center_x) / max(1.0, roi_rect.w)
    center_dy = abs(modal_center_y - roi_center_y) / max(1.0, roi_rect.h)
    center_score = max(0.0, 1.0 - (center_dx * 2.8 + center_dy * 3.5))

    aspect = modal.w / float(modal.h)
    aspect_score = max(0.0, 1.0 - abs(aspect - 1.56) / 0.70)

    interior = rect_sub(modal, 0.04, 0.04, 0.92, 0.92)
    uniformity = max(0.0, 1.0 - std_gray(gray, interior) / 42.0)

    return 0.40 * center_score + 0.35 * aspect_score + 0.25 * uniformity


def generate_center_candidates(win_w: int, win_h: int, roi: Rect) -> list[Rect]:
    # Learned from successful detections:
    # - small window true positive:   ~390x250
    # - maximized true positive:      ~390x250
    # - nearby valid larger variant:  ~452x290
    #
    # So do not scan huge modal sizes anymore. Keep candidates tightly centered
    # around the observed dialog sizes and allow only modest scale variation.
    base_sizes = [
        (390, 250),
        (420, 270),
        (452, 290),
    ]

    # Small center jitter to account for imperfect centering / capture offsets.
    dxs = [0, -60, 60, -120, 120]
    dys = [0, -40, 40, -80, 80]

    cx = win_w // 2
    cy = win_h // 2
    out: list[Rect] = []
    seen: set[tuple[int, int, int, int]] = set()

    for w, h in base_sizes:
        for dx in dxs:
            for dy in dys:
                rect = Rect(
                    x=int(round(cx - w / 2 + dx)),
                    y=int(round(cy - h / 2 + dy)),
                    w=w,
                    h=h,
                )
                rect = clamp_rect(rect, win_w, win_h)
                if (
                    rect.x < roi.x
                    or rect.y < roi.y
                    or rect.x2 > roi.x2
                    or rect.y2 > roi.y2
                ):
                    continue
                key = (rect.x, rect.y, rect.w, rect.h)
                if key in seen:
                    continue
                seen.add(key)
                out.append(rect)

    return out


def overlay_contrast_score(gray: np.ndarray, modal: Rect) -> float:
    # The dialog normally sits on top of a darker translucent overlay.
    outer = Rect(
        max(0, modal.x - 18),
        max(0, modal.y - 18),
        modal.w + 36,
        modal.h + 36,
    )
    outer = clamp_rect(outer, gray.shape[1], gray.shape[0])
    inner = rect_sub(modal, 0.08, 0.08, 0.84, 0.84)
    inner = clamp_rect(inner, gray.shape[1], gray.shape[0])

    outer_patch = gray[outer.y : outer.y2, outer.x : outer.x2]
    inner_patch = gray[inner.y : inner.y2, inner.x : inner.x2]
    if outer_patch.size == 0 or inner_patch.size == 0:
        return 0.0

    outer_mean = float(np.mean(outer_patch))
    inner_mean = float(np.mean(inner_patch))
    return max(0.0, min(1.0, (inner_mean - outer_mean) / 48.0))


def size_prior_score(modal: Rect) -> float:
    # Strong prior from real successful detections.
    targets = [(390, 250), (452, 290)]
    best = 0.0
    for tw, th in targets:
        dw = abs(modal.w - tw) / float(tw)
        dh = abs(modal.h - th) / float(th)
        score = max(0.0, 1.0 - (dw + dh) * 1.8)
        if score > best:
            best = score
    return best


def rect_iou(a: Rect, b: Rect) -> float:
    x1 = max(a.x, b.x)
    y1 = max(a.y, b.y)
    x2 = min(a.x2, b.x2)
    y2 = min(a.y2, b.y2)
    if x2 <= x1 or y2 <= y1:
        return 0.0
    inter = float((x2 - x1) * (y2 - y1))
    union = float(a.w * a.h + b.w * b.h) - inter
    if union <= 0.0:
        return 0.0
    return inter / union


def nms_detections(
    detections: list[Detection], iou_threshold: float = 0.55
) -> list[Detection]:
    # Highest-score box after non-maximum suppression.
    if not detections:
        return []
    ordered = sorted(detections, key=lambda d: d.score, reverse=True)
    kept: list[Detection] = []
    for det in ordered:
        suppress = False
        for kept_det in kept:
            if rect_iou(det.modal, kept_det.modal) >= iou_threshold:
                suppress = True
                break
        if not suppress:
            kept.append(det)
    return kept


def get_window_state(wid: str) -> WindowState:
    target_desktop = get_window_desktop(wid)
    current_desktop = get_current_desktop()
    off_current_desktop = (
        target_desktop is not None
        and target_desktop >= 0
        and current_desktop is not None
        and target_desktop != current_desktop
    )
    return WindowState(
        hidden_or_minimized=is_window_hidden_or_minimized(wid),
        off_current_desktop=off_current_desktop,
        target_desktop=target_desktop,
        current_desktop=current_desktop,
    )


def log_probe_result(result: ProbeResult, debug: bool = False) -> None:
    state_parts: list[str] = []
    if result.state.hidden_or_minimized:
        state_parts.append("hidden/minimized")
    if result.state.off_current_desktop:
        state_parts.append(
            f"desktop {result.state.target_desktop} vs current {result.state.current_desktop}"
        )
    if not state_parts:
        state_parts.append("visible/current-desktop")

    if result.reason:
        log(f"probe: {'; '.join(state_parts)} -> {result.reason}")
    elif result.detection is None:
        if debug:
            log(f"probe: {'; '.join(state_parts)} -> no reconnect dialog")
    else:
        det = result.detection
        log(
            f"disconnect detected: state={' ; '.join(state_parts)} "
            f"modal=({det.modal.x},{det.modal.y},{det.modal.w},{det.modal.h}) "
            f"button=({det.reconnect_button.x},{det.reconnect_button.y},{det.reconnect_button.w},{det.reconnect_button.h}) "
            f"score={det.score:.3f} panel={det.panel_score:.3f} title={det.title_score:.3f} "
            f"sep={det.separator_score:.3f} buttons={det.buttons_score:.3f}"
        )


def probe_window_dialog(
    wid: str,
    allow_unavailable: bool,
    debug: bool = False,
) -> ProbeResult:
    state = get_window_state(wid)
    try:
        win = get_window_info(wid)
        frame = grab_window_bgr(win)
    except WindowCaptureUnavailable as exc:
        reason = str(exc)
        if state.hidden_or_minimized or state.off_current_desktop:
            reason = f"window pixels unavailable in current state ({reason})"
        return ProbeResult(
            state=state,
            capture_ok=False,
            detection=None,
            reason=reason,
        )
    except Exception as exc:
        if allow_unavailable:
            return ProbeResult(
                state=state,
                capture_ok=False,
                detection=None,
                reason=f"capture failed: {exc}",
            )
        raise

    detection = detect_disconnect_modal(frame_bgr=frame, debug=debug)
    return ProbeResult(state=state, capture_ok=True, detection=detection)


def detect_disconnect_modal(
    frame_bgr: np.ndarray, debug: bool = False
) -> Optional[Detection]:
    H, W = frame_bgr.shape[:2]
    roi = center_roi_for_window(W, H)
    full_gray = gray_blur(frame_bgr)

    candidates = generate_center_candidates(W, H, roi)
    if debug:
        log(f"candidates={len(candidates)} roi=({roi.x},{roi.y},{roi.w},{roi.h})")

    scored: list[Detection] = []

    for modal in candidates:
        panel_score = panel_shape_score(full_gray, modal, roi)
        title_score = title_band_score(full_gray, modal)
        sep_score = separator_line_score(full_gray, modal)
        buttons_score, _left_btn, right_btn = button_geometry_score(full_gray, modal)
        overlay_score = overlay_contrast_score(full_gray, modal)
        size_score = size_prior_score(modal)

        total = (
            0.18 * panel_score
            + 0.12 * title_score
            + 0.07 * sep_score
            + 0.42 * buttons_score
            + 0.11 * overlay_score
            + 0.10 * size_score
        )

        det = Detection(
            modal=modal,
            reconnect_button=right_btn,
            score=total,
            panel_score=panel_score,
            title_score=title_score,
            separator_score=sep_score,
            buttons_score=buttons_score,
        )
        scored.append(det)

        if debug:
            log(
                f"candidate modal=({modal.x},{modal.y},{modal.w},{modal.h}) "
                f"panel={panel_score:.3f} title={title_score:.3f} sep={sep_score:.3f} "
                f"buttons={buttons_score:.3f} overlay={overlay_score:.3f} size={size_score:.3f} total={total:.3f}"
            )

    # Filter out weak garbage first, then apply NMS so nearby shifted copies of
    # the same real dialog do not cause a false rejection.
    strong = [d for d in scored if d.score >= 0.50 and d.buttons_score >= 0.35]
    if debug:
        log(f"strong_candidates={len(strong)}")

    kept = nms_detections(strong, iou_threshold=0.55)
    if debug:
        log(f"nms_kept={len(kept)}")

    if not kept:
        # Fall back to the best raw candidate only for debug visibility; still reject.
        if scored and debug:
            best_raw = max(scored, key=lambda d: d.score)
            log(
                f"best raw candidate rejected: score={best_raw.score:.3f} "
                f"buttons={best_raw.buttons_score:.3f}"
            )
        return None

    best = max(kept, key=lambda d: d.score)

    if best.score < 0.50:
        if debug:
            log(f"best total below threshold: {best.score:.3f}")
        return None
    if best.buttons_score < 0.35:
        if debug:
            log(f"best buttons score below threshold: {best.buttons_score:.3f}")
        return None

    if debug:
        log(
            f"nms best candidate: modal=({best.modal.x},{best.modal.y},{best.modal.w},{best.modal.h}) "
            f"score={best.score:.3f} buttons={best.buttons_score:.3f}"
        )

    return best


def click_detection(win: WindowInfo, det: Detection) -> None:
    btn = det.reconnect_button
    rel_x = int(round(btn.x + btn.w * 0.50))
    rel_y = int(round(btn.y + btn.h * 0.52))
    click_window_relative(win, rel_x, rel_y, restore_mouse=True)


def reconnect_click_sequence(
    wid: str,
    initial_win: WindowInfo,
    initial_det: Detection,
    debug: bool = False,
    max_clicks: int = 4,
) -> bool:
    # Click, wait, and verify. Retry only while a strong reconnect dialog is
    # still present. This avoids both one-shot failures and blind spam-clicking.
    delays = [0.25, 0.50, 0.80, 1.20]
    clicks_done = 0
    win = initial_win
    det: Optional[Detection] = initial_det

    while det is not None and clicks_done < max_clicks:
        if debug:
            log(
                f"reconnect attempt {clicks_done + 1}/{max_clicks}: "
                f"modal=({det.modal.x},{det.modal.y},{det.modal.w},{det.modal.h}) "
                f"score={det.score:.3f} buttons={det.buttons_score:.3f}"
            )

        click_detection(win, det)
        clicks_done += 1

        delay = delays[min(clicks_done - 1, len(delays) - 1)]
        time.sleep(delay)

        try:
            win = get_window_info(wid)
            frame = grab_window_bgr(win)
            det = detect_disconnect_modal(frame, debug=debug)
        except Exception as exc:
            if debug:
                log(f"post-click recapture error: {exc}")
            det = None

        if det is None:
            if debug:
                log("dialog no longer detected after click sequence")
            return True

        # If the dialog is still present but now weak/ambiguous, wait a little
        # and re-check once before clicking again.
        if det.score < 0.56 or det.buttons_score < 0.45:
            if debug:
                log(
                    f"dialog still weak after click: score={det.score:.3f} "
                    f"buttons={det.buttons_score:.3f}; waiting for confirmation"
                )
            time.sleep(0.35)
            try:
                win = get_window_info(wid)
                frame = grab_window_bgr(win)
                det2 = detect_disconnect_modal(frame, debug=debug)
            except Exception as exc:
                if debug:
                    log(f"confirmation recapture error: {exc}")
                det2 = None

            if det2 is None:
                if debug:
                    log("dialog disappeared during confirmation wait")
                return True
            det = det2

    if det is not None and debug:
        log(
            f"dialog still present after retry cap: score={det.score:.3f} "
            f"buttons={det.buttons_score:.3f}"
        )
    return det is None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Auto-click Roblox/Sober reconnect dialog on X11"
    )
    parser.add_argument(
        "--window-title", default="Sober", help="Window title substring to match"
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=4.0,
        help="Seconds between passive probe cycles",
    )
    parser.add_argument(
        "--aggressive-interval",
        type=float,
        default=6.0,
        help="Minimum seconds between aggressive recovery/click attempts",
    )
    parser.add_argument(
        "--cooldown",
        type=float,
        default=1.0,
        help="Minimum seconds between click sequences",
    )
    parser.add_argument(
        "--debug", action="store_true", help="Print detector diagnostics"
    )
    parser.add_argument(
        "--once", action="store_true", help="Run one probe pass and exit"
    )
    parser.add_argument(
        "--aggressive",
        action="store_true",
        help="Recover minimized/off-desktop window state and click when dialog is confirmed",
    )
    parser.add_argument(
        "--restore-session",
        action="store_true",
        help="After a successful aggressive click, try to restore previous desktop and active window",
    )
    args = parser.parse_args()

    if os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
        log("This watcher is for X11. DISPLAY is not set.")
        return 1

    def _stop(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    last_click = 0.0
    last_aggressive_recovery = 0.0
    missing_logged = False

    while True:
        wid = find_window(args.window_title)
        if wid is None:
            if not missing_logged:
                log(
                    f"No window found containing title substring: {args.window_title!r}"
                )
                missing_logged = True
            if args.once:
                return 2
            time.sleep(1.0)
            continue

        missing_logged = False
        session_state = save_session_state()

        if is_session_locked():
            if args.debug:
                log("session appears locked; skipping")
            if args.once:
                return 3
            time.sleep(max(args.poll_interval, 0.35))
            continue

        wake_display()

        probe = probe_window_dialog(wid, allow_unavailable=True, debug=args.debug)
        log_probe_result(probe, debug=args.debug)

        acted = False
        now = time.monotonic()

        if args.aggressive and now - last_click >= args.cooldown:
            needs_recovery = (
                probe.detection is not None
                or probe.state.hidden_or_minimized
                or probe.state.off_current_desktop
                or not probe.capture_ok
            )

            if (
                needs_recovery
                and now - last_aggressive_recovery >= args.aggressive_interval
            ):
                last_aggressive_recovery = now
                if recover_window_for_detection(wid, aggressive=True, debug=args.debug):
                    probe_after = probe_window_dialog(
                        wid, allow_unavailable=True, debug=args.debug
                    )
                    if args.debug:
                        log_probe_result(probe_after, debug=args.debug)
                    if probe_after.detection is not None:
                        win = get_window_info(wid)
                        reconnect_click_sequence(
                            wid=wid,
                            initial_win=win,
                            initial_det=probe_after.detection,
                            debug=args.debug,
                            max_clicks=4,
                        )
                        last_click = time.monotonic()
                        acted = True
                    elif args.debug:
                        log(
                            "aggressive probe did not confirm reconnect dialog; skipping click"
                        )
                elif args.debug:
                    log("could not recover window for aggressive probe/click")
            elif args.aggressive and needs_recovery and args.debug:
                log("aggressive mode throttled: waiting before next recovery probe")

        if acted and args.restore_session:
            restore_session_state(session_state)

        if args.once:
            if probe.detection is not None:
                return 0
            return 4
        time.sleep(args.poll_interval)


if __name__ == "__main__":
    raise SystemExit(main())
