# Shrike Lite signed MAC (multiply-accumulate) over the built-in RP2040 ↔ FPGA SPI link

A complete beginner project for the **Vicharak Shrike Lite** (RP2040 + Renesas ForgeFPGA SLG47910V):

```
acc  <=  acc + a × b        a, b  : signed 8-bit   (-128 … 127)
                            a × b : signed 16-bit  (exact, never rounded)
                            acc   : signed 32-bit  (wraps; sticky overflow flag)
```

The RP2040 (MicroPython) loads the FPGA, clears the accumulator, sends operand pairs and reads the signed result back — all over the board's internal wiring. **No jumper wires.**

---

## 0. Status — what is and isn't verified

| Item | Status |
|---|---|
| RTL simulation (Icarus Verilog 12, 50 MHz clock, real SPI waveforms) | ✅ **Passed**: 11 852 checks, 0 errors (`sim/sim_log.txt`) |
| Full overflow through SPI only (131 072 MACs) | ✅ **Passed** (`sim/sim_log_full_overflow.txt`) |
| Testbench catches injected bugs (unsigned multiply, no overflow check, wrong byte order, missing init check) | ✅ All 4 mutations failed the test as they should |
| Host Python: range rejection, encoding, decoding, driver framing | ✅ 10/10 unit tests (CPython); firmware compiles with `mpy-cross`; protocol module runs on MicroPython (unix port); `main.py` dry-run on a PC against a Python model of the FPGA prints `RESULT: PASS` (this checks the firmware logic, not the hardware) |
| Generic Yosys lint/synthesis (LUT-5 estimate, **not** the Renesas tool) | ✅ ~380 LUTs + 163 FFs — an estimate only |
| **Renesas Go Configure v6.56 synthesis + place-and-route** (run by the user on Windows, 10 Nov 2026) | ✅ 0 errors; 4 harmless PnR warnings (see section 9) |
| **Fits in the SLG47910** | ✅ 362 / 1120 LUT5 (32 %), 163 FFs (159 CLB + 4 IOB), 64 / 140 CLBs (46 %), 6 / 19 GPIOs, 0 PLL, 0 BRAM, 1 OSC |
| **Meets 50 MHz** | ✅ Post-route achievable frequency **68.6 MHz** (worst path 14.6 ns vs 20 ns needed). The report's negative slack is against the tool's automatic 500 MHz target because no clock constraint was given, not against 50 MHz. |
| **Physical board test** (user's Shrike Lite, Thonny, 11 Nov 2026) | ✅ `main.py` printed `RESULT: PASS`: reset status 0x40, CLEAR → 0x41, all 5 bad inputs rejected, 10 corner-case MACs correct, 1000 random MACs matched the model (acc = 270106) in 806 ms (≈0.8 ms per MAC incl. MicroPython overhead). Overflow demo not run. |

---

## 1. Board facts this design relies on (checked against official sources)

| Fact | Value | Source |
|---|---|---|
| FPGA | Renesas ForgeFPGA **SLG47910V** | [Vicharak README](https://github.com/vicharak-in/shrike), [TinyGo board page](https://tinygo.org/docs/reference/microcontrollers/vicharak_shrike-lite) |
| Logic | 1120 LUTs + 1120 DFFs. Vicharak says "1120 5-input LUTs"; the Renesas product page says 1120 6-input/2-output LUTs; the datasheet (Rev 1.06) says 1120 5-bit LUTs that pair into 560 6-bit LUTs. Same silicon, different counting. | [Shrike README](https://github.com/vicharak-in/shrike), [Renesas SLG47910](https://www.renesas.com/en/products/slg47910), [datasheet](https://www.renesas.com/en/document/dst/slg47910-datasheet) |
| Memory | 5 kb distributed RAM, 32 kb BRAM (2 × 16 kb) — unused here | [Renesas SLG47910](https://www.renesas.com/en/products/slg47910) |
| **DSP / hard multiplier** | **None listed.** The multiplier is built from LUTs. Vicharak's example projects also set `noDSP = true` in synthesis. | [datasheet](https://www.renesas.com/en/document/dst/slg47910-datasheet), `spi_loopback_led.ffpga` in [shrike/examples](https://github.com/vicharak-in/shrike/tree/main/examples/spi_loopback_led) |
| Clock | On-chip **50 MHz** oscillator (`OSC_CLK`, enabled by `OSC_EN`); one PLL (unused) | [datasheet](https://www.renesas.com/en/document/dst/slg47910-datasheet), [Vicharak bitstream guide](https://vicharak-in.github.io/shrike/generating_your_first_bitstream.html) |
| Every FPGA output needs an output-enable | yes — e.g. `LED` + `LED_en` → `GPIO16_OUT` + `GPIO16_OE` | [Vicharak bitstream guide](https://vicharak-in.github.io/shrike/generating_your_first_bitstream.html) |
| I/O voltage | **3.3 V only.** Absolute max 3.6 V on FPGA inputs. Board supply 5 V via USB-C **or** 5 V header, never both. | [hardware overview](https://vicharak-in.github.io/shrike/hardware_overview.html), [datasheet](https://www.renesas.com/en/document/dst/slg47910-datasheet) |
| Configuration | RP2040 loads the bitstream into the FPGA over SPI (FPGA in **SPI-Target** mode, volatile — lost at power-off). The SLG47910 also has **one-time-programmable** NVM; this project never touches it. | [datasheet](https://www.renesas.com/en/document/dst/slg47910-datasheet), [getting started](https://vicharak-in.github.io/shrike/getting_started.html) |

### The built-in RP2040 ↔ FPGA link (official table)

From [Shrike pin-outs → FPGA CPU Interconnect](https://vicharak-in.github.io/shrike/shrike_pinouts.html#fpga-rp2040-communication-pin-outs):

| FPGA pin | RP2040 GPIO | Role during configuration | Role in **this** design |
|---|---|---|---|
| EN | 13 | FPGA enable | owned by `shrike.flash()` — don't touch |
| PWR | 12 | FPGA power | owned by `shrike.flash()` — don't touch |
| GPIO3 | 2 | SPI_SCLK | **SPI SCK** (in) |
| GPIO4 | 1 | SPI_SS | **SPI CS, active low** (in) |
| GPIO5 | 3 | SPI_SI (MOSI) | **SPI MOSI** (in) |
| GPIO6 | 0 | SPI_SO (MISO) / CONFIG | **SPI MISO** (out, with OE) |
| GPIO18 | 14 | — (plain GPIO via 0 Ω resistor) | **logic reset `rst_n`, active low** (in) |
| GPIO17 | 15 | — (plain GPIO via 0 Ω resistor) | unused |

Why these pins are safe to reuse after configuration: Vicharak states that the 4 configuration pins are "dual purpose", used first to program the FPGA and *then* as an I/O bus, and that GPIO17/18 are wired to RP2040 GPIO15/14 by default-fitted 0 Ω resistors ([pin-outs page](https://vicharak-in.github.io/shrike/shrike_pinouts.html)). Vicharak's own [`spi_loopback_led`](https://github.com/vicharak-in/shrike/tree/main/examples/spi_loopback_led) example (marked "Tested" on Shrike-Lite) uses exactly this SPI pin set at 1 MHz, mode 0, plus GPIO14→FPGA GPIO18 as reset. This design deliberately uses the **same port names** as that example.

### Board revision notes
* Vicharak's bitstreams are published under [`test/bitstreams/v1_4`](https://github.com/vicharak-in/shrike/tree/main/test/bitstreams). Current docs put EN/PWR on RP2040 GPIO13/12.
* An **archived** early script in the same repo (`archive/MCU_FFPGA_script`) used **EN = GPIO14, PWR = GPIO15**. If you have a very early prototype board, GPIO14 might not be the reset line — check your board's silkscreen/revision before running, or ask on Vicharak's Discord. Retail Shrike Lite boards follow the current table.
* If someone removed the 0 Ω resistors on FPGA pins 17/18, GPIO14 no longer reaches the FPGA (the design would then sit in reset — see troubleshooting).

---

## 2. Are these widths sensible? (plain language)

* **8-bit signed inputs** — each operand is one byte, so it travels in one SPI byte. Range −128…127 is the usual "int8" used in small neural nets and DSP.
* **16-bit product** — the largest magnitude of an 8×8 signed product is (−128)×(−128) = +16 384 and the most negative is −128×127 = −16 256. Both fit in a signed 16-bit number, so the product is always **exact**.
* **32-bit accumulator** — gives enormous headroom: starting from 0, even the worst case (+16 384 every time) needs **131 072 MACs** before the value can exceed +2 147 483 647. Most dot products are far shorter.
* **Overflow policy: wrap + sticky flag.** If it ever goes past the 32-bit range, the value wraps around like normal two's-complement hardware (e.g. +2 147 483 647 + 1 → −2 147 483 648) **and** the `OVF` status bit turns on and stays on until the next CLEAR. Nothing is hidden: the host always sees the flag.

**Verdict: the requested widths are appropriate — kept unchanged.** The built-in SPI link is also the right channel: it is the only RP2040↔FPGA path that needs no wiring and it is the method Vicharak's tested examples use.

### Feasibility and limits
* No hard multiplier, so the 8×8 multiplier, the 32-bit adder and the SPI logic all use LUTs. A *generic* Yosys LUT-5 mapping gives ~380 LUTs and 163 flip-flops (≈34 % / 15 % of 1120) — see `synth/generic_estimate.log`. That is an **estimate from a different tool**; Renesas' own flow (with carry chains) may come out lower or higher. Vicharak's PicoRV32 CPU example also fits this FPGA, which suggests ample room, but **only your Go Configure report confirms the fit.**
* Timing: the multiply and the add are in separate pipeline stages to make 50 MHz easier. Check the timing summary in Go Configure (section 6.5).
* Speed is limited by the host, not the FPGA: each MAC is a 3-byte SPI frame (24 µs at 1 MHz) plus MicroPython overhead. The demo prints the measured time for 1000 MACs.

---

## 3. Host interface (SPI protocol)

| Parameter | Value |
|---|---|
| SPI mode | **0** (CPOL = 0, CPHA = 0): SCK idles low, both sides sample on the rising edge |
| Bit order | **MSB first** |
| Word size | 8 bits |
| Framing | One command per CS-low period (a "frame") |
| Clock | **1 MHz** default (same as Vicharak's tested example). Simulated OK at 1, 2, 4 MHz. Hard rule: SCK half-period ≥ 6 FPGA clocks (≥ 120 ns), i.e. SCK ≤ 4 MHz. |
| Timing | CS low → first SCK edge ≥ 100 ns; last SCK edge → CS high ≥ 100 ns; CS high between frames ≥ 200 ns. (MicroPython is far slower than this.) |
| Byte order of multi-byte values | **Big-endian** (most significant byte first) |
| First MISO byte of every frame | **0xA5** (SYNC) — proves the link and the bitstream are alive |

| Command | MOSI bytes | MISO bytes | Effect |
|---|---|---|---|
| CLEAR | `01` | `A5` | acc = 0, OVF = 0, all error flags = 0, INIT = 1 |
| MAC | `02 aa bb` | `A5 00 00` | acc += aa × bb (aa, bb are two's-complement bytes). **Refused if INIT = 0.** |
| READ | `03 00 00 00 00 00` | `A5 A3 A2 A1 A0 ST` | A3..A0 = acc (A3 = bits 31:24), ST = status |

Rules: a command is executed when CS goes high, **only if the frame length is exactly right** (CLEAR 1, MAC 3, READ 6 bytes); otherwise it is dropped and `ERR_FRAME` is set. Unknown command bytes set `ERR_CMD`. The result of a MAC is ready ~100 ns after CS goes high.

**Status byte `ST`** = `0 1 0 ERR_CMD ERR_FRAME ERR_UNINIT OVF INIT` (bit 7 → bit 0)

| Bit | Name | Meaning |
|---|---|---|
| 0 | INIT | Accumulator has been cleared since reset/configuration |
| 1 | OVF | Sticky: 32-bit signed overflow happened since last CLEAR |
| 2 | ERR_UNINIT | A MAC was sent before CLEAR (it was ignored) |
| 3 | ERR_FRAME | A frame had the wrong length (it was ignored) |
| 4 | ERR_CMD | Unknown command byte |
| 7:5 | `010` | Constant signature; catches a stuck/floating MISO line |

So: right after reset `ST = 0x40`; after CLEAR `ST = 0x41`; with overflow `0x43`.
The FPGA user LED (GPIO16) is **on** when INIT = 1 and no OVF/error flag is set.

### Initialization is mandatory
The accumulator must be cleared before arithmetic — enforced twice:
1. **FPGA**: after reset `INIT = 0`; any MAC is ignored and sets `ERR_UNINIT`.
2. **Firmware**: `ShrikeMac.mac()` raises `RuntimeError` until `clear()` has succeeded (and `clear()` reads back to confirm acc = 0, ST = 0x41). After `reset_logic()` you must clear again.

Out-of-range operands (e.g. 128, −129, `True`, `1.5`) raise `ValueError`/`TypeError` on the RP2040 **before anything is sent**. They are never wrapped.

---

## 4. Project files

```
shrike_mac/
├── README.md                     ← this file
├── ffpga/
│   ├── src/top.v                 ← top level: ports, command decoder, status
│   ├── src/spi_byte_target.v     ← SPI target (mode 0, MSB first)
│   ├── src/mac_core.v            ← signed 8×8 multiply + 32-bit accumulate
│   ├── mac_all_in_one.v          ← the three files above in one (paste into main.v)
│   └── constraints/mac_shrike.sdc← optional 50 MHz clock constraint (not yet picked up by v6.56)
├── bitstream/                    ← put mac_shrike.bin here (see bitstream/README.md)
├── firmware/micropython/
│   ├── main.py                   ← demo: flash FPGA, reset, CLEAR, test, print PASS/FAIL
│   ├── shrike_mac.py             ← driver class ShrikeMac (clear / mac / read)
│   └── mac_protocol.py           ← protocol constants, range checks, reference model
├── sim/
│   ├── tb_mac.v                  ← self-checking testbench
│   ├── gen_vectors.py            ← golden vectors from the Python model
│   ├── run_sim.bat / run_sim.sh  ← one-click simulation
│   ├── vectors.txt               ← generated by gen_vectors.py (not committed)
│   ├── sim_log.txt               ← my passing run
│   └── sim_log_full_overflow.txt ← my passing 131 072-MAC overflow run
├── docs/
│   ├── images/                   ← screenshots + diagrams used by the blog post
│   └── blog/                     ← post_template.md, build_post.py → post_dev.md, post_standalone.html
├── synth/generic_estimate.ys/.log← generic Yosys estimate (not Renesas)
└── tests/test_host.py            ← PC unit tests for the firmware logic
```

---

## 5. Software to install (Windows), in this order

1. **Go Configure Software Hub** (Renesas, free, needs a free Renesas account). Download page: <https://www.renesas.com/en/software-tool/go-configure-software-hub> — pick the Windows installer, register/log in, install with defaults. Renesas lists Windows 10/11 as supported. ([Vicharak tools guide](https://vicharak-in.github.io/shrike/tools_setup_guide.html), [Go Configure user guide](https://www.renesas.com/en/document/mat/go-configure-software-hub-user-guide))
2. **Thonny** (MicroPython IDE): <https://thonny.org/> → Windows installer.
3. **Shrike-Lite MicroPython firmware (UF2)**: from <https://github.com/vicharak-in/shrike/releases> (latest is v1.0.0 at the time of writing) download **`shrike-lite-micropython.uf2`** — *not* the Shrike/RP2350 or Shrike-fi files. This firmware contains the `shrike` module with `shrike.flash()`.
4. *(Optional, to rerun my simulation)* **Python 3** (<https://www.python.org/downloads/windows/>, tick "Add to PATH") and **Icarus Verilog for Windows** (<https://bleyer.org/icarus/>, tick "add to PATH"). Then double-click `sim\run_sim.bat` → expect `RESULT: PASS`. `python tests\test_host.py` → expect `OK`.

---

## 6. Build the FPGA bitstream in Go Configure

These steps follow Vicharak's [bitstream guide](https://vicharak-in.github.io/shrike/generating_your_first_bitstream.html). Menu names can differ slightly between Go Configure versions.

### 6.1 Create the project
1. Start **Go Configure Software Hub** → **Develop** tab → **Forge FPGA** → double-click **SLG47910 (BB)** (the Shrike's part).
2. Choose a project name (e.g. `mac_shrike`) and a folder **without spaces**.
3. In **Project settings**, choose the first value in each drop-down (as Vicharak's guide says).
4. Double-click the light-blue **FPGA Core** block to open the HDL editor.

### 6.2 Enter the RTL
* Easiest: open `main.v`, delete its contents, and paste the whole of **`ffpga/mac_all_in_one.v`**. (Verilog allows several modules in one file; the top module is marked `(* top *)`.)
* Or add the three files in `ffpga/src/` as separate sources.

> Shortcut for the curious: Vicharak's tested [`spi_loopback_led.ffpga`](https://github.com/vicharak-in/shrike/tree/main/examples/spi_loopback_led) already has the SPI, reset, clock and LED pins mapped with the **same port names** used here. You can open it, *Save As* a new project, replace its sources with this RTL, and then just confirm the I/O table below in the IO Planner.

### 6.3 Synthesize
Click the **Synthesize** button (bottom-left). Wait for the green tick. If it reports errors, the message names the file/line — see troubleshooting.

### 6.4 Map the pins (IO Planner, top toolbar)

| Port in `top.v` | Map to (IO Planner name) | Filter in IO Planner |
|---|---|---|
| `clk` | **OSC_CLK** | CLK / OSC_ctrl |
| `clk_en` | **OSC_EN** | CLK / OSC_ctrl |
| `spi_sck` | **GPIO3_IN** | GPIO |
| `spi_ss_n` | **GPIO4_IN** | GPIO |
| `spi_mosi` | **GPIO5_IN** | GPIO |
| `spi_miso` | **GPIO6_OUT** | GPIO |
| `spi_miso_en` | **GPIO6_OE** | GPIO |
| `rst_n` | **GPIO18_IN** | GPIO |
| `led` | **GPIO16_OUT** | GPIO |
| `led_en` | **GPIO16_OE** | GPIO |

(The clock/LED names come from Vicharak's guide; the SPI/reset assignments match Vicharak's `spi_loopback_led` project file, where they appear internally as IOB positions 0:9, 0:10, 0:22, 0:23, 31:4.) Leave all other pins unassigned. Save.

### 6.5 Generate the bitstream and read the reports
1. Click **Generate Bitstream** (bottom-left). Wait for the green tick.
2. In your project folder open `ffpga/build/`:
   * `resource-utilization-report.log` — **this is the real fit check.** Write down LUT and DFF use.
   * timing/PnR log (e.g. `FPGA_bitstream.log`) — check that the 50 MHz clock has no negative slack / failing paths.
3. The file for the RP2040 is **`ffpga/build/bitstream/FPGA_bitstream_MCU.bin`**. Copy it and rename the copy to **`mac_shrike.bin`**. Do **not** use `FPGA_bitstream_FLASH_MEM.bin` or any other file there ([Vicharak note](https://vicharak-in.github.io/shrike/getting_started.html)).

> ⚠️ **Never use an OTP / NVM "program" or "burn" function** in Go Configure for this chip. OTP is one-time and irreversible, and the Shrike workflow doesn't need it — the RP2040 loads the volatile configuration every time.

---

## 7. Put MicroPython on the RP2040 (once)

1. Unplug the board. **Hold BOOT**, plug in USB-C, release BOOT. A drive (e.g. `RPI-RP2`) appears.
2. Drag **`shrike-lite-micropython.uf2`** onto it. The drive disappears and the board reboots into MicroPython. ([getting started](https://vicharak-in.github.io/shrike/getting_started.html))
3. Open **Thonny** → bottom-right interpreter selector → **MicroPython (Raspberry Pi Pico)** / the board's COM port. You should get a `>>>` prompt. Test: `import shrike` gives no error.

## 8. Copy files and run the demo

1. Thonny → **View → Files**. Upload to the board (right-click → *Upload to /*):
   `mac_shrike.bin`, `mac_protocol.py`, `shrike_mac.py`, `main.py`.
2. Open `main.py` on the board and press **Run (F5)**. (Because it's called `main.py`, it will also run at every power-up.)

What `main.py` does: `shrike.flash("mac_shrike.bin")` → pulses reset on GPIO14 → reads status (expects 0x40) → **CLEAR** → shows that bad inputs are rejected → runs corner cases and a dot product, comparing every step with the Python model → 1000 random MACs.

### Expected output (shape; timing numbers will vary)
```
Loading mac_shrike.bin into the FPGA ...
After reset : acc = 0  status = 0x40 [-]
After CLEAR : acc = 0  status = 0x41 [INIT]
Rejected (128, 1) -> a=128 is outside signed 8-bit range -128..127
Rejected (-129, 1) -> a=-129 is outside signed 8-bit range -128..127
Rejected (1, 300) -> b=300 is outside signed 8-bit range -128..127
Rejected (True, 2) -> a must be an int, got True
Rejected (1.5, 2) -> a must be an int, got 1.5
 -128 *  -128  -> acc =    16384  (expected    16384) ok
  127 *   127  -> acc =    32513  (expected    32513) ok
 -128 *   127  -> acc =    16257  (expected    16257) ok
  127 *  -128  -> acc =        1  (expected        1) ok
   -1 *    -1  -> acc =        2  (expected        2) ok
    0 *  -128  -> acc =        2  (expected        2) ok
   64 *    -2  -> acc =     -126  (expected     -126) ok
 -100 *   100  -> acc =   -10126  (expected   -10126) ok
    3 *     5  -> acc =   -10111  (expected   -10111) ok
   -7 *     9  -> acc =   -10174  (expected   -10174) ok
1000 random MACs in ... ms: acc = ..., expected ..., status 0x41 [INIT]
RESULT: PASS
```
The blue FPGA LED should turn **on** after CLEAR and stay on. Set `RUN_OVERFLOW_DEMO = True` to watch OVF appear (takes minutes).

### Using it in your own code
```python
import shrike
from shrike_mac import ShrikeMac
shrike.flash("mac_shrike.bin")
m = ShrikeMac()
m.reset_logic()
m.clear()                 # REQUIRED before mac()
for a, b in zip([1, -2, 3], [4, 5, -6]):
    m.mac(a, b)
acc, st = m.read()        # acc = -24
```

---

## 9. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `LinkError: expected SYNC 0xA5, got ffffffffffff` | FPGA not driving MISO: bitstream not loaded (file name wrong, wrong `.bin` copied), `spi_miso`/`spi_miso_en` not mapped to GPIO6_OUT/OE, `clk`/`clk_en` not mapped to OSC_CLK/OSC_EN (no clock → nothing works), or design held in reset (GPIO14 → FPGA GPIO18 path missing / `rst_n` not mapped to GPIO18). |
| `got 000000000000` | Same as above, or `shrike.flash` printed a file error. Check the `[shrike_flash]` messages. |
| `bad status signature` | Wrong bitstream (e.g. the LED-blink one) or SPI mode/bit order changed. Must be mode 0, MSB first. |
| Status shows `ERR_FRAME` | Something sent a frame of the wrong length; use the driver functions, don't hand-craft frames. |
| Status shows `ERR_UNINIT` | A MAC was sent before CLEAR. Call `clear()` (needed again after `reset_logic()` or re-flashing). |
| Results correct at 1 MHz, wrong at higher SCK | Keep SCK ≤ 4 MHz (simulated limit); 1 MHz recommended. |
| `ImportError: no module named 'shrike'` | You flashed generic MicroPython. Install `shrike-lite-micropython.uf2` (section 7). |
| Board not seen in Thonny | Use a data-capable USB-C cable; pick the right COM port; re-do the BOOT + UF2 step. |
| Go Configure: synthesis error | Make sure only one module has `(* top *)`; if you pasted `mac_all_in_one.v` into `main.v`, don't also add the separate files (duplicate modules). |
| Go Configure: port not listed in IO Planner | Re-run Synthesize after editing; port names must match the table in 6.4 exactly. |
| PnR warnings "User IO … not packed with an IOB FF" (`spi_miso_en`, `rst_n`, `led`) | Harmless here: those signals are slow (1 MHz SPI enable, an asynchronous reset with a synchroniser, an LED), so pin-level flip-flops are not needed. |
| PnR warning "Clock clk directly fed by port without CLKBUF" | Expected: the `clkbuf_inhibit` attribute on `clk` follows Vicharak's official examples. Timing still shows 68.6 MHz achievable. |
| Timing report shows huge negative slack (e.g. −12580 ps) | The tool assumes a 2000 ps (500 MHz) period when no constraint is given. Read the **Achievable Frequency** column instead: it must be ≥ 50 MHz. |
| Resource report says it doesn't fit / timing fails | Tell me the numbers — fallback options: a bit-serial (8-cycle) multiplier, or a 24-bit accumulator. |

---

## 10. Re-running the checks yourself
* **Simulation**: `sim\run_sim.bat` (or `run_sim.bat full` for the 131 072-MAC overflow run, ~2 min). Expected last line: `RESULT: PASS`.
* **PC unit tests**: `python tests\test_host.py` → `OK`.
* **Waveforms** (optional): add `initial begin $dumpfile("mac.vcd"); $dumpvars(0, tb_mac); end` to `tb_mac.v` and open `mac.vcd` in GTKWave.

---

## 11. Sources
* Vicharak Shrike repository: <https://github.com/vicharak-in/shrike> (examples, `spi_loopback_led`, releases)
* Shrike docs: [pin-outs & interconnect](https://vicharak-in.github.io/shrike/shrike_pinouts.html) · [hardware overview](https://vicharak-in.github.io/shrike/hardware_overview.html) · [tools setup](https://vicharak-in.github.io/shrike/tools_setup_guide.html) · [getting started](https://vicharak-in.github.io/shrike/getting_started.html) · [first bitstream](https://vicharak-in.github.io/shrike/generating_your_first_bitstream.html) · [CLI (mpremote) guide](https://vicharak-in.github.io/shrike/shrike_cli_guide.html)
* Releases (UF2 firmware): <https://github.com/vicharak-in/shrike/releases>
* Renesas SLG47910: [product page](https://www.renesas.com/en/products/slg47910) · [datasheet](https://www.renesas.com/en/document/dst/slg47910-datasheet) · [ForgeFPGA Workshop user guide](https://www.renesas.com/en/document/gde/forgefpga-workshop-user-guide) · [ForgeFPGA configuration guide](https://www.renesas.com/us/en/document/mah/forgefpga-configuration-guide)
* Go Configure Software Hub: [download](https://www.renesas.com/en/software-tool/go-configure-software-hub) · [user guide](https://www.renesas.com/en/document/mat/go-configure-software-hub-user-guide)
* MicroPython `machine.SPI`: <https://docs.micropython.org/en/latest/library/machine.SPI.html>
* RP2040 datasheet: <https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf>
* Third-party cross-check of the board pin names: [TinyGo Shrike-Lite page](https://tinygo.org/docs/reference/microcontrollers/vicharak_shrike-lite)

Licence note: the design is original; it follows the structure of Vicharak's GPL-2.0 / CERN-OHL examples but copies no code from them.
