param(
    [string]$Distro = "Ubuntu",
    [string]$Port = "/dev/ttyACM0",
    [int]$Baud = 460800,
    [string]$WslSource = "/home/dimka/hd-zero-clone-build",
    [string]$IdfExport = "/home/dimka/esp32/esp-idf/export.sh",
    [switch]$SkipPack
)

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$storage = Join-Path $root "esp32\build\storage_transmitter.bin"

if (-not $SkipPack) {
    & (Join-Path $PSScriptRoot "deploy_transmitter_fpga.ps1") -NoFlash
    if ($LASTEXITCODE -ne 0) { throw "LittleFS packaging failed" }
}
if (-not (Test-Path $storage)) { throw "Missing storage image: $storage" }

$storageWsl = (& wsl.exe -d $Distro -- wslpath -a $storage).Trim()
if ($LASTEXITCODE -ne 0 -or -not $storageWsl) {
    throw "Could not convert storage image path to WSL."
}
$temporaryImage = "/tmp/hdzero-storage-transmitter.bin"

& wsl.exe -d $Distro -- rsync -a $storageWsl $temporaryImage
if ($LASTEXITCODE -ne 0) { throw "Copy to native WSL filesystem failed" }

& wsl.exe -d $Distro -- python3 "$WslSource/tools/serial_command.py" $Port `
    reboot bootloader CONFIRM --settle 7 --wait 1 --max-wait 10
if ($LASTEXITCODE -ne 0) { throw "Could not enter ROM bootloader" }

$flash = "set -e; source '$IdfExport' >/dev/null; " +
         "python -m esptool --chip esp32c5 --port '$Port' --baud $Baud " +
         "--before no-reset --after no-reset write-flash 0x620000 '$temporaryImage'; " +
         "python -m esptool --chip esp32c5 --port '$Port' --before no-reset " +
         "--after hard-reset write-mem 0x600b1034 0 0x60000000"
& wsl.exe -d $Distro -- bash -lc $flash
if ($LASTEXITCODE -ne 0) { throw "Storage flash failed" }

Write-Host "Transmitter storage flashed through $Distro $Port"
