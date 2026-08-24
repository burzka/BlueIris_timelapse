FROM python:3.11-slim

# Instalacja podstawowych narzędzi, rclone i ffmpeg
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    ffmpeg \
    rclone \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Instalacja zależności Python
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Kopiowanie plików aplikacji
COPY server.py index.html frame_comparator.html completeness_visualizer.html help.html /app/
COPY *.json /app/

# Katalogi na dane wideo i konfigurację
RUN mkdir -p /app/data /root/.config/rclone

ENV PYTHONUNBUFFERED=1
ENV VIDEO_DIR=/app/data
ENV RCLONE_REMOTE=drive_timelapse:/VIDEO
ENV RCLONE_CONFIG=/root/.config/rclone/rclone.conf
ENV PORT=8000
ENV HOST=0.0.0.0

EXPOSE 8000

CMD ["python", "server.py"]
