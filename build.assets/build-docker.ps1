#requires -Version 5.1
<#
Dockerized Teleport build for Windows (Option 3 — direct `docker buildx`/`docker run`,
no make on the host). Mirrors what `make -C build.assets build-binaries` does.

Examples:
    .\build-docker.ps1                          # OSS Linux amd64 binaries
    .\build-docker.ps1 -Target enterprise
    .\build-docker.ps1 -Arch arm64 -SkipWebassets
    .\build-docker.ps1 -BuildboxOnly            # just (re)build the buildbox images

Output binaries land in <repo-root>\build\.
#>

[CmdletBinding()]
param(
    [ValidateSet('amd64','arm64')]
    [string]$Arch = 'amd64',

    [ValidateSet('binaries','enterprise','release','fips')]
    [string]$Target = 'binaries',

    [ValidateSet('linux')]
    [string]$Os = 'linux',

    [switch]$SkipBuildbox,
    [switch]$SkipWebassets,
    [switch]$BuildboxOnly,
    [switch]$RebuildBuildbox,
    [switch]$Fido2,
    [switch]$Piv,
    [switch]$PurgeCaches
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$BuildAssets = $PSScriptRoot
$RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SrcDir      = '/go/src/github.com/gravitational/teleport'

function Read-MakeVar {
    param([string]$Path, [string]$Name)
    $m = Select-String -Path $Path -Pattern "^$Name\s*\??=" | Select-Object -First 1
    if (-not $m) { throw "Could not find $Name in $Path" }
    ($m.Line -split '=', 2)[1].Trim()
}

function Read-RustChannel {
    param([string]$Path)
    $m = Select-String -Path $Path -Pattern '^\s*channel\s*=' | Select-Object -First 1
    if (-not $m) { throw "Could not find channel in $Path" }
    (($m.Line -split '=', 2)[1].Trim()) -replace '"', ''
}

function Read-WasmBindgenVersion {
    param([string]$Path)
    $lines = Get-Content -LiteralPath $Path
    $inPkg = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*name\s*=\s*"wasm-bindgen"\s*$') { $inPkg = $true; continue }
        if ($inPkg -and $line -match '^\s*version\s*=\s*"([^"]+)"') { return $Matches[1] }
        if ($inPkg -and $line -match '^\s*\[\[package\]\]') { $inPkg = $false }
    }
    return $null
}

# --- Resolve versions ----------------------------------------------------
$VersionsMk      = Join-Path $BuildAssets 'versions.mk'
$ImagesMk        = Join-Path $BuildAssets 'images.mk'
$RustToolchain   = Join-Path $RepoRoot   'rust-toolchain.toml'
$CargoLock       = Join-Path $RepoRoot   'Cargo.lock'

$GOLANG_VERSION       = Read-MakeVar $VersionsMk 'GOLANG_VERSION'
$NODE_VERSION         = Read-MakeVar $VersionsMk 'NODE_VERSION'
$WASM_OPT_VERSION     = Read-MakeVar $VersionsMk 'WASM_OPT_VERSION'
$LIBBPF_VERSION       = Read-MakeVar $VersionsMk 'LIBBPF_VERSION'
$LIBPCSCLITE_VERSION  = Read-MakeVar $VersionsMk 'LIBPCSCLITE_VERSION'
$DEVTOOLSET           = Read-MakeVar $VersionsMk 'DEVTOOLSET'
$BUILDBOX_VERSION     = Read-MakeVar $ImagesMk   'BUILDBOX_VERSION'
$BUILDBOX_BASE_NAME   = Read-MakeVar $ImagesMk   'BUILDBOX_BASE_NAME'
$RUST_VERSION         = Read-RustChannel $RustToolchain
$WASM_BINDGEN_VERSION = if (Test-Path $CargoLock) { Read-WasmBindgenVersion $CargoLock } else { '' }

$BUILDBOX_CENTOS7_ASSETS = "${BUILDBOX_BASE_NAME}-centos7-assets:${BUILDBOX_VERSION}-${Arch}"
$BUILDBOX_CENTOS7        = "${BUILDBOX_BASE_NAME}-centos7:${BUILDBOX_VERSION}-${Arch}"
$BUILDBOX_CENTOS7_FIPS   = "${BUILDBOX_BASE_NAME}-centos7-fips:${BUILDBOX_VERSION}-${Arch}"
$BUILDBOX_NODE           = "${BUILDBOX_BASE_NAME}-node:${BUILDBOX_VERSION}-${Arch}"

