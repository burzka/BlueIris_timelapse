param(
    [string]$videoPath = "Front_FULL.mp4",
    [string]$outDay = $null,
    [string]$outNight = $null,
    [string]$importMetadataPath = $null,
    [switch]$onlyOcr = $false
)

$ffmpegExe = "C:\Tools\ffmpeg\ffmpeg.exe"
$ocrScript = "$PSScriptRoot\ocr_gpu.py"
$tempCropDir = "temp_crop_$([System.IO.Path]::GetFileNameWithoutExtension($videoPath))"
$TwilightOffsetMinutes = 45 # Offset dla zmierzchu/switu (kamera widzi dzien dluzej)

if ([string]::IsNullOrEmpty($outDay)) {
    $outDay = $videoPath -replace "_FULL\.mp4$", "_DAY.mp4"
    if ($outDay -eq $videoPath) { $outDay = "DAY_" + $videoPath }
}
if ([string]::IsNullOrEmpty($outNight)) {
    $outNight = $videoPath -replace "_FULL\.mp4$", "_NIGHT.mp4"
    if ($outNight -eq $videoPath) { $outNight = "NIGHT_" + $videoPath }
}

# 0. Wykrywanie rozdzielczosci i dobieranie cropa
Write-Host "KROK 0: Wykrywanie rozdzielczosci wideo..." -ForegroundColor Cyan
$ffprobeOut = & $ffmpegExe -i $videoPath 2>&1
$resLine = $ffprobeOut | Select-String -Pattern "Video:.* (\d{3,4})x(\d{3,4})"
$width = 3840
$height = 2160

if ($resLine -and $resLine.Matches.Count -gt 0) {
    $width = [int]$resLine.Matches[0].Groups[1].Value
    $height = [int]$resLine.Matches[0].Groups[2].Value
    Write-Host "   Wykryto rozdzielczosc: $($width)x$($height)" -ForegroundColor Green
} else {
    Write-Host "   Nie udalo sie wykryc rozdzielczosci. Uzywam domyslnej 3840x2160 (4K)" -ForegroundColor Yellow
}

if ($width -eq 1920) {
    $cropExpr = "crop=600:100:5:0"
} else {
    $cropExpr = "crop=1200:130:10:0"
}

# Sun position helper (wspolrzedne: Bialystok 53.13N, 23.16E)
# Wzor sinusoidalny skalibrowany na dane astronomiczne dla Bialegostoku:
#   Zima (21 XII, CET):  wschod ~7:52, zachod ~15:06
#   Lato (21 VI, CEST):  wschod ~4:08, zachod ~21:04
# Uwaga: przejscie CET/CEST powoduje blad ~30 min w okolicy rownonocy,
#         ale offset zmierzchu 45 min go absorbuje.
function Get-SunriseSunset {
    param([datetime]$Date)
    $day = $Date.DayOfYear
    $angle = 2 * [Math]::PI * ($day - 355) / 365
    $sunriseHour = 6.0   + 1.867 * [Math]::Cos($angle)
    $sunsetHour  = 18.083 - 2.983 * [Math]::Cos($angle)
    
    return [PSCustomObject]@{
        Sunrise = $Date.Date.AddHours($sunriseHour)
        Sunset  = $Date.Date.AddHours($sunsetHour)
    }
}

# Zainicjalizowanie flag i tablic
$frameFlags = @()
$metadataList = @()

