"""Invite codes (docs/spec.md 3.1): the one place access is checked, replaced by sign-in later.

Format of COACHW_INVITES: comma-separated `code:name:daily_minutes`, e.g.
`3f9c0a7e1b2d4c6e:earayu:90,a1b2c3d4e5f60718:friend:30`. Names are for the operator only and are
never logged or sent to the agent.
"""

from __future__ import annotations

import hmac
from dataclasses import dataclass

MIN_CODE_LENGTH = 12


@dataclass(frozen=True, slots=True)
class Invite:
    code: str
    name: str
    daily_minutes: int


class InviteBook:
    def __init__(self, invites: list[Invite]) -> None:
        codes = [i.code for i in invites]
        if len(set(codes)) != len(codes):
            raise ValueError("duplicate invite code")
        self._invites = invites

    def __len__(self) -> int:
        return len(self._invites)

    @classmethod
    def parse(cls, raw: str) -> InviteBook:
        invites = []
        for n, entry in enumerate(e.strip() for e in raw.split(",")):
            if not entry:
                continue
            parts = entry.split(":")
            if len(parts) != 3:
                raise ValueError(f"invite #{n + 1}: expected code:name:daily_minutes")
            code, name, minutes = (p.strip() for p in parts)
            if len(code) < MIN_CODE_LENGTH:
                raise ValueError(f"invite #{n + 1}: code shorter than {MIN_CODE_LENGTH} chars")
            if not name:
                raise ValueError(f"invite #{n + 1}: empty name")
            try:
                daily = int(minutes)
            except ValueError:
                raise ValueError(f"invite #{n + 1}: daily_minutes must be an integer") from None
            if daily <= 0:
                raise ValueError(f"invite #{n + 1}: daily_minutes must be positive")
            invites.append(Invite(code, name, daily))
        return cls(invites)

    def find(self, code: str) -> Invite | None:
        """Constant-time lookup so response timing does not leak code prefixes."""
        found = None
        for invite in self._invites:
            if hmac.compare_digest(invite.code.encode(), code.encode()):
                found = invite
        return found
