# Shared helpers for .github/workflows/armorpaint-compile.yml.
# Dot-source this file from a PowerShell 7 (pwsh) step:
#   . "$env:GITHUB_WORKSPACE/.github/scripts/armorpaint-build-common.ps1"

Set-StrictMode -Version Latest

# GitHub rejects pushed files of 100 MB or more; stay below that with margin.
$script:MaxCommitFileBytes = 95MB
$script:SplitPartBytes = 90MB

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ""
    Write-Host ("=" * 70)
    Write-Host $Title
    Write-Host ("=" * 70)
}

function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

function Get-BuildConfig {
    <# Per-version layout. Paths are relative to the repository root. #>
    param([Parameter(Mandatory)][ValidateSet("1.0", "0.9")][string]$Version)

    if ($Version -eq "1.0") {
        $config = @{
            Version     = "1.0"
            Tag         = "26.09"
            SourceRel   = "sources/armorpaint-260"
            ProjectDir  = "paint"          # directory the generator is run from
            RuntimeDir  = "build/out"      # where amake puts data/ and shaders
            Toolset     = "ClangCL"
            Required    = @(
                "paint/project.js", "base/project.js", "base/make.bat",
                "base/tools/make.js", "base/tools/bin/windows_x64/amake.exe"
            )
            CloneHint   = "ArmorPaint 1.0"
        }
    }
    else {
        $config = @{
            Version     = "0.9"
            Tag         = "23.09"
            SourceRel   = "sources/armorpaint-09"
            ProjectDir  = "armorpaint"
            RuntimeDir  = "build/krom"     # Kha/Krom export (krom.js, data, shaders)
            Toolset     = "v143"
            Required    = @(
                "armorpaint/khafile.js", "armorpaint/kincflags.js", "base/khafile.js",
                "armorcore/kfile.js", "armorcore/make.js", "armorcore/Kinc/make.bat",
                "armorcore/Kinc/kfile.js", "ARMORPAINT_DEPENDENCIES.json"
            )
            CloneHint   = "ArmorPaint 0.9"
        }
    }

    $config.OutputName = "ArmorPaint-$Version-Windows-x64"
    $config.ZipName = "$($config.OutputName).zip"
    return $config
}

function Invoke-Logged {
    <#
      Runs a native command, mirrors its output to the console and to a log file
      and returns the exit code. It never throws on a non-zero exit code; the
      caller decides what a failure means and must check the returned value.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$LogFile
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null

    $header = @(
        "Command:   $FilePath $($Arguments -join ' ')",
        "Directory: $WorkingDirectory",
        "Started:   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        ""
    )
    $header | Out-File -FilePath $LogFile -Encoding utf8
    $header | ForEach-Object { Write-Host $_ }

    $code = 1
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $global:LASTEXITCODE = 0
        # Stringify every record so stderr lines are logged as plain text.
        & $FilePath @Arguments 2>&1 |
            ForEach-Object { "$_" } |
            Tee-Object -FilePath $LogFile -Append |
            ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    }
    finally {
        Pop-Location
    }

    $footer = "`nFinished:  $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))  exit code $code"
    $footer | Out-File -FilePath $LogFile -Encoding utf8 -Append
    Write-Host $footer
    return [int]$code
}

function Invoke-Git {
    <# Runs git and throws with its output when it fails. #>
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$WorkingDirectory = (Get-Location).Path)
    $output = & git -c core.autocrlf=false -c core.longpaths=true -C $WorkingDirectory @Arguments 2>&1 |
        ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code ${LASTEXITCODE}:`n$($output -join "`n")"
    }
    return $output
}

