param(
    [string]$BackendPath = (Join-Path $PSScriptRoot "..\..\backend")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$frontendPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$tauriPath = Join-Path $frontendPath "src-tauri"
$resourcesPath = Join-Path $tauriPath "resources"
$backendResourcesPath = Join-Path $resourcesPath "backend"
$runtimeResourcesPath = Join-Path $resourcesPath "java-runtime"
$testRoot = Join-Path $tauriPath ".desktop-test"
$resolvedBackendPath = [System.IO.Path]::GetFullPath($BackendPath)
$runtimeModules = "java.se,jdk.crypto.ec,jdk.management,jdk.unsupported,jdk.zipfs"

function Assert-ChildPath {
    param([string]$Path, [string]$Root)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Caminho fora da área permitida: $fullPath"
    }
    return $fullPath
}

function Clear-GeneratedDirectory {
    param([string]$Path, [string]$AllowedRoot)

    $safePath = Assert-ChildPath -Path $Path -Root $AllowedRoot
    New-Item -ItemType Directory -Force -Path $safePath | Out-Null
    Get-ChildItem -Force -LiteralPath $safePath |
        Where-Object { $_.Name -ne '.gitkeep' } |
        ForEach-Object {
            [void](Assert-ChildPath -Path $_.FullName -Root $AllowedRoot)
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
}

function Assert-NativeSuccess {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step falhou com código $LASTEXITCODE."
    }
}

function Get-JdkHome {
    if ($env:JAVA_HOME) {
        $candidate = [System.IO.Path]::GetFullPath($env:JAVA_HOME)
        if ((Test-Path (Join-Path $candidate "bin\java.exe")) -and
            (Test-Path (Join-Path $candidate "bin\jlink.exe"))) {
            return $candidate
        }
    }

    $jlinkCommand = Get-Command jlink.exe -ErrorAction Stop
    return [System.IO.Directory]::GetParent(
        [System.IO.Directory]::GetParent($jlinkCommand.Source).FullName
    ).FullName
}

