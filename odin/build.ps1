<#
.SYNOPSIS
  Build, verify, benchmark, and diagnose the Vasperty Odin subsystem.

.PARAMETER Action
  One of: check, test, build, bench, doctor, all (default: all)
#>
param(
    [ValidateSet("check", "test", "build", "bench", "doctor", "all")]
    [string]$Action = "all"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OdinRoot = $PSScriptRoot
$RepoRoot = Split-Path -Parent $OdinRoot
$BuildDir = Join-Path $OdinRoot "build"

function Resolve-OdinExe {
    $cmd = Get-Command odin.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command odin -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }

    $wingetDir = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $wingetDir) {
        $found = Get-ChildItem -Path $wingetDir -Filter "odin.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    throw "odin compiler executable not found in PATH or WinGet packages."
}

function Resolve-ClangExe {
    $cmd = Get-Command clang.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command clang -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }

    $wingetDir = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $wingetDir) {
        $found = Get-ChildItem -Path $wingetDir -Filter "clang.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    throw "clang.exe (llvm-mingw UCRT) not found for native linking without Windows SDK."
}

function Test-HasWindowsSdk {
    if ($env:WindowsSdkDir -and (Test-Path $env:WindowsSdkDir)) {
        return $true
    }
    $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Lib"
    if (Test-Path $kits) {
        $k32 = Get-ChildItem -Path $kits -Filter "kernel32.lib" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($k32) { return $true }
    }
    return $false
}

function Ensure-CrtShim([string]$Dir) {
    $shim = Join-Path $Dir "mingw_crt_shim.c"
    $code = @'
int _fltused = 0;
extern void ___chkstk_ms(void);
__asm__(".globl __chkstk\n__chkstk: jmp ___chkstk_ms\n");
'@
    Set-Content -Path $shim -Value $code -Encoding Ascii -NoNewline
    return $shim
}

$Odin = Resolve-OdinExe
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$Collection = "-collection:vasperty=$OdinRoot"
$HasSdk = Test-HasWindowsSdk

function Invoke-OdinCheck([string]$PkgDir, [string]$Label, [switch]$NoEntry) {
    Write-Host "[check] $Label"
    $flags = @($PkgDir, $Collection, "-vet")
    if ($NoEntry) { $flags += "-no-entry-point" }
    & $Odin check @flags
    if ($LASTEXITCODE -ne 0) {
        throw "odin check failed for $Label (exit $LASTEXITCODE)"
    }
}

function Build-OdinBinary([string]$PkgDir, [string]$OutName, [switch]$Opt) {
    $exePath = Join-Path $BuildDir "$OutName.exe"
    $optFlag = if ($Opt) { "-o:speed" } else { "-o:minimal" }

    if ($HasSdk) {
        Write-Host "[build:msvc-sdk] $OutName.exe ($optFlag)"
        & $Odin build $PkgDir $Collection $optFlag "-out:$exePath"
        if ($LASTEXITCODE -ne 0) {
            throw "odin build failed for $OutName (exit $LASTEXITCODE)"
        }
        return $exePath
    }

    $Clang = Resolve-ClangExe
    $objPath = Join-Path $BuildDir "$OutName.obj"
    $shimPath = Ensure-CrtShim $BuildDir
    Write-Host "[build:llvm-mingw] $OutName.exe ($optFlag)"
    & $Odin build $PkgDir $Collection $optFlag -ignore-vs-search -build-mode:obj -use-single-module "-out:$objPath"
    if ($LASTEXITCODE -ne 0) {
        throw "odin object emission failed for $OutName (exit $LASTEXITCODE)"
    }

    & $Clang -municode $objPath $shimPath -o $exePath `
        -lkernel32 -lbcrypt -lsynchronization -lntdll -luser32 -ladvapi32 -lshell32 -lws2_32 -lole32 -luuid -lwinmm
    if ($LASTEXITCODE -ne 0) {
        throw "clang link failed for $OutName (exit $LASTEXITCODE)"
    }
    return $exePath
}

function Run-Check {
    Invoke-OdinCheck (Join-Path $OdinRoot "core") "vasperty:core" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "pe") "vasperty:pe" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "game") "vasperty:game" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "formats") "vasperty:formats" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "pipeline") "vasperty:pipeline" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "loader") "vasperty:loader" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "hle") "vasperty:hle" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "shader") "vasperty:shader" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "gpu") "vasperty:gpu" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "app") "vasperty:app" -NoEntry
    Invoke-OdinCheck (Join-Path $OdinRoot "cli") "vasperty:cli"
    Invoke-OdinCheck (Join-Path $OdinRoot "tests") "vasperty:tests"
}

function Run-Tests {
    $testExe = Build-OdinBinary (Join-Path $OdinRoot "tests") "vasperty_tests"
    Write-Host "[test] Running Odin suite with Tracking_Allocator leak verification..."
    & $testExe
    if ($LASTEXITCODE -ne 0) {
        throw "vasperty_tests.exe failed (exit $LASTEXITCODE)"
    }
}

function Run-CliBuild {
    return (Build-OdinBinary (Join-Path $OdinRoot "cli") "vasperty" -Opt)
}

switch ($Action) {
    "check" {
        Run-Check
    }
    "test" {
        Run-Tests
    }
    "build" {
        $null = Run-CliBuild
    }
    "bench" {
        $cliExe = Run-CliBuild
        & $cliExe bench 2
        if ($LASTEXITCODE -ne 0) { throw "vasperty.exe bench failed (exit $LASTEXITCODE)" }
    }
    "doctor" {
        $cliExe = Run-CliBuild
        & $cliExe doctor
        if ($LASTEXITCODE -ne 0) { throw "vasperty.exe doctor failed (exit $LASTEXITCODE)" }
    }
    "all" {
        Run-Check
        Run-Tests
        $cliExe = Run-CliBuild
        Write-Host "[cli] status"
        & $cliExe status
        if ($LASTEXITCODE -ne 0) { throw "vasperty.exe status failed (exit $LASTEXITCODE)" }
        Write-Host "[cli] doctor"
        & $cliExe doctor
        if ($LASTEXITCODE -ne 0) { throw "vasperty.exe doctor failed (exit $LASTEXITCODE)" }
        Write-Host "[cli] inspect"
        & $cliExe inspect $cliExe
        if ($LASTEXITCODE -ne 0) { throw "vasperty.exe inspect failed (exit $LASTEXITCODE)" }
        Write-Host "[cli] bench"
        & $cliExe bench 2
        if ($LASTEXITCODE -ne 0) { throw "vasperty.exe bench failed (exit $LASTEXITCODE)" }
    }
}
