# shrike_mac.py -- RP2040 (MicroPython) driver for the Shrike Lite MAC bitstream.
#
# Pins (Shrike Lite internal RP2040 <-> FPGA link, official pin-out table):
#   RP2040 GPIO2  -> FPGA GPIO3   SPI SCK
#   RP2040 GPIO1  -> FPGA GPIO4   SPI CS (active low)
#   RP2040 GPIO3  -> FPGA GPIO5   SPI MOSI
#   RP2040 GPIO0  <- FPGA GPIO6   SPI MISO
#   RP2040 GPIO14 -> FPGA GPIO18  logic reset (active low)
#   RP2040 GPIO12/13 = FPGA PWR/EN -- owned by shrike.flash(); do not touch.
#
# IMPORTANT: the accumulator must be cleared before any arithmetic.
#   mac = ShrikeMac(); mac.clear(); mac.mac(3, -4); print(mac.read())
# mac() raises RuntimeError until clear() has succeeded, and the FPGA itself
# also refuses MACs before CLEAR (status flag ERR_UNINIT).

import time
from machine import Pin, SPI

import mac_protocol as P

SPI_ID = 0
PIN_SCK = 2
PIN_MOSI = 3
PIN_MISO = 0
PIN_CS = 1
PIN_RST = 14
SPI_BAUD = 1_000_000        # 1 MHz; FPGA design is simulated up to 4 MHz


class ShrikeMac:
    def __init__(self, baudrate=SPI_BAUD):
        self.cs = Pin(PIN_CS, Pin.OUT, value=1)
        self.rst = Pin(PIN_RST, Pin.OUT, value=1)
        self.spi = SPI(SPI_ID, baudrate=baudrate, polarity=0, phase=0, bits=8,
                       firstbit=SPI.MSB, sck=Pin(PIN_SCK), mosi=Pin(PIN_MOSI),
                       miso=Pin(PIN_MISO))
        self._cleared = False

    # -- low level ---------------------------------------------------------
    def _xfer(self, tx):
        rx = bytearray(len(tx))
        self.cs.value(0)
        self.spi.write_readinto(tx, rx)
        self.cs.value(1)
        P.check_sync(rx)
        return rx

    def reset_logic(self):
        """Pulse the FPGA logic reset (keeps the bitstream). Requires clear() again."""
        self.rst.value(0)
        time.sleep_ms(5)
        self.rst.value(1)
        time.sleep_ms(5)
        self._cleared = False

    # -- commands ------------------------------------------------------------
    def read(self):
        """Return (acc, status) -- acc is a signed 32-bit Python int."""
        return P.decode_read(self._xfer(P.encode_read()))

    def clear(self):
        """Zero the accumulator and all flags. Must be called before mac()."""
        self._xfer(P.encode_clear())
        acc, st = self.read()
        if acc != 0 or st != (P.ST_SIG | P.ST_INIT):
            raise P.LinkError("CLEAR not confirmed: acc=%d status=%s"
                              % (acc, P.describe_status(st)))
        self._cleared = True

    def mac(self, a, b):
        """acc += a*b, where a and b are ints in -128..127 (out of range -> error)."""
        frame = P.encode_mac(a, b)        # validates range/type first
        if not self._cleared:
            raise RuntimeError("accumulator not initialised: call clear() first")
        self._xfer(frame)

    def status(self):
        return self.read()[1]
