import os
import sys
import glob
import json
import time
import urllib.parse
import subprocess
import signal
from datetime import datetime
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import threading

# Konfiguracja ścieżek
BASE_DIR = Path(__file__).resolve().parent
VIDEO_DIR = Path(os.environ.get("VIDEO_DIR", BASE_DIR))
RCLONE_REMOTE = os.environ.get("RCLONE_REMOTE", "drive_timelapse:/VIDEO")
RCLONE_CONFIG = os.environ.get("RCLONE_CONFIG", "")
PORT = int(os.environ.get("PORT", 8000))
HOST = os.environ.get("HOST", "0.0.0.0")

current_task = {
    "status": "idle", # idle, running, completed, error, cancelled
    "action": None,
    "progress_message": "Brak aktywnych zadań",
    "logs": ["[SYSTEM] Serwer gotowy."],
    "start_time": None,
    "end_time": None,
    "pid": None
}

active_process = None

def format_size(size_bytes: int) -> str:
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    else:
        return f"{size_bytes / (1024 * 1024 * 1024):.2f} GB"

def get_local_video_files():
    videos = []
    for p in VIDEO_DIR.rglob("*.mp4"):
        if p.is_file():
            name = p.name
            if "Week" in name: # Ignorujemy pliki tygodniowe na liście głównej jeśli jakieś zostały
                continue
            stat = p.stat()
            rel_path = p.relative_to(VIDEO_DIR).as_posix()
            
            cam_name = "Nieznana"
            type_name = "INNE"
            for part in ["DAY", "NIGHT", "FULL"]:
                if f"_{part}" in name:
                    type_name = part
                    cam_name = name.split(f"_{part}")[0]
                    break
            if cam_name == "Nieznana" and "_" in name:
                cam_name = name.split("_")[0]
            
            meta_name = name.replace(".mp4", "_metadata.json")
            has_meta = (p.parent / meta_name).exists() or (VIDEO_DIR / meta_name).exists()
            
            videos.append({
                "filename": name,
                "rel_path": rel_path,
                "camera": cam_name,
                "type": type_name,
                "size_bytes": stat.st_size,
                "size_formatted": format_size(stat.st_size),
                "mtime": stat.st_mtime,
                "mtime_formatted": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                "has_metadata": has_meta,
                "metadata_file": meta_name if has_meta else None
            })
    
    videos.sort(key=lambda x: x["mtime"], reverse=True)
    if videos:
        videos[0]["is_latest"] = True
        for v in videos[1:]:
            v["is_latest"] = False
    return videos

def get_metadata_files():
    meta_files = []
    for p in VIDEO_DIR.rglob("*.json"):
        if p.is_file():
            stat = p.stat()
            meta_files.append({
                "filename": p.name,
                "rel_path": p.relative_to(VIDEO_DIR).as_posix(),
                "size_formatted": format_size(stat.st_size),
                "mtime_formatted": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
            })
    meta_files.sort(key=lambda x: x["filename"])
    return meta_files

def get_rclone_cmd():
    cmd = ["rclone"]
    if RCLONE_CONFIG and os.path.exists(RCLONE_CONFIG):
        cmd.extend(["--config", RCLONE_CONFIG])
    elif os.path.exists(str(BASE_DIR / "rclone.conf")):
        cmd.extend(["--config", str(BASE_DIR / "rclone.conf")])
    return cmd

def fetch_cloud_main_files():
    """Zwraca listę TYLKO głównych plików zbiorczych (DAY, NIGHT, FULL, metadata.json) z Google Drive."""
    cmd = get_rclone_cmd() + [
        "lsjson", RCLONE_REMOTE,
        "--recursive", "--max-depth", "2",
        "--include", "*_DAY.mp4",
        "--include", "*_NIGHT.mp4",
        "--include", "*_FULL.mp4",
        "--include", "*_metadata.json"
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=40)
    if res.returncode != 0:
        raise Exception(f"Błąd rclone lsjson: {res.stderr}")

    items = json.loads(res.stdout)
    main_files = []
    for it in items:
        if it.get("IsDir"): continue
        name = it.get("Name", "")
        if any(name.endswith(s) for s in ["_DAY.mp4", "_NIGHT.mp4", "_FULL.mp4", "_metadata.json"]):
            cam_name = "Nieznana"
            type_name = "INNE"
            for part in ["DAY", "NIGHT", "FULL"]:
                if f"_{part}" in name:
                    type_name = part
                    cam_name = name.split(f"_{part}")[0]
                    break
            if cam_name == "Nieznana" and "_" in name:
                cam_name = name.split("_")[0]

            main_files.append({
                "path": it.get("Path"),
                "name": name,
                "camera": cam_name,
                "type": type_name,
                "size_bytes": it.get("Size", 0),
                "size_formatted": format_size(it.get("Size", 0)),
                "mtime": it.get("ModTime"),
                "is_video": name.endswith(".mp4"),
                "is_json": name.endswith(".json")
            })

    main_files.sort(key=lambda x: x.get("mtime", ""), reverse=True)
    return main_files

