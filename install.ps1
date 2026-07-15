<#
.SYNOPSIS
    Installs (or uninstalls) Toggle Turn-Based In Combat for Pillars of Eternity 1.

.DESCRIPTION
    Toggle Turn-Based In Combat lets you switch between real-time-with-pause and turn-based
    ("Tactical") combat at runtime from a keybind - including mid-combat, both directions.

    Install:
      1. copies the sidecar (LoomToggleTurnBasedInCombat.dll) into the game's Managed folder,
      2. backs up Assembly-CSharp.dll (once), and
      3. injects one call to LoomToggleTurnBasedInCombat.Bootstrap.Tick() at the top of
         GameState.Update() with the bundled Mono.Cecil.dll.

    Needs only Windows PowerShell (5.1+, built into Windows) - no .NET SDK, no C# compiler. Run it
    from the extracted release folder (the one that also contains LoomToggleTurnBasedInCombat.dll
    and Mono.Cecil.dll). Close the game first.

.PARAMETER GameDir
    Path to the Pillars of Eternity install folder (contains PillarsOfEternity_Data). Auto-detected
    if omitted; you are prompted if it can't be found.

.PARAMETER Uninstall
    Cleanly remove the mod: surgically strips only its hook call + assembly reference (so other mods
    that hook the same method are left intact) and deletes LoomToggleTurnBasedInCombat.dll.

.EXAMPLE
    ./install.ps1

.EXAMPLE
    ./install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [switch]$Uninstall,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$ModName       = 'Toggle Turn-Based In Combat'
$Sidecar       = 'LoomToggleTurnBasedInCombat'      # assembly name (no extension)
$SidecarDll    = "$Sidecar.dll"
$BootstrapType = "$Sidecar.Bootstrap"
$BackupSuffix  = '.toggleturnbased-backup'

# ---------------------------------------------------------------------------
# Probing that CANNOT throw.
#
# $ErrorActionPreference = 'Stop' promotes a non-terminating error to a fatal one, and
# Test-Path against a drive letter this machine does not have ("D:\...") raises
# "Cannot find drive". Probing a fixed list of guesses would therefore kill the installer
# outright on any PC without that drive - before it could ever offer the friendly prompt.
# Every probe funnels through Test-PathSafe, which swallows that and returns $false.
# ---------------------------------------------------------------------------
function Test-PathSafe([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    try { return [bool](Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) }
    catch { return $false }
}

function Join-PathSafe([string]$parent, [string]$child) {
    if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
    try { return [System.IO.Path]::Combine($parent, $child) } catch { return $null }
}

# Accepts what a human actually pastes: surrounding quotes (straight or smart), stray
# whitespace, %VARS%. Spaces and parentheses need no special handling - the string arrives
# intact and every downstream call uses -LiteralPath, so "C:\Program Files (x86)\..." is
# just a normal path.
function Normalize-PathInput([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    $p = $path.Trim()
    while ($p.Length -ge 2 -and (($p.StartsWith('"') -and $p.EndsWith('"')) -or ($p.StartsWith("'") -and $p.EndsWith("'")))) {
        $p = $p.Substring(1, $p.Length - 2).Trim()
    }
    $p = $p.Trim([char]0x2018, [char]0x2019, [char]0x201C, [char]0x201D).Trim()
    try { $p = [Environment]::ExpandEnvironmentVariables($p) } catch { }
    return $p
}

# Only drives that actually exist and are ready, so a machine with no D: never probes D:.
function Get-ReadyDriveRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if ($d.IsReady -and $d.DriveType -ne [System.IO.DriveType]::CDRom) {
                    $roots.Add($d.RootDirectory.FullName)
                }
            } catch { }
        }
    } catch { }
    if ($roots.Count -eq 0) { $roots.Add('C:\') }
    return $roots.ToArray()
}

function Get-SteamRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($regPath in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
            foreach ($name in @('SteamPath','InstallPath')) {
                $value = Normalize-PathInput $props.$name
                if (Test-PathSafe $value) { $roots.Add($value) }
            }
        } catch { }
    }
    # Steam library folders - games often live off the Steam root, on another drive.
    foreach ($root in @($roots.ToArray())) {
        foreach ($rel in @('steamapps\libraryfolders.vdf','config\libraryfolders.vdf')) {
            $vdf = Join-PathSafe $root $rel
            if (-not (Test-PathSafe $vdf)) { continue }
            try {
                foreach ($line in (Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue)) {
                    if ($line -match '"path"\s+"([^"]+)"') {
                        $library = ($Matches[1] -replace '\\\\', '\')
                        if (Test-PathSafe $library) { $roots.Add($library) }
                    }
                }
            } catch { }
        }
    }
    return @($roots.ToArray() | Where-Object { $_ } | Select-Object -Unique)
}

