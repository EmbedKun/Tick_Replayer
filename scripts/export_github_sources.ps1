param(
  [string]$OutDir = "",
  [switch]$Zip
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ($OutDir -eq "") {
  $OutDir = Join-Path $RepoRoot "artifacts\github_source\traffic_replay"
}

$RepoRootFull = [System.IO.Path]::GetFullPath($RepoRoot)
$OutDirFull = [System.IO.Path]::GetFullPath($OutDir)
$ArtifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "artifacts"))

if (!$OutDirFull.StartsWith($ArtifactsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to clean/export outside artifacts/: $OutDirFull"
}

if (Test-Path -LiteralPath $OutDirFull) {
  Remove-Item -LiteralPath $OutDirFull -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutDirFull | Out-Null

$RootFiles = @(
  ".gitattributes",
  ".gitignore",
  "README.md",
  "GITHUB_SOURCE_MANIFEST.md"
)

$SourceDirs = @(
  "constraints",
  "docs",
  "rtl",
  "scripts",
  "sim",
  "software"
)

$ExcludeNames = @(
  "__pycache__",
  ".pytest_cache"
)

$ExcludeExtensions = @(
  ".pyc",
  ".pyo",
  ".jou",
  ".log",
  ".wdb",
  ".bit",
  ".ltx"
)

function Copy-RepoFile {
  param(
    [Parameter(Mandatory=$true)][string]$RelativePath
  )

  $src = Join-Path $RepoRoot $RelativePath
  if (!(Test-Path -LiteralPath $src)) {
    throw "Required file missing: $RelativePath"
  }

  $dst = Join-Path $OutDirFull $RelativePath
  $dstDir = Split-Path -Parent $dst
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Force
}

foreach ($file in $RootFiles) {
  Copy-RepoFile -RelativePath $file
}

foreach ($dir in $SourceDirs) {
  $srcDir = Join-Path $RepoRoot $dir
  if (!(Test-Path -LiteralPath $srcDir)) {
    throw "Required directory missing: $dir"
  }

  Get-ChildItem -LiteralPath $srcDir -Recurse -File | ForEach-Object {
    $skip = $false
    foreach ($part in $_.FullName.Substring($srcDir.Length).Split([System.IO.Path]::DirectorySeparatorChar, [System.StringSplitOptions]::RemoveEmptyEntries)) {
      if ($ExcludeNames -contains $part) {
        $skip = $true
      }
    }
    if ($ExcludeExtensions -contains $_.Extension.ToLowerInvariant()) {
      $skip = $true
    }
    if (!$skip) {
      $relative = $_.FullName.Substring($RepoRootFull.Length).TrimStart('\', '/')
      Copy-RepoFile -RelativePath $relative
    }
  }
}

$fileCount = (Get-ChildItem -LiteralPath $OutDirFull -Recurse -File | Measure-Object).Count
Write-Host "Exported $fileCount source files to $OutDirFull"

if ($Zip) {
  $zipPath = Join-Path $ArtifactsRoot "traffic_replay_github_source.zip"
  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  Compress-Archive -Path (Join-Path $OutDirFull "*") -DestinationPath $zipPath -Force
  Write-Host "Wrote $zipPath"
}
