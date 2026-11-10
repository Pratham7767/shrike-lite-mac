# mac_protocol.py -- Shrike Lite MAC: SPI protocol helpers + reference model.
#
# Pure Python: runs unchanged on the board (MicroPython) and on a PC (CPython),
# so the same code is unit-tested on the PC and used by main.py on the board.
#
# SPI: mode 0 (CPOL=0, CPHA=0), MSB first, 8-bit, CS framed, 1 MHz default.
#   CLEAR  MOSI 01                 MISO A5
#   MAC    MOSI 02 AA BB           MISO A5 00 00
#   READ   MOSI 03 00 00 00 00 00  MISO A5 A3 A2 A1 A0 ST   (acc big-endian)

CMD_CLEAR = 0x01
CMD_MAC = 0x02
CMD_READ = 0x03
SYNC = 0xA5

LEN_CLEAR = 1
LEN_MAC = 3
LEN_READ = 6

# status byte bits
ST_INIT = 0x01
ST_OVF = 0x02
ST_ERR_UNINIT = 0x04
ST_ERR_FRAME = 0x08
ST_ERR_CMD = 0x10
ST_SIG_MASK = 0xE0
ST_SIG = 0x40          # bits 7:5 are always 0b010

S8_MIN = -128
S8_MAX = 127
S32_MIN = -(1 << 31)
S32_MAX = (1 << 31) - 1


class LinkError(Exception):
    """The FPGA did not answer with the expected SYNC/status pattern."""


def check_s8(value, name="value"):
    """Accept only a real int in -128..127. Never wrap silently."""
    if type(value) is not int:          # rejects bool, float, str, ...
        raise TypeError("%s must be an int, got %r" % (name, value))
    if value < S8_MIN or value > S8_MAX:
        raise ValueError("%s=%d is outside signed 8-bit range -128..127" % (name, value))
    return value


def encode_clear():
    return bytes([CMD_CLEAR])


def encode_mac(a, b):
    check_s8(a, "a")
    check_s8(b, "b")
    return bytes([CMD_MAC, a & 0xFF, b & 0xFF])


def encode_read():
    return bytes([CMD_READ, 0, 0, 0, 0, 0])


def to_s32(u):
    u &= 0xFFFFFFFF
    return u - (1 << 32) if u & 0x80000000 else u


def check_sync(rx):
    if len(rx) == 0 or rx[0] != SYNC:
        raise LinkError("expected SYNC 0xA5, got %s (is the MAC bitstream loaded? "
                        "is the FPGA out of reset?)" % (bytes(rx).hex() if rx else "nothing"))


def decode_read(rx):
    """rx = 6 bytes clocked in during a READ frame -> (acc, status)."""
    if len(rx) != LEN_READ:
        raise ValueError("READ response must be 6 bytes")
    check_sync(rx)
    st = rx[5]
    if st & ST_SIG_MASK != ST_SIG:
        raise LinkError("bad status signature 0x%02X (MISO stuck or wrong bitstream)" % st)
    acc = to_s32((rx[1] << 24) | (rx[2] << 16) | (rx[3] << 8) | rx[4])
    return acc, st


def describe_status(st):
    names = []
    for bit, name in ((ST_INIT, "INIT"), (ST_OVF, "OVF"), (ST_ERR_UNINIT, "ERR_UNINIT"),
                      (ST_ERR_FRAME, "ERR_FRAME"), (ST_ERR_CMD, "ERR_CMD")):
        if st & bit:
            names.append(name)
    return "0x%02X [%s]" % (st, " ".join(names) if names else "-")


def mac_model(acc, a, b):
    """Reference model of the FPGA: returns (new_acc_wrapped, overflowed_this_step)."""
    check_s8(a, "a")
    check_s8(b, "b")
    exact = acc + a * b
    wrapped = to_s32(exact)
    return wrapped, (exact < S32_MIN or exact > S32_MAX)
