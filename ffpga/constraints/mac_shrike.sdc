# mac_shrike.sdc -- timing constraint for the Shrike Lite MAC (ForgeFPGA Workshop)
#
# Tells the timing analyser the real clock: on-chip oscillator, 50 MHz = 20 ns period.
# Without this file the tool assumes 500 MHz and reports large negative slack.
#
# 'clk' comes from the internal oscillator (OSC_CLK), so after place-and-route it is
# a net, not a package port: [get_ports clk] finds nothing ("Object clk hasn't found
# any match"). The timing report lists "Clock net: clk", so we use get_nets.
#
# STATUS: in Go Configure v6.56 this constraint was not applied yet (the report still
# showed "(auto) 2000"). It is optional: the design already reaches 68.6 MHz.
#
# Check after Generate Bitstream -> Timing Analysis:
#   "Constrained Period(ps)" must read 20000 (not "(auto) 2000").
#   If it reads 20 instead, the tool expects picoseconds: change 20 to 20000.
create_clock -name clk -period 20 [get_nets clk]
