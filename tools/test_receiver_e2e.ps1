param(
    [ValidateRange(1, 100)]
    [int]$Passes = 2,

    [ValidateRange(0, 10000)]
    [int]$Records = 0,

    [string]$Stripes = "",

    [string]$Stream = "esp32/fs/test/decoder_base.rxt",

    [switch]$UnboundedOutput,

    [string]$CaptureDir = "",

    [ValidateRange(1, 8)]
    [int]$Threads = 4,

    [switch]$Profile
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$wslRepo = (wsl.exe wslpath -a ($repo -replace '\\', '/')).Trim()
if (-not $wslRepo) {
    throw 'Could not translate repository path for WSL.'
}

$target = if ($UnboundedOutput) { 'test-receiver-e2e-throughput-verilator' } else { 'test-receiver-e2e-verilator' }
$unbounded = if ($UnboundedOutput) { 1 } else { 0 }
$profileFlag = if ($Profile) { 1 } else { 0 }
$captureWsl = ""
if ($CaptureDir) {
    $capturePath = if ([IO.Path]::IsPathRooted($CaptureDir)) {
        $CaptureDir
    } else {
        Join-Path $repo $CaptureDir
    }
    $captureWsl = (wsl.exe wslpath -a ($capturePath -replace '\\', '/')).Trim()
    if (-not $captureWsl) {
        throw 'Could not translate capture path for WSL.'
    }
}
$command = "cd '$wslRepo/fpga' && RECEIVER_E2E_PASSES=$Passes RECEIVER_E2E_MAX_RECORDS=$Records RECEIVER_E2E_STRIPES='$Stripes' RECEIVER_E2E_STREAM='$Stream' RECEIVER_E2E_UNBOUNDED_OUTPUT=$unbounded RECEIVER_E2E_CAPTURE_DIR='$captureWsl' RECEIVER_E2E_THREADS=$Threads RECEIVER_E2E_PROFILE=$profileFlag make $target"
wsl.exe bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw "Receiver end-to-end simulation failed with exit code $LASTEXITCODE."
}

wsl.exe bash -lc "cat /tmp/receiver_e2e_report.json"