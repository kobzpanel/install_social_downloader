#!/usr/bin/env bash
set -euo pipefail

# =================== Config (env overrides allowed) ===================
APP_DIR="${APP_DIR:-/opt/social-downloader}"
WANTED_PORT="${PORT:-8080}"           # host port -> container 8080
IMAGE="${IMAGE:-social-downloader:latest}"
SERVICE="${SERVICE:-social-downloader}"
DOMAIN="${DOMAIN:-}"                  # set both DOMAIN and EMAIL for HTTPS
EMAIL="${EMAIL:-}"
# =====================================================================

ok(){ echo -e "\033[1;32m[ OK ]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
need_root(){ [[ "$(id -u)" -eq 0 ]] || { err "Run as root (sudo)."; exit 1; } }

port_in_use(){ ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":(^|)${1}\$"; }
find_free_port(){ local s="${1:-8080}"; for p in $(seq "$s" $((s+99))); do port_in_use "$p"||{ echo "$p"; return; }; done; return 1; }

detect_os(){
  . /etc/os-release
  OS_ID="${ID}"; OS_CODENAME="${VERSION_CODENAME:-}"
  case "$OS_ID" in ubuntu|debian) ;; *) warn "Non Ubuntu/Debian detected (${OS_ID}). Continuing...";; esac
}

preclean(){
  systemctl disable --now "${SERVICE}.service" >/dev/null 2>&1 || true
  docker rm -f "${SERVICE}" >/dev/null 2>&1 || true
}

install_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    ok "Installing Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${OS_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    ok "Docker already present."
  fi
}

write_app(){
  ok "Writing app to ${APP_DIR}..."
  mkdir -p "${APP_DIR}/backend/templates" "${APP_DIR}/downloads"

  # Dependencies (yt-dlp floats to latest for site fixes)
  cat > "${APP_DIR}/backend/requirements.txt" <<'REQ'
fastapi==0.115.0
uvicorn[standard]==0.30.6
jinja2==3.1.4
yt-dlp
REQ

  # Hardened Dockerfile
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

  # Backend (syntax fixed, SSE JSON, progress, history)
  cat > "${APP_DIR}/backend/app.py" <<'PY'
import re, uuid, asyncio, json
from pathlib import Path
from typing import Dict, Optional
from fastapi import FastAPI, Request, HTTPException, Form, BackgroundTasks
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse, FileResponse
from fastapi.templating import Jinja2Templates

DOWNLOAD_DIR = Path("/app/downloads"); DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
app = FastAPI(title="Social Video Downloader")
templates = Jinja2Templates(directory="templates")
JOBS: Dict[str, dict] = {}
PROG_RE = re.compile(r"\[download\]\s+(\d{1,3}(?:\.\d+)?)%")

def latest_file(d: Path)->Optional[Path]:
    files=[p for p in d.glob("*") if p.is_file()]
    return max(files,key=lambda p:p.stat().st_mtime) if files else None

async def run_yt_dlp(job_id:str, url:str, audio_only:bool):
    JOBS[job_id].update(status="running", progress="0%")
    try:
        out = str(DOWNLOAD_DIR / "%(title).80s-%(id)s.%(ext)s")
        cmd = ["yt-dlp","-o",out,"--restrict-filenames","--newline","--no-warnings",url]
        cmd += ["-x","--audio-format","mp3","--audio-quality","0"] if audio_only else ["-f","bv*+ba/b"]
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, cwd=str(DOWNLOAD_DIR)
        )
        assert proc.stdout
        async for raw in proc.stdout:
            line = raw.decode(errors="ignore").strip()
            if not line: continue
            m = PROG_RE.search(line)
            if m:
                pct=float(m.group(1)); JOBS[job_id]["progress"]=f"{min(max(pct,0.0),100.0):.1f}%"
            if "Destination:" in line and "%(title)" not in line:
                JOBS[job_id]["title"]=line.split("Destination:",1)[1].strip()
            JOBS[job_id]["last"]=line
        rc = await proc.wait()
        if rc != 0:
            JOBS[job_id].update(status="error", error=JOBS[job_id].get("last","Download failed.")); return
        f = latest_file(DOWNLOAD_DIR)
        if not f:
            JOBS[job_id].update(status="error", error="No file produced."); return
        JOBS[job_id].update(status="done", file=f.name, progress="100.0%")
    except Exception as e:
        JOBS[job_id].update(status="error", error=str(e))

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/healthz")
async def health():
    return JSONResponse({"ok": True})

@app.post("/api/download")
async def api_download(background_tasks: BackgroundTasks, url: str = Form(...), audio_only: bool = Form(False)):
    if not url.startswith(("http://","https://")):
        raise HTTPException(400, "Invalid URL")
    jid = str(uuid.uuid4())
    JOBS[jid]={"status":"queued","file":None,"error":None,"progress":"0%","url":url,"audio_only":audio_only,"title":None}
    background_tasks.add_task(run_yt_dlp, jid, url, audio_only)
    return JSONResponse({"job_id": jid})

@app.get("/api/status/{jid}")
async def api_status(jid:str):
    d = JOBS.get(jid)
    if not d: raise HTTPException(404, "Job not found.")
    return JSONResponse(d)

