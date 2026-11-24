param(
    [Parameter(Mandatory = $true)][string]$PhpExe,
    [Parameter(Mandatory = $true)][string]$PhpIni,
    [Parameter(Mandatory = $true)][string]$PhpIniScanDir,
    [Parameter(Mandatory = $true)][string]$AmqpDllDir,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-PathOfType([string]$Path, [bool]$Directory) {
    if (-not [IO.Path]::IsPathRooted($Path) -or
        ([IO.Path]::DirectorySeparatorChar -eq '\' -and $Path -notmatch '^[A-Za-z]:[\\/]')) {
        throw "Expected an absolute local path: $Path"
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSProvider.Name -ne 'FileSystem' -or $item.PSIsContainer -ne $Directory) {
        throw "Unexpected path type: $Path"
    }
    $item.FullName
}

$savedEnvironment = @{}
foreach ($name in 'PHPRC', 'PHP_INI_SCAN_DIR', 'PATH', 'APP_ENV', 'APP_DEBUG') {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$changedLocation = $false

try {
    $php = Get-PathOfType $PhpExe $false
    $ini = Get-PathOfType $PhpIni $false
    $scanDir = Get-PathOfType $PhpIniScanDir $true
    $dllDir = Get-PathOfType $AmqpDllDir $true
    $null = Get-PathOfType (Join-Path $dllDir 'rabbitmq.4.dll') $false
    $project = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $console = Get-PathOfType (Join-Path $project 'bin\console') $false

    # Only the dedicated task process and its children need these settings.
    $env:PHPRC = $ini
    $env:PHP_INI_SCAN_DIR = $scanDir
    $env:PATH = "$dllDir$([IO.Path]::PathSeparator)$env:PATH"
    $env:APP_ENV = 'prod'
    $env:APP_DEBUG = '0'

    Push-Location -LiteralPath $project
    $changedLocation = $true
    $phpArgs = @('-c', $ini, $console, 'schedulers:run', '--no-interaction')
    if ($Help) {
        $checkExtensions = @'
$missing = array_diff(['amqp', 'redis'], array_map('strtolower', get_loaded_extensions()));
if ($missing) {
    fwrite(STDERR, 'Missing portable PHP extensions: ' . implode(', ', $missing) . PHP_EOL);
    exit(1);
}
echo 'Portable PHP extensions loaded: amqp, redis', PHP_EOL;
'@
        & $php -c $ini -r $checkExtensions
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
        $phpArgs += '--help'
    }
    & $php @phpArgs
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    if ($changedLocation) {
        Pop-Location
    }
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
