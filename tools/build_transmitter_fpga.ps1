param(
    [string]$EfinityRoot = "C:\Efinity\2026.1",
    [switch]$SkipInterfaceDesigner,
    [switch]$SkipMap,
    [switch]$SkipPnr,
    [switch]$MapOnly,
    [int]$Seed = -1,
    [ValidateSet("", "TIMING_1", "TIMING_2", "TIMING_3",
                 "CONGESTION_1", "CONGESTION_2", "CONGESTION_3")]
    [string]$OptimizationLevel = ""
)

$ErrorActionPreference = "Stop"
$projectName = "t20f169_spi_debug"
$projectDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\fpga\t20f169_spi_debug"))
$logDir = Join-Path $projectDir "build_logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logDir "transmitter_$stamp.log"

function Invoke-EfinityStage {
    param([string]$Name, [string]$Command)
    Add-Content -Path $logFile -Value ("===== " + $Name + " =====")
    $wrapped = "call " + $EfinityRoot + "\bin\setup.bat && " + $Command + " >> " + '"' + $logFile + '"' + " 2>&1"
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/c", $wrapped) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode). See $logFile"
    }
}

Push-Location $projectDir
try {
    if (-not $SkipInterfaceDesigner) {
        Invoke-EfinityStage "interface-designer" "$EfinityRoot\python311\bin\python.exe $EfinityRoot\pt\bin\efx_run_pt_unified.py $projectName Trion T20F169 --timing_model C3 --project_xml $projectName.xml --output_dir outflow --work_dir work_pt --design_dir . --peri_file $projectName.peri.xml --un_flow"
    }
    if (-not $SkipMap) {
        Invoke-EfinityStage "map" "$EfinityRoot\bin\efx_map.exe --project $projectName --family Trion --device T20F169 --output-dir outflow --project-xml $projectName.xml --binary-db outflow\$projectName.vdb --peri-syn-instantiation=0 --peri-syn-inference=0 --peri-syn-modify-vdb-module-name=0 --root=$projectName --veri_options=verilog_mode=verilog_2k,vhdl_mode=vhdl_2008 --work-dir=work_syn --write-efx-verilog=outflow\$projectName.map.v"
    }
    if ($MapOnly) {
        Write-Output "Map completed. Log: $logFile"
        $mapReport = Join-Path $projectDir "outflow\$projectName.map.rpt"
        $resourceReport = Join-Path $projectDir "outflow\$projectName.res.csv"
        Select-String -Path $mapReport -Pattern "Logic Elements|LUT|Register|RAM|Multiplier"
        Get-Content -Path $resourceReport -TotalCount 12
        return
    }
    $pnrOptions = ""
    if ($Seed -ge 0) { $pnrOptions += " --seed $Seed" }
    if ($OptimizationLevel) { $pnrOptions += " --optimization_level $OptimizationLevel" }
    if (-not $SkipPnr) {
        Invoke-EfinityStage "place-route" "$EfinityRoot\bin\efx_pnr.exe --circuit $projectName --family Trion --device T20F169 --operating_conditions C3 --vdb_file outflow\$projectName.vdb --use_vdb_file on --prj $projectName.xml --output_dir outflow --work_dir work_pnr --place_file outflow\$projectName.place --route_file outflow\$projectName.route --sync_file outflow\$projectName.interface.csv --generate_prevpr_netlist off --sdc_file=$projectName.sdc$pnrOptions"
    }

    $hexPath = Join-Path $projectDir "outflow\$projectName.hex"
    $bitPath = Join-Path $projectDir "outflow\$projectName.bit"
    Remove-Item -LiteralPath $hexPath, $bitPath -Force -ErrorAction SilentlyContinue
    Invoke-EfinityStage "bitstream" "$EfinityRoot\bin\efx_pgm.exe --source work_pnr\$projectName.lbf --dest outflow\$projectName.hex --device T20F169 --family Trion --periph outflow\$projectName.lpf --interface_designer_settings outflow\${projectName}_or.ini --enable_external_master_clock off --oscillator_clock_divider DIV8 --active_capture_clk_edge posedge --spi_low_power_mode on --io_weak_pullup on --enable_roms smart --mode passive --width 1 --release_tri_then_reset on"
    $hexBytes = Get-Content -Path $hexPath | Where-Object { $_ -match "^[0-9A-Fa-f]{2}$" } | ForEach-Object { [Convert]::ToByte($_, 16) }
    [IO.File]::WriteAllBytes("$hexPath.bin", [byte[]]$hexBytes)
} finally {
    Pop-Location
}

Write-Output "Build completed. Log: $logFile"
$mapReport = Join-Path $projectDir "outflow\$projectName.map.rpt"
$timingReport = Join-Path $projectDir "outflow\$projectName.timing.rpt"
Select-String -Path $mapReport -Pattern "Logic Elements|LUT|Register|RAM|Multiplier"
Select-String -Path $timingReport -Pattern "Maximum possible analyzed clocks frequency|Setup Slack|Hold Slack"
