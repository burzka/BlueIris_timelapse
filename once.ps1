# --- KONFIGURACJA ---
$LocalVideoPath = "C:\BlueIris_timelapse\VIDEO"
$RcloneExe      = "C:\Tools\rclone\rclone.exe"
$RcloneRemote   = "drive_timelapse:/"  # Twoja nazwa remote
$RemoteFolder   = "VIDEO"              # Folder w chmurze

# --- LOGIKA ---
Write-Host "🚀 ROZPOCZYNAM TEST RĘCZNEGO WYSYŁANIA (RCLONE)..." -ForegroundColor Cyan
Write-Host "   Lokalizacja rclone: $RcloneExe"
Write-Host "   Cel w chmurze: $RcloneRemote$RemoteFolder"

if (-not (Test-Path $RcloneExe)) { Write-Error "❌ Nie znaleziono rclone.exe!"; Pause; exit }
if (-not (Test-Path $LocalVideoPath)) { Write-Error "❌ Nie znaleziono folderu VIDEO!"; Pause; exit }

$cameras = Get-ChildItem -Path $LocalVideoPath -Directory

foreach ($cam in $cameras) {
    $camName = $cam.Name
    $fullVideo = "$LocalVideoPath\$camName\$($camName)_FULL.mp4"

    Write-Host "`n📸 Kamera: $camName" -ForegroundColor Yellow

    if (Test-Path $fullVideo) {
        $sizeMB = "{0:N2} MB" -f ((Get-Item $fullVideo).Length / 1MB)
        Write-Host "   📦 Znaleziono plik FULL ($sizeMB)"
        
        # Ścieżka docelowa w chmurze: drive_timelapse:/VIDEO/NazwaKamery/NazwaKamery_FULL.mp4
        $cloudDest = "$RcloneRemote$RemoteFolder/$camName/$($camName)_FULL.mp4"
        
        Write-Host "   ⏳ Wysyłam do: $cloudDest" -ForegroundColor Cyan
        
        # Uruchamiamy rclone bezpośrednio w tym oknie z flagą -P (Progress)
        # Dzięki temu zobaczysz pasek postępu
        & $RcloneExe copyto "$fullVideo" "$cloudDest" -P
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ✅ SUKCES! Plik wysłany." -ForegroundColor Green
        } else {
            Write-Host "   ❌ BŁĄD! Kod błędu: $LASTEXITCODE" -ForegroundColor Red
        }

    } else {
        Write-Host "   ⚠️ Nie znaleziono pliku FULL dla tej kamery." -ForegroundColor DarkGray
    }
}

Write-Host "`n🏁 Test zakońoczny." -ForegroundColor Magenta
Pause