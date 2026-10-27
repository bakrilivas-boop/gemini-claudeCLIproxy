$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$configPath = Join-Path $env:USERPROFILE 'Downloads\CLIProxyAPI_7.3.17_windows_amd64\config.yaml'
$keyPath = Join-Path $PSScriptRoot '管理密钥.dat'
if (-not [IO.File]::Exists($configPath)) { throw '找不到 CLIProxyAPI config.yaml。' }
$config = [IO.File]::ReadAllText($configPath)
$keyPattern = '(?m)^([ \t]*secret-key:[ \t]*)(?:"([^"]*)"|''([^'']*)''|([^\r\n#]*))([ \t]*(?:#.*)?)\r?$'
$keyMatches = [regex]::Matches($config, $keyPattern)
if ($keyMatches.Count -ne 1) { throw '无法唯一定位管理密钥配置。' }
$usagePattern = '(?m)^usage-statistics-enabled:[ \t]*(?:true|false)[ \t]*\r?$'
if ([regex]::Matches($config, $usagePattern).Count -ne 1) { throw '无法唯一定位用量统计配置。' }
$existingKey = @($keyMatches[0].Groups[2].Value, $keyMatches[0].Groups[3].Value, $keyMatches[0].Groups[4].Value) -join ''
if ([IO.File]::Exists($keyPath)) {
    if (-not $existingKey -or $config -notmatch '(?m)^usage-statistics-enabled:[ \t]*true[ \t]*\r?$') { throw '本地管理密钥与配置状态不一致，请检查后再操作。' }
    'METRICS_ALREADY_CONFIGURED'
    return
}
if ($existingKey) { throw '代理已有管理密钥，本地没有对应密钥文件；为避免覆盖现有配置，已停止。' }

$random = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($random) } finally { $rng.Dispose() }
$key = ([BitConverter]::ToString($random) -replace '-', '').ToLowerInvariant()
$entropy = [Text.Encoding]::UTF8.GetBytes('CLIProxyAPI-Helper-Management-v1')
$protected = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($key), $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
$keyTemp = $keyPath + '.tmp'
$configTemp = $configPath + '.metrics.tmp'
$backup = $configPath + '.metrics-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
try {
    [IO.File]::WriteAllText($keyTemp, [Convert]::ToBase64String($protected), [Text.UTF8Encoding]::new($false))
    $updated = [regex]::Replace($config, $keyPattern, '${1}"' + $key + '"${5}')
    $updated = [regex]::Replace($updated, $usagePattern, 'usage-statistics-enabled: true')
    [IO.File]::WriteAllText($configTemp, $updated, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($keyPath)) { [IO.File]::Delete($keyPath) }
    [IO.File]::Move($keyTemp, $keyPath)
    [IO.File]::Replace($configTemp, $configPath, $backup)
    'METRICS_CONFIGURED; restart CLIProxyAPI to apply'
}
finally {
    if ([IO.File]::Exists($keyTemp)) { [IO.File]::Delete($keyTemp) }
    if ([IO.File]::Exists($configTemp)) { [IO.File]::Delete($configTemp) }
}
