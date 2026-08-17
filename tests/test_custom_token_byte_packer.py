from __future__ import annotations

import random

from custom_budget_writer import Layer
from custom_token_byte_packer import TokenBytePacker, left_align_token


def reference_bytes(tokens: list[tuple[int, int]]) -> bytes:
    bits: list[int] = []
    for value, length in tokens:
        bits.extend((value >> shift) & 1 for shift in range(length - 1, -1, -1))
    while len(bits) % 8:
        bits.append(0)
    return bytes(
        sum(bits[index + offset] << (7 - offset) for offset in range(8))
        for index in range(0, len(bits), 8)
    )


def test_known_partial_byte_is_zero_padded() -> None:
    packer = TokenBytePacker()
    packer.submit(Layer.BASE, left_align_token(0b101, 3), 3)
    packer.submit(Layer.BASE, left_align_token(0b11, 2), 2)
    packer.finish()

    assert [(int(item.layer), item.value) for item in packer.output] == [(0, 0b10111000)]
    assert packer.byte_count == [1, 0]


def test_layers_keep_independent_partial_bytes() -> None:
    packer = TokenBytePacker()
    packer.submit(Layer.BASE, left_align_token(0xA, 4), 4)
    packer.submit(Layer.ENHANCEMENT, left_align_token(0x3, 2), 2)
    packer.submit(Layer.BASE, left_align_token(0x5, 4), 4)
    packer.submit(Layer.ENHANCEMENT, left_align_token(0x2A, 6), 6)
    packer.finish()

    assert [(int(item.layer), item.value) for item in packer.output] == [(0, 0xA5), (1, 0xEA)]
    assert packer.byte_count == [1, 1]


def test_exact_byte_alignment_does_not_emit_padding_byte() -> None:
    packer = TokenBytePacker()
    packer.submit(Layer.BASE, left_align_token(0xD3, 8), 8)
    assert len(packer.finish()) == 0
    assert bytes(item.value for item in packer.output) == b"\xd3"


def test_random_tokens_match_bit_reference_per_layer() -> None:
    rng = random.Random(0x5041434B)
    natural: list[list[tuple[int, int]]] = [[], []]
    packer = TokenBytePacker()
    for _ in range(300):
        layer = Layer(rng.randrange(2))
        length = rng.randrange(1, 33)
        value = rng.getrandbits(length)
        natural[int(layer)].append((value, length))
        packer.submit(layer, left_align_token(value, length), length)
    packer.finish()

    for layer in Layer:
        actual = bytes(item.value for item in packer.output if item.layer is layer)
        assert actual == reference_bytes(natural[int(layer)])

