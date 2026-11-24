# Shared by the Windows packaging entry points. Requires Windows PowerShell 5.1.
function Get-PackagingContext {
    param([string] $RuntimeRoot, [int] $HttpPort = 18080, [int] $DbPort = 13306)
    if ($HttpPort -eq $DbPort) { throw 'HTTP and database ports must differ.' }
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    if ($root -eq $repo -or $root.StartsWith("$repo\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Keep the runtime outside the source checkout.'
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $id = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($repo.ToUpperInvariant()))).Replace('-', '').Substring(0, 12) }
    finally { $hash.Dispose() }
    $instance = Join-Path $root "instances\$id"
    [pscustomobject]@{
        Repo = $repo; Root = $root; Id = $id; Instance = $instance
        HttpPort = $HttpPort; DbPort = $DbPort
        TaskName = "SuiteCRM-Windows-$id"; ServiceName = "SuiteCRM-Windows-$id"
        Runtime = Join-Path $PSScriptRoot 'runtime.ps1'
        PowerShell = Join-Path $PSHOME 'powershell.exe'
        Php = Join-Path $root 'packages\php-8.2.36\php.exe'
        Node = Join-Path $root 'packages\node\node-v22.23.5-win-x64\node.exe'
        Corepack = Join-Path $root 'packages\node\node-v22.23.5-win-x64\corepack.cmd'
        Apache = Join-Path $root 'packages\apache\Apache24\bin\httpd.exe'
        Database = Join-Path $root 'packages\mariadb\mariadb-11.4.14-winx64\bin\mariadbd.exe'
        Reports = Join-Path $repo 'tests\_output\windows'
        Registration = Join-Path $instance 'startup-registration.json'
    }
}

function ConvertTo-WindowsArgument([string] $Value) {
    # Windows CommandLineToArgvW quoting, including quotes and trailing backslashes.
    '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Write-PackagingJUnit {
    param([string] $Path, [string] $Name, [object[]] $Results)
    $document = New-Object Xml.XmlDocument
    $suite = $document.CreateElement('testsuite')
    $suite.SetAttribute('name', $Name)
    $suite.SetAttribute('tests', [string]@($Results).Count)
    $suite.SetAttribute('failures', [string]@($Results | Where-Object { $_.ExitCode -ne 0 }).Count)
    $null = $document.AppendChild($suite)
    foreach ($result in $Results) {
        $case = $document.CreateElement('testcase')
        $case.SetAttribute('name', [string]$result.Name)
        $case.SetAttribute('classname', $Name)
        $case.SetAttribute('time', ([double]$result.Seconds).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture))
        if ($result.ExitCode -ne 0) {
            $failure = $document.CreateElement('failure')
            $failure.SetAttribute('message', "Exit $($result.ExitCode); see $($result.Log)")
            $null = $case.AppendChild($failure)
        }
        $null = $suite.AppendChild($case)
    }
    $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
    $document.Save($Path)
}