if (-not [string]::IsNullOrEmpty($importMetadataPath)) {
    Write-Host "IMPORT METADANYCH: Wczytuje skorygowane dane z pliku $importMetadataPath..." -ForegroundColor Green
    $metadataList = Get-Content $importMetadataPath -Raw | ConvertFrom-Json
    foreach ($item in $metadataList) {
        $frameFlags += $item.isDay
    }
    $totalFrames = $metadataList.Count
    Write-Host "   Wczytano $totalFrames klatek." -ForegroundColor Green
} else {
    # Sciezka do cache OCR (obok pliku wideo, trwaly miedzy uruchomieniami)
    $ocrCacheFile = "$([System.IO.Path]::GetFileNameWithoutExtension($videoPath))_ocr_cache.json"

    if (Test-Path $ocrCacheFile) {
        # --- CACHE ISTNIEJE: pomijamy FFmpeg i Ollame ---
        Write-Host "KROK 1: Znaleziono cache OCR: $ocrCacheFile - pomijam ekstrakcje i OCR!" -ForegroundColor Green
        $ocrResults = Get-Content $ocrCacheFile -Raw | ConvertFrom-Json

        # Potrzebujemy totalFrames - liczymy klucze w JSON
        $ocrKeys = @($ocrResults.PSObject.Properties.Name)
        $totalFrames = $ocrKeys.Count
        # Tworzymy wirtualna liste plikow (potrzebna do petli glownej)
        $files = $ocrKeys | Sort-Object | ForEach-Object { [PSCustomObject]@{ Name = $_ } }
        Write-Host "   Wczytano $totalFrames wynikow OCR z cache." -ForegroundColor Green
    } else {
        # --- BRAK CACHE: pelne przetwarzanie FFmpeg + Ollama ---
        # 1. Create temp directory
        if (-not (Test-Path $tempCropDir)) { New-Item -ItemType Directory -Path $tempCropDir | Out-Null }

        Write-Host "KROK 1: Wyodrebnianie wycinkow daty z klatek wideo ($cropExpr)..." -ForegroundColor Cyan
        & $ffmpegExe -y -i $videoPath -vf "$cropExpr" -q:v 2 "$tempCropDir\frame_%05d.jpg" 2>&1 | Out-Null

        $files = Get-ChildItem -Path $tempCropDir -Filter "frame_*.jpg" | Sort-Object Name
        $totalFrames = $files.Count
        Write-Host "   Pomyslnie wyodrebniono $totalFrames wycinkow." -ForegroundColor Green

        if ($totalFrames -eq 0) {
            Write-Error "Brak klatek do analizy."
            if (Test-Path $tempCropDir) { Remove-Item -Path $tempCropDir -Recurse -Force }
            exit
        }

        # 1B. Wykonanie OCR w jednym kroku (wielowatkowo)
        Write-Host "KROK 1B: Uruchamianie wielowatkowego przetwarzania OCR..." -ForegroundColor Cyan
        $ocrTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $env:PYTHONIOENCODING="utf-8"
        python $ocrScript $tempCropDir
        $ocrTimer.Stop()
        Write-Host "   OCR ukonczony w $($ocrTimer.Elapsed.TotalSeconds.ToString('F2')) s." -ForegroundColor Green

        $jsonFile = Join-Path $tempCropDir "ocr_results.json"
        if (-not (Test-Path $jsonFile)) {
            Write-Error "Blad: Brak pliku ocr_results.json."
            if (Test-Path $tempCropDir) { Remove-Item -Path $tempCropDir -Recurse -Force }
            exit
        }
        $ocrResults = Get-Content $jsonFile -Raw | ConvertFrom-Json

        # Zapisujemy cache OCR obok filmu (trwaly pomiedzy uruchomieniami)
        Copy-Item -Path $jsonFile -Destination $ocrCacheFile -Force
        Write-Host "   Zapisano cache OCR do: $ocrCacheFile" -ForegroundColor Green

        # Sprzatamy tymczasowy katalog z cropami (juz niepotrzebny)
        if (Test-Path $tempCropDir) { Remove-Item -Path $tempCropDir -Recurse -Force }
    }

Write-Host "KROK 2: Predykcyjna analiza czasu klatek..." -ForegroundColor Cyan
$regex = '(\d{2})[-./\s](\d{2})[-./\s](\d{4})(?:\s+[a-zA-Z]{3,4})?\s+(\d{2})(?::|\s)?(\d{2})?'
$frameFlags = @()

# 2A. Parsowanie wszystkich wynikow OCR do prostej mapy (godzina + minuta + data jesli mozliwa)
$ocrParsed = @{}
$ocrSuccessCount = 0
for ($idx = 0; $idx -lt $totalFrames; $idx++) {
    $fName = $files[$idx].Name
    $itemOcr = $ocrResults.$fName
    if ($itemOcr -and $itemOcr.text -match $regex) {
        try {
            $pDay = [int]$Matches[1]
            $pMonth = [int]$Matches[2]
            $pYear = [int]$Matches[3]
            $pHour = [int]$Matches[4]
            $pMin = if ($Matches[5]) { [int]$Matches[5] } else { 0 }

            $parsedDate = $null
            try { $parsedDate = [datetime]::new($pYear, $pMonth, $pDay) } catch {}

            $ocrParsed[$fName] = @{
                Hour   = $pHour
                Minute = $pMin
                Date   = $parsedDate
            }
            $ocrSuccessCount++
        } catch {}
    }
}
Write-Host "   Sparsowano $ocrSuccessCount odczytow OCR z $totalFrames klatek." -ForegroundColor Gray

# 2B. Synchronizacja czasu startowego z pierwszych klatek
$currentDateTime = [datetime]"2025-11-04 13:00"
for ($startIdx = 0; $startIdx -lt [Math]::Min(10, $totalFrames); $startIdx++) {
    $fName = $files[$startIdx].Name
    $ocr = $ocrParsed[$fName]
    if ($ocr -and $ocr.Date) {
        $currentDateTime = $ocr.Date.AddHours($ocr.Hour).AddMinutes($ocr.Minute).AddHours(-$startIdx)
        Write-Host "   [OCR] Zsynchronizowano czas startowy z klatki $($startIdx+1): $($currentDateTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
        break
    }
}

# 2C. Glowna petla predykcyjna
# Zasada: data NIGDY nie pochodzi bezposrednio z OCR.
#   - Data jest obliczana z predykcji (+1h/klatke, polnoc = nowy dzien)
#   - OCR koryguje GODZINE (±4h, wiarygodna)
#   - OCR WALIDUJE date (max ±3 dni od predykcji), ale nie narzuca jej slepо
$metadataList = @()
$previousDateTime = $currentDateTime

for ($i = 0; $i -lt $totalFrames; $i++) {
    $file = $files[$i]

    # Predykcja: +1 godzina na klatke (naturalnie przekracza polnoc -> nowy dzien)
    if ($i -gt 0) {
        $currentDateTime = $currentDateTime.AddHours(1)
    }

    $fName = $file.Name
    $ocr = $ocrParsed[$fName]
    $ocrSync = $false

    if ($ocr) {
        $ocrHour = $ocr.Hour
        $ocrMin = $ocr.Minute
        $predictedHour = $currentDateTime.Hour

        # Roznica godzin z uwzglednieniem przekroczenia polnocy (wrap-around)
        $hourDiff = $ocrHour - $predictedHour
        if ($hourDiff -gt 12)  { $hourDiff -= 24 }
        if ($hourDiff -lt -12) { $hourDiff += 24 }

        if ([Math]::Abs($hourDiff) -le 4) {
            # --- NORMALNA KOREKTA GODZINY ---
            # Godzina z OCR bliska predykcji -> data z predykcji jest PEWNA
            # Korygujemy TYLKO godzine i minute, data pozostaje z predykcji
            $currentDateTime = $currentDateTime.AddHours($hourDiff)
            $currentDateTime = $currentDateTime.Date.AddHours($currentDateTime.Hour).AddMinutes($ocrMin)
            $ocrSync = $true
        } elseif ($ocr.Date) {
            # --- DUZA ROZNICA GODZIN -> mozliwa przerwa w nagrywaniu ---
            $dateDiff = ($ocr.Date - $currentDateTime.Date).Days
            if ($dateDiff -ge 0 -and $dateDiff -le 3) {
                # Legitymowa przerwa (np. 2-dniowa dziura), akceptujemy pelny czas OCR
                $currentDateTime = $ocr.Date.AddHours($ocrHour).AddMinutes($ocrMin)
                $ocrSync = $true
                Write-Host "   [PRZERWA] Klatka $($i+1): wykryto przerwe $dateDiff dni, sync OCR: $($currentDateTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Magenta
            }
            # dateDiff > 3 -> halucynacja, ignorujemy calkowicie
        }
        # Jesli |hourDiff| > 4 i brak daty OCR -> ignorujemy, uzywamy czystej predykcji
    }

    # Zabezpieczenie monotonicznosci: czas nie moze cofnac sie
    if ($currentDateTime -lt $previousDateTime) {
        $currentDateTime = $previousDateTime.AddHours(1)
    }
    $previousDateTime = $currentDateTime

    # Wyznaczenie wschodu/zachodu slonca
    $sun = Get-SunriseSunset -Date $currentDateTime.Date
    $camSunrise = $sun.Sunrise.AddMinutes(-$TwilightOffsetMinutes)
    $camSunset  = $sun.Sunset.AddMinutes($TwilightOffsetMinutes)

    $isDay = ($currentDateTime -ge $camSunrise -and $currentDateTime -le $camSunset)

    $metadataItem = @{
        frame = $i + 1
        timestamp = $currentDateTime.ToString("yyyy-MM-dd HH:mm")
        isDay = $isDay
    }
    $metadataList += $metadataItem
    $frameFlags += $isDay

    if ($i % 300 -eq 0 -or $i -eq ($totalFrames - 1) -or $ocrSync) {
        $statusStr = if ($isDay) { "DZIEN" } else { "NOC" }
        $syncFlag = if ($ocrSync) { "[OCR SYNC] " } else { "           " }
        Write-Host "   $($syncFlag)Klatka $($i+1)/${totalFrames}: $($currentDateTime.ToString('yyyy-MM-dd HH:mm')) -> $statusStr (Granice kamery: $($camSunrise.ToString('HH:mm')) - $($camSunset.ToString('HH:mm')))" -ForegroundColor Gray
    }
}

    # Zapisujemy surowe metadane do pliku JSON (tylko jeśli robiliśmy analizę klatek)
    if ([string]::IsNullOrEmpty($importMetadataPath)) {
        $rawMetadataFile = "$([System.IO.Path]::GetFileNameWithoutExtension($videoPath))_raw_metadata.json"
        $metadataJson = ConvertTo-Json -InputObject $metadataList -Compress -Depth 5
        $metadataJson | Out-File -FilePath $rawMetadataFile -Encoding utf8
        Write-Host "   Zapisano surowe metadane klatek do: $rawMetadataFile" -ForegroundColor Green

        if ($onlyOcr) {
            Write-Host "Tryb onlyOcr aktywny. Sprzatam katalog tymczasowy i koncze." -ForegroundColor Green
            if (Test-Path $tempCropDir) { Remove-Item -Path $tempCropDir -Recurse -Force }
            exit
        }
        
        # Jeśli nie importowaliśmy metadanych, zapisujemy je również jako standardowy plik metadanych
        $standardMetadataFile = "$([System.IO.Path]::GetFileNameWithoutExtension($videoPath))_metadata.json"
        $metadataJson | Out-File -FilePath $standardMetadataFile -Encoding utf8
    }
}

