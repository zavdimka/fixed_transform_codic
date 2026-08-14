"""Integer reference for one HEVC CABAC bin arithmetic step.

This deliberately stops before the byte-output/carry-buffer stage. It mirrors
the FPGA boundary: one regular or bypass bin updates low/range and, for a
regular bin, its probability context.
"""

from __future__ import annotations

from dataclasses import dataclass


CABAC_INIT_B = 0
CABAC_INIT_P = 1
CABAC_INIT_I = 2

_COEFFICIENT_LAST_INIT = (
    (125, 110, 124, 110, 95, 94, 125, 111, 111, 79, 125, 126, 111, 111, 79),
    (125, 110, 94, 110, 95, 79, 125, 111, 110, 78, 110, 111, 111, 95, 94),
    (110, 110, 124, 125, 140, 153, 125, 127, 140, 109, 111, 143, 127, 111, 79),
)
_COEFFICIENT_SIG_CG_INIT = ((121, 140), (121, 140), (91, 171))
_COEFFICIENT_SIG_INIT = (
    (170, 154, 139, 153, 139, 123, 123, 63, 124, 166, 183, 140,
     136, 153, 154, 166, 183, 140, 136, 153, 154, 166, 183, 140,
     136, 153, 154, 140),
    (155, 154, 139, 153, 139, 123, 123, 63, 153, 166, 183, 140,
     136, 153, 154, 166, 183, 140, 136, 153, 154, 166, 183, 140,
     136, 153, 154, 140),
    (111, 111, 125, 110, 110, 94, 124, 108, 124, 107, 125, 141,
     179, 153, 125, 107, 125, 141, 179, 153, 125, 107, 125, 141,
     179, 153, 125, 141),
)
_COEFFICIENT_GREATER1_INIT = (
    (154, 196, 167, 167, 154, 152, 167, 182,
     182, 134, 149, 136, 153, 121, 136, 122),
    (154, 196, 196, 167, 154, 152, 167, 182,
     182, 134, 149, 136, 153, 121, 136, 137),
    (140, 92, 137, 138, 140, 152, 138, 139,
     153, 74, 149, 92, 139, 107, 122, 152),
)
_COEFFICIENT_GREATER2_INIT = (
    (107, 167, 91, 107),
    (107, 167, 91, 122),
    (138, 153, 136, 167),
)


def coefficient_context_init_values(slice_type: int) -> tuple[int, ...]:
    """Return the compact 128-byte HM coefficient initValue ROM row."""
    if slice_type not in (CABAC_INIT_B, CABAC_INIT_P, CABAC_INIT_I):
        raise ValueError("slice_type must be B=0, P=1 or I=2")
    values = [154] * 128
    values[0:15] = _COEFFICIENT_LAST_INIT[slice_type]
    values[16:31] = _COEFFICIENT_LAST_INIT[slice_type]
    values[32:34] = _COEFFICIENT_SIG_CG_INIT[slice_type]
    values[64:92] = _COEFFICIENT_SIG_INIT[slice_type]
    values[96:112] = _COEFFICIENT_GREATER1_INIT[slice_type]
    values[112:116] = _COEFFICIENT_GREATER2_INIT[slice_type]
    return tuple(values)


CABAC_CONTEXT_COUNT = 192

CONTEXT_SPLIT = 128
CONTEXT_PART_SIZE = 132
CONTEXT_INTRA_PRED_MODE = 136
CONTEXT_CHROMA_PRED_MODE = 137
CONTEXT_QT_CBF_LUMA = 144
CONTEXT_QT_CBF_CHROMA = 152
CONTEXT_TRANSFORM_SUBDIV = 160

_SPLIT_INIT = ((107, 139, 126), (107, 139, 126), (139, 141, 157))
_PART_SIZE_INIT = (
    (154, 139, 154, 154),
    (154, 139, 154, 154),
    (184, 154, 154, 154),
)
_INTRA_PRED_INIT = (183, 154, 184)
_CHROMA_PRED_INIT = ((152, 139), (152, 139), (63, 139))
_QT_CBF_LUMA_INIT = (
    (153, 111, 154, 154, 154),
    (153, 111, 154, 154, 154),
    (111, 141, 154, 154, 154),
)
_QT_CBF_CHROMA_INIT = (
    (149, 92, 167, 154, 154),
    (149, 107, 167, 154, 154),
    (94, 138, 182, 154, 154),
)
_TRANSFORM_SUBDIV_INIT = ((224, 167, 122), (124, 138, 94), (153, 138, 138))


