param(
    [ValidateRange(1, 100)]
    [int]$Passes = 2,

    [ValidateRange(0, 10000)]
    [int]$Records = 0,

    [switch]$UnboundedOutput
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$wslRepo = (wsl.exe wslpath -a ($repo -replace '\\', '/')).Trim()
if (-not $wslRepo) {
    throw 'Could not translate repository path for WSL.'
}

$target = if ($UnboundedOutput) { 'test-receiver-e2e-throughput-verilator' } else { 'test-receiver-e2e-verilator' }
$unbounded = if ($UnboundedOutput) { 1 } else { 0 }
$command = "cd '$wslRepo/fpga' && RECEIVER_E2E_PASSES=$Passes RECEIVER_E2E_MAX_RECORDS=$Records RECEIVER_E2E_UNBOUNDED_OUTPUT=$unbounded make $target"
wsl.exe bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw "Receiver end-to-end simulation failed with exit code $LASTEXITCODE."
}

wsl.exe bash -lc "cat /tmp/receiver_e2e_report.json"