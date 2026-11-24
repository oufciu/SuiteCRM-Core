param([Parameter(Mandatory = $true)][string]$PhpExe)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$project = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$launcher = Join-Path $project 'bin/windows/scheduler.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("SuiteCRM scheduler test " + [guid]::NewGuid())
$initialLocation = (Get-Location).Path
$names = 'PHPRC', 'PHP_INI_SCAN_DIR', 'PATH', 'APP_ENV', 'APP_DEBUG'
$initialEnvironment = @{}
foreach ($name in $names) {
    $initialEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $scanDir = Join-Path $sandbox 'ini scan'
    $dllDir = Join-Path $sandbox 'amqp dlls'
    $ini = Join-Path $sandbox 'test php.ini'
    $prepend = Join-Path $sandbox 'check invocation.php'
    $null = New-Item -ItemType Directory -Path $sandbox, $scanDir, $dllDir
    $null = New-Item -ItemType File -Path (Join-Path $dllDir 'rabbitmq.4.dll')
    Set-Content -LiteralPath $ini -Encoding ASCII -Value 'register_argc_argv=1'
    Set-Content -LiteralPath (Join-Path $scanDir 'fixture.ini') -Encoding ASCII -Value "auto_prepend_file=`"$prepend`""
    Set-Content -LiteralPath $prepend -Encoding ASCII -Value @'
<?php
$args = array_slice($_SERVER['argv'], 1);
$valid = getenv('APP_ENV') === 'prod'
    && getenv('APP_DEBUG') === '0'
    && realpath(getenv('PHPRC')) === realpath(php_ini_loaded_file())
    && basename(getenv('PHP_INI_SCAN_DIR')) === 'ini scan'
    && basename(explode(PATH_SEPARATOR, getenv('PATH'))[0]) === 'amqp dlls'
    && realpath(getcwd()) === realpath(dirname($_SERVER['SCRIPT_FILENAME'], 2))
    && $args === ['schedulers:run', '--no-interaction'];
if (!$valid) {
    fwrite(STDERR, "Unexpected scheduler environment or arguments\n");
    exit(2);
}
echo "Scheduler fixture verified PHP configuration, working directory and arguments\n";
fwrite(STDERR, "Scheduler fixture stderr\n");
exit(37);
'@

    $env:APP_ENV = 'fixture-parent'
    Remove-Item Env:APP_DEBUG -ErrorAction SilentlyContinue
    $expectedEnvironment = @{}
    foreach ($name in $names) {
        $expectedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    & $launcher -PhpExe $PhpExe -PhpIni $ini -PhpIniScanDir $scanDir -AmqpDllDir $dllDir
    if ($LASTEXITCODE -ne 37) {
        throw "Expected PHP exit 37, received $LASTEXITCODE"
    }
    if ((Get-Location).Path -ne $initialLocation) {
        throw 'Launcher did not restore the working directory'
    }
    foreach ($name in $names) {
        if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $expectedEnvironment[$name]) {
            throw "Launcher did not restore $name"
        }
    }

    & $launcher -PhpExe $PhpExe -PhpIni (Join-Path $sandbox 'missing.ini') -PhpIniScanDir $scanDir -AmqpDllDir $dllDir
    if ($LASTEXITCODE -ne 1) {
        throw "Expected invalid path to exit 1, received $LASTEXITCODE"
    }
    Write-Output 'Scheduler launcher smoke passed'
} finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $initialEnvironment[$name], 'Process')
    }
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse
    }
}
