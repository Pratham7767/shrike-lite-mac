#!/usr/bin/env sh
# Run the MAC simulation (Linux/macOS/WSL). Needs: python3, iverilog.
# Usage: ./run_sim.sh            (fast, ~10 s)
#        ./run_sim.sh full       (adds 131072 real SPI MACs to overflow, ~2 min)
set -e
cd "$(dirname "$0")"
python3 gen_vectors.py
iverilog -g2005 -o tb_mac.vvp tb_mac.v ../ffpga/src/spi_byte_target.v ../ffpga/src/mac_core.v ../ffpga/src/top.v
if [ "$1" = "full" ]; then vvp -n tb_mac.vvp +FULL_OVF; else vvp -n tb_mac.vvp; fi
