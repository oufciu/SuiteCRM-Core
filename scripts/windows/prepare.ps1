[CmdletBinding()]
param(
    [string] $RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'SuiteCRM-Windows-Runtime'),
    [Alias('Package')]
    [string[]] $OnlyPackage
)

$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run the 64-bit Windows PowerShell.' }
$root = [IO.Path]::GetFullPath($RuntimeRoot)
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ($root -eq $repo -or $root.StartsWith("$repo\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Keep the runtime outside the source checkout.'
}
$downloads = Join-Path $root 'downloads'
$packages = Join-Path $root 'packages'
New-Item -ItemType Directory -Path $downloads, $packages -Force | Out-Null

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'packages.json') -Raw | ConvertFrom-Json
foreach ($name in $OnlyPackage) {
    if ($name -notin $manifest.name) { throw "Unknown package: $name" }
}

function Test-PackageContents([object] $Package, [string] $Destination) {
    foreach ($file in @($Package.files)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $file) -PathType Leaf)) { return $false }
    }
    return $true
}

foreach ($package in $manifest) {
    if ($OnlyPackage -and $package.name -notin $OnlyPackage) { continue }
    $archive = Join-Path $downloads $package.file
    $destination = Join-Path $packages $package.name
    $markerName = ".extracted-$($package.sha256.ToLowerInvariant())"
    $lock = [IO.File]::Open("$destination.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        # Reuse only a destination whose completion marker matches this exact
        # manifest digest and whose required files are all present. Anything
        # else is stale or unknown: refuse without deleting it.
        if (Test-Path -LiteralPath $destination) {
            $marker = Join-Path $destination $markerName
            if ((Test-Path -LiteralPath $marker -PathType Leaf) -and (Test-PackageContents $package $destination)) {
                Write-Output "Verified $($package.file) (cached, marker $markerName)"
                continue
            }
            throw ("Unrecognized or stale package directory '$destination'. It does not match the " +
                "manifest digest $($package.sha256). Inspect it, then remove it yourself or use a fresh -RuntimeRoot; this script never deletes it.")
        }

        if (-not (Test-Path -LiteralPath $archive)) {
            # Ordered sources: canonical publisher URL first, then the declared
            # mirror. Every attempt must independently match the manifest
            # SHA-256; a mismatched archive is discarded, never accepted.
            $sources = @($package.url) + @($package.mirror) | Where-Object { $_ }
            $downloaded = $false
            $errors = @()
            foreach ($source in $sources) {
                $temp = "$archive.part"
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
                & curl.exe --fail --silent --show-error --location --connect-timeout 15 --max-time 900 --proto '=https' --proto-redir '=https' --output $temp $source
                if ($LASTEXITCODE -ne 0) {
                    $errors += "download failed from $source (exit $LASTEXITCODE)"
                    continue
                }
                $hash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
                if ($hash -ne $package.sha256) {
                    $errors += "checksum mismatch from $source (got $hash)"
                    Remove-Item -LiteralPath $temp -Force
                    continue
                }
                Move-Item -LiteralPath $temp -Destination $archive
                $downloaded = $true
                break
            }
            if (-not $downloaded) {
                throw "Could not obtain a valid archive for $($package.name): $($errors -join '; ')"
            }
        }

        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $package.sha256) {
            throw "Cached archive checksum mismatch: $archive. Remove it yourself after inspection; this script never deletes it."
        }

        $staging = "$destination.extracting"
        if (Test-Path -LiteralPath $staging) {
            throw "Unknown partial extraction at '$staging'. Inspect and remove it yourself; this script never deletes it."
        }
        New-Item -ItemType Directory -Path $staging | Out-Null
        if ($package.file.EndsWith('.zip')) {
            & tar.exe -xf $archive -C $staging
            if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $($package.file)" }
        } else {
            Copy-Item -LiteralPath $archive -Destination (Join-Path $staging 'composer.phar')
        }
        if (-not (Test-PackageContents $package $staging)) {
            throw "Extracted $($package.file) is missing required files; refusing incomplete package."
        }
        # Completion marker is written only after a full, verified extraction,
        # and it keys the directory to this exact manifest digest.
        [IO.File]::WriteAllText((Join-Path $staging $markerName), "$($package.sha256)`n", [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $staging -Destination $destination
        Write-Output "Verified $($package.file)"
    } finally {
        $lock.Dispose()
    }
}