function Get-EphemeralPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function New-SessionToken {
    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Get-ResponseText {
    param($Response)

    if ($Response.Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($Response.Content)
    }
    return [string]$Response.Content
}

function Start-EmbeddedBackend {
    param(
        [string]$JavaPath,
        [string]$JarPath,
        [string]$DatabasePath,
        [string]$LogDirectory,
        [int]$Port,
        [string]$Token
    )

    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $JavaPath
    $startInfo.Arguments = '--enable-native-access=ALL-UNNAMED -jar "{0}" --spring.profiles.active=desktop --server.address=127.0.0.1 --server.port={1}' -f $JarPath.Replace('"', '\"'), $Port
    $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName($DatabasePath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.EnvironmentVariables['JAVA_HOME'] = ''
    $startInfo.EnvironmentVariables['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot"
    [void]$startInfo.EnvironmentVariables.Remove('DEBUG')
    $startInfo.EnvironmentVariables['APP_FINANCE_DB_PATH'] = $DatabasePath
    $startInfo.EnvironmentVariables['APP_FINANCE_SESSION_TOKEN'] = $Token
    $startInfo.EnvironmentVariables['APP_FINANCE_LOG_PATH'] = (Join-Path $LogDirectory 'backend.log')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'O runtime embarcado não iniciou o backend.'
    }
    return $process
}

function Invoke-EmbeddedRuntimeCycle {
    param(
        [string]$JavaPath,
        [string]$JarPath,
        [string]$DatabasePath,
        [string]$CyclePath
    )

    $port = Get-EphemeralPort
    $token = New-SessionToken
    $process = Start-EmbeddedBackend `
        -JavaPath $JavaPath `
        -JarPath $JarPath `
        -DatabasePath $DatabasePath `
        -LogDirectory $CyclePath `
        -Port $port `
        -Token $token

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        $ready = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($process.HasExited) {
                throw "O backend embarcado encerrou durante o startup (código $($process.ExitCode))."
            }
            try {
                $response = Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri "http://127.0.0.1:$port/api/desktop/status" `
                    -Headers @{ 'X-App-Session' = $token } `
                    -TimeoutSec 2
                $responseText = Get-ResponseText -Response $response
                if ($response.StatusCode -eq 200 -and $responseText.Trim() -eq '{"status":"ready"}') {
                    $ready = $true
                    break
                }
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $ready) {
            throw 'O backend embarcado não ficou pronto em 45 segundos.'
        }

        $health = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri "http://127.0.0.1:$port/actuator/health" `
            -TimeoutSec 2
        $healthText = Get-ResponseText -Response $health
        if ($health.StatusCode -ne 200 -or $healthText.Trim() -ne '{"status":"UP"}') {
            throw 'O health check do backend embarcado não retornou UP.'
        }

        $shutdown = Invoke-WebRequest `
            -UseBasicParsing `
            -Method Post `
            -Uri "http://127.0.0.1:$port/api/desktop/shutdown" `
            -Headers @{ 'X-App-Session' = $token } `
            -TimeoutSec 2
        if ($shutdown.StatusCode -ne 202) {
            throw 'O endpoint de shutdown não aceitou o encerramento.'
        }
        if (-not $process.WaitForExit(5000)) {
            throw 'O backend embarcado não encerrou graciosamente em 5 segundos.'
        }
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

if (-not (Test-Path (Join-Path $resolvedBackendPath 'mvnw.cmd'))) {
    throw "Maven Wrapper não encontrado em $resolvedBackendPath."
}
if (-not (Test-Path (Join-Path $resolvedBackendPath 'pom.xml'))) {
    throw "pom.xml não encontrado em $resolvedBackendPath."
}

Write-Host 'Construindo e testando o backend...'
$previousDebug = $env:DEBUG
Push-Location $resolvedBackendPath
try {
    $env:DEBUG = 'false'
    & (Join-Path $resolvedBackendPath 'mvnw.cmd') clean verify
    Assert-NativeSuccess -Step 'Build Maven'
}
finally {
    $env:DEBUG = $previousDebug
    Pop-Location
}

$jarCandidates = @(
    Get-ChildItem -File -Path (Join-Path $resolvedBackendPath 'target') -Filter 'finance-control-backend-*.jar' |
        Where-Object { $_.Name -notmatch '-(sources|javadoc)\.jar$' }
)
if ($jarCandidates.Count -ne 1) {
    throw "Era esperado exatamente um JAR executável, mas foram encontrados $($jarCandidates.Count)."
}
$sourceJar = $jarCandidates[0].FullName

$jdkHome = Get-JdkHome
$javaPath = Join-Path $jdkHome 'bin\java.exe'
$jlinkPath = Join-Path $jdkHome 'bin\jlink.exe'
$javaVersionOutput = @(& $javaPath --version 2>&1)
Assert-NativeSuccess -Step 'Leitura da versão Java'
$javaVersion = $javaVersionOutput[0].ToString()
if ($javaVersion -notmatch '^openjdk 25\.') {
    throw "Java 25 é obrigatório para o runtime embarcado. Encontrado: $javaVersion"
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$runtimeBuildPath = Join-Path $testRoot ("runtime-build-" + [Guid]::NewGuid().ToString('N'))
[void](Assert-ChildPath -Path $runtimeBuildPath -Root $testRoot)

try {
    Write-Host "Gerando runtime Java com módulos: $runtimeModules"
    $jlinkArguments = @(
        '--add-modules', $runtimeModules,
        '--limit-modules', $runtimeModules,
        '--bind-services',
        '--strip-debug',
        '--no-header-files',
        '--no-man-pages',
        '--compress', 'zip-6',
        '--output', $runtimeBuildPath
    )
    $jmodsPath = Join-Path $jdkHome 'jmods'
    if (Test-Path $jmodsPath) {
        $jlinkArguments = @('--module-path', $jmodsPath) + $jlinkArguments
    }
    & $jlinkPath @jlinkArguments
    Assert-NativeSuccess -Step 'jlink'

    Clear-GeneratedDirectory -Path $backendResourcesPath -AllowedRoot $resourcesPath
    Clear-GeneratedDirectory -Path $runtimeResourcesPath -AllowedRoot $resourcesPath
    Copy-Item -LiteralPath $sourceJar -Destination (Join-Path $backendResourcesPath 'finance-control-backend.jar')
    Get-ChildItem -Force -LiteralPath $runtimeBuildPath |
        Copy-Item -Destination $runtimeResourcesPath -Recurse -Force
}
finally {
    if (Test-Path $runtimeBuildPath) {
        [void](Assert-ChildPath -Path $runtimeBuildPath -Root $testRoot)
        Remove-Item -LiteralPath $runtimeBuildPath -Recurse -Force
    }
}

$embeddedJava = Join-Path $runtimeResourcesPath 'bin\java.exe'
$embeddedJar = Join-Path $backendResourcesPath 'finance-control-backend.jar'
$cycleRoot = Join-Path $testRoot ("runtime-test-" + [Guid]::NewGuid().ToString('N'))
[void](Assert-ChildPath -Path $cycleRoot -Root $testRoot)
New-Item -ItemType Directory -Force -Path $cycleRoot | Out-Null
$databasePath = Join-Path $cycleRoot 'finance-control.db'

try {
    Write-Host 'Testando o backend com o runtime embarcado e sem Java externo no PATH...'
    Invoke-EmbeddedRuntimeCycle `
        -JavaPath $embeddedJava `
        -JarPath $embeddedJar `
        -DatabasePath $databasePath `
        -CyclePath (Join-Path $cycleRoot 'first-run')
    if (-not (Test-Path $databasePath)) {
        throw 'O banco SQLite isolado não foi criado.'
    }
    $databaseCreationTime = (Get-Item -LiteralPath $databasePath).CreationTimeUtc

    Invoke-EmbeddedRuntimeCycle `
        -JavaPath $embeddedJava `
        -JarPath $embeddedJar `
        -DatabasePath $databasePath `
        -CyclePath (Join-Path $cycleRoot 'second-run')
    if ((Get-Item -LiteralPath $databasePath).CreationTimeUtc -ne $databaseCreationTime) {
        throw 'O banco SQLite isolado foi substituído entre as execuções.'
    }
}
finally {
    if (Test-Path $cycleRoot) {
        [void](Assert-ChildPath -Path $cycleRoot -Root $testRoot)
        Remove-Item -LiteralPath $cycleRoot -Recurse -Force
    }
}

$runtimeSize = (Get-ChildItem -File -Recurse -LiteralPath $runtimeResourcesPath |
    Measure-Object -Property Length -Sum).Sum
$jarSize = (Get-Item -LiteralPath $embeddedJar).Length
Write-Host "Runtime preparado: $runtimeResourcesPath ($runtimeSize bytes)"
Write-Host "Backend preparado: $embeddedJar ($jarSize bytes)"
Write-Host "Java efetivo: $javaVersion"
Write-Host 'Teste do runtime embarcado e preservação do SQLite: APROVADO'
