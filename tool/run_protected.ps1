param(
    [string]$Device = "emulator-5554",

    [string]$RelayServerConfig = ''
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

Push-Location $projectRoot
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }
    $live2dPlatform = if ($Device -eq 'windows') { 'windows' } elseif ($Device -in @('chrome', 'edge', 'web-server', 'macos')) { 'web' } else { 'android' }
    & (Join-Path $projectRoot 'tool\prepare_live2d_runtime.ps1') -Platform $live2dPlatform
    $privateRelayDefines = ''
    $privateRelaySource = Join-Path $projectRoot '.asset_protection\relay_server.json'
    if ($RelayServerConfig) {
        $privateRelaySource = (Resolve-Path -LiteralPath $RelayServerConfig).Path
    }
    if (Test-Path -LiteralPath $privateRelaySource) {
        $privateRelayDefines = Join-Path $projectRoot '.asset_protection\relay_server.defines.json'
        & dart run tool/protect_relay_server.dart --config-file $privateRelaySource --output-file $privateRelayDefines --check-public-files
        if ($LASTEXITCODE -ne 0) { throw 'Private PC Agent server preparation failed.' }
    }
    else {
        Write-Host 'No private PC Agent configuration found; running the public configurable variant.'
    }
    # Runtime model imports replace the former bundled character archives.
    $runArgs = @('run', '-d', $Device, '--no-pub')
    if ($privateRelayDefines) {
        $runArgs += "--dart-define-from-file=$privateRelayDefines"
    }
    & flutter @runArgs
    if ($LASTEXITCODE -ne 0) { throw "Protected Flutter run failed." }
}
finally {
    Pop-Location
}