# 3. Create select filter expressions
Write-Host "KROK 3: Grupowanie klatek w zakresy..." -ForegroundColor Cyan

function Generate-SelectFilter {
    param(
        $flags,
        $targetFlag
    )
    $ranges = @()
    $inRange = $false
    $start = 0
    
    for ($i = 0; $i -lt $flags.Count; $i++) {
        $flag = $flags[$i]
        if ($flag -eq $targetFlag) {
            if (-not $inRange) {
                $start = $i
                $inRange = $true
            }
        } else {
            if ($inRange) {
                $ranges += @{ Start = $start; End = $i - 1 }
                $inRange = $false
            }
        }
    }
    if ($inRange) {
        $ranges += @{ Start = $start; End = $flags.Count - 1 }
    }
    
    if ($ranges.Count -eq 0) { return "0" }
    
    $exprs = @()
    foreach ($r in $ranges) {
        $s = $r.Start
        $e = $r.End
        if ($s -eq $e) {
            $exprs += "eq(n,$s)"
        } else {
            $exprs += "between(n,$s,$e)"
        }
    }
    return ($exprs -join "+")
}

$filterDayExpr = Generate-SelectFilter -flags $frameFlags -targetFlag $true
$filterNightExpr = Generate-SelectFilter -flags $frameFlags -targetFlag $false

