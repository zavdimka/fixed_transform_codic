param(
    [string]$Distro = "Ubuntu",
    [string]$Destination = "/home/dimka/hd-zero-clone-build",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sourceWsl = (& wsl.exe -d $Distro -- wslpath -a $repositoryRoot).Trim()
if ($LASTEXITCODE -ne 0 -or -not $sourceWsl) {
    throw "Could not convert repository path to a WSL path."
}

$rsyncArguments = @(
    "-d", $Distro, "--", "rsync",
    "-a", "--delete", "--info=stats1",
    "--exclude=.git/",
    "--exclude=/.codex/",
    "--exclude=/.pytest_cache/",
    "--exclude=/artifacts/",
    "--exclude=/captures/",
    "--exclude=/tmp/",
    "--exclude=/custom_stripe_results/",
    "--exclude=/hevc_*_results/",
    "--exclude=/hevc_*_previews/",
    "--exclude=/jpeg_radio_*_results/",
    "--exclude=/test_vectors/codec_profile_comparison/",
    "--exclude=/esp32/build/",
    "--exclude=/pc_receiver/build*/",
    "--exclude=/fpga/*/outflow/",
    "--exclude=/fpga/*/work_*/",
    "--exclude=/fpga/*/build_logs/",
    "--exclude=/tools/.flash-venv/",
    "--exclude=**/__pycache__/"
)

if ($DryRun) {
    $rsyncArguments += "--dry-run"
}

$rsyncArguments += @("$sourceWsl/", "$Destination/")

& wsl.exe @rsyncArguments
if ($LASTEXITCODE -ne 0) {
    throw "rsync failed with exit code $LASTEXITCODE"
}

Write-Host "WSL source mirror is ready at $Destination"
