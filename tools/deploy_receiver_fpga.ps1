param(
    [string]$Port = "COM84",
    [int]$Baud = 460800,
    [switch]$NoFlash
)

$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$python = Join-Path $PSScriptRoot ".flash-venv\Scripts\python.exe"
$littlefs = Join-Path $PSScriptRoot ".flash-venv\Scripts\littlefs-python.exe"
$fpgaImage = Join-Path $root "fpga\t20f169_receiver\outflow\t20f169_receiver.hex.bin"
$fsImage = Join-Path $root "esp32\fs\fpga\rx\default.hex.bin"
$storageImage = Join-Path $root "esp32\build\storage_enhancement.bin"

foreach ($required in @($python, $littlefs, $fpgaImage)) {
    if (-not (Test-Path $required)) { throw "Missing required file: $required" }
}
if ((Get-Item $fpgaImage).Length -ne 678650) {
    throw "Unexpected FPGA image size"
}

Copy-Item -Force $fpgaImage $fsImage
& $littlefs create (Join-Path $root "esp32\fs") $storageImage -v --fs-size=0x9E0000 --name-max=64 --block-size=4096
if ($LASTEXITCODE -ne 0) { throw "LittleFS image creation failed" }

if (-not $NoFlash) {
    & $python -m esptool --chip esp32c5 --port $Port --baud $Baud --before default-reset --after hard-reset write-flash 0x620000 $storageImage
    if ($LASTEXITCODE -ne 0) { throw "Storage flash failed" }
}
Write-Output "FPGA image: $fpgaImage"
Write-Output "Storage image: $storageImage"