function Get-CandidateGameDirs {
    $guesses = New-Object System.Collections.Generic.List[string]
    foreach ($root in Get-SteamRoots) {
        $guesses.Add((Join-PathSafe $root 'steamapps\common\Pillars of Eternity'))
    }
    # Common layouts, probed only on drives this machine actually has.
    $layouts = @(
        'SteamLibrary\steamapps\common\Pillars of Eternity',
        'Steam\steamapps\common\Pillars of Eternity',
        'Games\Steam\steamapps\common\Pillars of Eternity',
        'Program Files (x86)\Steam\steamapps\common\Pillars of Eternity',
        'Program Files\Steam\steamapps\common\Pillars of Eternity',
        'GOG Games\Pillars of Eternity',
        'GOG Galaxy\Games\Pillars of Eternity',
        'Program Files (x86)\GOG Galaxy\Games\Pillars of Eternity',
        'Epic Games\Pillars of Eternity',
        'Games\Pillars of Eternity',
        'Pillars of Eternity'
    )
    foreach ($drive in Get-ReadyDriveRoots) {
        foreach ($layout in $layouts) { $guesses.Add((Join-PathSafe $drive $layout)) }
    }
    return @($guesses.ToArray() | Where-Object { $_ } | Select-Object -Unique)
}

function Test-GameDir([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    return (Test-PathSafe (Join-PathSafe $dir 'PillarsOfEternity_Data\Managed\Assembly-CSharp.dll'))
}

function Find-GameDir {
    foreach ($g in Get-CandidateGameDirs) { if (Test-GameDir $g) { return $g } }
    return $null
}

# Forgiving about what gets handed over: the game folder, the .exe, the Managed folder, or a
# file inside it - walk up until the game layout is found.
function Resolve-GameDir([string]$dir) {
    $try = Normalize-PathInput $dir
    if ([string]::IsNullOrWhiteSpace($try)) { return $null }
    try {
        $leaf = Split-Path -Leaf $try
        if ($leaf -ieq 'Assembly-CSharp.dll' -or $leaf -ieq 'PillarsOfEternity.exe') { $try = Split-Path -Parent $try }
        if (Test-PathSafe $try) {
            $item = Get-Item -LiteralPath $try -ErrorAction SilentlyContinue
            if ($item) { $try = $item.FullName }
        } else {
            $try = [System.IO.Path]::GetFullPath($try)
        }
    } catch { return $dir }
    $guard = 0
    while ($try -and -not (Test-GameDir $try) -and $guard -lt 16) {
        $guard++
        $parent = $null
        try { $parent = Split-Path $try -Parent } catch { break }
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $try) { break }
        $try = $parent
    }
    if (Test-GameDir $try) { return $try }
    return $dir
}

