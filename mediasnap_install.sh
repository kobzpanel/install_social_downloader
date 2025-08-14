#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG (overridable by environment variables) =====
APP_DIR="${APP_DIR:-/opt/mediasnap}"
SERVICE="mediasnap"
IMAGE="${IMAGE:-mediasnap:latest}"
PORT="${PORT:-8080}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
APP_NAME="MediaSnap"
RATE_LIMIT_RPM="${RATE_LIMIT_RPM:-30}"
PROXY_LIST="${PROXY_LIST:-}"
# =========================================================

warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
info() { echo -e "\033[1;32m[ OK ]\033[0m $*"; }

# Require root
[ "$(id -u)" -eq 0 ] || { error "Run as root (use sudo)."; exit 1; }

detect_os() {
  . /etc/os-release
  OS_ID="${ID}"
  OS_CODENAME="${VERSION_CODENAME:-}"
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    info "Docker already installed."
  fi
}

prepare_app() {
  info "Preparing ${APP_NAME} at ${APP_DIR}..."
  rm -rf "${APP_DIR}"
  mkdir -p "${APP_DIR}/backend/templates" "${APP_DIR}/downloads"
  # requirements
  cat > "${APP_DIR}/backend/requirements.txt" <<'REQ'
fastapi==0.115.0
uvicorn[standard]==0.30.6
jinja2==3.1.4
yt-dlp
beautifulsoup4==4.12.3
httpx==0.27.2
REQ

  # Dockerfile
  cat > "${APP_DIR}/backend/Dockerfile" <<'DOCK'
FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg ca-certificates tzdata tini curl build-essential pkg-config libffi-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt /app/
RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel
RUN pip install --no-cache-dir -r requirements.txt || (sleep 5 && pip install --no-cache-dir -r requirements.txt)
COPY app.py /app/app.py
COPY templates /app/templates
RUN mkdir -p /app/downloads
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8080","--workers","1"]
DOCK

  # Backend (no syntax errors)
  cat > "${APP_DIR}/backend/app.py" <<'PY'
import os, re, uuid, asyncio, json, random, time
from pathlib import Path
from typing import Dict, Optional, List
from fastapi import FastAPI, Request, HTTPException, Form, BackgroundTasks
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse, FileResponse
from fastapi.templating import Jinja2Templates

DOWNLOAD_DIR = Path("/app/downloads"); DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
app = FastAPI(title=os.getenv("APP_NAME", "MediaSnap"))
templates = Jinja2Templates(directory="templates")

RATE_LIMIT_RPM = int(os.getenv("RATE_LIMIT_RPM","30"))
RATE_BUCKET: Dict[str, List[float]] = {}
def rate_limit_ok(ip:str)->bool:
    now=time.time(); window=60.0
    RATE_BUCKET.setdefault(ip,[]); RATE_BUCKET[ip]=[t for t in RATE_BUCKET[ip] if now-t<window]
    if len(RATE_BUCKET[ip])>=RATE_LIMIT_RPM: return False
    RATE_BUCKET[ip].append(now); return True

JOBS: Dict[str, dict] = {}
PROG_RE = re.compile(r"\[download\]\s+(\d{1,3}(?:\.\d+)?)%")
UA_POOL = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36",
]
PROXIES = [p.strip() for p in os.getenv("PROXY_LIST","").split(",") if p.strip()]

async def run_cmd_stream(cmd:List[str], job_id:str):
    proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.STDOUT, cwd=str(DOWNLOAD_DIR))
    assert proc.stdout
    async for raw in proc.stdout:
        line = raw.decode(errors="ignore").strip()
        if not line: continue
        m = PROG_RE.search(line)
        if m:
            pct=float(m.group(1)); JOBS[job_id]["progress"]=f"{min(max(pct,0.0),100.0):.1f}%"
        JOBS[job_id]["last"]=line
    return await proc.wait()

async def run_yt_dlp(job_id:str, url:str, audio_only:bool, to_gif:bool, format_id:Optional[str]):
    JOBS[job_id].update(status="running", progress="0%")
    try:
        out = str(DOWNLOAD_DIR / "%(title).100s-%(id)s.%(ext)s")
        ua = random.choice(UA_POOL)
        proxy = random.choice(PROXIES) if PROXIES else None
        cmd = ["yt-dlp","-o",out,"--restrict-filenames","--newline","--no-warnings","--no-color","--user-agent",ua,url]
        if proxy: cmd += ["--proxy", proxy]
        if audio_only: cmd += ["-x","--audio-format","mp3","--audio-quality","0"]
        elif format_id: cmd += ["-f", format_id]
        else: cmd += ["-f","bv*+ba/b"]
        rc = await run_cmd_stream(cmd, job_id)
        if rc != 0: JOBS[job_id].update(status="error", error=JOBS[job_id].get("last","Download failed.")); return
        f = max([p for p in DOWNLOAD_DIR.glob("*") if p.is_file()], key=lambda p:p.stat().st_mtime, default=None)
        if not f: JOBS[job_id].update(status="error", error="No file produced."); return
        if to_gif and f.suffix.lower() not in [".mp3",".m4a",".aac",".wav",".ogg",".opus"]:
            gif_path = f.with_suffix(".gif")
            cmd = ["ffmpeg","-y","-i",str(f),"-vf","fps=12,scale='min(600,iw)':-1:flags=lanczos","-t","30",str(gif_path)]
            rc = await run_cmd_stream(cmd, job_id)
            if rc==0 and gif_path.exists(): JOBS[job_id]["gif"]=gif_path.name
        JOBS[job_id].update(status="done", file=f.name, progress="100.0%")
    except Exception as e:
        JOBS[job_id].update(status="error", error=str(e))

