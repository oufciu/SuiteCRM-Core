[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Check', 'Backend', 'Frontend', 'Serve', 'Stop')]
    [string] $Action,
    [string] $RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'SuiteCRM-Windows-Runtime'),
    [ValidateRange(1024, 65535)]
    [int] $HttpPort = 18080,
    [ValidateRange(1024, 65535)]
    [int] $DbPort = 13306
)

$ErrorActionPreference = 'Stop'
if ($HttpPort -eq $DbPort) { throw 'HTTP and database ports must differ.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$root = [IO.Path]::GetFullPath($RuntimeRoot)
if ($root -eq $repo -or $root.StartsWith("$repo\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Keep the runtime outside the source checkout.'
}

function Invoke-Native([string] $Program, [string[]] $Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Program)) exited with code $LASTEXITCODE." }
}

function Write-Config([string] $Path, [string] $Contents) {
    [IO.File]::WriteAllText($Path, $Contents, [Text.UTF8Encoding]::new($false))
}

function Get-FreeLoopbackPort([int] $Port) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() }
    catch { throw "Loopback port $Port is unavailable; select a different port." }
    finally { $listener.Stop() }
}

function Test-OwnedListener([Diagnostics.Process] $Process, [int] $Port) {
    $connection = Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]($connection | Where-Object OwningProcess -eq $Process.Id)
}

$packages = Join-Path $root 'packages'
$phpHome = Join-Path $packages 'php-8.2.36'
$php = Join-Path $phpHome 'php.exe'
$composer = Join-Path $packages 'composer\composer.phar'
$apacheHome = Join-Path $packages 'apache\Apache24'
$apache = Join-Path $apacheHome 'bin\httpd.exe'
$dbHome = Join-Path $packages 'mariadb\mariadb-11.4.14-winx64'
$db = Join-Path $dbHome 'bin\mariadbd.exe'
$node = Join-Path $packages 'node\node-v22.23.5-win-x64'
$corepack = Join-Path $node 'corepack.cmd'
$amqp = Join-Path $packages 'amqp'
$redis = Join-Path $packages 'redis'
$amqpDll = Join-Path $amqp 'php_amqp.dll'
$redisDll = Join-Path $redis 'php_redis.dll'
$rabbitMqDll = Join-Path $amqp 'rabbitmq.4.dll'
$phpFiles = @($php, $amqpDll, $redisDll, $rabbitMqDll)
$required = switch ($Action) {
    Check { $phpFiles + @($composer, $apache, $db, $corepack) }
    Backend { $phpFiles + @($composer) }
    Frontend { $phpFiles + @($corepack) }
    Serve { $phpFiles + @($apache, $db) }
}
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing package file $path. Run prepare.ps1 first."
    }
}

$pathHash = [Security.Cryptography.SHA256]::Create()
try {
    $id = [BitConverter]::ToString($pathHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($repo.ToUpperInvariant()))).Replace('-', '').Substring(0, 12)
} finally {
    $pathHash.Dispose()
}
$instance = Join-Path $root "instances\$id"
$stopFile = Join-Path $instance 'stop-requested'
if ($Action -eq 'Stop') {
    if (-not (Test-Path -LiteralPath $instance -PathType Container)) {
        throw 'No instance exists for this worktree and runtime root.'
    }
    Write-Config $stopFile "stop`n"
    return
}
$logs = Join-Path $instance 'logs'
$temp = Join-Path $instance 'tmp'
$data = Join-Path $instance 'data'
New-Item -ItemType Directory -Path $instance, $logs, $temp -Force | Out-Null
$env:Path = "$phpHome;$amqp;$node;$env:Path"
$env:PHPRC = $instance
$iniScan = Join-Path $instance 'ini.d'
New-Item -ItemType Directory -Path $iniScan -Force | Out-Null
$env:PHP_INI_SCAN_DIR = $iniScan
$env:COMPOSER_HOME = Join-Path $root 'composer-home'
$env:COREPACK_HOME = Join-Path $root 'corepack'
$env:YARN_GLOBAL_FOLDER = Join-Path $root 'yarn'

