# ogr2gui Windows build + deploy (conda-forge Qt6 + GDAL on MSVC)
#
# No Python runtime is needed. We only borrow the conda "gis311" env for
# Qt6 + GDAL DEVELOPMENT files (headers / cmake / import libs). The actual
# compiler is MSVC (cl.exe) from Visual Studio Build Tools.
#
# Output: <repo_root>\build\ogr2gui.exe  - fully self-contained, no conda needed at runtime.
#
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Edit these paths if your install differs ---
$BT       = "D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools"
$condaEnv = "D:\ProgramData\anaconda3\envs\gis311"
$cmake    = "$BT\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$ninja    = "$BT\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
$vcvars   = "$BT\VC\Auxiliary\Build\vcvars64.bat"
$dumpbin  = "$BT\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe"  # wildcard, we glob below

if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found: $vcvars" }
$dumpbin = Get-ChildItem $dumpbin -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $dumpbin) { throw "dumpbin.exe not found under $BT" }

# --- Load MSVC environment (run vcvars in a cmd child shell, extract KEY=VALUE) ---
$envLines = & "$env:SystemRoot\System32\cmd.exe" /c "call `"$vcvars`" >nul 2>nul && set" 2>$null
foreach ($line in $envLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
    }
}

$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = "$root\build"
$qb    = "$condaEnv\Library\bin"
$qtPlg = "$condaEnv\Library\lib\qt6\plugins"

New-Item -ItemType Directory -Force -Path $build | Out-Null

# --- IMPORTANT: Qt tools (moc.exe / rcc.exe / uic.exe) are Qt apps too.
#     They crash with 0xC0000135 unless Qt6Core.dll is on PATH. ---
$env:PATH = "$qb;$condaEnv\Library\lib\qt6\bin;$env:PATH"

Write-Host "=== [1/3] CMake configure ==="
& $cmake -S $root -B $build -G "Ninja" `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_MAKE_PROGRAM="$ninja" `
    -DCMAKE_PREFIX_PATH="$condaEnv\Library" `
    -DGDAL_ROOT="$condaEnv\Library"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

Write-Host "=== [2/3] Build ==="
& $cmake --build $build
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

$exe = Join-Path $build "ogr2gui.exe"
Write-Host "=== [3/3] Deploy runtime DLLs ==="

# -------------------------------------------------------
# A) Qt6 core DLLs (direct imports of our exe)
# -------------------------------------------------------
@("Qt6Core.dll","Qt6Gui.dll","Qt6Widgets.dll","Qt6Sql.dll","Qt6Network.dll") | ForEach-Object {
    $f = Join-Path $qb $_; if (Test-Path $f) { Copy-Item $f $build -Force }
}

# -------------------------------------------------------
# B) Qt platform plugin (MUST be ./platforms/qwindows.dll)
# -------------------------------------------------------
$pPlatforms = "$build\platforms"; New-Item -ItemType Directory -Force -Path $pPlatforms | Out-Null
@("qwindows.dll","qdirect2d.dll","qminimal.dll","qoffscreen.dll") | ForEach-Object {
    $f = "$qtPlg\platforms\$_"; if (Test-Path $f) { Copy-Item $f $pPlatforms -Force }
}

# -------------------------------------------------------
# C) Qt imageformats / sqldrivers plugins (optional but harmless)
# -------------------------------------------------------
foreach ($pair in @(@("imageformats","imageformats"), @("sqldrivers","sqldrivers"))) {
    $srcDir = "$qtPlg\$($pair[0])"
    $dstDir = "$build\$($pair[1])"
    if (Test-Path $srcDir) {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Get-ChildItem $srcDir -Filter "*.dll" | ForEach-Object { Copy-Item $_.FullName $dstDir -Force }
    }
}

# -------------------------------------------------------
# D) BFS recursive dependency collection
#     For every DLL in build/, look up its non-system imports,
#     copy missing ones from conda env, then recurse on those new DLLs.
#     This catches everything Qt/GDAL chain pulls in (libarchive, xerces,
#     jxl, lz4, blosc, icu data, …) that manual globs would miss.
# -------------------------------------------------------
Write-Host "    (BFS collect missing conda DLLs)"

# Add build + conda bin to PATH so dumpbin can resolve known deps
$env:PATH = "$build;$qb;C:\Windows\System32;C:\Windows\SysWOW64;C:\Windows"

$systemPrefixes = @(
    "api-ms-win-","KERNEL32","KERNELBASE","USER32","GDI32","SHELL32",
    "ole32","oleaut32","MSVCP","VCRUNTIME","ntdll","WINMM","ADVAPI32",
    "SETUPAPI","COMDLG32","SHLWAPI","WS2_32","VERSION","IMM32","DWMAPI",
    "D3D9","D3D11","D3D12","UIAutomationCore","WTSAPI32","MPR","USERENV",
    "AUTHZ","NETAPI32","DWRITE","DXGI","UxTheme","WINHTTP","CRYPT32",
    "DSROLE","DNSAPI","ESENT","IPHLPAPI","COM32"
)

function Get-DllImports($path) {
    $out = & $dumpbin /DEPENDENTS $path 2>$null | Out-String
    return ($out -split "`n") | Where-Object { $_ -match "^\s+(\S+\.dll)\s*$" } |
        ForEach-Object { $matches[1] } | Select-Object -Unique
}
function Is-SystemDll($name) {
    foreach ($p in $systemPrefixes) { if ($name -like "$p*") { return $true } }
    return $false
}

# Index DLLs already in build (recursively, case-insensitive name -> full path)
$inBuild = @{}
Get-ChildItem $build -Recurse -Filter "*.dll" -File | ForEach-Object { $inBuild[$_.Name.ToLower()] = $_.FullName }

# Seed queue with exe + all DLLs present
$queue = New-Object System.Collections.Generic.List[string]
$queue.Add($exe)
Get-ChildItem $build -Filter "*.dll" -File | ForEach-Object { $queue.Add($_.FullName) }
Get-ChildItem "$build\platforms","$build\imageformats","$build\sqldrivers" -Filter "*.dll" -File -ErrorAction SilentlyContinue |
    ForEach-Object { $queue.Add($_.FullName) }

$visited = @{}
$copied = 0
while ($queue.Count -gt 0) {
    $dll = $queue[0]; $queue.RemoveAt(0)
    $key = $dll.ToLower()
    if ($visited.ContainsKey($key)) { continue }
    $visited[$key] = $true

    foreach ($imp in (Get-DllImports $dll)) {
        if (Is-SystemDll $imp) { continue }
        if ($inBuild.ContainsKey($imp.ToLower())) { continue }

        $src = Get-ChildItem $qb -Filter $imp -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($src) {
            Copy-Item $src.FullName $build -Force
            $inBuild[$imp.ToLower()] = "$build\$imp"
            $copied++
            Write-Host "      + $imp"
            $queue.Add("$build\$imp")
        }
    }
}
Write-Host "    ... BFS done, added $copied DLL(s)"

Write-Host ""
Write-Host "Done. Run it by double-clicking:"
Write-Host "  $exe"
