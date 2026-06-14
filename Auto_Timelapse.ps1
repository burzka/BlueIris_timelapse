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
# (Upewnij się, że ta ścieżka jest poprawna!)

# Szukanie FFmpeg
$ffmpegPath = "C:\Tools\ffmpeg\bin\ffmpeg.exe"
if (-not (Test-Path $ffmpegPath)) { $ffmpegPath = "C:\Tools\ffmpeg\ffmpeg.exe" }
if (-not (Test-Path $ffmpegPath)) { $ffmpegPath = "$PSScriptRoot\ffmpeg.exe" }
if (-not (Test-Path $ffmpegPath)) { Write-Error "❌ BŁĄD: Brak FFmpeg!"; exit }

# Data i czas
$CurrentDate = Get-Date -Format "yyyy-MM-dd"
$CurrentYear = Get-Date -Format "yyyy"
$TimeStamp   = Get-Date -Format "HH-mm-ss"

# Weryfikacja
if (-not (Test-Path $SourcePath)) { Write-Error "❌ BŁĄD: Brak folderu źródłowego $SourcePath"; exit }
if (-not (Test-Path $LogPath))    { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
if (-not (Test-Path $RcloneExe))  { Write-Error "❌ BŁĄD: Brak pliku rclone.exe"; exit }
if (-not (Test-Path $RcloneConfig)){ Write-Error "❌ BŁĄD: Brak pliku konfiguracyjnego rclone.conf w: $RcloneConfig"; exit }

# --- GŁÓWNA PĘTLA ---
$folders = Get-ChildItem -Path $SourcePath -Directory

foreach ($folder in $folders) {
    $CameraName = $folder.Name
    Write-Host "`n🎥 Przetwarzam kamerę: $CameraName" -ForegroundColor Cyan

    # --- 1. ŚCIEŻKI LOKALNE ---
    $ArchiveDir = "$StoragePath\$CameraName\$CurrentYear"
    if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
    
    $WeeklyVideo = "$ArchiveDir\$($CurrentDate)_Week.mp4"
    $FullVideo   = "$StoragePath\$CameraName\$($CameraName)_FULL.mp4"
    $TempFull    = "$StoragePath\$CameraName\Temp_Update.mp4"
    
    # Pliki tymczasowe i logi
    $ListFile    = "$($folder.FullName)\files_list.txt"
    $MergeList   = "$($folder.FullName)\merge_list.txt"
    $LogOut      = "$LogPath\$($CurrentDate)_$($TimeStamp)_$($CameraName)_OUT.log"
    $LogErr      = "$LogPath\$($CurrentDate)_$($TimeStamp)_$($CameraName)_ERR.log"

    # --- KROK 1: GENEROWANIE TYGODNIÓWKI ---
    $files = Get-ChildItem -Path $folder.FullName -Filter "*.jpg" | Sort-Object Name
    
    if ($files.Count -eq 0) {
        Write-Host "   ⚠️ Brak nowych zdjęć. Pomijam." -ForegroundColor DarkGray
        Add-Content -Path $LogOut -Value "Brak nowych zdjęć dla kamery $CameraName"
        continue
    }

    Write-Host "   1️⃣ Generowanie wideo tygodniowego ($($files.Count) zdjęć)..." -NoNewline
    $sw = [System.IO.StreamWriter]::new($ListFile)
    foreach ($file in $files) { $sw.WriteLine("file '$($file.Name)'") }
    $sw.Close()

    $argsGen = "-y -r $FPS -f concat -safe 0 -i `"$ListFile`" -c:v h264_nvenc -preset p6 -rc:v vbr_hq -cq:v $Quality -b:v 0 -pix_fmt yuv420p `"$WeeklyVideo`""
    $procGen = Start-Process -FilePath $ffmpegPath -ArgumentList $argsGen -WorkingDirectory $folder.FullName -NoNewWindow -Wait -PassThru -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr

    if ($procGen.ExitCode -eq 0 -and (Test-Path $WeeklyVideo) -and (Get-Item $WeeklyVideo).Length -gt 1000) {
        Write-Host " OK!" -ForegroundColor Green
        $GenerationSuccess = $true
    } else {
        Write-Host " BŁĄD! (Sprawdź folder LOGS)" -ForegroundColor Red
        $GenerationSuccess = $false
        if (Test-Path $ListFile) { Remove-Item $ListFile }
        continue 
    }

    # --- KROK 2: AKTUALIZACJA PLIKU FULL ---
    $MergeSuccess = $false 

    if ($GenerationSuccess) {
        Write-Host "   2️⃣ Aktualizacja pliku FULL..." -NoNewline
        Add-Content -Path $LogOut -Value "`n--- ROZPOCZYNAM ŁĄCZENIE (MERGE) ---"
        
        if (Test-Path $FullVideo) {
            $swM = [System.IO.StreamWriter]::new($MergeList)
            $swM.WriteLine("file '$FullVideo'")
            $swM.WriteLine("file '$WeeklyVideo'")
            $swM.Close()
            
            $argsMerge = "-y -f concat -safe 0 -i `"$MergeList`" -c copy `"$TempFull`""
            $LogMergeErr = "$LogPath\$($CurrentDate)_$($TimeStamp)_$($CameraName)_MERGE_ERR.log"
            
            $procMerge = Start-Process -FilePath $ffmpegPath -ArgumentList $argsMerge -NoNewWindow -Wait -PassThru -RedirectStandardOutput "NUL" -RedirectStandardError $LogMergeErr
            
            if ($procMerge.ExitCode -eq 0) {
                Remove-Item $FullVideo -Force
                Move-Item $TempFull $FullVideo
                Write-Host " OK! (Doklejono)" -ForegroundColor Green
                Add-Content -Path $LogOut -Value "Sukces łączenia."
                $MergeSuccess = $true
            } else {
                Write-Host " Błąd łączenia!" -ForegroundColor Red
                Add-Content -Path $LogOut -Value "BŁĄD łączenia! Zobacz plik: $LogMergeErr"
                if (Test-Path $TempFull) { Remove-Item $TempFull }
                $MergeSuccess = $false
            }
        } else {
            Copy-Item $WeeklyVideo $FullVideo
            Write-Host " OK! (Utworzono nowy)" -ForegroundColor Green
            Add-Content -Path $LogOut -Value "Utworzono nowy plik FULL."
            $MergeSuccess = $true
        }
    }

    # --- KROK 3: BACKUP PRZEZ RCLONE (Z PLIKIEM CONFIG!) ---
    $BackupSuccess = $false

    if ($GenerationSuccess -and $MergeSuccess) {
        Write-Host "   3️⃣ Rclone Upload (Config: $RcloneConfig)..." -NoNewline
        Add-Content -Path $LogOut -Value "Rozpoczynam upload Rclone..."

        $CloudPathYear = "$RcloneRemote$RemoteFolder/$CameraName/$CurrentYear"
        $CloudPathRoot = "$RcloneRemote$RemoteFolder/$CameraName"

        # Dodajemy --config do komendy
        $arg1 = "copyto `"$WeeklyVideo`" `"$CloudPathYear/$($CurrentDate)_Week.mp4`" --config `"$RcloneConfig`""
        $p1 = Start-Process -FilePath $RcloneExe -ArgumentList $arg1 -NoNewWindow -Wait -PassThru
        
        $arg2 = "copyto `"$FullVideo`" `"$CloudPathRoot/$($CameraName)_FULL.mp4`" --config `"$RcloneConfig`""
        $p2 = Start-Process -FilePath $RcloneExe -ArgumentList $arg2 -NoNewWindow -Wait -PassThru

        if ($p1.ExitCode -eq 0 -and $p2.ExitCode -eq 0) {
             Write-Host " OK!" -ForegroundColor Green
             Add-Content -Path $LogOut -Value "Rclone Upload: SUKCES"
             $BackupSuccess = $true
        } else {
             Write-Host " BŁĄD UPLOADU!" -ForegroundColor Red
             Add-Content -Path $LogOut -Value "Rclone Upload: BŁĄD (Kod $($p1.ExitCode) / $($p2.ExitCode))"
             $BackupSuccess = $false
        }
    }

    # --- KROK 4: CZYSZCZENIE ZDJĘĆ ---
    if ($GenerationSuccess -and $MergeSuccess -and $BackupSuccess) {
        Write-Host "   4️⃣ Usuwanie starych zdjęć..." -NoNewline
        Add-Content -Path $LogOut -Value "`n--- USUWANIE ZDJĘĆ ---"
        $deletedCount = 0
        foreach ($file in $files) { 
            try { Remove-Item $file.FullName -ErrorAction Stop; $deletedCount++ } catch {}
        }
        Add-Content -Path $LogOut -Value "Usunięto plików: $deletedCount"
        Write-Host " Wyczyszczono ($deletedCount)." -ForegroundColor Yellow
    } else {
        if ($GenerationSuccess) {
            Write-Host "   ⚠️ POMINIĘTO USUWANIE! (Problem z backupem)" -ForegroundColor Magenta
            Add-Content -Path $LogOut -Value "NIE USUNIĘTO ZDJĘĆ. BackupSuccess=$BackupSuccess"
        }
    }

    # Sprzątanie
    if (Test-Path $ListFile)  { Remove-Item $ListFile }
    if (Test-Path $MergeList) { Remove-Item $MergeList }
}

Write-Host "`n✅ ZADANIE ZAKOŃCZONE." -ForegroundColor Magenta
Start-Sleep -Seconds 5