Write-Host "==> versions" -ForegroundColor Cyan
Write-Host "    arch                = $Arch"
Write-Host "    buildbox version    = $BUILDBOX_VERSION"
Write-Host "    go                  = $GOLANG_VERSION"
Write-Host "    rust                = $RUST_VERSION"
Write-Host "    node                = $NODE_VERSION"
Write-Host "    devtoolset          = $DEVTOOLSET"
Write-Host "    libbpf              = $LIBBPF_VERSION"
Write-Host "    libpcsclite         = $LIBPCSCLITE_VERSION"
Write-Host "    wasm-opt            = $WASM_OPT_VERSION"
Write-Host "    wasm-bindgen        = $WASM_BINDGEN_VERSION"
Write-Host ""

# --- Helpers -------------------------------------------------------------
function Invoke-Native {
    param([Parameter(ValueFromRemainingArguments)]$Args)
    Write-Host "+ $($Args -join ' ')" -ForegroundColor DarkGray
    & $Args[0] @($Args | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $($Args -join ' ')" }
}

# Force LF endings on files that get parsed by Linux tooling inside the container.
# Git on Windows with core.autocrlf=true checks these out as CRLF, which breaks:
#   - heredoc-written shell scripts: `bad interpreter: /bin/sh^M`
#   - Makefile awk over Cargo.lock: "Unknown wasm-bindgen version"
#   - GNU make line-continuations and recipe parsing
function Repair-Eol {
    param([string]$BuildAssetsDir, [string]$RepoRootDir)
    $targets = New-Object System.Collections.Generic.List[string]
    # Anything sourced/executed inside the buildbox.
    Get-ChildItem -Path $BuildAssetsDir -File -Recurse -Include @('Dockerfile*', '*.sh') |
        ForEach-Object { $targets.Add($_.FullName) }
    # Files at repo root that the container Makefile reads.
    foreach ($name in @('Cargo.lock', 'go.mod', 'go.sum', 'Makefile', 'rust-toolchain.toml')) {
        $p = Join-Path $RepoRootDir $name
        if (Test-Path $p) { $targets.Add((Resolve-Path $p).Path) }
    }
    Get-ChildItem -Path $RepoRootDir -File -Filter '*.mk' |
        ForEach-Object { $targets.Add($_.FullName) }

    foreach ($path in $targets) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes -notcontains 13) { continue }
        $text = [IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"))
        Write-Host "    LF-normalized $path" -ForegroundColor Yellow
    }
}

