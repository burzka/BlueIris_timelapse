# Skrypt do uruchomienia Porównywarki Klatek Timelapse
Param(
    [switch]$Server = $true
)

$PSScriptRootPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $PSScriptRootPath) { $PSScriptRootPath = Get-Location }

Set-Location $PSScriptRootPath

$htmlPath = Join-Path $PSScriptRootPath "frame_comparator.html"

if ($Server) {
    Write-Host "Uruchamianie lokalnego serwera HTTP Python na porcie 8000..." -ForegroundColor Green
    Write-Host "Otwórz w przeglądarce: http://localhost:8000/frame_comparator.html" -ForegroundColor Cyan
    Start-Process "http://localhost:8000/frame_comparator.html"
    python -m http.server 8000
} else {
    Write-Host "Otwieranie pliku HTML w domyślnej przeglądarce..." -ForegroundColor Green
    Start-Process $htmlPath
}
