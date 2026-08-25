#!/usr/bin/env bash
# ==============================================================================
# Skrypt wdrożeniowy (Deploy) - BlueIris Timelapse Hub na Ubuntu / Linux
# Użycie:
#   ./deploy.sh          - Aktualizuje kod (git pull) i przebudowuje kontener
#   ./deploy.sh logs     - Podgląd logów na żywo
#   ./deploy.sh status   - Sprawdzenie stanu kontenera
#   ./deploy.sh restart  - Restart kontenera
#   ./deploy.sh stop     - Zatrzymanie kontenera
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ACTION="${1:-deploy}"

echo -e "\033[1;36m======================================================\033[0m"
echo -e "\033[1;36m   🚀 BlueIris Timelapse Hub - Ubuntu Deploy\033[0m"
echo -e "\033[1;36m======================================================\033[0m"
echo -e "Katalog projektu: \033[0;37m$SCRIPT_DIR\033[0m"
echo -e "Akcja:            \033[1;33m$ACTION\033[0m\n"

# Sprawdzenie dostępności Docker
if ! command -v docker &> /dev/null; then
    echo -e "\033[1;31m[BŁĄD] Docker nie jest zainstalowany na tym serwerze Ubuntu!\033[0m"
    echo -e "Zainstaluj go komendami:"
    echo -e "  sudo apt update && sudo apt install -y docker.io docker-compose-v2"
    echo -e "  sudo usermod -aG docker \$USER"
    exit 1
fi

case "$ACTION" in
    "deploy"|"up"|"build")
        # 1. Pobranie najnowszych zmian z repozytorium jeśli to repozytorium git
        if [ -d ".git" ]; then
            echo -e "\033[1;32m[1/3] Pobieranie najnowszych zmian z repozytorium (git pull)...\033[0m"
            git pull origin master || git pull || true
        fi

        # 2. Upewnienie się, że katalog danych istnieje
        mkdir -p ./data

        # 3. Przebudowanie i uruchomienie kontenera
        echo -e "\033[1;32m[2/3] Budowanie i uruchamianie kontenera Docker...\033[0m"
        docker compose up -d --build

        # 4. Sprawdzenie statusu
        echo -e "\033[1;32m[3/3] Status usług:\033[0m"
        docker compose ps

        echo -e "\n\033[1;32mWdrożenie zakończone sukcesem! 🎉\033[0m"
        echo -e "Aplikacja jest dostępna pod portem \033[1;36m8585\033[0m (np. http://localhost:8585)"
        ;;

    "logs")
        echo -e "\033[1;33mLogi aplikacji (Ctrl+C aby wyjść):\033[0m"
        docker compose logs -f
        ;;

    "status"|"ps")
        echo -e "\033[1;33mStatus kontenerów:\033[0m"
        docker compose ps
        ;;

    "restart")
        echo -e "\033[1;33mRestartowanie kontenerów...\033[0m"
        docker compose restart
        docker compose ps
        ;;

    "stop"|"down")
        echo -e "\033[1;33mZatrzymywanie aplikacji...\033[0m"
        docker compose down
        ;;

    *)
        echo -e "\033[1;31mNieznana akcja: $ACTION\033[0m"
        echo "Dozwolone akcje: deploy (domyślna), logs, status, restart, stop"
        exit 1
        ;;
esac
