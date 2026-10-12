param(
    [string]$BackendPath = (Join-Path $PSScriptRoot "..\..\backend")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$frontendPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$tauriTarget = Join-Path $frontendPath 'src-tauri\target'
$nsisPath = Join-Path $tauriTarget 'release\bundle\nsis'

function Assert-ChildPath {
    param([string]$Path, [string]$Root)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Caminho fora da área permitida: $fullPath"
    }
    return $fullPath
}

function Assert-NativeSuccess {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step falhou com código $LASTEXITCODE."
    }
}

Push-Location $frontendPath
try {
    & (Join-Path $PSScriptRoot 'prepare-desktop.ps1') -BackendPath $BackendPath
    if (-not $?) {
        throw 'A preparação dos recursos desktop falhou.'
    }

    Write-Host 'Instalando dependências npm exatamente pelo lockfile...'
    & npm.cmd ci
    Assert-NativeSuccess -Step 'npm ci'

    if (Test-Path $nsisPath) {
        [void](Assert-ChildPath -Path $nsisPath -Root $tauriTarget)
        Remove-Item -LiteralPath $nsisPath -Recurse -Force
    }

    Write-Host 'Gerando aplicativo e instalador NSIS...'
    & (Join-Path $PSScriptRoot 'run-tauri.ps1') build --bundles nsis
    Assert-NativeSuccess -Step 'Build Tauri/NSIS'

    $installers = @(Get-ChildItem -File -Path $nsisPath -Filter '*.exe')
    if ($installers.Count -eq 0) {
        throw "Nenhum instalador NSIS foi encontrado em $nsisPath."
    }
    foreach ($installer in $installers) {
        Write-Host "Instalador NSIS: $($installer.FullName) ($($installer.Length) bytes)"
    }
}
finally {
    Pop-Location
}