# A path pasted without quotes arrives split across argv on every space; stitch it back together.
if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
    $GameDir = (@($GameDir) + $RemainingArgs | Where-Object { $_ }) -join ' '
}
if ($GameDir) { $GameDir = Resolve-GameDir $GameDir }
if (-not (Test-GameDir $GameDir)) {
    $auto = Find-GameDir
    if (Test-GameDir $auto) { $GameDir = $auto }
}
if (-not (Test-GameDir $GameDir)) {
    Write-Host ""
    Write-Host "Could not find your Pillars of Eternity installation automatically." -ForegroundColor Yellow
    Write-Host "Paste the folder that contains 'PillarsOfEternity.exe' or 'PillarsOfEternity_Data'." -ForegroundColor DarkGray
    Write-Host "Quotes are optional; paths with spaces and parentheses are fine." -ForegroundColor DarkGray
    Write-Host "Example: C:\Program Files (x86)\Steam\steamapps\common\Pillars of Eternity" -ForegroundColor DarkGray
    Write-Host ""
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $entry = Read-Host "Pillars of Eternity install path (blank to cancel)"
        if ([string]::IsNullOrWhiteSpace($entry)) { throw "Cancelled - nothing was changed." }
        $candidate = Resolve-GameDir $entry
        if (Test-GameDir $candidate) { $GameDir = $candidate; break }
        Write-Host "That folder does not contain PillarsOfEternity_Data\Managed\Assembly-CSharp.dll." -ForegroundColor Yellow
        Write-Host "Give the main game folder - the one with PillarsOfEternity.exe in it." -ForegroundColor DarkGray
    }
    if (-not (Test-GameDir $GameDir)) { throw "Could not locate the game. Nothing was changed." }
}
Write-Host "Game folder: $GameDir" -ForegroundColor DarkGray

$managed   = Join-Path $GameDir 'PillarsOfEternity_Data\Managed'
$asmPath   = Join-Path $managed 'Assembly-CSharp.dll'
$cecilPath = Join-Path $here 'Mono.Cecil.dll'
if (-not (Test-PathSafe $cecilPath)) { throw "Required file not found: $cecilPath (run this from the extracted release folder)." }

$proc = Get-Process -Name 'PillarsOfEternity*' -ErrorAction SilentlyContinue
if ($proc) { throw "Pillars of Eternity is running (pid $($proc.Id)). Close it and re-run." }

Add-Type -Path $cecilPath
$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($managed)
$rp = New-Object Mono.Cecil.ReaderParameters
$rp.ReadWrite = $false; $rp.InMemory = $true; $rp.AssemblyResolver = $resolver

