#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/social-downloader"
DOMAIN="${DOMAIN:-}"   # optional, not used unless you add a reverse proxy
PORT="${PORT:-8080}"

# -- Helpers ---------------------------------------------------------------
log(){ echo -e "\033[1;32m[ OK ]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

require_root(){
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Run as root (use sudo)."
    exit 1
  fi
}

detect_ubuntu(){
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "This script targets Ubuntu. Continuing anyway..."
    fi
  fi
}

install_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    . /etc/os-release
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      ${VERSION_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    log "Docker already installed."
  fi
  if ! docker compose version >/dev/null 2>&1; then
    err "docker compose plugin missing. Install docker-compose-plugin."
    apt-get install -y docker-compose-plugin
  fi
}

make_files(){
  log "Creating app files in ${APP_DIR}..."
  mkdir -p "${APP_DIR}/backend/templates" "${APP_DIR}/downloads"

  # requirements.txt
  cat > "${APP_DIR}/backend/requirements.txt" <<'REQ'
fastapi==0.115.0
uvicorn[standard]==0.30.6
jinja2==3.1.4
yt-dlp==2025.1.8
REQ

  # Dockerfile
  cat > "${APP_DIR}/backend/Dockerfile" <<'DOCK'
FROM python:3.11-slim

# System deps that help yt-dlp (ffmpeg for muxing/merging)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# App
COPY app.py /app/app.py
COPY templates /app/templates
RUN mkdir -p /app/downloads

EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
DOCK

  # backend app.py
  cat > "${APP_DIR}/backend/app.py" <<'PY'
import os
import uuid
import shutil
import subprocess
from pathlib import Path
from fastapi import FastAPI, BackgroundTasks, Request, HTTPException, Form
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from jinja2 import Template
from fastapi.templating import Jinja2Templates

DOWNLOAD_DIR = Path("/app/downloads")
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Social Video Downloader")
templates = Jinja2Templates(directory="templates")

# In-memory job store (simple, single-process)
JOBS = {}  # job_id -> {"status": "queued|running|done|error", "file": str|None, "error": str|None}

def run_yt_dlp(job_id: str, url: str, audio_only: bool):
    JOBS[job_id]["status"] = "running"
    try:
      out_tpl = str(DOWNLOAD_DIR / "%(title).80s-%(id)s.%(ext)s")
      cmd = ["yt-dlp", "-o", out_tpl, "--restrict-filenames", "--no-warnings", "--newline", url]
      if audio_only:
          cmd += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
      else:
          # best video+audio if available, fallback to best
          cmd += ["-f", "bv*+ba/b"]

      proc = subprocess.run(cmd, capture_output=True, text=True)
      if proc.returncode != 0:
          JOBS[job_id]["status"] = "error"
          JOBS[job_id]["error"] = proc.stderr.strip() or "Download failed."
          return

      # Pick the newest file in the download dir (rough heuristic)
      files = sorted(DOWNLOAD_DIR.glob("*"), key=lambda p: p.stat().st_mtime, reverse=True)
      target = None
      for f in files:
          if f.is_file():
              target = f
              break
      if not target:
          JOBS[job_id]["status"] = "error"
          JOBS[job_id]["error"] = "No file produced."
          return

      JOBS[job_id]["status"] = "done"
      JOBS[job_id]["file"] = target.name
    except Exception as e:
      JOBS[job_id]["status"] = "error"
      JOBS[job_id]["error"] = str(e)

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/api/download")
async def api_download(url: str = Form(...), audio_only: bool = Form(False)):
    if not url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="Invalid URL.")
    job_id = str(uuid.uuid4())
    JOBS[job_id] = {"status": "queued", "file": None, "error": None}
    from fastapi import BackgroundTasks as _BT  # type: ignore
    # Ensure background task
    bt = _BT()
    bt.add_task(run_yt_dlp, job_id, url, audio_only)
    # FastAPI will run it after returning response
    return JSONResponse({"job_id": job_id})

@app.get("/api/status/{job_id}")
async def api_status(job_id: str):
    data = JOBS.get(job_id)
    if not data:
        raise HTTPException(status_code=404, detail="Job not found.")
    return JSONResponse(data)

@app.get("/d/{filename}")
async def download_file(filename: str):
    file_path = DOWNLOAD_DIR / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="File not found.")
    return FileResponse(path=str(file_path), filename=filename)