$dayFilterFile = "filter_day_$([System.IO.Path]::GetFileNameWithoutExtension($videoPath)).txt"
$nightFilterFile = "filter_night_$([System.IO.Path]::GetFileNameWithoutExtension($videoPath)).txt"

"select='$filterDayExpr',setpts=N/FRAME_RATE/TB" | Out-File -FilePath $dayFilterFile -Encoding ascii
"select='$filterNightExpr',setpts=N/FRAME_RATE/TB" | Out-File -FilePath $nightFilterFile -Encoding ascii

Write-Host "   Utworzono pliki filtrow." -ForegroundColor Green

# 3.5. Zapisywanie metadanych klatek do JSON
$metadataFile = "$([System.IO.Path]::GetFileNameWithoutExtension($videoPath))_metadata.json"
$metadataJson = ConvertTo-Json -InputObject $metadataList -Compress -Depth 5
$metadataJson | Out-File -FilePath $metadataFile -Encoding utf8
Write-Host "   Zapisano metadane klatek do: $metadataFile" -ForegroundColor Green

# 4. Generate videos
Write-Host "KROK 4: Generowanie wideo za pomoca FFmpeg..." -ForegroundColor Cyan

Write-Host "   Generuje klip dzienny ($outDay)..." -ForegroundColor Gray
& $ffmpegExe -y -i $videoPath -filter_script:v $dayFilterFile -c:v h264_nvenc -preset p6 -cq:v 19 -an $outDay 2>&1 | Out-Null

Write-Host "   Generuje klip nocny ($outNight)..." -ForegroundColor Gray
& $ffmpegExe -y -i $videoPath -filter_script:v $nightFilterFile -c:v h264_nvenc -preset p6 -cq:v 19 -an $outNight 2>&1 | Out-Null

# 5. Clean up
Write-Host "KROK 5: Sprzatanie plikow tymczasowych..." -ForegroundColor Cyan
if (Test-Path $dayFilterFile) { Remove-Item -Path $dayFilterFile -Force }
if (Test-Path $nightFilterFile) { Remove-Item -Path $nightFilterFile -Force }

Write-Host "PROCES ZAKONCZONY POMYSLNIE DLA WIDEO $videoPath!" -ForegroundColor Green
Write-Host "   Wygenerowano:" -ForegroundColor Green
Write-Host "   - $outDay" -ForegroundColor Yellow
Write-Host "   - $outNight" -ForegroundColor Yellow
