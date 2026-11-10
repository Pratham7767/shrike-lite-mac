# main.py -- Shrike Lite MAC demo (MicroPython, Vicharak Shrike-Lite UF2).
#
# Copy to the board: mac_shrike.bin, mac_protocol.py, shrike_mac.py, main.py
# Then run main.py in Thonny (or reset the board: main.py runs at boot).

import time
import shrike                      # provided by the official Shrike-Lite MicroPython UF2

import mac_protocol as P
from shrike_mac import ShrikeMac

BITSTREAM = "mac_shrike.bin"       # renamed copy of FPGA_bitstream_MCU.bin
RUN_OVERFLOW_DEMO = False          # True -> 131072 MACs to show OVF (slow: minutes)

# 1) Configure the FPGA (volatile SPI configuration -- NOT the one-time OTP)
print("Loading", BITSTREAM, "into the FPGA ...")
shrike.flash(BITSTREAM)
time.sleep_ms(100)

# 2) Open the SPI link and reset the MAC logic
mac = ShrikeMac()
mac.reset_logic()
acc, st = mac.read()
print("After reset : acc =", acc, " status =", P.describe_status(st))
if st != P.ST_SIG:
    print("WARNING: expected status 0x40 right after reset")

# 3) REQUIRED: clear the accumulator before any arithmetic
mac.clear()
acc, st = mac.read()
print("After CLEAR : acc =", acc, " status =", P.describe_status(st))

# 4) Out-of-range inputs are rejected on the RP2040, never wrapped
for bad in ((128, 1), (-129, 1), (1, 300), (True, 2), (1.5, 2)):
    try:
        mac.mac(*bad)
        print("ERROR: accepted", bad)
    except (ValueError, TypeError) as e:
        print("Rejected", bad, "->", e)

# 5) Corner cases + a dot product, checked against the Python model
a_vec = [-128, 127, -128, 127, -1, 0, 64, -100, 3, -7]
b_vec = [-128, 127, 127, -128, -1, -128, -2, 100, 5, 9]
model = 0
fails = 0
for a, b in zip(a_vec, b_vec):
    mac.mac(a, b)
    model, _ = P.mac_model(model, a, b)
    got, st = mac.read()
    ok = (got == model) and not (st & (P.ST_OVF | P.ST_ERR_UNINIT | P.ST_ERR_FRAME | P.ST_ERR_CMD))
    fails += 0 if ok else 1
    print("%5d * %5d  -> acc = %8d  (expected %8d) %s" % (a, b, got, model, "ok" if ok else "MISMATCH"))

# 6) A quick speed/bulk check: 1000 pseudo-random MACs
seed = 1
t0 = time.ticks_ms()
for _ in range(1000):
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    a = ((seed >> 8) & 0xFF) - 128
    b = ((seed >> 16) & 0xFF) - 128
    mac.mac(a, b)
    model, _ = P.mac_model(model, a, b)
dt = time.ticks_diff(time.ticks_ms(), t0)
got, st = mac.read()
print("1000 random MACs in %d ms: acc = %d, expected %d, status %s"
      % (dt, got, model, P.describe_status(st)))
if got != model:
    fails += 1

print("RESULT:", "PASS" if fails == 0 else "FAIL (%d)" % fails)

# 7) Optional: drive the accumulator past +2^31-1 to see wrap + OVF flag
if RUN_OVERFLOW_DEMO:
    mac.clear()
    print("Overflow demo: 131072 x (-128 * -128) ...")
    for i in range(131072):
        mac.mac(-128, -128)
    got, st = mac.read()
    print("acc =", got, "(expected -2147483648 after wrap), status", P.describe_status(st))
