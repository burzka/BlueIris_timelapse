# ==============================================================================
# Skrypt wdrozeniowy (Deploy) - BlueIris Timelapse Hub
# Srodowisko produkcyjne: Windows PowerShell / Docker Compose
# ==============================================================================

[CmdletBinding()]
Param(
    [ValidateSet("docker", "local", "status", "logs", "stop", "restart")]
    [string]$Mode = "docker",
    
    [switch]$ForceRebuild = $true
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ScriptDir) { $ScriptDir = Get-Location }
Set-Location $ScriptDir

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "   🚀 BlueIris Timelapse Hub - Skrypt Deploy" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Katalog projektu: $ScriptDir" -ForegroundColor Gray
Write-Host "Tryb wdrozenia:   $Mode" -ForegroundColor Yellow
Write-Host ""

function Check-Docker {
    try {
        $null = docker --version
        return $true
    } catch {
        return $false
    }
}

switch ($Mode) {
    "docker" {
        if (-not (Check-Docker)) {
            Write-Error "BLAD: Docker nie jest zainstalowany lub uruchomiony w systemie."
            exit 1
        }

        # Upewnij sie, ze katalog danych istnieje
        $DataDir = Join-Path $ScriptDir "data"
        if (-not (Test-Path $DataDir)) {
            Write-Host "[INFO] Tworzenie katalogu na dane: $DataDir" -ForegroundColor Gray
            New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        }

        Write-Host "[1/3] Budowanie i uruchamianie kontenera produkcyjnego..." -ForegroundColor Green
        if ($ForceRebuild) {
            docker compose up -d --build
        } else {
            docker compose up -d
        }

        Write-Host ""
        Write-Host "[2/3] Sprawdzanie statusu uslugi..." -ForegroundColor Green
        docker compose ps

        Write-Host ""
        Write-Host "[3/3] Wdrozenie zakonczone sukcesem! 🎉" -ForegroundColor Green
        Write-Host "Dostep do aplikacji:" -ForegroundColor Cyan
        Write-Host "  - Dashboard:        http://localhost:8585" -ForegroundColor White
        Write-Host "  - Porownywarka:     http://localhost:8585/comparator" -ForegroundColor White
        Write-Host "  - Kompletnosc:      http://localhost:8585/visualizer" -ForegroundColor White
        Write-Host "  - Pomoc:            http://localhost:8585/help" -ForegroundColor White
    }

    "local" {
        Write-Host "[1/2] Sprawdzanie zaleznosci Python..." -ForegroundColor Green
        if (Test-Path "requirements.txt") {
            pip install -r requirements.txt --quiet
        }

        Write-Host "[2/2] Uruchamianie serwera produkcyjnego Windows..." -ForegroundColor Green
        Write-Host "Otworz w przegladarce: http://localhost:8000" -ForegroundColor Cyan
        python server.py
    }

    "status" {
        Write-Host "Status kontenerow Docker:" -ForegroundColor Yellow
        docker compose ps
    }

    "logs" {
        Write-Host "Podglad logow aplikacji w czasie rzeczywistym (Ctrl+C aby wyjsc):" -ForegroundColor Yellow
        docker compose logs -f
    }

    "restart" {
        Write-Host "Restartowanie uslug..." -ForegroundColor Yellow
        docker compose restart
        docker compose ps
    }

    "stop" {
        Write-Host "Zatrzymywanie uslug..." -ForegroundColor Yellow
        docker compose down
    }
}
