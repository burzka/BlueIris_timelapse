Write-Host "ROZPOCZYNAM SEPARACJE DLA WSZYSTKICH 5 KAMER (WERSJA ZOPTYMALIZOWANA)..." -ForegroundColor Green

$cameras = @("Domofon", "Front", "Polnoc", "Poludnie", "Taras")

foreach ($cam in $cameras) {
    $videoFile = "$($cam)_FULL.mp4"
    if (Test-Path $videoFile) {
        Write-Host "`n================ PRZETWARZAM: $cam ================" -ForegroundColor Cyan
        powershell -File "$PSScriptRoot\split_camera_ocr.ps1" -videoPath $videoFile
        
        # Kopiowanie wyników do katalogu produkcyjnego VIDEO
        $destDir = "C:\BlueIris_timelapse\VIDEO\$cam"
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        
        $dayFile = "$($cam)_DAY.mp4"
        $nightFile = "$($cam)_NIGHT.mp4"
        $jsonFile = "$($cam)_FULL_metadata.json"
        
        if (Test-Path $dayFile) { Copy-Item $dayFile -Destination "$destDir\$dayFile" -Force; Write-Host "   -> Skopiowano $dayFile do $destDir" -ForegroundColor Gray }
        if (Test-Path $nightFile) { Copy-Item $nightFile -Destination "$destDir\$nightFile" -Force; Write-Host "   -> Skopiowano $nightFile do $destDir" -ForegroundColor Gray }
        if (Test-Path $jsonFile) { Copy-Item $jsonFile -Destination "$destDir\$jsonFile" -Force; Write-Host "   -> Skopiowano $jsonFile do $destDir" -ForegroundColor Gray }
    } else {
        Write-Host "⚠️ Brak pliku: $videoFile" -ForegroundColor Yellow
    }
}

Write-Host "`nWSZYSTKIE KAMERY ZOSTAŁY POMYŚLNIE PODZIELONE!" -ForegroundColor Green
