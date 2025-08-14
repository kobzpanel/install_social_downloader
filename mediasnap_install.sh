#!/usr/bin/env bash
set -euo pipefail

# =================== Config (env overrides allowed) ===================
APP_NAME="${APP_NAME:-MediaSnap}"
APP_DIR="${APP_DIR:-/opt/mediasnap}"
WANTED_PORT="${PORT:-8080}"           # host port -> container 8080
IMAGE="${IMAGE:-mediasnap:latest}"
SERVICE="${SERVICE:-mediasnap}"
DOMAIN="${DOMAIN:-}"                  # set both DOMAIN and EMAIL for HTTPS
EMAIL="${EMAIL:-}"
# Optional: comma-separated HTTP(S) proxies: http://user:pass@ip:port,https://ip:port
PROXY_LIST="${PROXY_LIST:-}"
# Rate limit: requests per minute per IP
RATE_LIMIT_RPM="${RATE_LIMIT_RPM:-30}"
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
    curl -fsSL "https://download.docker.com/linux/${ID:-$(. /etc/os-release; echo $ID)}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    ok "Docker already present."
  fi
}

write_app(){
  ok "Writing ${APP_NAME} to ${APP_DIR}..."
  mkdir -p "${APP_DIR}/backend/templates" "${APP_DIR}/downloads"

  # Dependencies
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

  # ============================ Backend =============================
  cat > "${APP_DIR}/backend/app.py" <<'PY'
import os, re, uuid, asyncio, json, random, time
from pathlib import Path
from typing import Dict, Optional, List
from fastapi import FastAPI, Request, HTTPException, Form, BackgroundTasks
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse, FileResponse
from fastapi.templating import Jinja2Templates
from bs4 import BeautifulSoup

DOWNLOAD_DIR = Path("/app/downloads"); DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
app = FastAPI(title=os.getenv("APP_NAME", "MediaSnap"))
templates = Jinja2Templates(directory="templates")

# Simple in-memory rate limiter: {ip: [timestamps]}
RATE_LIMIT_RPM = int(os.getenv("RATE_LIMIT_RPM","30"))
RATE_BUCKET: Dict[str, List[float]] = {}

JOBS: Dict[str, dict] = {}
PROG_RE = re.compile(r"\[download\]\s+(\d{1,3}(?:\.\d+)?)%")
PLATFORM_PATTERNS = {
    "instagram": r"(instagram\.com)",
    "tiktok": r"(tiktok\.com)",
    "twitter": r"(twitter\.com|x\.com)",
    "pinterest": r"(pinterest\.com|pin\.it)",
    "facebook": r"(facebook\.com|fb\.watch)",
    "youtube": r"(youtube\.com|youtu\.be)",
}
UA_POOL = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36",
]

PROXIES = [p.strip() for p in os.getenv("PROXY_LIST","").split(",") if p.strip()]

def platform_from_url(url:str)->str:
    u = url.lower()
    for name,pat in PLATFORM_PATTERNS.items():
        if re.search(pat, u):
            return name
    return "unknown"

def rate_limit_ok(ip:str)->bool:
    now=time.time()
    window=60.0
    RATE_BUCKET.setdefault(ip,[])
    RATE_BUCKET[ip]=[t for t in RATE_BUCKET[ip] if now-t < window]
    if len(RATE_BUCKET[ip]) >= RATE_LIMIT_RPM:
        return False
    RATE_BUCKET[ip].append(now)
    return True

def latest_file(d: Path)->Optional[Path]:
    files=[p for p in d.glob("*") if p.is_file()]
    return max(files,key=lambda p:p.stat().st_mtime) if files else None

async def run_cmd_stream(cmd:List[str], job_id:str):
    proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, cwd=str(DOWNLOAD_DIR))
    assert proc.stdout
    async for raw in proc.stdout:
        line = raw.decode(errors="ignore").strip()
        if not line: continue
        m = PROG_RE.search(line)
        if m:
            pct=float(m.group(1)); JOBS[job_id]["progress"]=f"{min(max(pct,0.0),100.0):.1f}%"
        JOBS[job_id]["last"]=line
    rc = await proc.wait()
    return rc

async def run_yt_dlp(job_id:str, url:str, audio_only:bool, to_gif:bool, user_agent:str, proxy:Optional[str], selection:Optional[str], format_id:Optional[str]):
    JOBS[job_id].update(status="running", progress="0%")

    try:
        out = str(DOWNLOAD_DIR / "%(title).100s-%(id)s.%(ext)s")
        cmd = ["yt-dlp","-o",out,"--restrict-filenames","--newline","--no-warnings","--no-color","--user-agent",user_agent, url]
        if proxy: cmd += ["--proxy", proxy]
        # format selection
        if audio_only:
            cmd += ["-x","--audio-format","mp3","--audio-quality","0"]
        elif format_id:
            cmd += ["-f", format_id]
        else:
            cmd += ["-f","bv*+ba/b"]
        # playlist or specific selection
        if selection:
            cmd += ["--playlist-items", selection]

        rc = await run_cmd_stream(cmd, job_id)
        if rc != 0:
            JOBS[job_id].update(status="error", error=JOBS[job_id].get("last","Download failed.")); return
        f = latest_file(DOWNLOAD_DIR)
        if not f:
            JOBS[job_id].update(status="error", error="No file produced."); return

        # Optional GIF conversion
        if to_gif and f.suffix.lower() not in [".mp3",".m4a",".aac",".wav",".ogg",".webm",".opus"]:
            gif_path = f.with_suffix(".gif")
            cmd = [
                "ffmpeg","-y","-i",str(f),
                "-vf","fps=12,scale='min(600,iw)':-1:flags=lanczos",
                "-t","30", # cap to 30s for size sanity
                str(gif_path)
            ]
            rc = await run_cmd_stream(cmd, job_id)
            if rc==0 and gif_path.exists():
                JOBS[job_id]["gif"]=gif_path.name

        JOBS[job_id].update(status="done", file=f.name, progress="100.0%")
    except Exception as e:
        JOBS[job_id].update(status="error", error=str(e))

async def preview_info(url:str, user_agent:str, proxy:Optional[str])->dict:
    # Use yt-dlp metadata first (most reliable)
    import subprocess, json as _json
    base = ["yt-dlp","--dump-json","--no-warnings","--no-color","--user-agent",user_agent]
    if proxy: base += ["--proxy", proxy]
    base += [url]
    try:
        out = subprocess.check_output(base, stderr=subprocess.STDOUT, cwd=str(DOWNLOAD_DIR), text=True, timeout=30)
        data = _json.loads(out.strip().splitlines()[-1])
        # Normalize multiple entries if playlist
        entries=[]
        if "entries" in data and data["entries"]:
            for i,ent in enumerate(data["entries"],