if ($Uninstall) {
    $module = [Mono.Cecil.ModuleDefinition]::ReadModule($asmPath, $rp)
    try {
        if (-not ($module.AssemblyReferences | Where-Object { $_.Name -eq $Sidecar })) {
            Write-Host "$ModName is not installed (no hook present). Nothing to do." -ForegroundColor Yellow
            return
        }
        $gs = $module.Types | Where-Object { $_.Name -eq 'GameState' } | Select-Object -First 1
        $update = $gs.Methods | Where-Object { $_.Name -eq 'Update' -and -not $_.IsStatic -and -not $_.HasParameters -and $_.HasBody } | Select-Object -First 1
        $il = $update.Body.GetILProcessor()
        $remove = @()
        foreach ($ins in $update.Body.Instructions) {
            if ($ins.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Call -and $ins.Operand -is [Mono.Cecil.MethodReference]) {
                $mr = [Mono.Cecil.MethodReference]$ins.Operand
                if ($mr.DeclaringType -and $mr.DeclaringType.FullName -eq $BootstrapType -and $mr.Name -eq 'Tick') { $remove += $ins }
            }
        }
        foreach ($ins in $remove) { $il.Remove($ins) }
        # Remove ALL matching references (a re-patched assembly can carry more than one).
        # Loop by index + RemoveAt: Mono.Cecil Collection.Remove($item) silently no-ops under PowerShell.
        for ($i = $module.AssemblyReferences.Count - 1; $i -ge 0; $i--) {
            if ($module.AssemblyReferences[$i].Name -eq $Sidecar) { $module.AssemblyReferences.RemoveAt($i) }
        }
        $tmp = "$asmPath.toggleturnbased-tmp"; if (Test-PathSafe $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $module.Write($tmp); $module.Dispose()
        Copy-Item -LiteralPath $tmp -Destination $asmPath -Force; Remove-Item -LiteralPath $tmp -Force
        Remove-Item -LiteralPath (Join-Path $managed $SidecarDll) -Force -ErrorAction SilentlyContinue
        Write-Host "`n$ModName uninstalled (hook removed, other mods untouched)." -ForegroundColor Cyan
    } finally { if ($module) { $module.Dispose() } }
    return
}

# ---- INSTALL ----
$sidecarSrc = Join-Path $here $SidecarDll
foreach ($p in @($asmPath, $sidecarSrc)) { if (-not (Test-PathSafe $p)) { throw "Required file not found: $p" } }

# 1. sidecar
Copy-Item -LiteralPath $sidecarSrc -Destination (Join-Path $managed $SidecarDll) -Force
Write-Host "Installed $SidecarDll" -ForegroundColor Green

# 2. backup once
$backup = "$asmPath$BackupSuffix"
if (-not (Test-PathSafe $backup)) {
    Copy-Item -LiteralPath $asmPath -Destination $backup -Force
    Write-Host "Backed up Assembly-CSharp.dll -> $backup" -ForegroundColor Green
} else {
    Write-Host "Backup already exists: $backup" -ForegroundColor DarkGray
}

# 3. inject hook
$module = [Mono.Cecil.ModuleDefinition]::ReadModule($asmPath, $rp)
try {
    if ($module.AssemblyReferences | Where-Object { $_.Name -eq $Sidecar }) {
        Write-Host "Already patched (hook present). DLL refreshed; nothing else to do." -ForegroundColor Yellow
        return
    }
    $gameState = $module.Types | Where-Object { $_.Name -eq 'GameState' } | Select-Object -First 1
    if (-not $gameState) { throw "Could not find type GameState." }
    $update = $gameState.Methods | Where-Object { $_.Name -eq 'Update' -and -not $_.IsStatic -and -not $_.HasParameters -and $_.HasBody } | Select-Object -First 1
    if (-not $update) { throw "Could not find GameState.Update()." }
    $sidecar   = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($sidecarSrc)
    $bootstrap = $sidecar.MainModule.Types | Where-Object { $_.FullName -eq $BootstrapType } | Select-Object -First 1
    if (-not $bootstrap) { throw "Bootstrap type not found in sidecar." }
    $tick = $bootstrap.Methods | Where-Object { $_.Name -eq 'Tick' -and $_.IsStatic -and -not $_.HasParameters } | Select-Object -First 1
    if (-not $tick) { throw "Bootstrap.Tick() not found in sidecar." }
    $importedTick = $module.ImportReference($tick)
    $il = $update.Body.GetILProcessor()
    $il.InsertBefore($update.Body.Instructions[0], $il.Create([Mono.Cecil.Cil.OpCodes]::Call, $importedTick))
    $module.AssemblyReferences.Add((New-Object Mono.Cecil.AssemblyNameReference($Sidecar, $sidecar.Name.Version)))
    $tmp = "$asmPath.toggleturnbased-patched"; if (Test-PathSafe $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $module.Write($tmp); $module.Dispose()
    Copy-Item -LiteralPath $tmp -Destination $asmPath -Force; Remove-Item -LiteralPath $tmp -Force
    Write-Host "Patched GameState.Update -> $BootstrapType.Tick()." -ForegroundColor Green
} finally { if ($module) { $module.Dispose() } }

Write-Host "`n$ModName installed. Launch the game and press T (in or out of combat) to switch" -ForegroundColor Cyan
Write-Host "between real-time and turn-based. Rebind it in Options -> Controls (camera/turn group," -ForegroundColor Cyan
Write-Host "near Pass Turn / Wait Turn) like any other control." -ForegroundColor Cyan
Write-Host "To uninstall: run  install.ps1 -Uninstall  (or the uninstall.bat)." -ForegroundColor DarkGray