@app.middleware("http")
async def rate_middleware(request: Request, call_next):
    ip = request.client.host if request.client else "unknown"
    if not rate_limit_ok(ip):
        return JSONResponse({"error": "Rate limit exceeded. Try again later."}, status_code=429)
    return await call_next(request)

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request, "appname": app.title})

@app.get("/healthz")
async def health():
    return JSONResponse({"ok": True})

@app.post("/api/download")
async def api_download(background_tasks: BackgroundTasks,
                       url: str = Form(...),
                       audio_only: bool = Form(False),
                       to_gif: bool = Form(False),
                       format_id: str = Form("")):
    if not url.startswith(("http://","https://")):
        raise HTTPException(400,"Invalid URL")
    jid=str(uuid.uuid4())
    JOBS[jid]={"status":"queued","file":None,"gif":None,"error":None,"progress":"0%"}
    background_tasks.add_task(run_yt_dlp, jid, url, audio_only, to_gif, format_id or None)
    return JSONResponse({"job_id": jid})

@app.get("/api/stream/{jid}")
async def api_stream(jid:str):
    if jid not in JOBS: raise HTTPException(404,"Job not found.")
    async def gen():
        last=None
        while True:
            st=JOBS.get(jid)
            if not st: break
            payload={k:st.get(k) for k in("status","progress","file","gif","error")}
            s=json.dumps(payload,ensure_ascii=False)
            if payload!=last:
                yield f"data: {s}\n\n"; last=payload
            if st.get("status") in ("done","error"): break
            await asyncio.sleep(1.0)
    return StreamingResponse(gen(), media_type="text/event-stream")

@app.get("/api/history")
async def history():
    items=[]
    for jid,d in list(JOBS.items())[-200:]:
        if d.get("status") in ("done","error"):
            items.append({"job_id":jid,"status":d["status"],"file":d.get("file"),"gif":d.get("gif")})
    items.reverse(); return JSONResponse(items)

@app.get("/d/{filename}")
async def download_file(filename:str):
    p=DOWNLOAD_DIR/filename
    if not p.exists(): raise HTTPException(404,"Not found.")
    return FileResponse(str(p), filename=filename)
PY

  # Simple UI template
  cat > "${APP_DIR}/backend/templates/index.html" <<'HTML'
