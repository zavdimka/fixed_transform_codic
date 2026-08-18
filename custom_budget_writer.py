"""Bit-exact reference model for the custom codec dual budget guard.

The guard operates on complete entropy tokens.  It deliberately does not know
their syntax: the VLC encoder supplies a value and length plus the amount of
worst-case mandatory-tail reservation released by that token.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, IntEnum


class Layer(IntEnum):
    BASE = 0
    ENHANCEMENT = 1


class Admission(Enum):
    ACCEPTED = "accepted"
    DROPPED = "dropped"
    FATAL = "fatal"


@dataclass(frozen=True)
class BudgetToken:
    layer: Layer
    value: int
    bit_length: int
    mandatory: bool = False
    reserve_release: int = 0


@dataclass(frozen=True)
class AcceptedToken:
    layer: Layer
    value: int
    bit_length: int


class DualBudgetWriter:
    """Reference for the RTL token admission and accounting state machine."""

    def __init__(
        self,
        base_limit_bits: int,
        enhancement_limit_bits: int,
        base_reserved_bits: int = 0,
        enhancement_reserved_bits: int = 0,
    ) -> None:
        limits = (int(base_limit_bits), int(enhancement_limit_bits))
        reserves = (int(base_reserved_bits), int(enhancement_reserved_bits))
        if min(*limits, *reserves) < 0:
            raise ValueError("budgets and reservations must be non-negative")
        if any(reserve > limit for reserve, limit in zip(reserves, limits)):
            raise ValueError("mandatory reservation exceeds layer budget")
        self.limits = list(limits)
        self.reserved = list(reserves)
        self.used = [0, 0]
        self.accepted: list[AcceptedToken] = []
        self.dropped = [0, 0]
        self.discard_optional = [False, False]
        self.fatal = False

    def submit(self, token: BudgetToken) -> Admission:
        layer = int(token.layer)
        length = int(token.bit_length)
        release = int(token.reserve_release)
        if not 0 <= layer < 2:
            raise ValueError("invalid layer")
        metadata_valid = (
            0 <= length <= 32
            and 0 <= release <= self.reserved[layer]
            and (token.mandatory or release == 0)
        )
        if not metadata_valid:
            self.fatal = True
            return Admission.FATAL

        if not token.mandatory and self.discard_optional[layer]:
            self.dropped[layer] += 1
            return Admission.DROPPED

        reserved_after = self.reserved[layer] - release
        fits = self.used[layer] + length + reserved_after <= self.limits[layer]
        if not fits:
            if token.mandatory:
                self.fatal = True
                return Admission.FATAL
            self.dropped[layer] += 1
            self.discard_optional[layer] = True
            return Admission.DROPPED

        self.reserved[layer] = reserved_after
        self.used[layer] += length
        if token.mandatory:
            self.discard_optional[layer] = False
        if length:
            self.accepted.append(AcceptedToken(token.layer, int(token.value), length))
        return Admission.ACCEPTED

    def finish(self) -> tuple[int, int]:
        if any(self.reserved):
            self.fatal = True
            raise RuntimeError("mandatory reservation remains at end of stripe")
        return self.used[0], self.used[1]
