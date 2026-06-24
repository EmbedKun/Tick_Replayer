param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("sim", "synth", "program")]
  [string]$Action,

  [string]$Bitfile = ""
)

$VivadoBat = "D:\Xilinx\Vivado\2020.2\bin\vivado.bat"
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (!(Test-Path $VivadoBat)) {
  throw "Vivado 2020.2 not found at $VivadoBat"
}

switch ($Action) {
  "sim" {
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "run_sim.tcl")
  }
  "synth" {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "reports") | Out-Null
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "synth_check.tcl")
  }
  "program" {
    if ($Bitfile -eq "") {
      throw "Please pass -Bitfile path\to\design.bit"
    }
    & $VivadoBat -mode batch -source (Join-Path $PSScriptRoot "program_remote.tcl") -tclargs $Bitfile
  }
}
