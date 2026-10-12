param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TauriArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue)) {
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (-not (Test-Path (Join-Path $cargoBin 'cargo.exe'))) {
        throw 'cargo.exe não foi encontrado no PATH nem no diretório padrão do rustup.'
    }
    $env:PATH = "$cargoBin;$env:PATH"
}

$frontendPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $frontendPath
try {
    & npm.cmd run tauri -- @TauriArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Tauri falhou com código $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