function Test-LocalImage {
    param([string]$Image)
    $null = & docker image inspect $Image 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Try-PullImage {
    param([string]$Image)
    Write-Host "==> trying to pull $Image" -ForegroundColor Cyan
    & docker pull $Image 2>&1 | Write-Host
    return ($LASTEXITCODE -eq 0)
}

function Ensure-PrebuiltOrBuild {
    param(
        [string]$Image,
        [scriptblock]$BuildFn
    )
    if (-not $RebuildBuildbox -and (Test-LocalImage $Image)) {
        Write-Host "==> $Image already present locally" -ForegroundColor Green
        return
    }
    if (-not $RebuildBuildbox -and (Try-PullImage $Image)) {
        Write-Host "==> $Image pulled from registry" -ForegroundColor Green
        return
    }
    Write-Host "==> local build for $Image (CentOS 7 base may fail — upstream EOL)" -ForegroundColor Yellow
    & $BuildFn
}

function Build-BuildboxNode {
    Write-Host "==> building $BUILDBOX_NODE" -ForegroundColor Cyan
    Invoke-Native docker buildx build `
        --build-arg "BUILDARCH=$Arch" `
        --build-arg "UID=1000" `
        --build-arg "GID=1000" `
        --build-arg "NODE_VERSION=$NODE_VERSION" `
        --build-arg "RUST_VERSION=$RUST_VERSION" `
        --build-arg "WASM_OPT_VERSION=$WASM_OPT_VERSION" `
        --build-arg "WASM_BINDGEN_VERSION=$WASM_BINDGEN_VERSION" `
        --load `
        --tag $BUILDBOX_NODE `
        -f (Join-Path $BuildAssets 'Dockerfile-node') $BuildAssets
}

function Build-BuildboxCentos7 {
    param([string]$BuildTarget = 'buildbox', [string]$Tag = $BUILDBOX_CENTOS7)
    Write-Host "==> building $Tag (target=$BuildTarget)" -ForegroundColor Cyan
    Invoke-Native docker buildx build `
        --target $BuildTarget `
        --build-arg "UID=1000" `
        --build-arg "GID=1000" `
        --build-arg "BUILDBOX_CENTOS7_ASSETS=$BUILDBOX_CENTOS7_ASSETS" `
        --build-arg "BUILDARCH=$Arch" `
        --build-arg "TARGETARCH=$Arch" `
        --build-arg "GOLANG_VERSION=$GOLANG_VERSION" `
        --build-arg "RUST_VERSION=$RUST_VERSION" `
        --build-arg "DEVTOOLSET=$DEVTOOLSET" `
        --build-arg "LIBBPF_VERSION=$LIBBPF_VERSION" `
        --build-arg "LIBPCSCLITE_VERSION=$LIBPCSCLITE_VERSION" `
        --load `
        --tag $Tag `
        -f (Join-Path $BuildAssets 'Dockerfile-centos7') $BuildAssets
}

# Named volumes persist Go/Rust/Node caches across runs. Scoped by arch so
# amd64 and arm64 builds don't trash each other's artifacts. node_modules is
# shadowed by a named volume so pnpm's hardlink-heavy tree stays inside the
# Linux VM filesystem (Docker Desktop bind mounts on Windows are slow and
# break pnpm's rename/hardlink ops).
$Script:CacheVolumes = [ordered]@{
    "teleport-buildbox-gomodcache-$Arch"   = '/tmp/gomodcache'
    "teleport-buildbox-gocache-$Arch"      = '/tmp/gocache'
    "teleport-buildbox-cargo-$Arch"        = '/home/ci/.cargo'
    "teleport-buildbox-xdgcache-$Arch"     = '/home/ci/.cache'
    "teleport-buildbox-node-modules-$Arch" = "$SrcDir/node_modules"
}
$Script:CacheVolumesInitialized = $false

function Remove-CacheVolumes {
    Write-Host "==> removing cache volumes" -ForegroundColor Yellow
    foreach ($name in $Script:CacheVolumes.Keys) {
        & docker volume rm $name 2>&1 | Out-Null
    }
}

function Initialize-CacheVolumes {
    param([string]$Image)
    if ($Script:CacheVolumesInitialized) { return }
    Write-Host "==> initializing cache volume ownership (uid/gid 1000)" -ForegroundColor Cyan
    $args = @('--rm', '-u', '0:0')
    foreach ($kv in $Script:CacheVolumes.GetEnumerator()) {
        $args += @('-v', "$($kv.Key):$($kv.Value)")
    }
    # chown by name (ci:ci) rather than a hardcoded uid: the published
    # buildbox images use uid 1001, locally-built ones use 1000. -R covers any
    # leftover root-owned entries from earlier failed runs.
    $paths = ($Script:CacheVolumes.Values | ForEach-Object { $_ }) -join ' '
    $cmd = "chown -R ci:ci $paths && chmod -R u+rwX,g+rwX $paths"
    $args += @($Image, 'sh', '-c', $cmd)
    Invoke-Native docker run @args
    $Script:CacheVolumesInitialized = $true
}

function Get-DockerRunArgs {
    param([string]$Image)
    $mount = "${RepoRoot}:${SrcDir}"
    $args = @(
        '--rm',
        '-v', $mount
    )
    foreach ($kv in $Script:CacheVolumes.GetEnumerator()) {
        $args += @('-v', "$($kv.Key):$($kv.Value)")
    }
    $args += @(
        '-w', $SrcDir,
        '-h', 'buildbox',
        '-u', 'ci:ci',
        '-e', 'HOME=/home/ci',
        '-e', 'GOMODCACHE=/tmp/gomodcache',
        '-e', 'GOCACHE=/tmp/gocache',
        '-e', 'CARGO_HOME=/home/ci/.cargo',
        '-e', 'XDG_CACHE_HOME=/home/ci/.cache',
        '-e', 'HELM_PLUGINS=/home/ci/.local/share/helm/plugins-new',
        '-e', 'CI=true',
        $Image
    )
    return ,$args
}

function Build-Webassets {
    Write-Host "==> building webassets in $BUILDBOX_NODE" -ForegroundColor Cyan
    Initialize-CacheVolumes -Image $BUILDBOX_NODE
    $extra = if (Test-Path (Join-Path $RepoRoot 'e\Makefile')) { 'ensure-webassets-e' } else { '' }
    $makeArgs = @('ensure-webassets')
    if ($extra) { $makeArgs += $extra }
    $runArgs = Get-DockerRunArgs $BUILDBOX_NODE
    Invoke-Native docker run @runArgs /usr/bin/make @makeArgs
}

function Invoke-Build {
    $fido2 = if ($Fido2) { 'yes' } else { 'no' }
    $piv   = if ($Piv)   { 'yes' } else { 'no' }

    $initImage = if ($Target -eq 'fips') { $BUILDBOX_CENTOS7_FIPS } else { $BUILDBOX_CENTOS7 }
    Initialize-CacheVolumes -Image $initImage

    switch ($Target) {
        'binaries' {
            $image = $BUILDBOX_CENTOS7
            $makeCmd = "make clean-build full -e ADDFLAGS='' OS=$Os ARCH=$Arch RUNTIME=$GOLANG_VERSION FIDO2=$fido2 PIV=$piv REPRODUCIBLE=no"
            $runArgs = Get-DockerRunArgs $image
            Write-Host "==> building OSS binaries" -ForegroundColor Cyan
            Invoke-Native docker run @runArgs /usr/bin/scl enable $DEVTOOLSET $makeCmd
        }
        'enterprise' {
            $image = $BUILDBOX_CENTOS7
            $makeCmd = "make clean-build full-ent -e ADDFLAGS='' OS=$Os ARCH=$Arch RUNTIME=$GOLANG_VERSION FIDO2=$fido2 PIV=$piv REPRODUCIBLE=no"
            $runArgs = Get-DockerRunArgs $image
            Write-Host "==> building Enterprise binaries" -ForegroundColor Cyan
            Invoke-Native docker run @runArgs /usr/bin/scl enable $DEVTOOLSET $makeCmd
        }
        'release' {
            $image = $BUILDBOX_CENTOS7
            $runArgs = Get-DockerRunArgs $image
            Write-Host "==> building release tarball" -ForegroundColor Cyan
            Invoke-Native docker run @runArgs make -C $SrcDir PIV=$piv release-unix-preserving-webassets
        }
        'fips' {
            $image = $BUILDBOX_CENTOS7_FIPS
            $runArgs = Get-DockerRunArgs $image
            Write-Host "==> building FIPS enterprise binaries" -ForegroundColor Cyan
            Invoke-Native docker run @runArgs make -C "$SrcDir/e" PIV=$piv FIPS=yes clean full
        }
    }
}

# --- Run -----------------------------------------------------------------
Push-Location $BuildAssets
try {
    if ($PurgeCaches) { Remove-CacheVolumes }

    Write-Host "==> normalizing line endings (build.assets + repo-root build files)" -ForegroundColor Cyan
    Repair-Eol -BuildAssetsDir $BuildAssets -RepoRootDir $RepoRoot

    if (-not $SkipBuildbox) {
        if ($Target -eq 'fips') {
            Ensure-PrebuiltOrBuild -Image $BUILDBOX_CENTOS7_FIPS -BuildFn {
                Build-BuildboxCentos7 -BuildTarget 'buildbox-fips' -Tag $BUILDBOX_CENTOS7_FIPS
            }
        } else {
            Ensure-PrebuiltOrBuild -Image $BUILDBOX_CENTOS7 -BuildFn {
                Build-BuildboxCentos7
            }
        }
        if (-not $SkipWebassets -and -not $BuildboxOnly) {
            Ensure-PrebuiltOrBuild -Image $BUILDBOX_NODE -BuildFn {
                Build-BuildboxNode
            }
        }
    }

    if ($BuildboxOnly) {
        Write-Host "buildbox(es) built. Skipping final build (-BuildboxOnly)." -ForegroundColor Green
        return
    }

    if (-not $SkipWebassets) {
        Build-Webassets
    }

    Invoke-Build

    Write-Host ""
    Write-Host "Done. Binaries in $RepoRoot\build" -ForegroundColor Green
}
finally {
    Pop-Location
}
