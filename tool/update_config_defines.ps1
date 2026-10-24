function Resolve-OpenAgentUpdateConfigDefines {
    param([string]$Path = '')

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $content = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop
    if ($content.Length -gt 131200) {
        throw 'OpenAgentAtelier update definitions exceed the permitted size.'
    }
    try { $definitions = $content | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'OpenAgentAtelier update definitions must be a JSON object.' }
    $allowedKeys = @('OAA_UPDATE_CONFIG_BLOB', 'OAA_UPDATE_CONFIG_KEY')
    if ($null -eq $definitions -or $definitions -is [array] -or
        @($definitions.PSObject.Properties).Count -ne 2 -or
        [regex]::Matches($content, '"(?:[^"\\]|\\.)*"\s*:').Count -ne 2) {
        throw 'Update definitions must contain exactly the two independent OAA update keys.'
    }
    foreach ($property in $definitions.PSObject.Properties) {
        if ($property.Name -cnotin $allowedKeys -or
            $property.Value -isnot [string] -or
            $property.Value -cnotmatch '^[A-Za-z0-9_-]+={0,2}$') {
            throw 'Update definitions may contain only the two encoded OAA update keys.'
        }
    }
    return $resolved
}
