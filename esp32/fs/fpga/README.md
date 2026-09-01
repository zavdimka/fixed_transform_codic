# FPGA images

This directory is packed into the `storage` LittleFS partition by every
ESP-IDF build. Put Efinity passive-SPI binary output files here before running
`idf.py build`:

- `tx/default.hex.bin` for the transmitter FPGA project;
- `rx/default.hex.bin` for the receiver FPGA project.

Additional versions may use any filename below `tx/` or `rx/`. Select them
from the USB console with `fpga tx-file <path>` and `fpga rx-file <path>`, then
run `save` and `reboot`. Paths inside the application start with `/fs`.

Do not copy the textual `.hex` or `.bit` file. The loader expects Efinity's
raw `.hex.bin` output generated for passive SPI x1 configuration.
