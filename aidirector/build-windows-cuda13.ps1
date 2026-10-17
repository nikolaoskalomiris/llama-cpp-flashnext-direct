[CmdletBinding()]
param(
    [string]$ContractPath = (Join-Path $PSScriptRoot 'direct-build-contract-v1.json'),
    [string]$BuildRoot,
    [string]$OutputRoot,
    [switch]$AllowCustomToolchain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function To-NativePath([string]$Path) { return $Path -replace '/', '\\' }
function To-CMakePath([string]$Path) { return $Path -replace '\\', '/' }

function Test-IsSameOrChildPath([string]$Candidate, [string]$Parent) {
    $seps = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $c = [IO.Path]::GetFullPath($Candidate).TrimEnd($seps)
    $p = [IO.Path]::GetFullPath($Parent).TrimEnd($seps)
    return $c.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or `
        $c.StartsWith($p + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-NativeChecked([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory) {
    Push-Location $WorkingDirectory
    try {
        & $Exe @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe $($Arguments -join ' ')" }
    } finally { Pop-Location }
}

function Import-VcVars([string]$VcVars, [string]$Argument, [string]$TempDirectory) {
    $cmdPath = Join-Path $TempDirectory 'capture-vcvars.cmd'
    $body = "@echo off`r`ncall `"$VcVars`" $Argument >nul`r`nif errorlevel 1 exit /b %errorlevel%`r`nset`r`n"
    [IO.File]::WriteAllText($cmdPath, $body, (New-Object Text.UTF8Encoding($false)))
    try {
        $lines = & $env:ComSpec /d /c $cmdPath
        if ($LASTEXITCODE -ne 0) { throw "vcvars64.bat failed with exit code $LASTEXITCODE" }
        foreach ($line in $lines) {
            $i = $line.IndexOf('=')
            if ($i -le 0) { continue }
            $name = $line.Substring(0,$i)
            $value = $line.Substring($i+1)
            [Environment]::SetEnvironmentVariable($name,$value,'Process')
        }
    } finally {
        Remove-Item -LiteralPath $cmdPath -Force -ErrorAction SilentlyContinue
    }
}

function Read-CMakeCache([string]$Path) {
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^(?<k>[^/#][^:=]*):[^=]*=(?<v>.*)$') { $map[$Matches.k] = $Matches.v }
    }
    return $map
}

$ContractPath = (Resolve-Path -LiteralPath $ContractPath).Path
$Contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

if (-not $BuildRoot) {
    $BuildRoot = Join-Path $env:LOCALAPPDATA ("AIDirectorDirectBuild\\" + [guid]::NewGuid().ToString('N'))
}
if (-not $OutputRoot) { $OutputRoot = Join-Path $BuildRoot 'out' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$BuildDir = Join-Path $BuildRoot 'b'
$ShippingDir = Join-Path $OutputRoot 'shipping'

if (Test-IsSameOrChildPath $BuildRoot $RepoRoot) { throw "BuildRoot must be outside the repository checkout: $BuildRoot" }
if (Test-IsSameOrChildPath $OutputRoot $RepoRoot) { throw "OutputRoot must be outside the repository checkout: $OutputRoot" }
if (Test-IsSameOrChildPath $OutputRoot $BuildDir) { throw "OutputRoot must not be inside the CMake build directory: $OutputRoot" }
if (Test-Path -LiteralPath $BuildRoot) { throw "BuildRoot must be a new non-existing path: $BuildRoot" }
if (Test-Path -LiteralPath $OutputRoot) { throw "OutputRoot must be a new non-existing path: $OutputRoot" }

$representative = Join-Path $BuildDir 'CMakeFiles\\CMakeScratch\\TryCompile-XXXXXXXX\\CMakeFiles\\cmTC_XXXXXXXX.dir\\Debug\\cmTC_XXXXXXXX.obj'
if ($representative.Length -ge 220) { throw "BuildRoot is too long for the conservative path policy ($($representative.Length) >= 220): $BuildRoot" }
New-Item -ItemType Directory -Path $BuildDir,$ShippingDir | Out-Null

$git = (Get-Command git.exe -ErrorAction Stop).Source
$head = (& $git -C $RepoRoot rev-parse HEAD).Trim()
$tree = (& $git -C $RepoRoot rev-parse HEAD^{tree}).Trim()
$status = @(& $git -C $RepoRoot status --porcelain=v1 --untracked-files=all)
if ($status.Count -ne 0) { throw "Reference build requires a clean worktree." }

$baseline = [string]$Contract.source_baseline.commit
& $git -C $RepoRoot merge-base --is-ancestor $baseline HEAD *> $null
if ($LASTEXITCODE -ne 0) { throw "Source baseline $baseline is not an ancestor of HEAD $head" }
$allowed = @($Contract.source_baseline.allowed_overlay_paths | ForEach-Object { [string]$_ })
$changed = @(& $git -C $RepoRoot diff --name-only "$baseline..HEAD")
$unexpected = @($changed | Where-Object { $_ -notin $allowed })
if ($unexpected.Count -ne 0) { throw "Build-relevant source drift from contract baseline: $($unexpected -join ', ')" }

foreach ($name in @($Contract.environment.required_absent)) {
    $v = [Environment]::GetEnvironmentVariable([string]$name,'Process')
    if ($v) { throw "Compiler injection variable must be absent: $name" }
}

$toolPaths = @{}
$toolHashes = @{}
$customTool = $false
foreach ($p in $Contract.reference_toolchain.tools.PSObject.Properties) {
    $name = $p.Name
    $path = To-NativePath ([string]$p.Value.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Reference tool missing: $name at $path" }
    $actual = Get-Sha256 $path
    $expected = ([string]$p.Value.sha256).ToUpperInvariant()
    if ($actual -ne $expected) {
        if (-not $AllowCustomToolchain) { throw "Reference tool hash mismatch for $name. Expected $expected, got $actual" }
        $customTool = $true
    }
    $toolPaths[$name] = $path
    $toolHashes[$name] = $actual
}

Import-VcVars $toolPaths['vcvars64.bat'] ([string]$Contract.environment.vcvars_argument) $BuildRoot
foreach ($name in @($Contract.environment.required_absent)) {
    $v = [Environment]::GetEnvironmentVariable([string]$name,'Process')
    if ($v) { throw "Compiler injection variable appeared after vcvars: $name" }
}
foreach ($name in @($Contract.reference_toolchain.vcvars_resolution_must_match)) {
    $resolved = (Get-Command ([string]$name) -CommandType Application -ErrorAction Stop).Source
    $expected = [IO.Path]::GetFullPath([string]$toolPaths[[string]$name])
    $actual = [IO.Path]::GetFullPath([string]$resolved)
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "vcvars resolved $name to unexpected path. Expected $expected, got $actual"
    }
}
$ccache = Get-Command ccache.exe -CommandType Application -ErrorAction SilentlyContinue
if ($ccache) { throw "Reference recipe requires ccache executable to be absent; found: $($ccache.Source)" }
$env:CUDA_PATH = To-NativePath ([string]$Contract.environment.required_set.CUDA_PATH)
$env:CUDACXX = To-NativePath ([string]$Contract.environment.required_set.CUDACXX)

$cmake = $toolPaths['cmake.exe']
$ninja = $toolPaths['ninja.exe']
$cl = $toolPaths['cl.exe']
$nvcc = $toolPaths['nvcc.exe']
$rc = $toolPaths['rc.exe']
$sourceC = To-CMakePath $RepoRoot
$buildC = To-CMakePath $BuildDir

$args = @('-S',$sourceC,'-B',$buildC,'-G','Ninja')
$args += '-DCMAKE_MAKE_PROGRAM:FILEPATH=' + (To-CMakePath $ninja)
$args += '-DCMAKE_C_COMPILER:FILEPATH=' + (To-CMakePath $cl)
$args += '-DCMAKE_CXX_COMPILER:FILEPATH=' + (To-CMakePath $cl)
$args += '-DCMAKE_CUDA_COMPILER:FILEPATH=' + (To-CMakePath $nvcc)
$args += '-DCMAKE_RC_COMPILER:FILEPATH=' + (To-CMakePath $rc)
foreach ($p in $Contract.configure.cache.PSObject.Properties) { $args += "-D$($p.Name)=$($p.Value)" }

Invoke-NativeChecked $cmake $args $RepoRoot
$cachePath = Join-Path $BuildDir 'CMakeCache.txt'
if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { throw "CMakeCache.txt missing after configure" }
$cache = Read-CMakeCache $cachePath
foreach ($p in $Contract.configure.expected_cache_after_configure.PSObject.Properties) {
    if (-not $cache.ContainsKey($p.Name)) { throw "Required cache key absent: $($p.Name)" }
    if ([string]$cache[$p.Name] -ne [string]$p.Value) { throw "Cache mismatch $($p.Name): expected $($p.Value), got $($cache[$p.Name])" }
}
foreach ($name in @($Contract.configure.must_be_absent_from_cache)) {
    if ($cache.ContainsKey([string]$name) -and [string]$cache[[string]$name]) { throw "Forbidden cache override present: $name=$($cache[[string]$name])" }
}

$uiDir = Join-Path $BuildDir 'tools\\ui\\dist'
if (Test-Path -LiteralPath $uiDir) {
    $uiFiles = @(Get-ChildItem -LiteralPath $uiDir -File -Recurse -ErrorAction Stop)
    if ($uiFiles.Count -ne [int]$Contract.configure.ui_dist_file_count) { throw "Unexpected UI assets in build tree: $($uiFiles.Count)" }
}

$parallel = [Environment]::ProcessorCount
Invoke-NativeChecked $cmake @('--build',$buildC,'--parallel',[string]$parallel) $RepoRoot

$binRoot = Join-Path $BuildDir 'bin'
if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) { throw "Build bin directory missing: $binRoot" }
$artifactRecords = @()
foreach ($entry in @($Contract.shipping_set)) {
    $name = [string]$entry.name
    $matches = @(Get-ChildItem -LiteralPath $binRoot -File -Recurse | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected exactly one build output named $name, found $($matches.Count)" }
    $dest = Join-Path $ShippingDir $name
    Copy-Item -LiteralPath $matches[0].FullName -Destination $dest -Force
    $sha = Get-Sha256 $dest
    $artifactRecords += [ordered]@{
        name=$name; bytes=(Get-Item -LiteralPath $dest).Length; sha256=$sha;
        accepted_historical_sha256=([string]$entry.accepted_historical_sha256).ToUpperInvariant();
        accepted_historical_match=($sha -eq ([string]$entry.accepted_historical_sha256).ToUpperInvariant())
    }
}
$shippingFiles = @(Get-ChildItem -LiteralPath $ShippingDir -File)
if ($shippingFiles.Count -ne [int]$Contract.shipping_policy.exact_file_count) { throw "Shipping directory must contain exactly $($Contract.shipping_policy.exact_file_count) files" }

$identityClass = if ($customTool) { [string]$Contract.identity_policy.custom_toolchain_identity_class } else { [string]$Contract.identity_policy.reference_toolchain_identity_class }
$provenance = [ordered]@{
    schema='ai-director-direct-build-provenance/v1'
    identity_class=$identityClass
    official_accepted_runtime_replacement_authorized=$false
    contract_path='aidirector/direct-build-contract-v1.json'
    contract_sha256=(Get-Sha256 $ContractPath)
    source=[ordered]@{ repository=[string]$Contract.source_baseline.repository; head=$head; tree=$tree; baseline_commit=$baseline; worktree_clean=$true; overlay_changes=$changed }
    cuda=[ordered]@{ build_toolkit=[string]$Contract.cuda_version_distinction.build_toolkit; nvcc_identity=[string]$Contract.cuda_version_distinction.nvcc_identity; installed_shared_runtime_identity=[string]$Contract.cuda_version_distinction.installed_shared_runtime_identity }
    tool_sha256=$toolHashes
    configure_arguments=$args
    build_parallelism=$parallel
    artifacts=$artifactRecords
}
$provPath = Join-Path $OutputRoot 'direct-build-provenance.json'
[IO.File]::WriteAllText($provPath, ($provenance | ConvertTo-Json -Depth 10) + "`n", (New-Object Text.UTF8Encoding($false)))

Write-Host "AIDIRECTOR_DIRECT_BUILD=PASS"
Write-Host "IDENTITY_CLASS=$identityClass"
Write-Host "SOURCE_HEAD=$head"
Write-Host "SOURCE_TREE=$tree"
Write-Host "SHIPPING_FILES=$($shippingFiles.Count)"
Write-Host "SHIPPING_DIR=$ShippingDir"
Write-Host "PROVENANCE=$provPath"
