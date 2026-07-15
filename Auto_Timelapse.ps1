# --- KONFIGURACJA ---
$SourcePath  = "C:\BlueIris_timelapse\JPEG"   # 📥 Źródło zdjęć
$StoragePath = "C:\BlueIris_timelapse\VIDEO"  # 📤 Tu tworzymy filmy (Lokalnie)
$LogPath     = "C:\BlueIris_timelapse\LOGS"   # 📝 Logi
$Quality     = 19                             # Jakość
$FPS         = 30                             # Prędkość

# KONFIGURACJA RCLONE
$RcloneExe    = "C:\Tools\rclone\rclone.exe"   
$RcloneRemote = "drive_timelapse:/"            
$RemoteFolder = "VIDEO"                        

# --- WAŻNE: Wklej tu ścieżkę z komendy 'rclone config file' ---
$RcloneConfig = "C:\Users\michal\AppData\Roaming\rclone\rclone.conf" 

# Szukanie FFmpeg
$ffmpegPath = "C:\Tools\ffmpeg\bin\ffmpeg.exe"
if (-not (Test-Path $ffmpegPath)) { $ffmpegPath = "C:\Tools\ffmpeg\ffmpeg.exe" }
if (-not (Test-Path $ffmpegPath)) { $ffmpegPath = "$PSScriptRoot\ffmpeg.exe" }
if (-not (Test-Path $ffmpegPath)) { Write-Error "❌ BŁĄD: Brak FFmpeg!"; exit }

# Data i czas
$CurrentDate = Get-Date -Format "yyyy-MM-dd"
$CurrentYear = Get-Date -Format "yyyy"
$TimeStamp   = Get-Date -Format "HH-mm-ss"

# Wyliczanie poniedziałku bieżącego tygodnia (zapobiega nadpisywaniu plików tygodniowych w ciągu tygodnia)
$dt = Get-Date
$dayOfWeek = [int]$dt.DayOfWeek
$daysToSubtract = if ($dayOfWeek -eq 0) { 6 } else { $dayOfWeek - 1 }
$MondayDate = $dt.AddDays(-$daysToSubtract).ToString("yyyy-MM-dd")