PY

  # index.html
  cat > "${APP_DIR}/backend/templates/index.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Social Video Downloader</title>
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <style>
    body{font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 16px;}
    .card{border:1px solid #e5e7eb; border-radius:12px; padding:20px; box-shadow: 0 1px 8px rgba(0,0,0,0.05);}
    label{display:block; font-weight:600; margin-bottom:8px;}
    input[type="text"]{width:100%; padding:12px; border:1px solid #ddd; border-radius:8px;}
    button{padding:12px 16px; border:0; background:#111827; color:#fff; border-radius:10px; cursor:pointer;}
    button:disabled{opacity:.6; cursor:not-allowed;}
    .muted{color:#6b7280; font-size:14px;}
    .row{display:flex; align-items:center; gap:8px; margin-top:12px;}
    .status{margin-top:12px; padding:10px; background:#f9fafb; border:1px dashed #e5e7eb; border-radius:8px;}
    .dl{margin-top:10px;}
  </style>
</head>
<body>
  <h1>Social Video Downloader</h1>
  <p class="muted">Paste a public video link. For audio only, check the box. Use responsibly.</p>
  <div class="card">
    <form id="f">
      <label for="url">Video URL</label>
      <input id="url" name="url" type="text" placeholder="https://..." required />
      <div class="row">
        <label><input type="checkbox" id="audio_only" name="audio_only" /> Audio only (MP3)</label>
      </div>
      <div class="row">
        <button id="go" type="submit">Download</button>
      </div>
    </form>
    <div id="out" class="status" style="display:none;"></div>
    <div id="link" class="dl"></div>
  </div>

<script>
const f = document.getElementById('f');
const out = document.getElementById('out');
const go = document.getElementById('go');
const link = document.getElementById('link');

f.addEventListener('submit', async (e)=>{
  e.preventDefault();
  out.style.display='block';
  out.textContent='Starting...';
  link.innerHTML='';
  go.disabled = true;

  const fd = new FormData(f);
  const r = await fetch('/api/download', { method:'POST', body: fd });
  if(!r.ok){
    out.textContent = 'Error: ' + (await r.text());
    go.disabled = false;
    return;
  }
  const {job_id} = await r.json();
  out.textContent = 'Queued. Job: ' + job_id;

  const iv = setInterval(async ()=>{
    const s = await fetch('/api/status/'+job_id);
    if(!s.ok){
      out.textContent = 'Status error';
      clearInterval(iv);
      go.disabled = false;
      return;
    }
    const data = await s.json();
    out.textContent = 'Status: ' + data.status + (data.error ? (' — ' + data.error) : '');
    if(data.status === 'done' && data.file){
      clearInterval(iv);
      link.innerHTML = `<a href="/d/${encodeURIComponent(data.file)}" download>⬇️ Download file</a>`;
      go.disabled = false;
    }
    if(data.status === 'error'){
      clearInterval(iv);
      go.disabled = false;
    }
  }, 1500);
});
</script>
</body>
</html>
HTML

  # docker-compose.yml
  cat > "${APP_DIR}/docker-compose.yml" <<COMPOSE
services:
  web:
    build:
      context: ./backend
    container_name: social-downloader
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    volumes:
      - ./downloads:/app/downloads
    environment:
      - PYTHONUNBUFFERED=1
      - UVICORN_WORKERS=1
    # security: drop capabilities where possible
    cap_drop:
      - ALL
COMPOSE

  log "Files created."
}

systemd_unit(){
  # Optional systemd unit to keep it running
  cat > /etc/systemd/system/social-downloader.service <<'UNIT'
[Unit]
Description=Social Video Downloader (Docker Compose)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/social-downloader
ExecStart=/usr/bin/docker compose up -d --build
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now social-downloader.service
}

print_summary(){
  echo
  log "Setup complete."
  echo "URL:  http://$(hostname -I | awk '{print $1}'):${PORT}/"
  echo "Path: ${APP_DIR}"
  echo "Downloads stored in: ${APP_DIR}/downloads"
  echo
  echo "Commands:"
  echo "  systemctl restart social-downloader"
  echo "  systemctl stop social-downloader"
  echo "  systemctl status social-downloader"
  echo "  docker compose -f ${APP_DIR}/docker-compose.yml logs -f"
}

main(){
  require_root
  detect_ubuntu
  install_docker
  make_files
  systemd_unit
  print_summary
}

main "$@"
