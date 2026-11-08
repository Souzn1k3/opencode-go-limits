#requires -version 5.1
$ErrorActionPreference = 'Stop'

$dir = $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw 'Не найден csc.exe (.NET Framework 4.x). Установите .NET Framework 4.8 или запускайте build.ps1 на Windows 10/11.'
}

$out = Join-Path $dir 'OpenCode Limits.exe'

$scriptVersion = $null
$scriptMatch = Select-String -LiteralPath (Join-Path $dir 'limits-widget.ps1') -Pattern "`$script:AppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
if ($scriptMatch) { $scriptVersion = $scriptMatch.Matches[0].Groups[1].Value }
$launcherVersion = $null
$launcherMatch = Select-String -LiteralPath (Join-Path $dir 'launcher.cs') -Pattern 'AssemblyVersion\("([^"]+)"\)' | Select-Object -First 1
if ($launcherMatch) { $launcherVersion = $launcherMatch.Matches[0].Groups[1].Value }
if ($scriptVersion -and $launcherVersion -and -not $launcherVersion.StartsWith($scriptVersion)) {
    Write-Warning "Версия launcher.cs ($launcherVersion) не совпадает с limits-widget.ps1 ($scriptVersion)"
}

& $csc /nologo /target:winexe /optimize+ /out:"$out" `
    /win32icon:"$dir\widget.ico" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    /resource:"$dir\limits-widget.ps1",limits-widget.ps1 `
    "$dir\launcher.cs"

if ($LASTEXITCODE -ne 0) { throw "csc завершился с кодом $LASTEXITCODE" }

Write-Host "Собрано: $out"
