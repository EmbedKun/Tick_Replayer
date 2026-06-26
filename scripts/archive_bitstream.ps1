param(
  [Parameter(Mandatory = $true)]
  [string]$Bitfile,

  [string]$Ltx = "",
  [string]$Name = "manual",
  [string]$OutDir = "",
  [string]$Notes = "",
  [string]$BuildRoot = ""
)

$ErrorActionPreference = "Stop"

$repoDir = Resolve-Path (Join-Path $PSScriptRoot "..")
if ($OutDir -eq "") {
  $OutDir = Join-Path $repoDir "bitstreams"
}

$bitPath = Resolve-Path $Bitfile
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$safeName = ($Name -replace "[^A-Za-z0-9_.-]", "_").Trim("_")
if ($safeName -eq "") {
  $safeName = "manual"
}

$archiveDir = Join-Path $OutDir "${timestamp}_${safeName}"
New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

$bitDest = Join-Path $archiveDir (Split-Path $bitPath -Leaf)
Copy-Item -LiteralPath $bitPath -Destination $bitDest -Force
$bitHash = Get-FileHash -Algorithm SHA256 -LiteralPath $bitDest
$bitInfo = Get-Item -LiteralPath $bitDest

function Get-RepoHeadInfo {
  param([string]$RepoDir)

  $headFile = Join-Path $RepoDir ".git\HEAD"
  $result = @{
    Branch = "unknown"
    Commit = "unknown"
  }

  if (-not (Test-Path -LiteralPath $headFile)) {
    return $result
  }

  $head = (Get-Content -LiteralPath $headFile -Raw).Trim()
  if ($head.StartsWith("ref: ")) {
    $ref = $head.Substring(5)
    $result.Branch = Split-Path $ref -Leaf

    $refPath = Join-Path (Join-Path $RepoDir ".git") ($ref -replace "/", "\")
    if (Test-Path -LiteralPath $refPath) {
      $result.Commit = (Get-Content -LiteralPath $refPath -Raw).Trim()
      return $result
    }

    $packedRefs = Join-Path $RepoDir ".git\packed-refs"
    if (Test-Path -LiteralPath $packedRefs) {
      foreach ($line in Get-Content -LiteralPath $packedRefs) {
        if ($line -match "^([0-9a-fA-F]{40})\s+$([regex]::Escape($ref))$") {
          $result.Commit = $Matches[1]
          return $result
        }
      }
    }
  } elseif ($head -match "^[0-9a-fA-F]{40}$") {
    $result.Commit = $head
    $result.Branch = "detached"
  }

  return $result
}

$ltxText = "none"
if ($Ltx -ne "") {
  $ltxPath = Resolve-Path $Ltx
  $ltxDest = Join-Path $archiveDir (Split-Path $ltxPath -Leaf)
  Copy-Item -LiteralPath $ltxPath -Destination $ltxDest -Force
  $ltxHash = Get-FileHash -Algorithm SHA256 -LiteralPath $ltxDest
  $ltxInfo = Get-Item -LiteralPath $ltxDest
  $ltxText = @"
LTX file: $($ltxInfo.Name)
LTX size bytes: $($ltxInfo.Length)
LTX SHA256: $($ltxHash.Hash)
"@
}

$commit = "unknown"
try {
  $commit = (& git -C $repoDir rev-parse HEAD 2>$null).Trim()
  if ($LASTEXITCODE -ne 0 -or $commit -eq "") {
    $commit = "unknown"
  }
} catch {
  $commit = "unknown (git.exe unavailable)"
}

$branch = "unknown"
try {
  $branch = (& git -C $repoDir branch --show-current 2>$null).Trim()
  if ($LASTEXITCODE -ne 0 -or $branch -eq "") {
    $branch = "unknown"
  }
} catch {
  $branch = "unknown (git.exe unavailable)"
}

if ($commit -like "unknown*") {
  $headInfo = Get-RepoHeadInfo -RepoDir $repoDir
  $commit = $headInfo.Commit
  $branch = $headInfo.Branch
}

if ($BuildRoot -eq "") {
  $BuildRoot = "not recorded"
}
if ($Notes -eq "") {
  $Notes = "No extra notes were provided."
}

$notePath = Join-Path $archiveDir "${timestamp}_${safeName}.txt"
$content = @"
Traffic Replay Bitstream Archive
================================

Name: $Name
Archive timestamp: $timestamp
Repository: $repoDir
Git branch: $branch
Git commit: $commit
Build root: $BuildRoot

Bitstream file: $($bitInfo.Name)
Bitstream size bytes: $($bitInfo.Length)
Bitstream SHA256: $($bitHash.Hash)
Original bitstream path: $bitPath

$ltxText

Design summary
--------------
- Target board: Xilinx Alveo U200.
- PCIe path: XDMA memory-mapped H2C/C2H plus AXI-Lite BAR control.
- Replay path: DDR-backed preload/loop replay and DDR-backed stream-buffer replay.
- Ethernet path: 100G CMAC/QSFP replay and capture datapaths.

Verification notes
------------------
$Notes

Operational reminder
--------------------
Keep this directory together with the matching repository commit.  The SHA256
line above is the canonical integrity check before programming the FPGA.
"@

$content | Set-Content -LiteralPath $notePath -Encoding UTF8

Write-Host "Archived bitstream to $archiveDir"
Write-Host "Notes: $notePath"
