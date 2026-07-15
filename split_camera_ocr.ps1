# Configuration
param(
    [string]$videoPath = "Front_FULL.mp4",
    [string]$outDay = $null,
    [string]$outNight = $null
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

# Sun position helper
function Get-SunriseSunset {
    param([datetime]$Date)
    $day = $Date.DayOfYear
    $sunriseHour = 6.0 + 1.75 * [Math]::Cos(2 * [Math]::PI * ($day - 355) / 365)
    $sunsetHour = 18.25 - 2.75 * [Math]::Cos(2 * [Math]::PI * ($day - 355) / 365)
    
    return [PSCustomObject]@{
        Sunrise = $Date.Date.AddHours($sunriseHour)
        Sunset  = $Date.Date.AddHours($sunsetHour)
    }
}

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

# 1B. Wykonanie OCR w jednym kroku (wielowątkowo)
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

Write-Host "KROK 2: Hybrydowa analiza czasu klatek..." -ForegroundColor Cyan
$regex = '(\d{2})[-./\s](\d{2})[-./\s](\d{4})(?:\s+[a-zA-Z]{3,4})?\s+(\d{2})(?::|\s)?(\d{2})?'
$frameFlags = @()

# Domyslny czas startowy (skrypt sprobuje odczytac faktyczny czas z pierwszej klatki)
$lastDate = [datetime]"2025-11-04"
$lastHour = 13
$lastMinute = 59
$currentDateTime = $lastDate.Date.AddHours($lastHour).AddMinutes($lastMinute)

# Szybka proba odczytania poczatku filmu z pierwszych 10 klatek w celu synchronizacji startowej
for ($startIdx = 0; $startIdx -lt [Math]::Min(10, $totalFrames); $startIdx++) {
    $fName = $files[$startIdx].Name
    $itemOcr = $ocrResults.$fName
    $text = ""
    if ($itemOcr) { $text = $itemOcr.text }
    if ($text -match $regex) {
        try {
            $pYear = [int]$Matches[3]
            $pMonth = [int]$Matches[2]
            $pDay = [int]$Matches[1]
            $pHour = [int]$Matches[4]
            $pMin = 59
            
            $parsedDate = [datetime]::new($pYear, $pMonth, $pDay)
            $currentDateTime = $parsedDate.AddHours($pHour).AddMinutes($pMin).AddHours(-$startIdx)
            $lastDate = $currentDateTime.Date
            $lastHour = $currentDateTime.Hour
            $lastMinute = $currentDateTime.Minute
            Write-Host "   [OCR] Zsynchronizowano czas startowy z klatki $($startIdx+1): $($currentDateTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
            break
        } catch {}
    }
}

$lastConfirmedDateTime = $currentDateTime
$metadataList = @()

for ($i = 0; $i -lt $totalFrames; $i++) {
    $file = $files[$i]
    
    # Hybrydowy przyrost czasu (dodajemy 1 godzine na klatke)
    if ($i -gt 0) {
        $currentDateTime = $currentDateTime.AddHours(1)
        $lastDate = $currentDateTime.Date
        $lastHour = $currentDateTime.Hour
        $lastMinute = $currentDateTime.Minute
    }

    # Pobranie OCR dla biezacej klatki
    $fName = $file.Name
    $itemOcr = $ocrResults.$fName
    $text = ""
    $brightness = 0
    if ($itemOcr) {
        $text = $itemOcr.text
        $brightness = $itemOcr.brightness
    }
    $ocrSync = $false
    
    if ($text -match $regex) {
        $dayStr = $Matches[1]
        $monthStr = $Matches[2]
        $yearStr = $Matches[3]
        $hourStr = $Matches[4]
        
        try {
            $pYear = [int]$yearStr
            $pMonth = [int]$monthStr
            $pDay = [int]$dayStr
            $parsedDate = [datetime]::new($pYear, $pMonth, $pDay)
            
            $parsedHour = [int]$hourStr
            $parsedMinute = 59
            
            # Reset/Synchronizacja biezacego czasu z rzeczywistym odczytem
            $newDateTime = $parsedDate.AddHours($parsedHour).AddMinutes($parsedMinute)
            
            # Monotoniczność czasu od ostatniej zatwierdzonej klatki
            if ($newDateTime -ge $lastConfirmedDateTime) {
                $timeDiffFromForecast = ($newDateTime - $currentDateTime).TotalHours
                # Dopuszczamy dowolne skoki w przód oraz małe korekty w tył do -2 godzin (duplikaty klatek)
                if ($timeDiffFromForecast -ge -2) {
                    $currentDateTime = $newDateTime
                    $lastDate = $parsedDate
                    $lastHour = $parsedHour
                    $lastMinute = $parsedMinute
                    $ocrSync = $true
                }
            }
        } catch {}
    }
    
    # Wyznaczenie wschodu/zachodu slonca
    $sun = Get-SunriseSunset -Date $lastDate
    $camSunrise = $sun.Sunrise.AddMinutes(-$TwilightOffsetMinutes)
    $camSunset  = $sun.Sunset.AddMinutes($TwilightOffsetMinutes)
    
    $isDayTheoretical = $false
    if ($currentDateTime -ge $camSunrise -and $currentDateTime -le $camSunset) {
        $isDayTheoretical = $true
    }
    
    $isDay = $isDayTheoretical
    
    $lastConfirmedDateTime = $currentDateTime
    
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
if (Test-Path $tempCropDir) { Remove-Item -Path $tempCropDir -Recurse -Force }
if (Test-Path $dayFilterFile) { Remove-Item -Path $dayFilterFile -Force }
if (Test-Path $nightFilterFile) { Remove-Item -Path $nightFilterFile -Force }

Write-Host "PROCES ZAKONCZONY POMYSLNIE DLA WIDEO $videoPath!" -ForegroundColor Green
Write-Host "   Wygenerowano:" -ForegroundColor Green
Write-Host "   - $outDay" -ForegroundColor Yellow
Write-Host "   - $outNight" -ForegroundColor Yellow
