#!/usr/bin/env python3
"""PC-side tests (CPython, no board needed).

1. mac_protocol: range checks, encoding, decoding, overflow model.
2. shrike_mac driver: runs against a fake `machine` module whose SPI behaves like
   the FPGA protocol in top.v, checking the exact bytes the RP2040 would send.

Run:  python tests/test_host.py
"""
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "firmware", "micropython"))

import mac_protocol as P  # noqa: E402


# ---------------------------------------------------------------- fake board
class FakeFpga:
    """Behavioural model of top.v's SPI protocol (frame applied at CS high)."""

    def __init__(self):
        self.reset()
        self.frames = []

    def reset(self):
        self.acc, self.init, self.ovf = 0, False, False
        self.e_un = self.e_fr = self.e_cmd = False

    def status(self):
        return (0x40 | self.e_cmd << 4 | self.e_fr << 3 | self.e_un << 2
                | self.ovf << 1 | self.init)

    def frame(self, tx):
        self.frames.append(bytes(tx))
        rx = bytearray(len(tx))
        rx[0] = 0xA5
        cmd = tx[0]
        if cmd == 0x03:
            snap = (self.acc & 0xFFFFFFFF).to_bytes(4, "big") + bytes([self.status()])
            for i in range(1, min(len(tx), 6)):
                rx[i] = snap[i - 1]
            if len(tx) != 6:
                self.e_fr = True
        elif cmd == 0x01:
            if len(tx) == 1:
                self.acc, self.ovf, self.init = 0, False, True
                self.e_un = self.e_fr = self.e_cmd = False
            else:
                self.e_fr = True
        elif cmd == 0x02:
            if len(tx) != 3:
                self.e_fr = True
            elif not self.init:
                self.e_un = True
            else:
                a = tx[1] - 256 if tx[1] > 127 else tx[1]
                b = tx[2] - 256 if tx[2] > 127 else tx[2]
                self.acc, o = P.mac_model(self.acc, a, b)
                self.ovf = self.ovf or o
        else:
            self.e_cmd = True
        return rx


FPGA = FakeFpga()


class FakePin:
    OUT, IN = 1, 0

    def __init__(self, num, mode=None, value=None):
        self.num, self.v = num, value

    def value(self, v=None):
        if v is None:
            return self.v
        if self.num == 14 and v == 0:
            FPGA.reset()
        self.v = v


class FakeSPI:
    MSB = 0

    def __init__(self, *a, **kw):
        self.cfg = kw

    def write_readinto(self, tx, rx):
        rx[:] = FPGA.frame(tx)


machine = types.ModuleType("machine")
machine.Pin, machine.SPI = FakePin, FakeSPI
sys.modules["machine"] = machine
import time as _t  # noqa: E402
_t.sleep_ms = lambda ms: None

import shrike_mac  # noqa: E402


# ---------------------------------------------------------------- tests
class ProtocolTests(unittest.TestCase):
    def test_range_rejected_not_wrapped(self):
        for bad in (128, -129, 255, 1000, -1000):
            with self.assertRaises(ValueError):
                P.encode_mac(bad, 0)
            with self.assertRaises(ValueError):
                P.encode_mac(0, bad)
        for bad in (True, False, 1.0, "1", None):
            with self.assertRaises(TypeError):
                P.encode_mac(bad, 0)

    def test_encoding(self):
        self.assertEqual(P.encode_clear(), b"\x01")
        self.assertEqual(P.encode_mac(-128, 127), b"\x02\x80\x7f")
        self.assertEqual(P.encode_mac(-1, 0), b"\x02\xff\x00")
        self.assertEqual(P.encode_read(), b"\x03\x00\x00\x00\x00\x00")

    def test_decode_big_endian_signed(self):
        self.assertEqual(P.decode_read(b"\xa5\x80\x00\x00\x00\x43"), (-2**31, 0x43))
        self.assertEqual(P.decode_read(b"\xa5\x7f\xff\xff\xff\x41"), (2**31 - 1, 0x41))
        self.assertEqual(P.decode_read(b"\xa5\xff\xff\xff\xfa\x41"), (-6, 0x41))
        self.assertEqual(P.decode_read(b"\xa5\x00\x01\x02\x03\x41"), (0x010203, 0x41))

    def test_decode_link_errors(self):
        with self.assertRaises(P.LinkError):
            P.decode_read(b"\x00\x00\x00\x00\x00\x00")     # MISO stuck low
        with self.assertRaises(P.LinkError):
            P.decode_read(b"\xff\xff\xff\xff\xff\xff")     # MISO stuck high / floating
        with self.assertRaises(P.LinkError):
            P.decode_read(b"\xa5\x00\x00\x00\x00\x01")     # bad signature

    def test_model_overflow(self):
        self.assertEqual(P.mac_model(2**31 - 16385, -128, -128), (2**31 - 1, False))
        self.assertEqual(P.mac_model(2**31 - 1, 1, 1), (-2**31, True))
        self.assertEqual(P.mac_model(-2**31 + 16256, -128, 127), (-2**31, False))
        self.assertEqual(P.mac_model(-2**31, -1, 1), (2**31 - 1, True))
        self.assertEqual(P.mac_model(0, -128, -128), (16384, False))


class DriverTests(unittest.TestCase):
    def setUp(self):
        FPGA.reset()
        FPGA.frames.clear()
        self.m = shrike_mac.ShrikeMac()

    def test_spi_config(self):
        cfg = self.m.spi.cfg
        self.assertEqual((cfg["polarity"], cfg["phase"], cfg["bits"]), (0, 0, 8))
        self.assertEqual(cfg["baudrate"], 1_000_000)

    def test_mac_requires_clear(self):
        with self.assertRaises(RuntimeError):
            self.m.mac(1, 1)
        self.assertEqual(FPGA.frames, [])            # nothing was sent

    def test_flow(self):
        self.m.clear()
        self.m.mac(-128, -128)
        self.m.mac(3, -4)
        acc, st = self.m.read()
        self.assertEqual(acc, 16384 - 12)
        self.assertEqual(st, 0x41)
        self.assertEqual(FPGA.frames[:3], [b"\x01", b"\x03\x00\x00\x00\x00\x00", b"\x02\x80\x80"])

    def test_bad_value_sends_nothing(self):
        self.m.clear()
        n = len(FPGA.frames)
        with self.assertRaises(ValueError):
            self.m.mac(200, 1)
        self.assertEqual(len(FPGA.frames), n)

    def test_reset_requires_new_clear(self):
        self.m.clear()
        self.m.reset_logic()
        with self.assertRaises(RuntimeError):
            self.m.mac(1, 1)
        self.assertEqual(self.m.read(), (0, 0x40))


if __name__ == "__main__":
    unittest.main(verbosity=2)
