# Injects LoomToggleTurnBasedInCombat.Bootstrap.Tick() at the top of GameState.Update() in Assembly-CSharp.dll.
# Idempotent: skips if the LoomToggleTurnBasedInCombat assembly reference is already present.
# Coexists with other Loom mods that hook GameState.Update (each checks its own reference).
# Usage: ./patch-hook.ps1 [-GameDir "<install folder>"]   (game must be closed)
[CmdletBinding()]
param(
    [string]$GameDir = "E:\SteamLibrary\steamapps\common\Pillars of Eternity",
    [string]$Cecil
)

$ErrorActionPreference = 'Stop'

$managed = Join-Path $GameDir 'PillarsOfEternity_Data\Managed'
$asmPath = Join-Path $managed 'Assembly-CSharp.dll'
$sidecar = Join-Path $managed 'LoomToggleTurnBasedInCombat.dll'

# Mono.Cecil: prefer a copy next to this script (drop one here), else search the ilspycmd
# dotnet-tool store under the current user profile. (End users don't run this - the release
# installer bundles Mono.Cecil.dll. This is the developer hook injector.)
if ($Cecil) {
    $cecil = $Cecil
} else {
    $cecil = Join-Path $PSScriptRoot 'Mono.Cecil.dll'
    if (-not (Test-Path $cecil)) {
        $cecil = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.dotnet\tools\.store\ilspycmd') `
            -Recurse -Filter 'Mono.Cecil.dll' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $cecil -or -not (Test-Path $cecil)) {
    throw "Mono.Cecil.dll not found. Drop one next to this script or pass -Cecil <path>."
}

foreach ($p in @($asmPath, $sidecar)) {
    if (-not (Test-Path $p)) { throw "Required file not found: $p" }
}

$proc = Get-Process -Name 'PillarsOfEternity*' -ErrorAction SilentlyContinue
if ($proc) { throw "Pillars of Eternity is running (pid $($proc.Id)). Close it and re-run." }

Add-Type -Path $cecil

$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($managed)

$rp = New-Object Mono.Cecil.ReaderParameters
$rp.ReadWrite = $false
$rp.InMemory  = $true
$rp.AssemblyResolver = $resolver

$module = [Mono.Cecil.ModuleDefinition]::ReadModule($asmPath, $rp)
try {
    if ($module.AssemblyReferences | Where-Object { $_.Name -eq 'LoomToggleTurnBasedInCombat' }) {
        Write-Host "Already patched (LoomToggleTurnBasedInCombat reference present). Nothing to do." -ForegroundColor Yellow
        return
    }

    $gameState = $module.Types | Where-Object { $_.Name -eq 'GameState' } | Select-Object -First 1
    if (-not $gameState) { throw "Could not find type GameState." }

    $update = $gameState.Methods | Where-Object {
        $_.Name -eq 'Update' -and -not $_.IsStatic -and -not $_.HasParameters -and $_.HasBody
    } | Select-Object -First 1
    if (-not $update) { throw "Could not find GameState.Update()." }

    $sc        = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($sidecar)
    $bootstrap = $sc.MainModule.Types | Where-Object { $_.FullName -eq 'LoomToggleTurnBasedInCombat.Bootstrap' } | Select-Object -First 1
    if (-not $bootstrap) { throw "LoomToggleTurnBasedInCombat.Bootstrap not found in sidecar." }
    $tick = $bootstrap.Methods | Where-Object { $_.Name -eq 'Tick' -and $_.IsStatic -and -not $_.HasParameters } | Select-Object -First 1
    if (-not $tick) { throw "Bootstrap.Tick() not found in sidecar." }

    $importedTick = $module.ImportReference($tick)
    $il    = $update.Body.GetILProcessor()
    $first = $update.Body.Instructions[0]
    $call  = $il.Create([Mono.Cecil.Cil.OpCodes]::Call, $importedTick)
    $il.InsertBefore($first, $call)

    $anr = New-Object Mono.Cecil.AssemblyNameReference('LoomToggleTurnBasedInCombat', $sc.Name.Version)
    $module.AssemblyReferences.Add($anr)

    $backup = "$asmPath.toggleturnbased-backup"
    if (-not (Test-Path $backup)) { Copy-Item -LiteralPath $asmPath -Destination $backup -Force }

    $tmp = "$asmPath.toggleturnbased-patched"
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $module.Write($tmp)
    $module.Dispose()

    Copy-Item -LiteralPath $tmp -Destination $asmPath -Force
    Remove-Item -LiteralPath $tmp -Force
    Write-Host "Patched GameState.Update -> LoomToggleTurnBasedInCombat.Bootstrap.Tick()" -ForegroundColor Green
    Write-Host "Backup saved: $backup" -ForegroundColor DarkGray
}
finally {
    if ($module) { $module.Dispose() }
}
