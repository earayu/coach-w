"""Profile registry: the wire `activity` (HealthKit activity type name) → profile (spec 5)."""

from __future__ import annotations

from dataclasses import replace

from coachw.profiles.base import ActivityProfile
from coachw.profiles.cycling import CYCLING
from coachw.profiles.fallback import FALLBACK
from coachw.profiles.running import RUNNING
from coachw.profiles.walking import HIKING, WALKING

PROFILES: tuple[ActivityProfile, ...] = (RUNNING, WALKING, HIKING, CYCLING)


def _index(profiles: tuple[ActivityProfile, ...]) -> dict[str, ActivityProfile]:
    index: dict[str, ActivityProfile] = {}
    for profile in profiles:
        for activity in profile.activity_types:
            if activity in index:
                raise ValueError(f"activity {activity!r} is claimed by two profiles")
            index[activity] = profile
    return index


_BY_ACTIVITY = _index(PROFILES)


def profile_for(activity: str) -> ActivityProfile:
    """The profile for `activity`; every activity without its own profile gets the fallback."""
    if profile := _BY_ACTIVITY.get(activity):
        return profile
    # claim the activity so the session does not reload the fallback on every frame
    return replace(FALLBACK, activity_types=(activity,))
