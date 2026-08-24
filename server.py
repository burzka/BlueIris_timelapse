import os
import sys
import glob
import json
import time
import urllib.parse
import subprocess
from datetime import datetime
from pathlib import Path

# Konfiguracja ścieżek
BASE_DIR = Path(__file__).resolve().parent
VIDEO_DIR = Path(os.environ.get("VIDEO_DIR", BASE_DIR))
RCLONE_REMOTE = os.environ.get("RCLONE_REMOTE", "drive_timelapse:/VIDEO")
RCLONE_CONFIG = os.environ.get("RCLONE_CONFIG", "")
PORT = int(os.environ.get("PORT", 8000))
HOST = os.environ.get("HOST", "0.0.0.0")

current_task = {
    "status": "idle",
    "action": None,
    "progress_message": "Brak aktywnych zadań",
    "logs": ["[SYSTEM] Serwer gotowy."],
    "start_time": None,
    "end_time": None
}

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
            stat = p.stat()
            rel_path = p.relative_to(VIDEO_DIR).as_posix()
            name = p.name
            
            cam_name = "Nieznana"
            type_name = "INNE"
            for part in ["DAY", "NIGHT", "FULL", "Week", "Week_Day", "Week_Night"]:
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
    return cmd

def run_download_latest_sync():
    global current_task
    current_task["status"] = "running"
    current_task["action"] = "Pobieranie najnowszego filmu z Dysku Google"
    current_task["start_time"] = datetime.now().isoformat()
    current_task["logs"] = ["Sprawdzanie listy plików na Dysku Google..."]

    try:
        cmd_list = get_rclone_cmd() + ["lsjson", RCLONE_REMOTE, "--recursive"]
        res = subprocess.run(cmd_list, capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            raise Exception(f"Błąd rclone: {res.stderr}")

        items = json.loads(res.stdout)
        video_items = [it for it in items if not it.get("IsDir") and it.get("Name", "").endswith(".mp4")]
        if not video_items:
            current_task["logs"].append("Nie znaleziono żadnych plików .mp4 na Dysku Google.")
            current_task["status"] = "completed"
            return

        video_items.sort(key=lambda x: x.get("ModTime", ""), reverse=True)
        latest_video = video_items[0]
        video_remote_path = f"{RCLONE_REMOTE.rstrip('/')}/{latest_video['Path']}"
        local_dest = VIDEO_DIR / latest_video["Name"]

        current_task["logs"].append(f"Znaleziono najnowszy film: {latest_video['Name']} ({format_size(latest_video.get('Size', 0))})")
        current_task["logs"].append(f"Pobieranie: {video_remote_path} -> {local_dest} ...")

        cmd_dl = get_rclone_cmd() + ["copyto", video_remote_path, str(local_dest), "-P"]
        res_dl = subprocess.run(cmd_dl, capture_output=True, text=True)
        if res_dl.returncode != 0:
            raise Exception(res_dl.stderr)

        current_task["logs"].append("Wideo pobrane pomyślnie!")

        meta_name = latest_video["Name"].replace(".mp4", "_metadata.json")
        meta_remote_path = video_remote_path.replace(".mp4", "_metadata.json")
        local_meta = VIDEO_DIR / meta_name

        cmd_meta = get_rclone_cmd() + ["copyto", meta_remote_path, str(local_meta)]
        res_meta = subprocess.run(cmd_meta, capture_output=True, text=True)
        if res_meta.returncode == 0:
            current_task["logs"].append(f"Pobrano powiązane metadane: {meta_name}")

        current_task["status"] = "completed"
        current_task["progress_message"] = f"Pomyślnie pobrano film: {latest_video['Name']}"
    except Exception as e:
        current_task["status"] = "error"
        current_task["logs"].append(f"BŁĄD: {str(e)}")
        current_task["progress_message"] = f"Błąd: {str(e)}"
    finally:
        current_task["end_time"] = datetime.now().isoformat()

# --- STANDALONE HTTP SERVER (BEZ ZEWNĘTRZNYCH ZALEŻNOŚCI) ---
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import threading

class TimelapseHTTPHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass # Ciche logowanie dla wydajności strumieniowania

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
        query = urllib.parse.parse_qs(parsed.query)

        # Routing stron
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

        # Routing API
        if path == "/api/videos":
            self.send_json({"videos": get_local_video_files()})
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

        # Statyczne pliki z folderu roboczego
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
        if path == "/api/gdrive/download-latest":
            if current_task["status"] == "running":
                self.send_json({"status": "busy", "message": "Zadanie jest już w trakcie wykonywania."})
                return
            threading.Thread(target=run_download_latest_sync, daemon=True).start()
            self.send_json({"status": "started", "message": "Rozpoczęto pobieranie najnowszego filmu z Dysku Google."})
            return
        elif path == "/api/gdrive/sync":
            if current_task["status"] == "running":
                self.send_json({"status": "busy", "message": "Zadanie jest już w trakcie wykonywania."})
                return
            def run_sync():
                global current_task
                current_task["status"] = "running"
                current_task["action"] = "Synchronizacja całego folderu"
                current_task["start_time"] = datetime.now().isoformat()
                current_task["logs"] = ["Rozpoczynanie synchronizacji rclone..."]
                try:
                    cmd = get_rclone_cmd() + ["copy", RCLONE_REMOTE, str(VIDEO_DIR), "-P", "--include", "*.mp4", "--include", "*.json"]
                    res = subprocess.run(cmd, capture_output=True, text=True)
                    if res.returncode == 0:
                        current_task["status"] = "completed"
                        current_task["progress_message"] = "Synchronizacja zakończona sukcesem."
                        current_task["logs"].append("Synchronizacja plików powiodła się.")
                    else:
                        raise Exception(res.stderr)
                except Exception as e:
                    current_task["status"] = "error"
                    current_task["logs"].append(f"BŁĄD: {str(e)}")
                    current_task["progress_message"] = f"Błąd: {str(e)}"
                finally:
                    current_task["end_time"] = datetime.now().isoformat()

            threading.Thread(target=run_sync, daemon=True).start()
            self.send_json({"status": "started", "message": "Rozpoczęto pełną synchronizację."})
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
            pass # Klient przerwał odtwarzanie/przewinął wideo

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