def cabac_context_init_values(slice_type: int) -> tuple[int, ...]:
    """Return the compact 192-byte coefficient/CU initValue ROM row."""
    values = list(coefficient_context_init_values(slice_type)) + [154] * 64
    values[CONTEXT_SPLIT:CONTEXT_SPLIT + 3] = _SPLIT_INIT[slice_type]
    values[CONTEXT_PART_SIZE:CONTEXT_PART_SIZE + 4] = _PART_SIZE_INIT[slice_type]
    values[CONTEXT_INTRA_PRED_MODE] = _INTRA_PRED_INIT[slice_type]
    values[CONTEXT_CHROMA_PRED_MODE:CONTEXT_CHROMA_PRED_MODE + 2] = (
        _CHROMA_PRED_INIT[slice_type]
    )
    values[CONTEXT_QT_CBF_LUMA:CONTEXT_QT_CBF_LUMA + 5] = (
        _QT_CBF_LUMA_INIT[slice_type]
    )
    values[CONTEXT_QT_CBF_CHROMA:CONTEXT_QT_CBF_CHROMA + 5] = (
        _QT_CBF_CHROMA_INIT[slice_type]
    )
    values[CONTEXT_TRANSFORM_SUBDIV:CONTEXT_TRANSFORM_SUBDIV + 3] = (
        _TRANSFORM_SUBDIV_INIT[slice_type]
    )
    return tuple(values)


def cabac_context_init_state(qp: int, init_value: int) -> tuple[int, int]:
    """Convert one HEVC initValue into the FPGA ``(state_index, MPS)``."""
    if not 0 <= init_value <= 255:
        raise ValueError("init_value must fit one byte")
    qp = min(51, max(0, qp))
    slope = (init_value >> 4) * 5 - 45
    offset = ((init_value & 15) << 3) - 16
    init_state = min(126, max(1, ((slope * qp) >> 4) + offset))
    if init_state >= 64:
        return init_state - 64, 1
    return 63 - init_state, 0


def coefficient_context_init_states(
    slice_type: int, qp: int,
) -> list[tuple[int, int]]:
    """Build a complete 256-entry context image for the byte oracle."""
    neutral = cabac_context_init_state(qp, 154)
    contexts = [neutral] * 256
    contexts[:CABAC_CONTEXT_COUNT] = [
        cabac_context_init_state(qp, value)
        for value in cabac_context_init_values(slice_type)
    ]
    return contexts


RANGE_TAB_LPS = (
    (128,176,208,240),(128,167,197,227),(128,158,187,216),(123,150,178,205),
    (116,142,169,195),(111,135,160,185),(105,128,152,175),(100,122,144,166),
    (95,116,137,158),(90,110,130,150),(85,104,123,142),(81,99,117,135),
    (77,94,111,128),(73,89,105,122),(69,85,100,116),(66,80,95,110),
    (62,76,90,104),(59,72,86,99),(56,69,81,94),(53,65,77,89),
    (51,62,73,85),(48,59,69,80),(46,56,66,76),(43,53,63,72),
    (41,50,59,69),(39,48,56,65),(37,45,54,62),(35,43,51,59),
    (33,41,48,56),(32,39,46,53),(30,37,43,50),(29,35,41,48),
    (27,33,39,45),(26,31,37,43),(24,30,35,41),(23,28,33,39),
    (22,27,32,37),(21,26,30,35),(20,24,29,33),(19,23,27,31),
    (18,22,26,30),(17,21,25,28),(16,20,23,27),(15,19,22,25),
    (14,18,21,24),(14,17,20,23),(13,16,19,22),(12,15,18,21),
    (12,14,17,20),(11,14,16,19),(11,13,15,18),(10,12,15,17),
    (10,12,14,16),(9,11,13,15),(9,11,12,14),(8,10,12,14),
    (8,9,11,13),(7,9,11,12),(7,9,10,12),(7,8,10,11),
    (6,8,9,11),(6,7,9,10),(6,7,8,9),(2,2,2,2),
)

TRANS_IDX_MPS = tuple(range(1, 63)) + (62, 63)
TRANS_IDX_LPS = (
    0,0,1,2,2,4,4,5,6,7,8,9,9,11,11,12,
    13,13,15,15,16,16,18,18,19,19,21,21,22,22,23,24,
    24,25,26,26,27,27,28,29,29,30,30,30,31,32,32,33,
    33,33,34,34,35,35,35,36,36,36,37,37,37,38,38,63,
)


@dataclass(frozen=True)
class CabacBinStep:
    low: int
    range: int
    state_index: int
    mps: int
    renorm_bits: int


def cabac_bin_step(
    low: int,
    range_value: int,
    state_index: int,
    mps: int,
    bin_value: int,
    bypass: bool = False,
) -> CabacBinStep:
    """Apply one regular or bypass bin using fixed-width integer math only."""
    if not 0 <= low <= 0xFFFFFFFF:
        raise ValueError("low must fit unsigned 32 bits")
    if not 256 <= range_value <= 510:
        raise ValueError("range must be normalized to 256..510")
    if not 0 <= state_index <= 63:
        raise ValueError("state_index must be in 0..63")
    if mps not in (0, 1) or bin_value not in (0, 1):
        raise ValueError("mps and bin_value must be bits")

    if bypass:
        next_low = ((low << 1) + (range_value if bin_value else 0)) & 0xFFFFFFFF
        return CabacBinStep(next_low, range_value, state_index, mps, 1)

    range_lps = RANGE_TAB_LPS[state_index][(range_value >> 6) & 3]
    range_mps = range_value - range_lps
    if bin_value == mps:
        shift = int(range_mps < 256)
        return CabacBinStep(
            (low << shift) & 0xFFFFFFFF,
            range_mps << shift,
            TRANS_IDX_MPS[state_index],
            mps,
            shift,
        )

    shift = 0
    while (range_lps << shift) < 256:
        shift += 1
    return CabacBinStep(
        ((low + range_mps) << shift) & 0xFFFFFFFF,
        range_lps << shift,
        TRANS_IDX_LPS[state_index],
        mps ^ int(state_index == 0),
        shift,
    )

