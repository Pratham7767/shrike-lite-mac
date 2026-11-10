#!/usr/bin/env python3
"""Generate golden MAC vectors for tb_mac.v from an independent Python model.

Each line of vectors.txt:  AA BB EEEEEEEE O
  AA, BB    operands as 8-bit two's-complement hex
  EEEEEEEE  expected accumulator after this MAC (32-bit hex, wrapped)
  O         expected sticky overflow flag (0/1)
The sequence starts from a cleared accumulator.

Usage:  python gen_vectors.py [count] [seed]   (defaults: 3000, 12345)
"""
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "firmware", "micropython"))
from mac_protocol import mac_model  # noqa: E402  (same model the firmware uses)

CORNERS = [
    (0, 0), (1, 1), (-1, -1), (-1, 1), (127, 127), (-128, -128),
    (-128, 127), (127, -128), (-128, 1), (1, -128), (0, -128), (-128, 0),
    (64, -2), (-2, 64), (100, -100), (-7, 9),
]


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 12345
    rng = random.Random(seed)
    pairs = list(CORNERS)
    pairs += [(rng.randint(-128, 127), rng.randint(-128, 127)) for _ in range(count)]
    acc, ovf = 0, False
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors.txt")
    with open(out, "w") as f:
        for a, b in pairs:
            acc, o = mac_model(acc, a, b)
            ovf = ovf or o
            f.write("%02x %02x %08x %d\n" % (a & 0xFF, b & 0xFF, acc & 0xFFFFFFFF, int(ovf)))
    print("wrote %d vectors to %s (final acc = %d)" % (len(pairs), out, acc))


if __name__ == "__main__":
    main()
