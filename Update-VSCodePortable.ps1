#requires -Version 5.1
<#
Windows VS Code Stable ZIP, x64/ARM64. See README.md.
No elevation, external modules, self-modification, or forced process termination.
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [switch]$CheckOnly,
    [switch]$Reinstall,
    [switch]$Rollback,
    [string[]]$Keep = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = $PSScriptRoot }
$script:StateName = '.vscode-portable-updater'
$script:KnownFiles = @('Code.exe','Code.VisualElementsManifest.xml','LICENSE.txt','LICENSES.chromium.html',
    'ThirdPartyNotices.txt','chrome_100_percent.pak','chrome_200_percent.pak','d3dcompiler_47.dll',
    'ffmpeg.dll','icudtl.dat','libEGL.dll','libGLESv2.dll','resources.pak','snapshot_blob.bin',
    'v8_context_snapshot.bin','vk_swiftshader.dll','vk_swiftshader_icd.json','vulkan-1.dll',
    'chrome_crashpad_handler.exe')

function Say([string]$Message) { Write-Host $Message }
function Read-Json([string]$File) { Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json }
function New-Dir([string]$Dir) { [IO.Directory]::CreateDirectory($Dir) | Out-Null }
function Has([string]$File) { Test-Path -LiteralPath $File }
function Is-Link([string]$File) { ((Get-Item -LiteralPath $File -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
function Assert-PlainPath([string]$File) {
    $part = [IO.Path]::GetFullPath($File)
    while ($part) {
        if ((Has $part) -and (Is-Link $part)) { throw "A symbolic link or junction was found in a managed path: $part" }
        $part = [IO.Path]::GetDirectoryName($part)
    }
}
function Assert-PlainTree([string]$Dir) {
    Assert-PlainPath $Dir
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $Dir -Force) {
        if (Is-Link $item.FullName) { throw "A symbolic link was found inside the application files: $($item.FullName)" }
        if ($item.PSIsContainer) { Assert-PlainTree $item.FullName }
    }
}
function Assert-Child([string]$Child, [string]$Parent) {
    $c = [IO.Path]::GetFullPath($Child)
    $p = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { throw "The path is outside the allowed working folder: $c" }
    Assert-PlainPath $c
}
function Remove-PrivateTree([string]$Dir, [string]$Parent) {
    Assert-Child $Dir $Parent
    if (Has $Dir) { Assert-PlainTree $Dir; Remove-Item -LiteralPath $Dir -Recurse -Force }
}
function Move-AppItem([string]$From, [string]$To) {
    Assert-PlainPath $From; Assert-PlainPath $To
    if (Has $To) { throw "The destination already exists: $To" }
    # Same-volume rename; no wildcard expansion and no overwrite.
    if (Test-Path -LiteralPath $From -PathType Container) { [IO.Directory]::Move($From, $To) }
    else { [IO.File]::Move($From, $To) }
}
function Write-Journal($Journal, [string]$Tx) {
    $file = Join-Path $Tx 'journal.json'
    $tmp = Join-Path $Tx 'journal.tmp'
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($tmp, 'Create', 'Write', 'None')
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if (Has $file) { [IO.File]::Replace($tmp,$file,(Join-Path $Tx 'journal.previous.json')) } else { [IO.File]::Move($tmp,$file) }
}
function Assert-Stopped([string]$Root) {
    $prefix = $Root.TrimEnd('\') + '\'
    foreach ($p in Get-Process) {
        $exe = ''
        try { $exe = [string]$p.Path } catch { }
        if (($exe -and $exe.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) -or
            (-not $exe -and $p.ProcessName -in @('Code','code-tunnel'))) {
            throw "Close VS Code and processes running from this folder, then try again (PID $($p.Id))."
        }
    }
}
function Get-Architecture([string]$Exe) {
    $stream = [IO.File]::OpenRead($Exe); $r = New-Object IO.BinaryReader($stream)
    try {
        if ($r.ReadUInt16() -ne 0x5A4D) { throw 'The executable is missing its MZ header.' }
        $stream.Position = 0x3C; $offset = $r.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'The executable has an invalid PE header.' }
        $stream.Position = $offset
        if ($r.ReadUInt32() -ne 0x4550) { throw 'The executable is missing its PE header.' }
        switch ($r.ReadUInt16()) { 0x8664 { return 'x64' }; 0xAA64 { return 'arm64' }; default { throw 'Only x64 and ARM64 are supported.' } }
    } finally { $r.Dispose() }
}
function Assert-Microsoft([string]$Exe) {
    $s = Get-AuthenticodeSignature -LiteralPath $Exe
    if ($s.Status -ne 'Valid' -or -not $s.SignerCertificate -or
        $s.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "A valid Microsoft signature is required: $Exe ($($s.Status))."
    }
}
function Get-Bundle([string]$Base, [string]$Tag = '') {
    $app = Join-Path $Base 'resources\app'
    if (-not (Has (Join-Path $app 'product.json')) -or -not (Has (Join-Path $app 'package.json'))) { return $null }
    Assert-PlainPath $app
    try { $p = Read-Json (Join-Path $app 'product.json'); $v = Read-Json (Join-Path $app 'package.json') } catch { return $null }
    foreach ($field in @('applicationName','nameShort','quality','commit')) { if (-not $p.PSObject.Properties[$field]) { return $null } }
    if (-not $v.PSObject.Properties['version']) { return $null }
    if ($p.applicationName -ne 'code' -or $p.nameShort -ne 'Code' -or $p.quality -ne 'stable' -or
        $p.commit -notmatch '^[a-f0-9]{40}$' -or $v.version -notmatch '^\d+\.\d+\.\d+$') { return $null }
    if ($p.PSObject.Properties['target'] -and $p.target -in @('user','system')) { throw 'An installer-based version was detected. Use the official portable ZIP distribution.' }
    if ($Tag -and $Tag -ne $p.commit.Substring(0,10)) { return $null }
    [pscustomobject]@{ Version=[string]$v.version; Commit=[string]$p.commit; Tag=$Tag; App=$app }
}
function Get-Installation([string]$Root) {
    $exe = Join-Path $Root 'Code.exe'; Assert-PlainPath $exe; Assert-Microsoft $exe
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if ($version -notmatch '^(\d+\.\d+\.\d+)(?:\s|$)') { throw 'Could not read the version of Code.exe.' }
    $version = $Matches[1]
    $bundles = @()
    $legacy = Get-Bundle $Root
    if ($legacy) { $bundles += $legacy }
    foreach ($d in Get-ChildItem -LiteralPath $Root -Directory -Force) {
        if ($d.Name -match '^[a-f0-9]{10}$' -and -not (Is-Link $d.FullName)) {
            $b = Get-Bundle $d.FullName $d.Name
            if ($b) { $bundles += $b }
        }
    }
    $candidates = @($bundles | Where-Object { $_.Version -eq $version })
    # The installed CLI identifies the active commit; never pick the first stale directory.
    $cmd = Join-Path $Root 'bin\code.cmd'
    if (Has $cmd) {
        Assert-PlainPath $cmd
        $text = Get-Content -LiteralPath $cmd -Raw
        $tags = @([regex]::Matches($text,'(?i)[\\/]([a-f0-9]{10})[\\/]') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($tags.Count -eq 1) { $candidates = @($candidates | Where-Object { $_.Tag -eq $tags[0] }) }
    }
    if ($candidates.Count -ne 1) { throw 'The active build is ambiguous or damaged. Automatic replacement was cancelled.' }
    $b = $candidates[0]
    [pscustomobject]@{ Version=$b.Version; Commit=$b.Commit; Tag=$b.Tag; App=$b.App; Architecture=(Get-Architecture $exe); Bundles=$bundles }
}
function Assert-Url([uri]$Uri) {
    $allowed = @('update.code.visualstudio.com','vscode.download.prss.microsoft.com')
    if ($Uri.Scheme -ne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Host -notin $allowed) {
        throw "The update source is not allowed: $Uri"
    }
}
function Get-Official([string]$Url, [string]$OutFile = '') {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(20)
    try {
        $uri = [uri]$Url
        for ($i=0; $i -le 5; $i++) {
            Assert-Url $uri
            $response = $client.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    if (-not $response.Headers.Location) { throw 'The server returned a redirect without a destination.' }
                    $uri = New-Object uri($uri,$response.Headers.Location); continue
                }
                if ($status -ne 200) { throw "HTTP $status while requesting $uri" }
                if ($OutFile) {
                    $length = $response.Content.Headers.ContentLength
                    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($OutFile)))
                    if ($null -ne $length -and $drive.AvailableFreeSpace -lt ([long]$length + 256MB)) { throw 'Not enough disk space to download the ZIP archive.' }
                    # A finite timeout applies to the complete body, not just response headers.
                    $cancel = New-Object Threading.CancellationTokenSource
                    $cancel.CancelAfter([TimeSpan]::FromMinutes(20))
                    $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $outputStream = [IO.File]::Open($OutFile,'CreateNew','Write','None')
                    try { [void]$inputStream.CopyToAsync($outputStream,81920,$cancel.Token).GetAwaiter().GetResult(); $outputStream.Flush($true) }
                    finally { $outputStream.Dispose(); $inputStream.Dispose(); $cancel.Dispose() }
                    return
                }
                return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            } finally { $response.Dispose() }
        }
        throw 'Too many redirects.'
    } finally { $client.Dispose(); $handler.Dispose() }
}
function Get-Release([string]$Architecture) {
    $m = (Get-Official "https://update.code.visualstudio.com/api/update/win32-$Architecture-archive/stable/latest") | ConvertFrom-Json
    if ($m.version -notmatch '^[a-f0-9]{40}$' -or $m.productVersion -notmatch '^\d+\.\d+\.\d+$' -or
        $m.sha256hash -notmatch '^[a-f0-9]{64}$') { throw 'The release metadata is incomplete or has an unexpected format.' }
    Assert-Url ([uri]$m.url)
    $expected = '/stable/' + $m.version + '/VSCode-win32-' + $Architecture + '-' + $m.productVersion + '.zip'
    if (-not ([uri]$m.url).AbsolutePath.EndsWith($expected,[StringComparison]::Ordinal)) { throw 'The download URL does not match the release version or architecture.' }
    return $m
}
function Assert-ArchiveHash([string]$Zip, [string]$Expected) {
    if ($Expected -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash -ne $Expected) { throw 'The archive SHA-256 does not match. The installation has not been changed.' }
}
function Expand-CheckedZip([string]$Zip, [string]$Dest) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Assert-PlainPath $Dest
    if (Has $Dest) { throw 'The extraction folder already exists.' }
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        if ($z.Entries.Count -lt 10 -or $z.Entries.Count -gt 100000) { throw 'The ZIP archive contains an unexpected number of entries.' }
        $seen = @{}; [long]$total = 0
        foreach ($e in $z.Entries) {
            $name = $e.FullName.Replace('/','\').TrimEnd('\')
            if (-not $name -or $name.StartsWith('\') -or $name.Contains(':')) { throw 'The ZIP archive contains an unsafe path.' }
            foreach ($segment in $name.Split('\')) {
                if ($segment -in @('','.','..') -or $segment -match '[<>"|?*\x00-\x1f]' -or $segment -match '[. ]$' -or
                    $segment -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw "The ZIP archive contains an unsafe entry: $name" }
            }
            if ($seen.ContainsKey($name)) { throw "The ZIP archive contains a duplicate path: $name" }; $seen[$name] = $true
            if ((($e.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($e.ExternalAttributes -band 0x400) -ne 0) { throw 'Symbolic links are not allowed in the ZIP archive.' }
            $resolved = [IO.Path]::GetFullPath((Join-Path $Dest $name))
            if (-not $resolved.StartsWith(($Dest.TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'A ZIP entry points outside the extraction folder.' }
            $total += $e.Length
        }
        if ($total -gt 4GB) { throw 'The extracted archive exceeds the 4 GB limit.' }
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Dest))
        if ($drive.AvailableFreeSpace -lt ($total + 256MB)) { throw 'Not enough disk space for extraction and recovery.' }
        New-Dir $Dest
        foreach ($e in $z.Entries) {
            $file = Join-Path $Dest ($e.FullName.Replace('/','\'))
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { New-Dir $file }
            else { New-Dir ([IO.Path]::GetDirectoryName($file)); [IO.Compression.ZipFileExtensions]::ExtractToFile($e,$file,$false) }
        }
    } finally { $z.Dispose() }
}
function Assert-NewBuild([string]$Root, $Release, [string]$Architecture) {
    $v = Get-Installation $Root
    if ($v.Version -ne $Release.productVersion -or $v.Commit -ne $Release.version -or $v.Architecture -ne $Architecture) { throw 'The extracted version, commit or architecture does not match the release metadata.' }
    if ($v.Bundles.Count -ne 1 -or -not (Has (Join-Path $v.App 'out\cli.js')) -or -not (Has (Join-Path $Root 'bin\code.cmd'))) { throw 'The ZIP archive is missing required application files.' }
    if ((Has (Join-Path $Root 'data')) -or (Has (Join-Path $Root $script:StateName))) { throw 'The ZIP archive contains a protected user-data or updater folder.' }
    return $v
}
function Invoke-Probe([string]$Root, $Build, [string]$Scratch) {
    # Node CLI only, isolated data path: no editor windows, extensions or user settings.
    $exe = Join-Path $Root 'Code.exe'
    if ($Build.Tag -and (Has (Join-Path $Root ($Build.Tag + '\Code.exe')))) { $exe = Join-Path $Root ($Build.Tag + '\Code.exe') }
    Assert-Microsoft $exe
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '"' + (Join-Path $Build.App 'out\cli.js') + '" --version'
    $info.WorkingDirectory = $Root; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $info.EnvironmentVariables['VSCODE_PORTABLE'] = $Scratch
    $p = New-Object Diagnostics.Process; $p.StartInfo = $info
    try {
        [void]$p.Start(); $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { $p.Kill(); $p.WaitForExit(); throw 'The command-line check timed out after 30 seconds.' }
        $lines = @($stdout.GetAwaiter().GetResult().Trim() -split '\r?\n')
        $err = $stderr.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0 -or $lines.Count -ne 3 -or $lines[0] -ne $Build.Version -or $lines[1] -ne $Build.Commit -or $lines[2] -ne $Build.Architecture) { throw "The command-line check failed: $err" }
    } finally { $p.Dispose() }
}
function Get-ManagedNames([string]$Root, $Installed) {
    $names = @()
    foreach ($name in $script:KnownFiles) { if (Has (Join-Path $Root $name)) { $names += $name } }
    if (Has (Join-Path $Root 'bin\code.cmd')) { $names += 'bin' }
    # Recognize shared vendor directories by their actual contents, not their name alone.
    if (Has (Join-Path $Root 'tools\inno_updater.exe')) { Assert-Microsoft (Join-Path $Root 'tools\inno_updater.exe'); $names += 'tools' }
    $shellDll = Join-Path $Root ('appx\code_explorer_command_' + $Installed.Architecture + '.dll')
    if (Has $shellDll) { Assert-Microsoft $shellDll; $names += 'appx' }
    if (Has (Join-Path $Root 'policies\VSCode.admx')) {
        $policy = Get-Content -LiteralPath (Join-Path $Root 'policies\VSCode.admx') -Raw
        if ($policy -match 'Microsoft.Policies.VSCode') { $names += 'policies' }
    }
    foreach ($b in $Installed.Bundles) {
        if ($b.Tag) { $names += $b.Tag }
        else {
            $names += 'resources'
            if (Has (Join-Path $Root 'locales')) { $names += 'locales' }
        }
    }
    return @($names | Select-Object -Unique)
}
function Assert-Plan([string]$Root, [string]$New, [string[]]$OldNames, [string[]]$KeepNames) {
    $newNames = @(Get-ChildItem -LiteralPath $New -Force | ForEach-Object Name)
    foreach ($name in @($OldNames) + $newNames) {
        if ($name -in (@('data',$script:StateName,'Update-VSCodePortable.ps1','Update.cmd','Rollback.cmd') + $KeepNames)) { throw "A protected name conflicts with an application entry: $name" }
    }
    foreach ($name in $newNames) {
        if ((Has (Join-Path $Root $name)) -and $name -notin $OldNames) { throw "The new release conflicts with an existing user item '$name'. Move that item manually before updating." }
    }
    foreach ($name in $OldNames) { Assert-PlainTree (Join-Path $Root $name) }
    Assert-PlainTree $New
    return $newNames
}
function Assert-Journal($J, [string]$Root, [string]$Tx) {
    Assert-Child $Tx (Join-Path $Root $script:StateName)
    # Root is provenance only: Portable folders can move between drive letters.
    # Every operation uses the current validated Root and relative entry names.
    if ($J.Schema -ne 1 -or -not $J.Root -or $J.Status -notin @('Applying','Committed','RollingBack','RolledBack')) { throw "The recovery journal is invalid: $Tx" }
    foreach ($n in @($J.OldNames) + @($J.NewNames)) {
        if ($n -notmatch '^[a-zA-Z0-9_.-]+$' -or $n -in @('.','..','data',$script:StateName,'Update-VSCodePortable.ps1','Update.cmd','Rollback.cmd')) { throw 'The recovery journal contains an invalid path.' }
    }
}
function Undo-Transaction([string]$Root, [string]$Tx) {
    $j = Read-Json (Join-Path $Tx 'journal.json'); Assert-Journal $j $Root $Tx
    Assert-Stopped $Root
    $j.Status = 'RollingBack'
    try { Write-Journal $j $Tx } catch { Say 'Could not save the rollback status. Recovering from the existing journal.' }
    foreach ($name in @($j.NewNames)) {
        $staged = Join-Path $Tx ('new\' + $name); $live = Join-Path $Root $name
        # Presence in staging proves that this new entry has not been installed (or was already undone).
        if (-not (Has $staged) -and (Has $live)) { Move-AppItem $live $staged }
    }
    foreach ($name in @($j.OldNames)) {
        $backup = Join-Path $Tx ('old\' + $name)
        if (Has $backup) { Move-AppItem $backup (Join-Path $Root $name) }
    }
    $j.Status = 'RolledBack'; Write-Journal $j $Tx
    Say "The previous application files have been restored. Operation files: $Tx"
}
function Apply-Transaction([string]$Root, [string]$Tx, [string[]]$OldNames, [string[]]$NewNames, $Release, [string]$Architecture) {
    $j = [pscustomobject]@{ Schema=1; Root=$Root; Status='Applying'; OldNames=@($OldNames); NewNames=@($NewNames); Version=$Release.productVersion; Commit=$Release.version }
    New-Dir (Join-Path $Tx 'old'); Write-Journal $j $Tx
    # Verify atomic journal replacement on this filesystem before any live file moves.
    Write-Journal $j $Tx
    try {
        Assert-Stopped $Root
        foreach ($name in $OldNames) { Move-AppItem (Join-Path $Root $name) (Join-Path $Tx ('old\' + $name)) }
        foreach ($name in $NewNames) { Move-AppItem (Join-Path $Tx ('new\' + $name)) (Join-Path $Root $name) }
        $build = Get-Installation $Root
        if ($build.Commit -ne $Release.version -or $build.Version -ne $Release.productVersion -or $build.Architecture -ne $Architecture) { throw 'The installed version check failed.' }
        Invoke-Probe $Root $build (Join-Path $Tx 'probe')
        $j.Status = 'Committed'; Write-Journal $j $Tx
    } catch {
        $original = $_.Exception.Message
        try { Undo-Transaction $Root $Tx } catch { throw "Error: $original`nRollback could not finish: $($_.Exception.Message)`nClose VS Code and run Update.cmd again. Do not delete $Tx" }
        throw "The update was cancelled and the previous files were restored. Reason: $original"
    }
}
function Invoke-Updater {
    if ($CheckOnly -and $Rollback) { throw 'CheckOnly and Rollback cannot be used together.' }
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    if ($root -notmatch '^[a-zA-Z]:\\' -or $root.Length -le 3) { throw 'Choose a folder on a local drive. Drive roots and UNC paths are not supported.' }
    Assert-PlainPath $root
    if (-not (Test-Path -LiteralPath (Join-Path $root 'data') -PathType Container)) { throw 'No data folder was found next to Code.exe. This updater requires an existing portable installation.' }
    foreach ($n in $Keep) { if ($n -notmatch '^[^\\/:]+$' -or $n -in @('.','..')) { throw 'Keep accepts only file or folder names in the installation root.' } }
    $state = Join-Path $root $script:StateName; Assert-PlainPath $state
    $lock = $null; $tx = $null
    try {
        if (-not $CheckOnly) {
            New-Dir $state
            $lock = [IO.File]::Open((Join-Path $state 'update.lock'),'OpenOrCreate','ReadWrite','None')
        }
        $history = @()
        if (Has $state) {
            foreach ($dir in Get-ChildItem -LiteralPath $state -Directory -Force | Sort-Object Name) {
                if ($dir.Name -match '^tx-[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$' -and (Has (Join-Path $dir.FullName 'journal.json'))) {
                    $j = Read-Json (Join-Path $dir.FullName 'journal.json'); Assert-Journal $j $root $dir.FullName
                    $history += [pscustomobject]@{ Dir=$dir.FullName; Journal=$j }
                }
            }
        }
        $pending = @($history | Where-Object { $_.Journal.Status -in @('Applying','RollingBack') })
        if ($pending.Count -gt 1) { throw 'Multiple unfinished operations were found. Inspect the backups before continuing.' }
        if ($pending.Count -eq 1) {
            if ($CheckOnly) { throw 'An unfinished operation was found. Run Update.cmd to recover the previous installation.' }
            Undo-Transaction $root $pending[0].Dir
            Say 'Recovery is complete. Run Update.cmd again to start a new update.'; return
        }
        if ($Rollback) {
            # Only the latest transaction may be undone: never restore an unrelated older backup.
            if (-not $history.Count -or $history[-1].Journal.Status -ne 'Committed') { throw 'There is no latest successful update available to roll back.' }
            $current = Get-Installation $root
            if ($current.Commit -ne $history[-1].Journal.Commit) { throw 'The installed build has changed since the update. Automatic rollback was cancelled.' }
            Undo-Transaction $root $history[-1].Dir; return
        }
        $installed = Get-Installation $root
        Say "Installed: $($installed.Version), $($installed.Architecture), commit $($installed.Commit)"
        $release = Get-Release $installed.Architecture
        Say "Latest official Stable: $($release.productVersion), commit $($release.version)"
        if ([version]$release.productVersion -lt [version]$installed.Version) { throw 'The server returned an older version. Automatic downgrades are not allowed.' }
        if ($CheckOnly) { return }
        $oldNames = @(Get-ManagedNames $root $installed)
        $stale = @($installed.Bundles | Where-Object { $_.Commit -ne $installed.Commit })
        if ($installed.Commit -eq $release.version -and -not $Reinstall -and -not $stale.Count) { Say 'The installed version is already up to date.'; return }
        Assert-Stopped $root
        $tx = Join-Path $state ('tx-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Dir $tx
        $zip = Join-Path $tx 'download.zip'; $new = Join-Path $tx 'new'
        Say 'Downloading the official ZIP archive...'
        Get-Official $release.url $zip
        Assert-ArchiveHash $zip $release.sha256hash
        Say 'SHA-256 verified. Extracting and checking the signature, version, architecture and command-line startup...'
        Expand-CheckedZip $zip $new
        $build = Assert-NewBuild $new $release $installed.Architecture
        Invoke-Probe $new $build (Join-Path $tx 'probe')
        $newNames = @(Assert-Plan $root $new $oldNames $Keep)
        Say ('Application entries to replace: ' + ($oldNames -join ', '))
        Say 'The data folder and other user items will stay in place.'
        Apply-Transaction $root $tx $oldNames $newNames $release $installed.Architecture
        # Only disposable artifacts of this transaction are removed automatically.
        try {
            Remove-Item -LiteralPath $zip -Force
            Remove-PrivateTree (Join-Path $tx 'probe') $tx
        } catch { Say "The update succeeded. Some temporary files remain in $tx" }
        Say "Done: VS Code $($release.productVersion). Backup: $tx\old"
        Say 'Run Rollback.cmd to restore the previous application files. Backups are not deleted automatically.'
    } catch {
        if ($tx -and -not (Has (Join-Path $tx 'journal.json'))) {
            try { Remove-PrivateTree $tx $state } catch { Say "The temporary folder was kept for inspection: $tx" }
        }
        throw
    } finally { if ($lock) { $lock.Dispose() } }
}
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Updater; exit 0 }
    catch { Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red; exit 1 }
}