<!doctype html><html lang="en"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>{{ appname or 'MediaSnap' }}</title>
<style>
body {font-family:system-ui, sans-serif; margin:0;padding:0; background:#0b1220; color:#e5e7eb;}
.container {max-width:900px;margin:30px auto;padding:0 16px;}
.card {background:#0f172a;border:1px solid #1f2937;border-radius:16px;padding:20px;margin-bottom:20px;}
input[type="text"] {width:100%;padding:12px;border-radius:10px;border:1px solid #334155;background:#0b1220;color:#e5e7eb;}
button {padding:12px 16px;border-radius:10px;border:0;background:#2563eb;color:white;cursor:pointer;}
button:disabled {opacity:.6;cursor:not-allowed;}
.progress {margin-top:12px;height:10px;background:#0b1220;border-radius:999px;overflow:hidden;border:1px solid #334155;}
.progress > div {height:100%;width:0%;background:linear-gradient(90deg,#22c55e,#3b82f6);}
.status {margin-top:12px;padding:10px;border:1px dashed #334155;border-radius:10px;min-height:40px;}
</style></head><body>
<div class="container">
<h1>{{ appname or 'MediaSnap' }}</h1>
<div class="card">
  <form id="downloadForm">
    <label>Media URL</label>
    <input name="url" type="text" placeholder="Paste Instagram, TikTok, X, Pinterest, Facebook or YouTube link..." required/>
    <div style="margin-top:10px;">
      <label><input type="checkbox" name="audio_only"/> Audio only (MP3)</label>
      <label><input type="checkbox" name="to_gif"/> Video → GIF</label>
    </div>
    <button type="submit" id="downloadBtn">Download</button>
  </form>
  <div class="status" id="status" style="display:none;"></div>
  <div class="progress"><div id="progressBar"></div></div>
  <p id="downloadLink"></p>
</div>
<div class="card">
  <strong>Recent Downloads</strong>
  <div id="history" class="status">Loading...</div>
</div>
</div>
<script>
async function refreshHistory() {
  const r = await fetch('/api/history');
  if (!r.ok) return;
  const data = await r.json();
  const history = document.getElementById('history');
  history.innerHTML = data.map(i => {
    let links = i.file ? `<a href="/d/${encodeURIComponent(i.file)}" download>${i.file}</a>` : '';
    if (i.gif) links += ` | <a href="/d/${encodeURIComponent(i.gif)}" download>${i.gif}</a>`;
    return `${i.status === 'done' ? '✅':'⚠️'} ${links}`;
  }).join('<br>') || 'No finished jobs yet.';
}
refreshHistory();
document.getElementById('downloadForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const status = document.getElementById('status'); status.style.display='block'; status.textContent='Starting...';
  const formData = new FormData(e.target);
  const btn = document.getElementById('downloadBtn'); btn.disabled = true;
  const r = await fetch('/api/download', { method:'POST', body: formData });
  if (!r.ok) { status.textContent = 'Error: ' + await r.text(); btn.disabled=false; return;}
  const { job_id } = await r.json();
  const es = new EventSource('/api/stream/' + job_id);
  es.onmessage = (ev) => {
    const data = JSON.parse(ev.data);
    document.getElementById('progressBar').style.width = (parseFloat(data.progress||'0') || 0) + '%';
    status.textContent = `Status: ${data.status}` + (data.error ? ' — ' + data.error : '');
    if (data.status === 'done' && data.file) {
      document.getElementById('downloadLink').innerHTML = `<a href="/d/${encodeURIComponent(data.file)}" download>⬇️ ${data.file}</a>` + (data.gif ? ` | <a href="/d/${encodeURIComponent(data.gif)}" download>GIF</a>`:'');
      btn.disabled=false; es.close(); refreshHistory();
    }
    if (data.status === 'error') { btn.disabled=false; es.close(); }
  };
});
</script>
</body></html>
HTML
}

build_and_run_container() {
  info "Building container image..."
  docker compose -f "${APP_DIR}/docker-compose.yml" build --pull || {
    warn "Initial build failed. Retrying without cache..."
    DOCKER_BUILDKIT=0 docker compose -f "${APP_DIR}/docker-compose.yml" build --no-cache --pull
  }
  info "Starting container..."
  docker compose -f "${APP_DIR}/docker-compose.yml" up -d
  # Wait for health check
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
      info "App is healthy."
      break
    fi
    sleep 2
  done
}

setup_nginx() {
  info "Installing Nginx..."
  apt-get update -y
  apt-get install -y nginx
  # Remove default sites
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/000-default || true
  # Default proxy to our app (port 80)
  cat > /etc/nginx/sites-available/mediasnap_default <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
NGINX
  ln -sf /etc/nginx/sites-available/mediasnap_default /etc/nginx/sites-enabled/000-mediasnap
  nginx -t && systemctl reload nginx

  # Optionally set up HTTPS for DOMAIN
  if [[ -n "$DOMAIN" && -n "$EMAIL" ]]; then
    apt-get install -y certbot python3-certbot-nginx
    cat > /etc/nginx/sites-available/${DOMAIN} <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/${DOMAIN}
    nginx -t && systemctl reload nginx
    certbot --nginx -d "$DOMAIN" --redirect -m "$EMAIL" --agree-tos -n || warn "Certbot failed. Check DNS and try again."
  fi
}

configure_firewall() {
  # Open ports if UFW is active
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow ${PORT}/tcp || true
  fi
}

write_compose() {
  cat > "${APP_DIR}/docker-compose.yml" <<COMPOSE
services:
  web:
    build:
      context: ./backend
    image: ${IMAGE}
    container_name: ${SERVICE}
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    env_file:
      - ./.env
    volumes:
      - ./downloads:/app/downloads
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    cap_drop: ["ALL"]
COMPOSE
  cat > "${APP_DIR}/.env" <<ENV
APP_NAME=${APP_NAME}
RATE_LIMIT_RPM=${RATE_LIMIT_RPM}
PROXY_LIST=${PROXY_LIST}
ENV
}

create_systemd_service() {
  info "Creating systemd service..."
  cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=${APP_NAME} Service via Docker Compose
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${APP_DIR}
ExecStartPre=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml build --pull
ExecStart=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "${SERVICE}.service" || true
}

main() {
  detect_os
  install_docker
  prepare_app
  write_compose
  build_and_run_container
  create_systemd_service
  setup_nginx
  configure_firewall

  info "${APP_NAME} is ready."
  local ip="$(hostname -I | awk '{print $1}')"
  echo "Open:    http://${ip}/    (via Nginx)"
  echo "Local:   http://127.0.0.1:${PORT}/"
  [[ -n "$DOMAIN" ]] && echo "Domain:  https://${DOMAIN}/"
  echo "Files:   ${APP_DIR}"
  echo "DL dir: ${APP_DIR}/downloads"
  echo
  echo "Useful commands:"
  echo "  docker compose -f ${APP_DIR}/docker-compose.yml logs -f"
  echo "  systemctl status ${SERVICE}"
  echo "NOTE: If you still get 'connection refused', check your cloud provider firewall and open ports 80/443."
}

main "$@"
