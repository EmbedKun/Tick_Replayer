param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("sim", "synth", "hwbd", "hwbit", "hwbit_existing", "hwimpl", "program")]
  [string]$Action,

  [string]$Bitfile = ""
)

$VivadoBat = "D:\Xilinx\Vivado\2020.2\bin\vivado.bat"
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (!(Test-Path $VivadoBat)) {
  throw "Vivado 2020.2 not found at $VivadoBat"
}

if ($env:TRAFFIC_REPLAY_VIVADO_TEMP -ne $null -and $env:TRAFFIC_REPLAY_VIVADO_TEMP -ne "") {
  $VivadoTemp = $env:TRAFFIC_REPLAY_VIVADO_TEMP
} elseif (Test-Path "D:\") {
  $VivadoTemp = "D:\tr_tmp"
} else {
  $VivadoTemp = Join-Path $RepoRoot "build\tmp"
}
New-Item -ItemType Directory -Force -Path $VivadoTemp | Out-Null
$env:TEMP = $VivadoTemp
$env:TMP = $VivadoTemp
$env:TMPDIR = $VivadoTemp

switch ($Action) {
  "sim" {
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "run_sim.tcl")
  }
  "synth" {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "reports") | Out-Null
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "synth_check.tcl")
  }
  "hwbd" {
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "create_hw_project.tcl")
  }
  "hwbit" {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "reports") | Out-Null
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "build_hw_bitstream.tcl")
  }
  "hwbit_existing" {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "reports") | Out-Null
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "build_existing_hw_bitstream.tcl")
  }
  "hwimpl" {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "reports") | Out-Null
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "rerun_hw_impl.tcl")
  }
  "program" {
    if ($Bitfile -eq "") {
      throw "Please pass -Bitfile path\to\design.bit"
    }
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "program_remote.tcl") -tclargs $Bitfile
  }
}