@app.get("/api/stream/{jid}")
async def api_stream(jid:str):
    if jid not in JOBS: raise HTTPException(404, "Job not found.")
    async def gen():
        last=None
        while True:
            st = JOBS.get(jid)
            if not st:
                break
            payload={k:st.get(k) for k in("status","progress","file","error","title")}
            s=json.dumps(payload, ensure_ascii=False)
            if payload!=last:
                yield f"data: {s}\n\n"
                last=payload
            if st.get("status") in("done","error"):
                break
            await asyncio.sleep(1.0)
    return StreamingResponse(gen(), media_type="text/event-stream")

@app.get("/api/history")
async def history():
    items=[]
    for jid,d in list(JOBS.items())[-100:]:
        if d.get("status") in("done","error"):
            items.append({"job_id":jid,"status":d["status"],"file":d.get("file"),"title":d.get("title")})
    items.reverse(); return JSONResponse(items)

@app.get("/d/{filename}")
async def download_file(filename:str):
    p = DOWNLOAD_DIR / filename
    if not p.exists(): raise HTTPException(404,"File not found.")
    return FileResponse(str(p), filename=filename)
PY

  # New responsive UI/UX (mobile-first)
  cat > "${APP_DIR}/backend/templates/index.html" <<'HTML'
<!doctype html><html lang="en"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"/>
<title>Social Video Downloader</title>
<style>
:root{color-scheme:light dark; --bg:#0b1220; --card:#0f172a; --line:#1f2937; --muted:#9ca3af; --text:#e5e7eb; --brand:#2563eb;}
*{box-sizing:border-box} body{font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:var(--bg);color:var(--text);margin:0;}
.wrap{max-width:1080px;margin:32px auto;padding:0 16px;} header{display:flex;gap:14px;align-items:center;margin-bottom:18px}
.logo{width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,#6ee7b7,#3b82f6)}
h1{font-size:26px;margin:0}.muted{color:var(--muted);font-size:14px}
.grid{display:grid;grid-template-columns:1fr;gap:16px}@media(min-width:900px){.grid{grid-template-columns:2fr 1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px}
label{display:block;font-weight:600;margin:0 0 8px}
input[type="text"]{width:100%;padding:14px 12px;border:1px solid #334155;border-radius:12px;background:var(--bg);color:var(--text)}
.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-top:10px}
.btn{padding:12px 16px;background:var(--brand);color:#fff;border:0;border-radius:12px;font-weight:600;cursor:pointer}
.btn:disabled{opacity:.6;cursor:not-allowed}.status{margin-top:12px;padding:12px;background:var(--bg);border:1px dashed #334155;border-radius:12px;min-height:44px;white-space:pre-wrap}
.bar{height:10px;background:var(--bg);border:1px solid #334155;border-radius:999px;overflow:hidden;margin-top:8px}.bar>i{display:block;height:100%;width:0%;background:linear-gradient(90deg,#22c55e,#3b82f6)}
.ok{box-shadow:0 0 12px rgba(34,197,94,.35) inset}.err{box-shadow:0 0 12px rgba(239,68,68,.35) inset}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{padding:10px;border-bottom:1px solid var(--line)}
a{color:#93c5fd;text-decoration:none}a:hover{text-decoration:underline}.hint{font-size:12px;color:#94a3b8;margin-top:8px}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}.chip{font-size:12px;padding:6px 8px;background:#0b1220;border:1px solid #334155;border-radius:999px}
</style></head>
<body>
<div class="wrap">
<header><div class="logo"></div><div><h1>Social Video Downloader</h1><div class="muted">Paste a public link. Live progress. Optional MP3.</div></div></header>
<div class="chips"><div class="chip">YouTube</div><div class="chip">TikTok</div><div class="chip">Facebook</div><div class="chip">Instagram</div><div class="chip">X/Twitter</div></div>
<div class="grid">
  <div class="card">
    <form id="f">
      <label for="url">Video URL</label>
      <input id="url" name="url" type="text" inputmode="url" placeholder="https://..." required/>
      <div class="row"><label><input type="checkbox" id="audio_only" name="audio_only"/> MP3 only</label><button class="btn" id="go" type="submit">Download</button></div>
      <div class="hint">Only download content you’re allowed to. Private links may require cookies.</div>
    </form>
    <div id="out" class="status" style="display:none;"></div>
    <div class="bar" aria-hidden="true"><i id="p"></i></div>
    <p id="link"></p>
  </div>
  <div class="card"><strong>Recent Jobs</strong><div id="hist" class="muted" style="margin-top:8px;">No finished jobs yet.</div></div>
</div></div>
<script>
const f=document.getElementById('f'),out=document.getElementById('out'),go=document.getElementById('go'),p=document.getElementById('p'),link=document.getElementById('link'),hist=document.getElementById('hist');
async function refreshHistory(){try{const r=await fetch('/api/history');if(!r.ok)return;const d=await r.json();if(!d.length){hist.textContent='No finished jobs yet.';return}
let h='<table><thead><tr><th>Status</th><th>Title/File</th><th>Action</th></tr></thead><tbody>';for(const it of d){h+=`<tr><td>${it.status}</td><td>${(it.title??it.file??'').replace(/</g,'&lt;')}</td><td>${it.file?`<a href="/d/${encodeURIComponent(it.file)}" download>Download</a>`:''}</td></tr>`}h+='</tbody></table>';hist.innerHTML=h}catch{}}
refreshHistory();
f.addEventListener('submit',async e=>{e.preventDefault();out.style.display='block';out.textContent='Starting...';link.textContent='';p.style.width='0%';p.className='';go.disabled=true;
const fd=new FormData(f);const r=await fetch('/api/download',{method:'POST',body:fd});if(!r.ok){out.textContent='Error: '+(await r.text());go.disabled=false;return}
const {job_id}=await r.json();const es=new EventSource('/api/stream/'+job_id);es.onmessage=(ev)=>{try{const data=JSON.parse(ev.data);const pct=parseFloat((data.progress||'0').toString().replace('%',''))||0;p.style.width=Math.max(0,Math.min(100,pct))+'%';
out.textContent=(data.title?(data.title+'\n'):'')+`Status: ${data.status}${data.error?' — '+data.error:''}`;if(data.status==='done'&&data.file){p.className='ok';link.innerHTML=`<a href="/d/${encodeURIComponent(data.file)}" download>⬇️ Download file</a>`;es.close();go.disabled=false;refreshHistory()}
else if(data.status==='error'){p.className='err';es.close();go.disabled=false}}catch{}};es.onerror=()=>{};});
</script>
</body></html>
HTML
}

write_compose(){
  local PORT="$1"
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
    environment:
      - UVICORN_WORKERS=1
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
}

build_and_run(){
  ok "Building image..."
  docker compose -f "${APP_DIR}/docker-compose.yml" build --pull || {
    warn "Build failed once — retrying without cache..."
    DOCKER_BUILDKIT=0 docker compose -f "${APP_DIR}/docker-compose.yml" build --no-cache --pull
  }
  ok "Starting container..."
  docker compose -f "${APP_DIR}/docker-compose.yml" up -d

  ok "Waiting for app health..."
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/healthz" >/dev/null 2>&1; then
      ok "App is healthy."; return 0
    fi
    sleep 2
  done
  warn "App health not confirmed. Logs:"
  docker compose -f "${APP_DIR}/docker-compose.yml" logs --tail=120 || true
}

open_firewall(){
  if command -v ufw >/dev/null 2>/dev/null; then
    ufw status | grep -q inactive || { ufw allow 80/tcp || true; ufw allow 443/tcp || true; ufw allow ${HOST_PORT}/tcp || true; }
  fi
}

make_service(){
  ok "Creating systemd unit..."
  cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=Social Video Downloader (Docker Compose)
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

setup_nginx(){
  ok "Installing Nginx + reverse proxy..."
  apt-get update -y
  apt-get install -y nginx
  # Remove distro defaults to avoid duplicate default_server
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/000-default || true

  tee /etc/nginx/sites-available/social_downloader_default >/dev/null <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${HOST_PORT};
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
  ln -sf /etc/nginx/sites-available/social_downloader_default /etc/nginx/sites-enabled/000-social
  nginx -t && systemctl reload nginx
}

setup_https(){
  [[ -z "$DOMAIN" || -z "$EMAIL" ]] && { warn "DOMAIN/EMAIL not set — skipping HTTPS."; return; }
  apt-get install -y certbot python3-certbot-nginx
  tee /etc/nginx/sites-available/${DOMAIN} >/dev/null <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        proxy_pass http://127.0.0.1:${HOST_PORT};
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
  certbot --nginx -d "${DOMAIN}" --redirect -m "${EMAIL}" --agree-tos -n || warn "Certbot failed; verify DNS A → this server, then retry."
}

summary(){
  echo
  ok "All set."
  local ip="$(hostname -I | awk '{print $1}')"
  echo "Open:   http://${ip}/   (Nginx proxy)"
  echo "Local:  http://127.0.0.1:${HOST_PORT}/"
  [[ -n "$DOMAIN" ]] && echo "Domain: https://${DOMAIN}/"
  echo "Path:   ${APP_DIR}"
  echo "DL dir: ${APP_DIR}/downloads"
  echo
  echo "Useful:"
  echo "  docker compose -f ${APP_DIR}/docker-compose.yml logs -f"
  echo "  systemctl status ${SERVICE}"
}

main(){
  need_root
  detect_os
  preclean

  if port_in_use "$WANTED_PORT"; then
    warn "Port ${WANTED_PORT} busy — picking a free one..."
    HOST_PORT="$(find_free_port "$WANTED_PORT")" || { err "No free port near ${WANTED_PORT}."; exit 1; }
  else
    HOST_PORT="$WANTED_PORT"
  fi
  ok "App will listen on host port ${HOST_PORT} (-> container 8080)."

  install_docker
  write_app
  write_compose "$HOST_PORT"
  build_and_run
  open_firewall
  make_service
  setup_nginx
  setup_https
  summary
}
main "$@"
