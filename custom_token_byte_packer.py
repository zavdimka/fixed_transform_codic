"""Reference model for the FPGA-friendly VLC token-to-byte serializer."""

from __future__ import annotations

from dataclasses import dataclass

from custom_budget_writer import Layer


TOKEN_WIDTH = 32


def left_align_token(value: int, bit_length: int) -> int:
    """Convert a natural integer code to the FPGA wire representation."""
    if not 1 <= bit_length <= TOKEN_WIDTH:
        raise ValueError("token length must be in the range 1..32")
    return (int(value) & ((1 << bit_length) - 1)) << (TOKEN_WIDTH - bit_length)


@dataclass(frozen=True)
class PackedByte:
    layer: Layer
    value: int


class TokenBytePacker:
    """Serialize left-aligned tokens MSB-first into two independent layers."""

    def __init__(self) -> None:
        self.partial = [0, 0]
        self.partial_bits = [0, 0]
        self.output: list[PackedByte] = []
        self.byte_count = [0, 0]
        self.finished = False

    def submit(self, layer: Layer, bits: int, bit_length: int) -> list[PackedByte]:
        if self.finished:
            raise RuntimeError("cannot submit a token after finish")
        layer_index = int(layer)
        if not 0 <= layer_index < 2:
            raise ValueError("invalid layer")
        if not 1 <= bit_length <= TOKEN_WIDTH:
            raise ValueError("token length must be in the range 1..32")

        emitted: list[PackedByte] = []
        wire_bits = int(bits) & 0xFFFFFFFF
        for bit_index in range(bit_length):
            bit = (wire_bits >> (31 - bit_index)) & 1
            self.partial[layer_index] = (self.partial[layer_index] << 1) | bit
            self.partial_bits[layer_index] += 1
            if self.partial_bits[layer_index] == 8:
                packed = PackedByte(layer, self.partial[layer_index])
                self.output.append(packed)
                emitted.append(packed)
                self.byte_count[layer_index] += 1
                self.partial[layer_index] = 0
                self.partial_bits[layer_index] = 0
        return emitted

    def finish(self) -> list[PackedByte]:
        if self.finished:
            raise RuntimeError("packer already finished")
        emitted: list[PackedByte] = []
        for layer in Layer:
            layer_index = int(layer)
            if self.partial_bits[layer_index]:
                value = self.partial[layer_index] << (8 - self.partial_bits[layer_index])
                packed = PackedByte(layer, value)
                self.output.append(packed)
                emitted.append(packed)
                self.byte_count[layer_index] += 1
                self.partial[layer_index] = 0
                self.partial_bits[layer_index] = 0
        self.finished = True
        return emitted

