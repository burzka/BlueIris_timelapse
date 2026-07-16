import os
import sys
import json
import glob
import base64
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

def query_ollama(file_path):
    try:
        with open(file_path, "rb") as image_file:
            encoded_string = base64.b64encode(image_file.read()).decode('utf-8')
            
        data = {
            "model": "glm-ocr",
            "prompt": "OCR: read the date and time from this image. Return it exactly as displayed, do not reformat.",
            "images": [encoded_string],
            "stream": False,
            "options": {
                "temperature": 0.0,
                "num_predict": 30
            }
        }
        
        req = urllib.request.Request(
            "http://127.0.0.1:11434/api/generate",
            data=json.dumps(data).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        
        with urllib.request.urlopen(req, timeout=60) as response:
            res = json.loads(response.read().decode('utf-8'))
            return res.get('response', '').strip()
    except Exception as e:
        return f"ERROR OLLAMA: {str(e)}"

def main():
    if len(sys.argv) < 2:
        print("ERROR: Brak sciezki do pliku lub katalogu")
        return
        
    path = os.path.abspath(sys.argv[1])
    
    if os.path.isdir(path):
        files = sorted(glob.glob(os.path.join(path, "frame_*.jpg")))
        results = {}
        
        total = len(files)
        sys.stdout.write(f"Inicjalizacja Ollama (glm-ocr) dla {total} plikow (wielowatkowo)...\n")
        sys.stdout.flush()
        
        def process_file(file_path):
            file_name = os.path.basename(file_path)
            text = query_ollama(file_path)
            return file_name, text
            
        completed = 0
        # Uzywamy 6 rownoleglych watkow
        with ThreadPoolExecutor(max_workers=6) as executor:
            future_to_file = {executor.submit(process_file, f): f for f in files}
            for future in as_completed(future_to_file):
                file_name, text = future.result()
                results[file_name] = {
                    "text": text
                }
                completed += 1
                
                # Dynamiczny pasek postepu co 20 klatek
                if completed % 20 == 0 or completed == total:
                    percent = int(completed / total * 100)
                    bar_length = 40
                    filled = int(percent / 100 * bar_length)
                    bar = "#" * filled + "-" * (bar_length - filled)
                    sys.stdout.write(f"\rOllama GLM-OCR: |{bar}| {percent}% ({completed}/{total}) klatek")
                    sys.stdout.flush()
                    
        print() # Nowa linia na koniec
        
        # Zapisujemy JSON
        json_path = os.path.join(path, "ocr_results.json")
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False)
            
        print(f"SUKCES: Zapisano {len(results)} wynikow w {json_path}")
        
    elif os.path.isfile(path):
        text = query_ollama(path)
        print(f"{text}", end="")
    else:
        print(f"ERROR: Sciezka nie istnieje: {path}")

if __name__ == "__main__":
    main()
