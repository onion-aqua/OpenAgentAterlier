param(
    [ValidateSet('android', 'windows', 'ios', 'web', 'all')]
    [string]$Platform = 'all',

    [switch]$CheckOnly,

    [switch]$Offline,

    [string]$PublishedPackageRoot = '',

    [switch]$RebuildWebAssets
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$vendorRoot = Join-Path $projectRoot 'third_party\live2d_flutter'
$runtimeManifest = Get-Content -LiteralPath (Join-Path $vendorRoot 'RUNTIME_FILES.json') -Raw | ConvertFrom-Json
$upstreamManifest = Get-Content -LiteralPath (Join-Path $vendorRoot 'UPSTREAM_FILES.json') -Raw | ConvertFrom-Json

function Test-ExpectedFile([string]$Root, [string]$Relative, $Record) {
    $path = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $path).Length -ne $Record.bytes) { return $false }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $Record.sha256
}

function Get-CheckedTarget([string]$Relative) {
    if ($Relative.Contains(':') -or $Relative.StartsWith('/') -or
        $Relative.Replace('\', '/').Split('/') -contains '..') {
        throw 'Unsafe runtime manifest path.'
    }
    $path = [System.IO.Path]::GetFullPath((Join-Path $vendorRoot $Relative))
    $prefix = [System.IO.Path]::GetFullPath($vendorRoot) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime manifest target escapes the vendor directory.'
    }
    return $path
}

# Check the reviewed plugin/Framework sources independently from local Core.
foreach ($property in $upstreamManifest.files.PSObject.Properties) {
    if (-not (Test-ExpectedFile $vendorRoot $property.Name $property.Value)) {
        throw "Vendored Live2D source has changed: $($property.Name). Review the patch and update its manifest deliberately."
    }
}

$coreFiles = @($runtimeManifest.core.PSObject.Properties | Where-Object {
    $Platform -eq 'all' -or $_.Name.StartsWith("$Platform/") -or
        ($Platform -eq 'windows' -and $_.Name.StartsWith('android/src/main/cpp/CubismCore/'))
})
$missingCore = @($coreFiles | Where-Object {
    -not (Test-ExpectedFile $vendorRoot $_.Name $_.Value)
})

if ($missingCore.Count -gt 0 -and -not $CheckOnly) {
    $source = $PublishedPackageRoot
    if ($source) {
        $source = (Resolve-Path -LiteralPath $source).Path
    }
    else {
        $cacheRoot = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
        $candidate = Join-Path $cacheRoot 'hosted\pub.dev\live2d_flutter-1.0.3'
        $cacheMatches = Test-Path -LiteralPath $candidate -PathType Container
        foreach ($property in $coreFiles) {
            if (-not (Test-ExpectedFile $candidate $property.Name $property.Value)) { $cacheMatches = $false }
        }
        if ($cacheMatches) { $source = $candidate }
    }
    if (-not $source) {
        if ($Offline) {
            throw 'Verified local Cubism Core files are unavailable in offline mode. Prepare them once with network access or supply -PublishedPackageRoot.'
        }
        $downloadRoot = Join-Path $projectRoot 'build\vendor_upstream'
        New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
        $archivePath = Join-Path $downloadRoot 'live2d_flutter-1.0.3.tar.gz'
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            Invoke-WebRequest -Uri $runtimeManifest.archive_url -OutFile $archivePath
        }
        $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($archiveHash -ne $runtimeManifest.archive_sha256) {
            throw 'Published Live2D package checksum mismatch; the archive was not extracted.'
        }
        $source = Join-Path $downloadRoot 'live2d_flutter-1.0.3'
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            $tar = Get-Command tar -ErrorAction Stop
            $entries = @(& $tar.Source -tzf $archivePath)
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the verified published package.' }
            foreach ($entry in $entries) {
                $path = $entry.Replace('\', '/')
                if ($path.StartsWith('/') -or $path.Contains(':') -or $path.Split('/') -contains '..') {
                    throw 'Unsafe published package path; no files extracted.'
                }
            }
            New-Item -ItemType Directory -Path $source | Out-Null
            & $tar.Source -xzf $archivePath -C $source
            if ($LASTEXITCODE -ne 0) { throw 'Cannot extract the verified published package.' }
        }
    }
    foreach ($property in $coreFiles) {
        if (-not (Test-ExpectedFile $source $property.Name $property.Value)) {
            throw "Core source differs from the exact published 1.0.3 package: $($property.Name)"
        }
    }
    foreach ($property in $missingCore) {
        $target = Get-CheckedTarget $property.Name
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source $property.Name) -Destination $target -Force
    }
}

if ($RebuildWebAssets) {
    if ($CheckOnly) { throw '-CheckOnly and -RebuildWebAssets cannot be combined.' }
    Push-Location (Join-Path $vendorRoot 'web_runtime')
    try {
        & npm ci --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Live2D web dependencies failed.' }
        & npm run build
        if ($LASTEXITCODE -ne 0) { throw 'Live2D web runtime compilation failed.' }
    }
    finally { Pop-Location }
}

$failures = @()
foreach ($property in $coreFiles) {
    if (-not (Test-ExpectedFile $vendorRoot $property.Name $property.Value)) { $failures += $property.Name }
}
foreach ($property in $runtimeManifest.web.PSObject.Properties) {
    if (-not (Test-ExpectedFile $vendorRoot $property.Name $property.Value)) { $failures += $property.Name }
}
if ($failures.Count -gt 0) {
    throw "Live2D runtime files are missing or corrupt: $($failures -join ', '). Run tool/prepare_live2d_runtime.ps1 -Platform $Platform to prepare verified local Core files."
}
$webAssetCount = @($runtimeManifest.web.PSObject.Properties).Count
Write-Host "Live2D 1.0.3 runtime integrity passed ($Platform): $($coreFiles.Count) local Core files; $webAssetCount real web assets."
Write-Host 'Cubism Core and release/distribution licenses remain separate from the BSD plugin license; see third_party/live2d_flutter/NOTICES.'