$phpPath = $phpHome.Replace('\', '/')
$amqpPath = $amqpDll.Replace('\', '/')
$redisPath = $redisDll.Replace('\', '/')
$logsPath = $logs.Replace('\', '/')
$tempPath = $temp.Replace('\', '/')
$phpIni = Join-Path $instance 'php.ini'
Write-Config $phpIni @"
[PHP]
extension_dir = "$phpPath/ext"
extension = curl
extension = fileinfo
extension = gd
extension = intl
extension = ldap
extension = mbstring
extension = mysqli
extension = openssl
extension = pdo_mysql
extension = soap
extension = sodium
extension = zip
extension = "$amqpPath"
extension = "$redisPath"
date.timezone = UTC
memory_limit = 512M
max_execution_time = 180
post_max_size = 64M
upload_max_filesize = 32M
error_reporting = E_ALL
display_errors = Off
log_errors = On
error_log = "$logsPath/php.log"
session.save_path = "$tempPath"
upload_tmp_dir = "$tempPath"
sys_temp_dir = "$tempPath"
"@

Push-Location -LiteralPath $repo
try {
    if ($Action -eq 'Check') {
        Write-Output "Instance: $instance"
        Invoke-Native $php @('-v')
        Invoke-Native $php @('-m')
        Invoke-Native $apache @('-v')
        Invoke-Native $db @('--no-defaults', '--version')
        Invoke-Native (Join-Path $node 'node.exe') @('--version')
        Invoke-Native $php @($composer, '--version')
        Invoke-Native $corepack @('yarn', '--version')
        return
    }
    if ($Action -eq 'Backend') {
        Invoke-Native $php @($composer, 'check-platform-reqs', '--lock')
        Invoke-Native $php @($composer, 'install', '--no-interaction', '--prefer-dist')
        Invoke-Native $php @($composer, 'check-platform-reqs')
        return
    }
    if ($Action -eq 'Frontend') {
        if (-not (Test-Path -LiteralPath 'vendor\autoload.php' -PathType Leaf)) {
            throw 'Composer dependencies are missing. Run -Action Backend first.'
        }
        Invoke-Native $corepack @('yarn', 'install', '--immutable')
        Invoke-Native $corepack @('yarn', 'merge-angular-json')
        Invoke-Native $corepack @('yarn', 'build')
        Invoke-Native $corepack @('yarn', 'build:extension', 'defaultExt')
        Invoke-Native $php @('bin/console', 'scrm:extension-asset-install')
        if (-not (Test-Path -LiteralPath 'public\extensions\defaultExt\remoteEntry.js' -PathType Leaf)) {
            throw 'The built defaultExt was not published under public\extensions.'
        }
        return
    }

    if (-not (Test-Path -LiteralPath 'vendor\autoload_runtime.php' -PathType Leaf)) {
        throw 'The Symfony web autoloader is missing. Run -Action Backend first.'
    }
    $lock = [IO.File]::Open((Join-Path $instance 'serve.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile }
        Get-FreeLoopbackPort $HttpPort
        Get-FreeLoopbackPort $DbPort
        $dbBin = Join-Path $dbHome 'bin'
        $dbInit = Join-Path $dbBin 'mariadb-install-db.exe'
        $dbClient = Join-Path $dbBin 'mariadb.exe'
        $dbAdmin = Join-Path $dbBin 'mariadb-admin.exe'
        $secretsPath = Join-Path $instance 'credentials.json'
        $initialized = Join-Path $instance 'database-initialized'
        if (-not (Test-Path -LiteralPath $initialized)) {
            if ((Test-Path -LiteralPath '.env.local') -or (Test-Path -LiteralPath 'public\legacy\config.php')) {
                throw 'This checkout is already configured. Use a fresh worktree for the isolated runtime.'
            }
            if (Test-Path -LiteralPath $data) {
                throw "Unrecognized or partially initialized DB data at $data. Do not reuse it; choose another runtime root."
            }
            $secrets = @{
                rootPassword = [Guid]::NewGuid().ToString('N')
                dbPassword = [Guid]::NewGuid().ToString('N')
                sitePassword = [Guid]::NewGuid().ToString('N')
            }
            Write-Config $secretsPath ($secrets | ConvertTo-Json)
            # No service registration. Initialization is performed only on absent data.
            Invoke-Native $dbInit @("--datadir=$data", "--password=$($secrets.rootPassword)", "--port=$DbPort")
        } else {
            $secrets = Get-Content -LiteralPath $secretsPath -Raw | ConvertFrom-Json
        }
        $dbClientConfig = Join-Path $instance 'db-client.ini'
        Write-Config $dbClientConfig @"
[client]
protocol=tcp
host=127.0.0.1
port=$DbPort
user=root
password=$($secrets.rootPassword)
"@
        $dbConfig = Join-Path $instance 'database.ini'
        $dataPath = $data.Replace('\', '/')
        $dbPath = $dbHome.Replace('\', '/')
        Write-Config $dbConfig @"
[mysqld]
basedir="$dbPath"
datadir="$dataPath"
bind-address=127.0.0.1
port=$DbPort
log-error="$logsPath/mariadb.log"
skip-name-resolve
"@

        $apacheConfig = Join-Path $instance 'httpd.conf'
        $apachePath = $apacheHome.Replace('\', '/')
        $instancePath = $instance.Replace('\', '/')
        $public = (Join-Path $repo 'public').Replace('\', '/')
        Write-Config $apacheConfig @"
ServerRoot "$apachePath"
Listen 127.0.0.1:$HttpPort
ServerName 127.0.0.1:$HttpPort
PidFile "$instancePath/httpd.pid"
ErrorLog "$logsPath/apache-error.log"
LoadModule alias_module modules/mod_alias.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule dir_module modules/mod_dir.so
LoadModule env_module modules/mod_env.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule mime_module modules/mod_mime.so
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule headers_module modules/mod_headers.so
LoadModule php_module "$phpPath/php8apache2_4.dll"
PHPIniDir "$instancePath"
SetEnv APP_ENV prod
SetEnv APP_DEBUG 0
TypesConfig conf/mime.types
LogFormat "%h %l %u %t \"%m %U %H\" %>s %b" sandbox
CustomLog "$logsPath/apache-access.log" sandbox
DocumentRoot "$public"
<Directory />
    AllowOverride None
    Require all denied
</Directory>
<Directory "$public">
    Options FollowSymLinks
    AllowOverride All
    Require local
</Directory>
<FilesMatch "\.php$">
    SetHandler application/x-httpd-php
</FilesMatch>
"@
        Invoke-Native $apache @('-f', $apacheConfig, '-t')
        $dbProcess = $null
        $apacheProcess = $null
        try {
            $dbProcess = Start-Process -FilePath $db -ArgumentList "`"--defaults-file=$dbConfig`"" -PassThru -NoNewWindow
            $clientArg = "--defaults-file=$dbClientConfig"
            $deadline = [DateTime]::UtcNow.AddSeconds(45)
            do {
                if ($dbProcess.HasExited) { throw "MariaDB failed to start. See $logsPath/mariadb.log." }
                $ownsListener = Test-OwnedListener $dbProcess $DbPort
                if ($ownsListener) { break }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $deadline)
            if (-not $ownsListener) { throw "MariaDB did not become ready. See $logsPath/mariadb.log." }
            if (-not (Test-Path -LiteralPath $initialized)) {
                @"
CREATE DATABASE suitecrm_windows CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'suitecrm_windows'@'127.0.0.1' IDENTIFIED BY '$($secrets.dbPassword)';
GRANT ALL ON suitecrm_windows.* TO 'suitecrm_windows'@'127.0.0.1';
"@ | & $dbClient $clientArg --batch
                if ($LASTEXITCODE -ne 0) { throw 'Could not create the dedicated database and application user.' }
                Write-Config $initialized "initialized`n"
            }
            $apacheProcess = Start-Process -FilePath $apache -ArgumentList "-X -f `"$apacheConfig`"" -PassThru -NoNewWindow
            $deadline = [DateTime]::UtcNow.AddSeconds(45)
            do {
                if ($apacheProcess.HasExited) { throw "Apache failed to start. See $logsPath/apache-error.log." }
                if ($dbProcess.HasExited) { throw "MariaDB exited during startup. See $logsPath/mariadb.log." }
                $apacheReady = Test-OwnedListener $apacheProcess $HttpPort
                if ($apacheReady) { break }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $deadline)
            if (-not $apacheReady) { throw "Apache did not bind its loopback listener. See $logsPath/apache-error.log." }
            Write-Output "URL: http://127.0.0.1:$HttpPort/"
            Write-Output "Instance and logs: $instance"
            Write-Output "Local credentials file (do not share): $secretsPath"
            while (-not (Test-Path -LiteralPath $stopFile)) {
                if ($apacheProcess.WaitForExit(250)) { throw "Apache exited unexpectedly with code $($apacheProcess.ExitCode). See $logsPath/apache-error.log." }
                if ($dbProcess.HasExited) { throw "MariaDB exited unexpectedly with code $($dbProcess.ExitCode). See $logsPath/mariadb.log." }
            }
        } finally {
            if ($apacheProcess -and -not $apacheProcess.HasExited) { Stop-Process -InputObject $apacheProcess }
            if ($dbProcess -and -not $dbProcess.HasExited) {
                $ownsListener = Test-OwnedListener $dbProcess $DbPort
                if ($ownsListener) { & $dbAdmin "--defaults-file=$dbClientConfig" shutdown }
                if (-not $ownsListener -or $LASTEXITCODE -ne 0 -or -not $dbProcess.WaitForExit(15000)) {
                    Stop-Process -InputObject $dbProcess
                }
            }
        }
    } finally {
        $lock.Dispose()
    }
} finally {
    Pop-Location
}
