"""Number formatting shared by tool results, cue facts and summaries."""

from __future__ import annotations


def pace_seconds(speed_mps: float) -> float | None:
    """Seconds per kilometre, or None when standing still."""
    return None if speed_mps < 0.3 else 1000 / speed_mps


def format_pace(speed_mps: float) -> str | None:
    """Pace per kilometre as m'ss\", or None when standing still."""
    seconds = pace_seconds(speed_mps)
    return None if seconds is None else format_pace_seconds(seconds)


def format_pace_seconds(seconds: float) -> str:
    total = round(seconds)
    return f"{total // 60}'{total % 60:02d}\""


def say_duration(seconds: float) -> str:
    """Spoken Chinese duration: "1 小时 5 分 3 秒", "12 分 30 秒", "45 秒"."""
    total = max(0, round(seconds))
    h, rest = divmod(total, 3600)
    m, s = divmod(rest, 60)
    parts = [f"{h} 小时"] if h else []
    if m or h:
        parts.append(f"{m} 分")
    if s or not parts:
        parts.append(f"{s} 秒")
    return " ".join(parts)


def say_pace(seconds: float) -> str:
    total = round(seconds)
    return f"每公里 {total // 60} 分 {total % 60} 秒"


def say_distance(meters: float) -> str:
    return f"{meters / 1000:.2f} 公里" if meters >= 1000 else f"{meters:.0f} 米"