function Get-PinnedRepo {
    <#
      Fetches exactly one commit (shallow) into Destination and removes the
      .git directory. Candidate URLs are tried in order; the commit SHA is
      verified, so a mirror yields byte-identical content.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][string]$Destination
    )

    $errors = @()
    foreach ($url in $Urls) {
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        try {
            Invoke-Git -WorkingDirectory $Destination -Arguments @("init", "-q") | Out-Null
            Invoke-Git -WorkingDirectory $Destination -Arguments @("remote", "add", "origin", $url) | Out-Null
            Invoke-Git -WorkingDirectory $Destination -Arguments @("fetch", "-q", "--depth", "1", "origin", $Sha) | Out-Null
            Invoke-Git -WorkingDirectory $Destination -Arguments @("checkout", "-q", "--detach", "FETCH_HEAD") | Out-Null
            $head = (Invoke-Git -WorkingDirectory $Destination -Arguments @("rev-parse", "HEAD") | Select-Object -First 1).Trim()
            if ($head -ne $Sha) {
                throw "fetched $head but expected $Sha"
            }
            Remove-Item -LiteralPath (Join-Path $Destination ".git") -Recurse -Force
            return $url
        }
        catch {
            $errors += "$url -> $($_.Exception.Message.Split("`n")[0])"
            Write-Host "  not available from $url"
        }
    }
    throw "Commit $Sha could not be fetched from any candidate URL:`n  $($errors -join "`n  ")"
}

function Find-Solution {
    <#
      Returns the solution to build from Directory: a .sln when one exists,
      otherwise a .slnx, otherwise $null. Extensions are compared exactly
      because a "*.sln" wildcard can also match ".slnx" through NTFS short names.
    #>
    param([Parameter(Mandatory)][string]$Directory, [string]$PreferredName = "ArmorPaint")

    if (!(Test-Path -LiteralPath $Directory)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $Directory -File)
    foreach ($extension in @(".sln", ".slnx")) {
        $found = @($files | Where-Object { $_.Extension -ieq $extension } | Sort-Object Name)
        if ($found.Count -gt 0) {
            $preferred = $found | Where-Object { $_.BaseName -ieq $PreferredName } | Select-Object -First 1
            if ($preferred) { return $preferred }
            return $found[0]
        }
    }
    return $null
}

function Get-VisualStudio {
    <# Locates Visual Studio, MSBuild and the installed C++ platform toolsets. #>
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (!(Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe was not found at $vswhere. This job needs a Windows runner image with Visual Studio."
    }

    $path = (& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath | Select-Object -First 1)
    if (!$path) {
        throw "No Visual Studio installation with MSBuild was found."
    }
    $version = (& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property catalog_productDisplayVersion | Select-Object -First 1)

    $msbuild = Join-Path $path "MSBuild/Current/Bin/MSBuild.exe"
    if (!(Test-Path -LiteralPath $msbuild)) {
        throw "MSBuild.exe was not found at $msbuild."
    }

    $toolsets = @()
    $toolsetRoot = Join-Path $path "MSBuild/Microsoft/VC"
    if (Test-Path -LiteralPath $toolsetRoot) {
        $toolsets = @(
            Get-ChildItem -Path (Join-Path $toolsetRoot "*/Platforms/x64/PlatformToolsets") -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
                Select-Object -ExpandProperty Name -Unique
        )
    }

    return [pscustomobject]@{
        Path     = $path
        Version  = $version
        MSBuild  = $msbuild
        Toolsets = $toolsets
    }
}

function Get-DependentDlls {
    <# Lists the DLLs an executable imports, using dumpbin from the VS toolchain. #>
    param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$VisualStudioPath)

    $dumpbin = Get-ChildItem -Path (Join-Path $VisualStudioPath "VC/Tools/MSVC/*/bin/Hostx64/x64/dumpbin.exe") -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (!$dumpbin) { return $null }

    $lines = & $dumpbin.FullName /nologo /dependents $Executable 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { return $null }

    $dlls = @()
    $inList = $false
    foreach ($line in $lines) {
        if ($line -match "Image has the following dependencies") { $inList = $true; continue }
        if (!$inList) { continue }
        if ($line -match "^\s*Summary") { break }
        if ($line -match "^\s+(\S+\.dll)\s*$") { $dlls += $Matches[1] }
    }
    return $dlls
}

function Split-FileIntoParts {
    <# Splits Path into Path.part001, Path.part002, ... of at most PartBytes. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$PartBytes = $script:SplitPartBytes
    )

    $parts = @()
    $buffer = New-Object byte[] (4MB)
    $reader = [System.IO.File]::OpenRead($Path)
    try {
        $index = 1
        while ($reader.Position -lt $reader.Length) {
            $partPath = "{0}.part{1:D3}" -f $Path, $index
            $writer = [System.IO.File]::Create($partPath)
            $written = [long]0
            try {
                while ($written -lt $PartBytes -and $reader.Position -lt $reader.Length) {
                    $want = [int][Math]::Min([long]$buffer.Length, $PartBytes - $written)
                    $read = $reader.Read($buffer, 0, $want)
                    if ($read -le 0) { break }
                    $writer.Write($buffer, 0, $read)
                    $written += $read
                }
            }
            finally { $writer.Dispose() }
            $parts += $partPath
            $index++
        }
    }
    finally { $reader.Dispose() }
    return $parts
}

function New-VerifiedZip {
    <#
      Zips the contents of SourceDirectory into ZipPath (no wrapping folder),
      then re-opens the archive and checks it against the directory listing.
    #>
    param([Parameter(Mandatory)][string]$SourceDirectory, [Parameter(Mandatory)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceDirectory, $ZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal, $false)

    $root = (Resolve-Path -LiteralPath $SourceDirectory).Path
    $expected = @(Get-ChildItem -LiteralPath $root -Recurse -File)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.Name })
        if ($entries.Count -ne $expected.Count) {
            throw "ZIP holds $($entries.Count) files but the package folder has $($expected.Count)."
        }
        $names = $entries | ForEach-Object { $_.FullName.Replace("\", "/") }
        if ($names -notcontains "ArmorPaint.exe") {
            throw "ZIP does not contain ArmorPaint.exe at its root."
        }
        $junk = @($names | Where-Object { $_ -match "\.(pdb|obj|ilk|exp|lib|log|temp|tmp)$" })
        if ($junk.Count -gt 0) {
            throw "ZIP contains intermediate files: $($junk -join ', ')"
        }
    }
    finally { $archive.Dispose() }

    return Get-Item -LiteralPath $ZipPath
}