function Invoke-PackagingCommand {
    param($Context, [string] $Name, [string] $Program, [string[]] $Arguments)
    $null = New-Item -ItemType Directory -Path $Context.Reports -Force
    $log = Join-Path $Context.Reports "$Name.stdout.log"
    $errorLog = Join-Path $Context.Reports "$Name.stderr.log"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $code = 1
    try {
        if (-not (Test-Path -LiteralPath $Program -PathType Leaf)) { throw "Missing executable: $Program" }
        # .cmd launch must go through cmd.exe; arguments are fixed tool commands, not shell input.
        if ($Program.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase)) {
            $line = '"' + ((@($Program) + $Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ') + '"'
            $process = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/s', '/c', $line) -WorkingDirectory $Context.Repo -Wait -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError $errorLog
        } else {
            $line = ($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
            $process = Start-Process -FilePath $Program -ArgumentList $line -WorkingDirectory $Context.Repo -Wait -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError $errorLog
        }
        $code = $process.ExitCode
    } catch { [IO.File]::AppendAllText($errorLog, $_.Exception.Message); $code = 1 }
    $watch.Stop()
    Write-Host "$Name exit=$code ($([math]::Round($watch.Elapsed.TotalSeconds, 1))s), logs: $log / $errorLog"
    [pscustomobject]@{ Name = $Name; ExitCode = $code; Seconds = $watch.Elapsed.TotalSeconds; Log = $log }
}

function Get-RuntimeArguments($Context, [string] $Action) {
    @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Context.Runtime,
      '-Action', $Action, '-RuntimeRoot', $Context.Root,
      '-HttpPort', [string]$Context.HttpPort, '-DbPort', [string]$Context.DbPort)
}

function Set-PackagingEnvironment($Context) {
    $env:PHPRC = $Context.Instance
    $env:PHP_INI_SCAN_DIR = Join-Path $Context.Instance 'ini.d'
    $env:PATH = "$(Split-Path $Context.Php);$(Join-Path $Context.Root 'packages\amqp');$(Split-Path $Context.Node);$env:PATH"
    $env:COMPOSER_HOME = Join-Path $Context.Root 'composer-home'
    $env:COREPACK_HOME = Join-Path $Context.Root 'corepack'
    $env:YARN_GLOBAL_FOLDER = Join-Path $Context.Root 'yarn'
    $env:APP_ENV = 'prod'
    $env:APP_DEBUG = '0'
}

function Get-PackagingEnvironmentSnapshot {
    $saved = @{}
    foreach ($name in @('PHPRC', 'PHP_INI_SCAN_DIR', 'PATH', 'COMPOSER_HOME', 'COREPACK_HOME',
        'YARN_GLOBAL_FOLDER', 'APP_ENV', 'APP_DEBUG', 'CHROME_BIN', 'SUITECRM_KARMA_PROJECT', 'SUITECRM_JUNIT_PATH')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $saved
}

function Restore-PackagingEnvironment($Saved) {
    foreach ($name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($name, $Saved[$name], 'Process') }
}

function Get-InstanceListener($Context, [int] $Port, [string] $Program, [string] $ConfigName) {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if (-not $listeners.Count) { return $null }
    if (@($listeners | Where-Object LocalAddress -ne '127.0.0.1').Count) { throw "Port $Port is not exclusively loopback." }
    $owners = @($listeners.OwningProcess | Select-Object -Unique)
    if ($owners.Count -ne 1) { throw "Ambiguous listener on port $Port." }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owners[0])"
    if (-not $process) { return $null }
    $config = Join-Path $Context.Instance $ConfigName
    if ($process.ExecutablePath -ne $Program -or
        $process.CommandLine.IndexOf($config, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Port $Port belongs to another instance; no action taken."
    }
    $owners[0]
}

function Get-InstanceStatus($Context) {
    $web = Get-InstanceListener $Context $Context.HttpPort $Context.Apache 'httpd.conf'
    $db = Get-InstanceListener $Context $Context.DbPort $Context.Database 'database.ini'
    $state = 'Stopped'
    if ($web -and $db) { $state = 'Running' }
    elseif ($web -or $db) { $state = 'Partial' }
    [pscustomobject]@{ State = $state; Instance = $Context.Id; ApachePid = $web; DatabasePid = $db; HttpPort = $Context.HttpPort; DbPort = $Context.DbPort }
}

function Get-StartupRegistration($Context) {
    if (-not (Test-Path -LiteralPath $Context.Registration)) { return $null }
    $registration = Get-Content -LiteralPath $Context.Registration -Raw | ConvertFrom-Json
    if ($registration.Repo -ne $Context.Repo -or $registration.Root -ne $Context.Root -or
        $registration.HttpPort -ne $Context.HttpPort -or $registration.DbPort -ne $Context.DbPort) {
        throw 'Startup registration has different paths or ports. Use its original parameters.'
    }
    $registration
}

function Get-OwnedStartupTask($Context) {
    $task = Get-ScheduledTask -TaskName $Context.TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $launcher = Join-Path $Context.Instance 'startup-launcher.ps1'
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + (ConvertTo-WindowsArgument $launcher)
    if ($task.Actions.Execute -ne $Context.PowerShell -or $task.Actions.Arguments -ne $arguments) {
        throw 'Task action was replaced; refusing to start or remove it.'
    }
    $task
}

function Open-MessengerStateLock($Context) {
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        try { return [IO.File]::Open((Join-Path $Context.Instance 'messenger-state.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 25
        }
    } while ($true)
}

function Get-MessengerStatus($Context) {
    $statePath = Join-Path $Context.Instance 'messenger-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { return 'Stopped' }
    $stateLock = Open-MessengerStateLock $Context
    try {
        if (-not (Test-Path -LiteralPath $statePath)) { return 'Stopped' }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } finally { $stateLock.Dispose() }
    $monitor = Get-CimInstance Win32_Process -Filter "ProcessId=$($state.MonitorPid)"
    if (-not $monitor) { return 'Stopped' }
    $script = Join-Path $Context.Repo 'scripts\windows\messenger-worker.ps1'
    if ($monitor.ExecutablePath -ne $Context.PowerShell -or $monitor.CommandLine.IndexOf($script, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'Messenger state refers to a foreign process; no action taken.'
    }
    if (-not $state.WorkerPid) { return 'Starting' }
    $worker = Get-CimInstance Win32_Process -Filter "ProcessId=$($state.WorkerPid)"
    if (-not $worker) { return 'Starting' }
    $console = Join-Path $Context.Repo 'bin\console'
    if ($worker.ExecutablePath -ne $Context.Php -or
        $worker.CommandLine.IndexOf($console, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $worker.CommandLine -notmatch 'messenger:consume') { throw 'Messenger worker ownership mismatch.' }
    'Running'
}

function Get-PackagingStatus($Context, $Registration) {
    $status = Get-InstanceStatus $Context
    $messenger = Get-MessengerStatus $Context
    $status | Add-Member -NotePropertyName Messenger -NotePropertyValue $messenger
    if ($Registration -and $Registration.WithMessenger) {
        if ($status.State -eq 'Running' -and $messenger -ne 'Running') { $status.State = 'Partial' }
        elseif ($status.State -eq 'Stopped' -and $messenger -ne 'Stopped') { $status.State = 'Partial' }
    }
    $status
}
