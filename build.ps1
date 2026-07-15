<#
.SYNOPSIS
    Builds the Toggle Turn-Based In Combat sidecar and installs it into the game's Managed folder.

.DESCRIPTION
    Compiles src/*.cs into LoomToggleTurnBasedInCombat.dll and copies it to
    <GameDir>/PillarsOfEternity_Data/Managed/. After a first install, run patch-hook.ps1
    once to wire Bootstrap.Tick() into GameState.Update(). Game must be closed for the patch.

.PARAMETER GameDir
    Path to the Pillars of Eternity install directory (contains PillarsOfEternity_Data).

.PARAMETER Csc
    Optional path to the Roslyn C# compiler (csc.exe). Probed if omitted.

.EXAMPLE
    ./build.ps1 -GameDir "E:\SteamLibrary\steamapps\common\Pillars of Eternity"
#>
[CmdletBinding()]
param(
    [string]$GameDir = "E:\SteamLibrary\steamapps\common\Pillars of Eternity",
    [string]$Csc
)

$ErrorActionPreference = 'Stop'

$managed = Join-Path $GameDir 'PillarsOfEternity_Data\Managed'
if (-not (Test-Path $managed)) {
    throw "Managed folder not found: $managed  (is -GameDir correct?)"
}

if (-not $Csc) {
    $candidates = @(
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\Roslyn\csc.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\Roslyn\csc.exe'
    )
    $Csc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Csc) {
        $cmd = Get-Command csc.exe -ErrorAction SilentlyContinue
        if ($cmd) { $Csc = $cmd.Source }
    }
}
if (-not $Csc -or -not (Test-Path $Csc)) {
    throw "Could not locate csc.exe. Pass it explicitly with -Csc."
}

$srcDir = Join-Path $PSScriptRoot 'src'
$src    = Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' | Sort-Object Name
if (-not $src) {
    throw "No C# source files found in $srcDir."
}

$outDll = Join-Path $managed 'LoomToggleTurnBasedInCombat.dll'

Write-Host "Compiler : $Csc"
Write-Host "Output   : $outDll"

$refs = @(
    'Assembly-CSharp.dll',
    'Assembly-CSharp-firstpass.dll',
    'UnityEngine.dll',
    'UnityEngine.CoreModule.dll',
    'UnityEngine.IMGUIModule.dll',
    'UnityEngine.InputLegacyModule.dll',
    'UnityEngine.TextRenderingModule.dll',
    'UnityEngine.PhysicsModule.dll'
) | ForEach-Object { "/reference:$(Join-Path $managed $_)" }

$argList = @('/nologo', '/target:library', "/out:$outDll") + $refs + ($src | ForEach-Object { $_.FullName })
& $Csc @argList
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed ($LASTEXITCODE)."
}

Write-Host "`nBuilt LoomToggleTurnBasedInCombat.dll." -ForegroundColor Green
Write-Host "First install? Run: ./patch-hook.ps1 -GameDir `"$GameDir`"  (game closed)" -ForegroundColor Yellow
Write-Host "Then restart the game to load the new build." -ForegroundColor Yellow
