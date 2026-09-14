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
& $csc /nologo /target:winexe /optimize+ /out:"$out" `
    /win32icon:"$dir\widget.ico" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    /resource:"$dir\limits-widget.ps1",limits-widget.ps1 `
    "$dir\launcher.cs"

if ($LASTEXITCODE -ne 0) { throw "csc завершился с кодом $LASTEXITCODE" }

Write-Host "Собрано: $out"
