param(
    [string]$EfinityRoot = "C:\Efinity\2026.1",
    [switch]$SkipInterfaceDesigner,
    [switch]$SkipMap,
    [int]$Seed = -1,
    [ValidateSet("", "TIMING_1", "TIMING_2", "TIMING_3", "CONGESTION_1", "CONGESTION_2", "CONGESTION_3")]
    [string]$OptimizationLevel = ""
)

$ErrorActionPreference = "Stop"
$projectDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\fpga\t20f169_receiver"))
$logDir = Join-Path $projectDir "build_logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logDir "receiver_$stamp.log"

function Invoke-EfinityStage {
    param([string]$Name, [string]$Command)
    Add-Content -Path $logFile -Value "`n===== $Name ====="
    $wrapped = "call `"$EfinityRoot\bin\setup.bat`" && $Command >> `"$logFile`" 2>&1"
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/c", $wrapped) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode). See $logFile"
    }
}

Push-Location $projectDir
try {
    if (-not $SkipInterfaceDesigner) {
        Invoke-EfinityStage "interface-designer" "`"$EfinityRoot\python311\bin\python.exe`" `"$EfinityRoot\pt\bin\efx_run_pt_unified.py`" t20f169_receiver Trion T20F169 --timing_model C3 --project_xml t20f169_receiver.xml --output_dir outflow --work_dir work_pt --design_dir . --peri_file t20f169_receiver.peri.xml --un_flow"
    }
    if (-not $SkipMap) {
        Invoke-EfinityStage "map" "`"$EfinityRoot\bin\efx_map.exe`" --project t20f169_receiver --family Trion --device T20F169 --output-dir outflow --project-xml t20f169_receiver.xml --binary-db outflow\t20f169_receiver.vdb --peri-syn-instantiation=0 --peri-syn-inference=0 --peri-syn-modify-vdb-module-name=0 --root=t20f169_receiver --veri_options=verilog_mode=verilog_2k,vhdl_mode=vhdl_2008 --work-dir=work_syn --write-efx-verilog=outflow\t20f169_receiver.map.v"
    }
    $pnrOptions = ""
    if ($Seed -ge 0) { $pnrOptions += " --seed $Seed" }
    if ($OptimizationLevel) { $pnrOptions += " --optimization_level $OptimizationLevel" }
    Invoke-EfinityStage "place-route" "`"$EfinityRoot\bin\efx_pnr.exe`" --circuit t20f169_receiver --family Trion --device T20F169 --operating_conditions C3 --vdb_file outflow\t20f169_receiver.vdb --use_vdb_file on --prj t20f169_receiver.xml --output_dir outflow --work_dir work_pnr --place_file outflow\t20f169_receiver.place --route_file outflow\t20f169_receiver.route --sync_file outflow\t20f169_receiver.interface.csv --generate_prevpr_netlist off --sdc_file=t20f169_receiver.sdc$pnrOptions"
    Invoke-EfinityStage "bitstream" "`"$EfinityRoot\bin\efx_pgm.exe`" --source work_pnr\t20f169_receiver.lbf --dest outflow\t20f169_receiver.hex --device T20F169 --family Trion --periph outflow\t20f169_receiver.lpf --interface_designer_settings outflow\t20f169_receiver_or.ini --enable_external_master_clock off --oscillator_clock_divider DIV8 --active_capture_clk_edge posedge --spi_low_power_mode on --io_weak_pullup on --enable_roms smart --mode passive --width 1 --release_tri_then_reset on"
    $hexPath = Join-Path $projectDir "outflow\t20f169_receiver.hex"
    $binPath = "$hexPath.bin"
    $hexBytes = Get-Content -Path $hexPath |
        Where-Object { $_ -match "^[0-9A-Fa-f]{2}$" } |
        ForEach-Object { [Convert]::ToByte($_, 16) }
    [IO.File]::WriteAllBytes($binPath, [byte[]]$hexBytes)} finally {
    Pop-Location
}

Write-Output "Build completed. Log: $logFile"
& (Join-Path $PSScriptRoot "report_receiver_timing.ps1") -ProjectDir $projectDir