@dataclass
class CabacContext:
    state_index: int
    mps: int


class CabacByteEncoder:
    """HM-compatible scalar CABAC encoder used as the RTL byte oracle."""

    def __init__(self, contexts: list[tuple[int, int]] | None = None):
        source = contexts if contexts is not None else [(0, 0)] * 256
        if len(source) != 256:
            raise ValueError("exactly 256 context entries are required")
        self.contexts = [CabacContext(state, mps) for state, mps in source]
        for context in self.contexts:
            if not 0 <= context.state_index <= 63 or context.mps not in (0, 1):
                raise ValueError("invalid CABAC context")
        self.start()

    def start(self) -> None:
        self.low = 0
        self.range = 510
        self.bits_left = 23
        self.num_buffered_bytes = 0
        self.buffered_byte = 0xFF
        self.output = bytearray()
        self.finished = False

    def _write_out(self) -> None:
        lead_byte = self.low >> (24 - self.bits_left)
        self.bits_left += 8
        self.low &= 0xFFFFFFFF >> self.bits_left
        if lead_byte == 0xFF:
            self.num_buffered_bytes += 1
            return
        if self.num_buffered_bytes > 0:
            carry = lead_byte >> 8
            self.output.append((self.buffered_byte + carry) & 0xFF)
            self.buffered_byte = lead_byte & 0xFF
            self.output.extend(
                bytes(((0xFF + carry) & 0xFF,))
                * (self.num_buffered_bytes - 1)
            )
            self.num_buffered_bytes = 1
        else:
            self.num_buffered_bytes = 1
            self.buffered_byte = lead_byte

    def _test_and_write_out(self) -> None:
        if self.bits_left < 12:
            self._write_out()

    def encode_regular(self, bin_value: int, context_address: int) -> CabacContext:
        if self.finished:
            raise ValueError("CABAC slice has already finished")
        if not 0 <= context_address < 256:
            raise ValueError("context address must be in 0..255")
        context = self.contexts[context_address]
        result = cabac_bin_step(
            self.low, self.range, context.state_index, context.mps, bin_value
        )
        self.low = result.low
        self.range = result.range
        self.bits_left -= result.renorm_bits
        context.state_index = result.state_index
        context.mps = result.mps
        self._test_and_write_out()
        return CabacContext(context.state_index, context.mps)

    def encode_bypass(self, bin_value: int) -> None:
        if self.finished:
            raise ValueError("CABAC slice has already finished")
        result = cabac_bin_step(
            self.low, self.range, 0, 0, bin_value, bypass=True
        )
        self.low = result.low
        self.range = result.range
        self.bits_left -= 1
        self._test_and_write_out()

    def encode_terminate(self, bin_value: int) -> None:
        if self.finished:
            raise ValueError("CABAC slice has already finished")
        if bin_value not in (0, 1):
            raise ValueError("terminate value must be a bit")
        self.range -= 2
        if bin_value:
            self.low = ((self.low + self.range) << 7) & 0xFFFFFFFF
            self.range = 256
            self.bits_left -= 7
        elif self.range < 256:
            self.low = (self.low << 1) & 0xFFFFFFFF
            self.range <<= 1
            self.bits_left -= 1
        self._test_and_write_out()
        if bin_value:
            self._finish_and_align()

    def _finish_and_align(self) -> None:
        carry_mask = 1 << (32 - self.bits_left)
        if self.low >> (32 - self.bits_left):
            self.output.append((self.buffered_byte + 1) & 0xFF)
            self.output.extend(b"\x00" * max(0, self.num_buffered_bytes - 1))
            self.low = (self.low - carry_mask) & 0xFFFFFFFF
        else:
            if self.num_buffered_bytes > 0:
                self.output.append(self.buffered_byte)
            self.output.extend(b"\xFF" * max(0, self.num_buffered_bytes - 1))

        bit_count = 24 - self.bits_left
        tail = ((self.low >> 8) & ((1 << bit_count) - 1))
        tail = (tail << 1) | 1
        total_bits = bit_count + 1
        padding = (-total_bits) & 7
        tail <<= padding
        total_bytes = (total_bits + padding) >> 3
        self.output.extend(tail.to_bytes(total_bytes, "big"))
        self.finished = True

    def bytes(self) -> bytes:
        if not self.finished:
            raise ValueError("terminate bin 1 has not been encoded")
        return bytes(self.output)
