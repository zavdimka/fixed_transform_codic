param([switch]$Cocotb)

$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$linuxRoot = (wsl.exe -d Ubuntu -- wslpath -a $root).Trim()
$script = "$linuxRoot/tools/test_receiver_idct.sh"
if ($Cocotb) {
    wsl.exe -d Ubuntu -- env COCOTB=1 bash $script
} else {
    wsl.exe -d Ubuntu -- bash $script
}
if ($LASTEXITCODE -ne 0) { throw "Receiver IDCT tests failed" }