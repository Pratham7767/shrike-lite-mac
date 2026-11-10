@echo off
REM Run the MAC simulation on Windows. Needs Python 3 and Icarus Verilog on PATH.
REM Usage: run_sim.bat          (fast, ~10 s)
REM        run_sim.bat full     (adds 131072 real SPI MACs to overflow, ~2 min)
cd /d "%~dp0"
python gen_vectors.py || goto :err
iverilog -g2005 -o tb_mac.vvp tb_mac.v ..\ffpga\src\spi_byte_target.v ..\ffpga\src\mac_core.v ..\ffpga\src\top.v || goto :err
if "%1"=="full" (vvp -n tb_mac.vvp +FULL_OVF) else (vvp -n tb_mac.vvp)
goto :eof
:err
echo Build failed.
exit /b 1