def run_download_file_task(cloud_path, filename):
    global current_task, active_process
    current_task["status"] = "running"
    current_task["action"] = f"Pobieranie pliku: {filename}"
    current_task["start_time"] = datetime.now().isoformat()
    current_task["logs"] = [f"[START] Pobieranie {filename} z Dysku Google..."]

    try:
        remote_source = f"{RCLONE_REMOTE.rstrip('/')}/{cloud_path}"
        local_dest = VIDEO_DIR / filename
        cmd = get_rclone_cmd() + ["copyto", remote_source, str(local_dest), "-P", "--update"]
        current_task["logs"].append(f"Polecenie: rclone copyto {remote_source} -> {local_dest}")

        active_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        current_task["pid"] = active_process.pid

        for line in active_process.stdout:
            line_str = line.strip()
            if line_str and ("%" in line_str or "Transferred" in line_str or "ETA" in line_str):
                current_task["progress_message"] = line_str
            elif line_str:
                current_task["logs"].append(line_str)

        active_process.wait()
        if active_process.returncode != 0:
            raise Exception("Pobieranie zostało przerwane lub wystąpił błąd.")

        # Jeśli to wideo, pobierz także metadane json
        if filename.endswith(".mp4") and not filename.endswith("_metadata.json"):
            meta_name = filename.replace(".mp4", "_metadata.json")
            meta_remote = remote_source.replace(".mp4", "_metadata.json")
            local_meta = VIDEO_DIR / meta_name
            cmd_meta = get_rclone_cmd() + ["copyto", meta_remote, str(local_meta)]
            subprocess.run(cmd_meta, capture_output=True, timeout=20)

        current_task["status"] = "completed"
        current_task["progress_message"] = f"Plik {filename} został pomyślnie zaktualizowany!"
        current_task["logs"].append(f"[SUKCES] Pobrano {filename}.")
    except Exception as e:
        if current_task["status"] != "cancelled":
            current_task["status"] = "error"
            current_task["progress_message"] = f"Błąd: {str(e)}"
            current_task["logs"].append(f"[BŁĄD] {str(e)}")
    finally:
        active_process = None
        current_task["end_time"] = datetime.now().isoformat()

def run_sync_main_files_task():
    global current_task, active_process
    current_task["status"] = "running"
    current_task["action"] = "Synchronizacja pełnych plików (DAY, NIGHT, FULL)"
    current_task["start_time"] = datetime.now().isoformat()
    current_task["logs"] = ["[START] Wyszukiwanie głównych plików zbiorczych na Dysku Google..."]

    try:
        files = fetch_cloud_main_files()
        video_files = [f for f in files if f["is_video"]]
        current_task["logs"].append(f"Znaleziono {len(video_files)} plików zbiorczych dla kamer.")

        for idx, f in enumerate(video_files, 1):
            if current_task["status"] == "cancelled":
                break
            fname = f["name"]
            cpath = f["path"]
            current_task["progress_message"] = f"[{idx}/{len(video_files)}] Aktualizowanie: {fname}..."
            current_task["logs"].append(f"Sprawdzanie {fname} ({f['size_formatted']})...")

            remote_src = f"{RCLONE_REMOTE.rstrip('/')}/{cpath}"
            local_dst = VIDEO_DIR / fname

            cmd = get_rclone_cmd() + ["copyto", remote_src, str(local_dst), "-P", "--update"]
            active_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            current_task["pid"] = active_process.pid

            for line in active_process.stdout:
                line_str = line.strip()
                if line_str and ("%" in line_str or "ETA" in line_str):
                    current_task["progress_message"] = f"[{idx}/{len(video_files)}] {fname}: {line_str}"

            active_process.wait()

            # Pobranie metadanych JSON
            meta_name = fname.replace(".mp4", "_metadata.json")
            meta_remote = remote_src.replace(".mp4", "_metadata.json")
            local_meta = VIDEO_DIR / meta_name
            cmd_meta = get_rclone_cmd() + ["copyto", meta_remote, str(local_meta), "--update"]
            subprocess.run(cmd_meta, capture_output=True, timeout=15)

        if current_task["status"] != "cancelled":
            current_task["status"] = "completed"
            current_task["progress_message"] = "Wszystkie pliki główne (DAY, NIGHT, FULL) są aktualne!"
            current_task["logs"].append("[SUKCES] Zakończono synchronizację głównych plików.")
    except Exception as e:
        if current_task["status"] != "cancelled":
            current_task["status"] = "error"
            current_task["progress_message"] = f"Błąd synchronizacji: {str(e)}"
            current_task["logs"].append(f"[BŁĄD] {str(e)}")
    finally:
        active_process = None
        current_task["end_time"] = datetime.now().isoformat()

