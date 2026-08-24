# 🐳 Wdrożenie BlueIris Timelapse Hub na serwerze Ubuntu (Docker Compose)

Ten przewodnik opisuje, jak w prosty sposób uruchomić zintegrowany **BlueIris Timelapse Hub** w kontenerze Docker na serwerze Ubuntu.

---

## 🚀 Co oferuje aplikacja?

1. **Dashboard Główny (`/`)**:
   - Automatyczne wykrywanie i odtwarzanie **najnowszego filmu** z podglądem metadanych.
   - Integracja z **Dyskiem Google** – przycisk pobierania najnowszego filmu jednym kliknięciem oraz synchronizacja całych archiwów (przez `rclone`).
   - Tabela wszystkich lokalnych filmów z filtrowaniem i natychmiastowym przejściem do analizy.
2. **Porównywarka Klatek (`/comparator`)**:
   - Analiza zmian terenu/przyrody z kalibracją ruszającej się kamery.
   - Tryby porównywania: **A/B Przełącznik**, **Kurtyna (Split Curtain)**, **Przenikanie (Blend / Opacity)**, **Obok siebie (Side-by-Side)**.
   - Zoom & Pan (przybliżanie w punkcie kursora i przesuwanie myszą).
   - Wsparcie dla strumieniowania HTTP 206 Partial Content (błyskawiczne przewijanie dużych plików MP4).
3. **Wizualizator Kompletności (`/visualizer`)**:
   - Heatmapa klatek dzień/noc z podglądem luk czasowych i powiększeniem OCR zegara kamery.
4. **Podręcznik i Dokumentacja (`/help`)**:
   - Kompletny opis architektury, skryptów podziału klatek, automatyzacji i rozwiązywania problemów.

---

## 🛠️ Wymagania wstępne na serwerze Ubuntu

Na serwerze Ubuntu musi być zainstalowany **Docker** oraz wtyczka **Docker Compose**.

Jeśli ich jeszcze nie masz, zainstaluj je komendą:
```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER
```

---

## 📦 Krok po kroku: Uruchomienie aplikacji

### 1. Przygotowanie struktury katalogów na serwerze Ubuntu
Przejdź do wybranego katalogu (np. `/opt/timelapse` lub `~/timelapse`) i skopiuj pliki projektu:
```bash
mkdir -p ~/timelapse/data
cd ~/timelapse
```

Skopiuj do tego folderu pliki:
- `docker-compose.yml`
- `Dockerfile`
- `requirements.txt`
- `server.py`
- `index.html`
- `frame_comparator.html`
- `completeness_visualizer.html`
- `help.html`

### 2. Przygotowanie pliku konfiguracyjnego `rclone.conf` (Google Drive)
Aby kontener mógł łączyć się z Twoim Dyskiem Google:
1. Skopiuj swój plik `rclone.conf` do katalogu aplikacji:
   ```bash
   cp ~/.config/rclone/rclone.conf ~/timelapse/rclone.conf
   ```
2. Upewnij się, że w pliku `docker-compose.yml` nazwa remote odpowiada Twojej konfiguracji (domyślnie: `drive_timelapse:/VIDEO`). Jeśli Twój remote nazywa się np. `moj_dysk:/Timelapsy`, zmień zmienną w `docker-compose.yml`:
   ```yaml
   environment:
     - RCLONE_REMOTE=moj_dysk:/Timelapsy
   ```

### 3. Uruchomienie aplikacji za pomocą `docker compose`
Zbuduj obraz i uruchom kontener w tle:
```bash
docker compose up -d --build
```

### 4. Sprawdzenie statusu i logów
```bash
# Sprawdzenie czy kontener działa
docker compose ps

# Podgląd logów aplikacji na żywo
docker compose logs -f
```

### 5. Dostęp przez przeglądarkę
Otwórz w przeglądarce adres IP swojego serwera Ubuntu na porcie `8000`:
- **Dashboard**: `http://IP_SERWERA:8000/`
- **Porównywarka Klatek**: `http://IP_SERWERA:8000/comparator`
- **Wizualizator Kompletności**: `http://IP_SERWERA:8000/visualizer`
- **Podręcznik**: `http://IP_SERWERA:8000/help`

---

## 🔄 Przydatne komendy `docker compose`

- **Zatrzymanie aplikacji:**
  ```bash
  docker compose down
  ```
- **Restart aplikacji:**
  ```bash
  docker compose restart
  ```
- **Ponowne przebudowanie po zmianie kodu:**
  ```bash
  docker compose up -d --build
  ```

---

## 📁 Przechowywanie danych i filmów wideo
Wszystkie pobrane lub wygenerowane filmy znajdują się na hoście w katalogu `./data` (zmapowanym do `/app/data` w kontenerze). Dzięki temu filmy nie znikają po restartach kontenera.