# Weryfikacja ścieżek
if (-not (Test-Path $SourcePath)) { Write-Error "❌ BŁĄD: Brak folderu źródłowego $SourcePath"; exit }
if (-not (Test-Path $LogPath))    { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
if (-not (Test-Path $RcloneExe))  { Write-Error "❌ BŁĄD: Brak pliku rclone.exe"; exit }
if (-not (Test-Path $RcloneConfig)){ Write-Error "❌ BŁĄD: Brak pliku konfiguracyjnego rclone.conf w: $RcloneConfig"; exit }

# Funkcja obliczająca wschód/zachód słońca dla Polski (szerokość ok. 52°N)
function Get-SunriseSunset {
    param([datetime]$Date)
    $day = $Date.DayOfYear
    # Wschód słońca: Średnia 6:00, waha się od 4:15 do 7:45
    $sunriseHour = 6.0 + 1.75 * [Math]::Cos(2 * [Math]::PI * ($day - 355) / 365)
    # Zachód słońca: Średnia 18:15, waha się od 15:30 do 21:00
    $sunsetHour = 18.25 - 2.75 * [Math]::Cos(2 * [Math]::PI * ($day - 355) / 365)
    
    return [PSCustomObject]@{
        Sunrise = $Date.Date.AddHours($sunriseHour)
        Sunset  = $Date.Date.AddHours($sunsetHour)
    }
}

# --- GŁÓWNA PĘTLA ---
$folders = Get-ChildItem -Path $SourcePath -Directory

foreach ($folder in $folders) {
    $CameraName = $folder.Name
    Write-Host "`n🎥 Przetwarzam kamerę: $CameraName" -ForegroundColor Cyan

    # --- 1. ŚCIEŻKI LOKALNE ---
    $ArchiveDir = "$StoragePath\$CameraName\$CurrentYear"
    if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
    
    # Pliki list plików dla FFmpeg
    $ListFileFull  = "$($folder.FullName)\files_list_full.txt"
    $ListFileDay   = "$($folder.FullName)\files_list_day.txt"
    $ListFileNight = "$($folder.FullName)\files_list_night.txt"
    
    # Definicja typów timelapsów (pliki tygodniowe oparte o poniedziałek)
    $timelapseTypes = @(
        @{
            Name       = "FULL"
            ListFile   = $ListFileFull
            Weekly     = "$ArchiveDir\$($MondayDate)_Week.mp4"
            Full       = "$StoragePath\$CameraName\$($CameraName)_FULL.mp4"
            Temp       = "$StoragePath\$CameraName\Temp_Update_Full.mp4"
            CloudName  = "$($CameraName)_FULL.mp4"
            CloudWeek  = "$($MondayDate)_Week.mp4"
            Success    = $false
        },
        @{
            Name       = "DAY"
            ListFile   = $ListFileDay
            Weekly     = "$ArchiveDir\$($MondayDate)_Week_Day.mp4"
            Full       = "$StoragePath\$CameraName\$($CameraName)_DAY.mp4"
            Temp       = "$StoragePath\$CameraName\Temp_Update_Day.mp4"
            CloudName  = "$($CameraName)_DAY.mp4"
            CloudWeek  = "$($MondayDate)_Week_Day.mp4"
            Success    = $false
        },
        @{
            Name       = "NIGHT"
            ListFile   = $ListFileNight
            Weekly     = "$ArchiveDir\$($MondayDate)_Week_Night.mp4"
            Full       = "$StoragePath\$CameraName\$($CameraName)_NIGHT.mp4"
            Temp       = "$StoragePath\$CameraName\Temp_Update_Night.mp4"
            CloudName  = "$($CameraName)_NIGHT.mp4"
            CloudWeek  = "$($MondayDate)_Week_Night.mp4"
            Success    = $false
        }
    )

    $MergeList  = "$($folder.FullName)\merge_list.txt"
    $LogOut     = "$LogPath\$($CurrentDate)_$($TimeStamp)_$($CameraName)_OUT.log"
    $LogErr     = "$LogPath\$($CurrentDate)_$($TimeStamp)_$($CameraName)_ERR.log"

    # --- KROK 1: SEGREGACJA ZDJĘĆ I GENEROWANIE TYGODNIÓWEK ---
    $files = Get-ChildItem -Path $folder.FullName -Filter "*.jpg" | Sort-Object Name
    
    if ($files.Count -eq 0) {
        Write-Host "   ⚠️ Brak nowych zdjęć. Pomijam." -ForegroundColor DarkGray
        Add-Content -Path $LogOut -Value "Brak nowych zdjęć dla kamery $CameraName"
        continue
    }

    # Wczytujemy istniejące metadane, aby zapobiec duplikatom klatek po awarii
    $metadataPath = "$StoragePath\$CameraName\$($CameraName)_FULL_metadata.json"
    $existingTimestamps = @{}
    if (Test-Path $metadataPath) {
        try {
            $existingList = Get-Content $metadataPath -Raw | ConvertFrom-Json
            if ($existingList) {
                foreach ($item in $existingList) {
                    $existingTimestamps[$item.timestamp] = $true
                }
            }
        } catch {}
    }

    $nameRegex = '\.(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})\.jpg$'
    $validFiles = @()
    $duplicateDeleted = 0

    foreach ($file in $files) {
        $fileTime = $file.LastWriteTime
        if ($file.Name -match $nameRegex) {
            try {
                $fileTime = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
            } catch {}
        }
        
        $tsStr = $fileTime.ToString("yyyy-MM-dd HH:mm")
        
        if ($existingTimestamps.ContainsKey($tsStr)) {
            # Klatka o tym czasie została już wcześniej włączona do wideo i bazy JSON!
            # Usuwamy plik źródłowy, ponieważ nie jest nam już potrzebny
            try { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue; $duplicateDeleted++ } catch {}
            continue
        }
        
        $validFiles += @{ File = $file; Time = $fileTime }
    }

    if ($duplicateDeleted -gt 0) {
        Write-Host "   🧹 Wykryto i usunięto $duplicateDeleted wcześniej przetworzonych klatek." -ForegroundColor Yellow
    }

    if ($validFiles.Count -eq 0) {
        Write-Host "   ⚠️ Brak nowych klatek do doklejenia. Przechodzę do ponownego uploadu Rclone." -ForegroundColor Yellow
        # Jeśli brak nowych klatek, to oznacza, że poprzednia próba dodała je do plików lokalnych, 
        # ale mogła wywalić się na uploadzie Rclone. Oznaczamy sukces, aby Rclone podjął ponowną próbę wysłania aktualnych plików.
        foreach ($type in $timelapseTypes) {
            $type.Success = $true
        }
        $swFull  = [System.IO.StreamWriter]::new($ListFileFull); $swFull.Close()
        $swDay   = [System.IO.StreamWriter]::new($ListFileDay); $swDay.Close()
        $swNight = [System.IO.StreamWriter]::new($ListFileNight); $swNight.Close()
    } else {
        Write-Host "   1️⃣ Segregacja zdjęć ($($validFiles.Count) sztuk)..." -NoNewline
        
        $swFull  = [System.IO.StreamWriter]::new($ListFileFull)
        $swDay   = [System.IO.StreamWriter]::new($ListFileDay)
        $swNight = [System.IO.StreamWriter]::new($ListFileNight)
        
        $dayCount = 0
        $nightCount = 0
        
        foreach ($item in $validFiles) {
            $file = $item.File
            $fileTime = $item.Time
            
            $swFull.WriteLine("file '$($file.Name)'")
            
            $sun = Get-SunriseSunset -Date $fileTime
            
            if ($fileTime -ge $sun.Sunrise -and $fileTime -le $sun.Sunset) {
                $swDay.WriteLine("file '$($file.Name)'")
                $dayCount++
            } else {
                $swNight.WriteLine("file '$($file.Name)'")
                $nightCount++
            }
        }
        
        $swFull.Close()
        $swDay.Close()
        $swNight.Close()
    }
    
    Write-Host " OK! (Dzień: $dayCount, Noc: $nightCount)" -ForegroundColor Green

    # Generowanie wideo dla każdego typu (o ile ma zdjęcia)
    foreach ($type in $timelapseTypes) {
        $imgCount = if ($type.Name -eq "FULL") { $files.Count } elseif ($type.Name -eq "DAY") { $dayCount } else { $nightCount }
        
        if ($imgCount -eq 0) {
            Write-Host "   ⚠️ Typ $($type.Name): Brak zdjęć w tym okresie. Pomijam." -ForegroundColor Yellow
            continue
        }

        $listPath = $type.ListFile
        $weeklyPath = $type.Weekly
        
        if (Test-Path $weeklyPath) {
            # Plik tygodniowy już istnieje - doklejamy nowe klatki!
            Write-Host "   🎥 Doklejanie do wideo tygodniowego $($type.Name)..." -NoNewline
            $tempNewPath = "$StoragePath\$CameraName\Temp_New_Week_$($type.Name).mp4"
            $tempMergePath = "$StoragePath\$CameraName\Temp_Merge_Week_$($type.Name).mp4"
            
            $argsGen = "-y -r $FPS -f concat -safe 0 -i `"$listPath`" -c:v h264_nvenc -preset p6 -rc:v vbr_hq -cq:v $Quality -b:v 0 -pix_fmt yuv420p `"$tempNewPath`""
            $procGen = Start-Process -FilePath $ffmpegPath -ArgumentList $argsGen -WorkingDirectory $folder.FullName -NoNewWindow -Wait -PassThru -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
            
            if ($procGen.ExitCode -eq 0 -and (Test-Path $tempNewPath)) {
                $swM = [System.IO.StreamWriter]::new($MergeList)
                $swM.WriteLine("file '$weeklyPath'")
                $swM.WriteLine("file '$tempNewPath'")
                $swM.Close()
                
                $argsMerge = "-y -f concat -safe 0 -i `"$MergeList`" -c copy `"$tempMergePath`""
                $procMerge = Start-Process -FilePath $ffmpegPath -ArgumentList $argsMerge -NoNewWindow -Wait -PassThru -RedirectStandardOutput "NUL" -RedirectStandardError $LogErr
                
                if ($procMerge.ExitCode -eq 0 -and (Test-Path $tempMergePath)) {
                    Remove-Item $weeklyPath -Force
                    Move-Item $tempMergePath $weeklyPath
                    Write-Host " OK! (Doklejono)" -ForegroundColor Green
                    $type.Success = $true
                } else {
                    Write-Host " BŁĄD ŁĄCZENIA TYGODNIÓWKI!" -ForegroundColor Red
                    $type.Success = $false
                }
                if (Test-Path $tempNewPath) { Remove-Item $tempNewPath -Force }
                if (Test-Path $tempMergePath) { Remove-Item $tempMergePath -Force }
            } else {
                Write-Host " BŁĄD NOWYCH KLATEK!" -ForegroundColor Red
                $type.Success = $false
            }
        } else {
            # Plik tygodniowy nie istnieje - tworzymy nowy
            Write-Host "   🎥 Generowanie nowego wideo tygodniowego $($type.Name)..." -NoNewline
            $argsGen = "-y -r $FPS -f concat -safe 0 -i `"$listPath`" -c:v h264_nvenc -preset p6 -rc:v vbr_hq -cq:v $Quality -b:v 0 -pix_fmt yuv420p `"$weeklyPath`""
            $procGen = Start-Process -FilePath $ffmpegPath -ArgumentList $argsGen -WorkingDirectory $folder.FullName -NoNewWindow -Wait -PassThru -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
            
            if ($procGen.ExitCode -eq 0 -and (Test-Path $weeklyPath) -and (Get-Item $weeklyPath).Length -gt 1000) {
                Write-Host " OK!" -ForegroundColor Green
                $type.Success = $true
            } else {
                Write-Host " BŁĄD!" -ForegroundColor Red
                $type.Success = $false
            }
        }
    }

    # --- KROK 2: AKTUALIZACJA PLIKÓW zbiorczych (FULL, DAY, NIGHT) ---
    $AllMergeSuccess = $true

    foreach ($type in $timelapseTypes) {
        if (-not $type.Success) { continue }
        
        Write-Host "   🔄 Aktualizacja pliku $($type.Name)..." -NoNewline
        Add-Content -Path $LogOut -Value "`n--- ŁĄCZENIE (MERGE) dla $($type.Name) ---"
        
        $weeklyPath = $type.Weekly
        $fullPath = $type.Full
        $tempPath = $type.Temp
        
        if (Test-Path $fullPath) {
            $swM = [System.IO.StreamWriter]::new($MergeList)
            $swM.WriteLine("file '$fullPath'")
            $swM.WriteLine("file '$weeklyPath'")
            $swM.Close()
            
            $argsMerge = "-y -f concat -safe 0 -i `"$MergeList`" -c copy `"$tempPath`""
            $LogMergeErr = "$LogPath\$($CurrentDate)_$($TimeStamp)_$($CameraName)_$($type.Name)_MERGE_ERR.log"
            
            $procMerge = Start-Process -FilePath $ffmpegPath -ArgumentList $argsMerge -NoNewWindow -Wait -PassThru -RedirectStandardOutput "NUL" -RedirectStandardError $LogMergeErr
            
            if ($procMerge.ExitCode -eq 0) {
                Remove-Item $fullPath -Force
                Move-Item $tempPath $fullPath
                Write-Host " OK! (Doklejono)" -ForegroundColor Green
                Add-Content -Path $LogOut -Value "Sukces łączenia $($type.Name)."
            } else {
                Write-Host " Błąd łączenia!" -ForegroundColor Red
                Add-Content -Path $LogOut -Value "BŁĄD łączenia $($type.Name)! Zobacz: $LogMergeErr"
                if (Test-Path $tempPath) { Remove-Item $tempPath }
                $AllMergeSuccess = $false
            }
        } else {
            Copy-Item $weeklyPath $fullPath
            Write-Host " OK! (Utworzono nowy)" -ForegroundColor Green
            Add-Content -Path $LogOut -Value "Utworzono nowy plik $($type.Name)."
        }
    }

    # --- KROK 2.5: AKTUALIZACJA METADANYCH JSON ---
    $fullType = $timelapseTypes | Where-Object { $_.Name -eq "FULL" }
    if ($fullType -and $fullType.Success -and $AllMergeSuccess) {
        $metadataPath = "$StoragePath\$CameraName\$($CameraName)_FULL_metadata.json"
        
        $metadataList = @()
        if (Test-Path $metadataPath) {
            try {
                $metadataList = Get-Content $metadataPath -Raw | ConvertFrom-Json
            } catch {
                Write-Host "   ⚠️ Nie udalo sie wczytac pliku metadanych. Tworze nowy." -ForegroundColor Yellow
            }
        }
        
        $lastFrameIndex = 0
        if ($metadataList.Count -gt 0) {
            $lastFrameIndex = [int]$metadataList[-1].frame
        }
        
        foreach ($file in $files) {
            $lastFrameIndex++
            
            $fileTime = $file.LastWriteTime
            if ($file.Name -match $nameRegex) {
                try {
                    $fileTime = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
                } catch {}
            }
            
            $sun = Get-SunriseSunset -Date $fileTime
            $isDay = $false
            if ($fileTime -ge $sun.Sunrise -and $fileTime -le $sun.Sunset) {
                $isDay = $true
            }
            
            $metadataItem = [Ordered]@{
                frame = $lastFrameIndex
                timestamp = $fileTime.ToString("yyyy-MM-dd HH:mm")
                isDay = $isDay
            }
            $metadataList += [PSCustomObject]$metadataItem
        }
        
        $metadataJson = ConvertTo-Json -InputObject $metadataList -Compress -Depth 5
        $metadataJson | Out-File -FilePath $metadataPath -Encoding utf8
        Write-Host "   📝 Zaktualizowano metadane klatek w: $metadataPath" -ForegroundColor Green
    }

    # --- KROK 3: BACKUP PRZEZ RCLONE ---
    $AllBackupSuccess = $true

    foreach ($type in $timelapseTypes) {
        if (-not $type.Success) { continue }
        
        Write-Host "   ☁️ Rclone Upload dla $($type.Name)..." -NoNewline
        Add-Content -Path $LogOut -Value "Rozpoczynam upload Rclone dla $($type.Name)..."
        
        $weeklyPath = $type.Weekly
        $fullPath = $type.Full
        
        $CloudPathYear = "$RcloneRemote$RemoteFolder/$CameraName/$CurrentYear"
        $CloudPathRoot = "$RcloneRemote$RemoteFolder/$CameraName"

        $arg1 = "copyto `"$weeklyPath`" `"$CloudPathYear/$($type.CloudWeek)`" --config `"$RcloneConfig`""
        $p1 = Start-Process -FilePath $RcloneExe -ArgumentList $arg1 -NoNewWindow -Wait -PassThru
        
        $arg2 = "copyto `"$fullPath`" `"$CloudPathRoot/$($type.CloudName)`" --config `"$RcloneConfig`""
        $p2 = Start-Process -FilePath $RcloneExe -ArgumentList $arg2 -NoNewWindow -Wait -PassThru

        if ($type.Name -eq "FULL") {
            $metadataPath = "$StoragePath\$CameraName\$($CameraName)_FULL_metadata.json"
            if (Test-Path $metadataPath) {
                $argJson = "copyto `"$metadataPath`" `"$CloudPathRoot/$($CameraName)_FULL_metadata.json`" --config `"$RcloneConfig`""
                Start-Process -FilePath $RcloneExe -ArgumentList $argJson -NoNewWindow -Wait | Out-Null
            }
        }

        if ($p1.ExitCode -eq 0 -and $p2.ExitCode -eq 0) {
             Write-Host " OK!" -ForegroundColor Green
             Add-Content -Path $LogOut -Value "Rclone Upload $($type.Name): SUKCES"
        } else {
             Write-Host " BŁĄD UPLOADU!" -ForegroundColor Red
             Add-Content -Path $LogOut -Value "Rclone Upload $($type.Name): BŁĄD (Kod $($p1.ExitCode) / $($p2.ExitCode))"
             $AllBackupSuccess = $false
        }
    }

    # --- KROK 4: CZYSZCZENIE ZDJĘĆ ---
    # Usuwamy oryginalne zdjęcia tylko jeśli:
    # 1. Wszystkie zaplanowane tygodniówki wygenerowały się poprawnie (Success)
    # 2. Wszystkie operacje Merge się udały (AllMergeSuccess)
    # 3. Wszystkie backupy Rclone przeszły pomyślnie (AllBackupSuccess)
    $ActiveTypes = $timelapseTypes | Where-Object { $_.Success -eq $true }
    $ExpectedSuccessCount = $ActiveTypes.Count
    
    if ($ExpectedSuccessCount -gt 0 -and $AllMergeSuccess -and $AllBackupSuccess) {
        Write-Host "   🧹 Usuwanie starych zdjęć..." -NoNewline
        Add-Content -Path $LogOut -Value "`n--- USUWANIE ZDJĘĆ ---"
        $deletedCount = 0
        foreach ($file in $files) { 
            try { Remove-Item $file.FullName -ErrorAction Stop; $deletedCount++ } catch {}
        }
        Add-Content -Path $LogOut -Value "Usunięto plików: $deletedCount"
        Write-Host " Wyczyszczono ($deletedCount)." -ForegroundColor Yellow
    } else {
        Write-Host "   ⚠️ POMINIĘTO USUWANIE! (Problem z merge/backupem)" -ForegroundColor Magenta
        Add-Content -Path $LogOut -Value "NIE USUNIĘTO ZDJĘĆ. MergeSuccess=$AllMergeSuccess, BackupSuccess=$AllBackupSuccess"
    }

    # Sprzątanie list plików
    foreach ($type in $timelapseTypes) {
        if (Test-Path $type.ListFile) { Remove-Item $type.ListFile }
    }
    if (Test-Path $MergeList) { Remove-Item $MergeList }
}

Write-Host "`n✅ ZADANIE ZAKOŃCZONE." -ForegroundColor Magenta
Start-Sleep -Seconds 5