param(
    [string]$ProjectDir = (Join-Path $PSScriptRoot "..\fpga\t20f169_receiver")
)

$ErrorActionPreference = "Stop"
$projectDir = [System.IO.Path]::GetFullPath($ProjectDir)
$timing = Join-Path $projectDir "outflow\t20f169_receiver.timing.rpt"
$resource = Join-Path $projectDir "outflow\t20f169_receiver.map.rpt"
if (-not (Test-Path $timing)) { throw "Timing report not found: $timing" }

Write-Output "Timing summary:"
Select-String -Path $timing -Pattern "Maximum possible frequency|Slack|pll_60Mhz|pll_hdmi" |
    Select-Object -First 30 | ForEach-Object { $_.Line.TrimEnd() }
if (Test-Path $resource) {
    Write-Output "Resource summary:"
    Select-String -Path $resource -Pattern "Logic Elements|LUT|Flipflop|Multiplier|RAM" |
        Select-Object -First 20 | ForEach-Object { $_.Line.TrimEnd() }
}