def stop_active_task():
    global current_task, active_process
    if active_process and active_process.poll() is None:
        try:
            active_process.terminate()
            time.sleep(0.5)
            if active_process.poll() is None:
                active_process.kill()
        except Exception:
            pass
    current_task["status"] = "cancelled"
    current_task["progress_message"] = "Zadanie zostało przerwane przez użytkownika."
    current_task["logs"].append("[STOP] Zadanie anulowane.")
    current_task["end_time"] = datetime.now().isoformat()

class TimelapseHTTPHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_HEAD(self):
        self.do_GET()

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path in ["/", "/index.html"]:
            self.serve_file(BASE_DIR / "index.html", "text/html; charset=utf-8")
            return
        elif path in ["/comparator", "/frame_comparator.html"]:
            self.serve_file(BASE_DIR / "frame_comparator.html", "text/html; charset=utf-8")
            return
        elif path in ["/visualizer", "/completeness_visualizer.html"]:
            self.serve_file(BASE_DIR / "completeness_visualizer.html", "text/html; charset=utf-8")
            return
        elif path in ["/help", "/help.html"]:
            self.serve_file(BASE_DIR / "help.html", "text/html; charset=utf-8")
            return

        if path == "/api/videos":
            self.send_json({"videos": get_local_video_files()})
            return
        elif path == "/api/gdrive/cloud-files":
            try:
                files = fetch_cloud_main_files()
                self.send_json({"success": True, "files": files})
            except Exception as e:
                self.send_json({"success": False, "error": str(e), "files": []})
            return
        elif path == "/api/metadata":
            self.send_json({"metadata_files": get_metadata_files()})
            return
        elif path.startswith("/api/metadata/"):
            filename = urllib.parse.unquote(path[len("/api/metadata/"):])
            target = VIDEO_DIR / filename
            if not target.exists():
                matches = list(VIDEO_DIR.rglob(filename))
                if matches: target = matches[0]
            if target.exists() and target.is_file():
                self.serve_file(target, "application/json; charset=utf-8")
            else:
                self.send_error(404, "Plik metadanych nie znaleziony")
            return
        elif path.startswith("/api/video/"):
            filename = urllib.parse.unquote(path[len("/api/video/"):])
            target = VIDEO_DIR / filename
            if not target.exists():
                matches = list(VIDEO_DIR.rglob(filename))
                if matches: target = matches[0]
            if target.exists() and target.is_file():
                self.serve_video_range(target)
            else:
                self.send_error(404, "Plik wideo nie znaleziony")
            return
        elif path == "/api/gdrive/status":
            rclone_installed = False
            try:
                res = subprocess.run(["rclone", "version"], capture_output=True, timeout=3)
                rclone_installed = (res.returncode == 0)
            except Exception: pass
            self.send_json({
                "rclone_installed": rclone_installed,
                "remote_configured": RCLONE_REMOTE,
                "video_dir": str(VIDEO_DIR),
                "task": current_task
            })
            return

        clean_path = path.lstrip("/")
        static_target = BASE_DIR / clean_path
        if static_target.exists() and static_target.is_file():
            content_type = "application/octet-stream"
            if clean_path.endswith(".html"): content_type = "text/html; charset=utf-8"
            elif clean_path.endswith(".json"): content_type = "application/json; charset=utf-8"
            elif clean_path.endswith(".css"): content_type = "text/css"
            elif clean_path.endswith(".js"): content_type = "application/javascript"
            elif clean_path.endswith(".mp4"):
                self.serve_video_range(static_target)
                return
            self.serve_file(static_target, content_type)
            return

        self.send_error(404, "Nie znaleziono zasobu")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/api/gdrive/cancel":
            stop_active_task()
            self.send_json({"status": "cancelled", "message": "Zadanie zostało zatrzymane."})
            return

        if path == "/api/gdrive/download-latest":
            if current_task["status"] == "running":
                self.send_json({"status": "busy", "message": "Inne zadanie jest już w trakcie wykonywania."})
                return
            def run_latest():
                try:
                    files = fetch_cloud_main_files()
                    video_files = [f for f in files if f["is_video"]]
                    if not video_files:
                        current_task["logs"].append("Brak plików głównych na Dysku Google.")
                        current_task["status"] = "completed"
                        return
                    latest = video_files[0]
                    run_download_file_task(latest["path"], latest["name"])
                except Exception as e:
                    current_task["status"] = "error"
                    current_task["logs"].append(f"BŁĄD: {str(e)}")
                    current_task["progress_message"] = f"Błąd: {str(e)}"
            threading.Thread(target=run_latest, daemon=True).start()
            self.send_json({"status": "started", "message": "Rozpoczęto pobieranie najnowszego pliku głównego."})
            return

        elif path == "/api/gdrive/sync-main":
            if current_task["status"] == "running":
                self.send_json({"status": "busy", "message": "Inne zadanie jest już w trakcie wykonywania."})
                return
            threading.Thread(target=run_sync_main_files_task, daemon=True).start()
            self.send_json({"status": "started", "message": "Rozpoczęto aktualizację wszystkich plików głównych (DAY, NIGHT, FULL)."})
            return

        elif path == "/api/gdrive/download-file":
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length)
            try:
                payload = json.loads(post_data.decode('utf-8'))
                cpath = payload.get("path")
                fname = payload.get("name")
                if not cpath or not fname:
                    self.send_json({"status": "error", "message": "Brak parametrów path/name."})
                    return
                if current_task["status"] == "running":
                    self.send_json({"status": "busy", "message": "Inne zadanie jest w trakcie wykonywania."})
                    return
                threading.Thread(target=run_download_file_task, args=(cpath, fname), daemon=True).start()
                self.send_json({"status": "started", "message": f"Rozpoczęto pobieranie {fname}."})
            except Exception as e:
                self.send_json({"status": "error", "message": str(e)})
            return

        self.send_error(404, "Endpoint nie istnieje")

    def send_json(self, data):
        body = json.dumps(data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def serve_file(self, path: Path, content_type: str):
        try:
            with open(path, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self.send_error(500, f"Błąd odczytu pliku: {str(e)}")

    def serve_video_range(self, path: Path):
        try:
            file_size = path.stat().st_size
            range_header = self.headers.get('Range')

            if not range_header:
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(file_size))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                with open(path, 'rb') as f:
                    while True:
                        chunk = f.read(128 * 1024)
                        if not chunk: break
                        self.wfile.write(chunk)
                return

            range_val = range_header.replace('bytes=', '')
            parts = range_val.split('-')
            start = int(parts[0]) if parts[0] else 0
            end = int(parts[1]) if len(parts) > 1 and parts[1] else file_size - 1
            end = min(end, file_size - 1)
            chunk_length = end - start + 1

            self.send_response(206)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Content-Length", str(chunk_length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            with open(path, 'rb') as f:
                f.seek(start)
                bytes_left = chunk_length
                while bytes_left > 0:
                    read_len = min(64 * 1024, bytes_left)
                    chunk = f.read(read_len)
                    if not chunk: break
                    bytes_left -= len(chunk)
                    self.wfile.write(chunk)
        except Exception:
            pass

def start_server():
    print(f"🚀 BlueIris Timelapse Hub działa pod adresem: http://{HOST}:{PORT}")
    print(f"   Katalog wideo: {VIDEO_DIR}")
    server = ThreadingHTTPServer((HOST, PORT), TimelapseHTTPHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nZatrzymywanie serwera.")
        server.server_close()

if __name__ == "__main__":
    start_server()
