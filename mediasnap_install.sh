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
            for i,ent in enumerate(data["entries"], start=1):
                if not ent: continue
                entries.append({
                    "title": ent.get("title"),
                    "id": ent.get("id"),
                    "thumbnail": ent.get("thumbnail"),
                    "duration": ent.get("duration"),
                    "index": i,
                })
        formats=[]
        for f in (data.get("formats") or []):
            if f.get("vcodec")!="none" or f.get("acodec")!="none":
                fmt_id=f.get("format_id")
                note=f.get("format_note") or ""
                res=(f.get("height") and f"{f.get('height')}p") or note or "best"
                ext=f.get("ext") or ""
                formats.append({"id":fmt_id,"res":res,"ext":ext})
        best_thumb = data.get("thumbnail")
        return {
            "title": data.get("title"),
            "uploader": data.get("uploader"),
            "platform": platform_from_url(url),
            "thumbnail": best_thumb,
            "entries": entries,        # for carousels/playlists
            "formats": formats[:30],   # limit
        }
    except Exception:
        # Fallback: fetch HTML and read Open Graph
        import httpx
        proxies = {"http://":proxy,"https://":proxy} if proxy else None
        headers = {"User-Agent": user_agent}
        async with httpx.AsyncClient(headers=headers, proxies=proxies, timeout=20) as client:
            r = await client.get(url, follow_redirects=True)
            r.raise_for_status()
            soup = BeautifulSoup(r.text, "html.parser")
            og_title = soup.find("meta", property="og:title")
            og_img = soup.find("meta", property="og:image")
            return {
                "title": (og_title and og_title.get("content")) or "Preview",
                "thumbnail": (og_img and og_img.get("content")) or None,
                "platform": platform_from_url(url),
                "entries": [],
                "formats": [],
            }

@app.middleware("http")
async def apply_rate_limit(request: Request, call_next):
    ip = request.client.host if request.client else "unknown"
    if not rate_limit_ok(ip):
        return JSONResponse({"error": "Rate limit exceeded. Try again soon."}, status_code=429)
    return await call_next(request)

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request, "appname": app.title})

@app.get("/healthz")
async def health(): return JSONResponse({"ok": True})

@app.post("/api/preview")
async def api_preview(url: str = Form(...), selection: str = Form("", description="playlist items, e.g., 1-3")):
    if not url.startswith(("http://","https://")):
        raise HTTPException(400, "Invalid URL")
    ua = random.choice(UAPOOL := os.getenv("UA_POOL","").split("|")) if os.getenv("UA_POOL") else random.choice(UA_POOL)
    proxy = random.choice(PROXIES) if PROXIES else None
    data = await preview_info(url, ua, proxy)
    data["selection_hint"] = "e.g., 1,3,5 or 1-3 for carousels/playlists"
    return JSONResponse(data)

@app.post("/api/download")
async def api_download(background_tasks: BackgroundTasks,
                       url: str = Form(...),
                       audio_only: bool = Form(False),
                       to_gif: bool = Form(False),
                       selection: str = Form(""),
                       format_id: str = Form("")):
    if not url.startswith(("http://","https://")):
        raise HTTPException(400, "Invalid URL")

    ua = random.choice(UA_POOL)
    proxy = random.choice(PROXIES) if PROXIES else None

    jid = str(uuid.uuid4())
    JOBS[jid] = {"status":"queued","file":None,"gif":None,"error":None,"progress":"0%","url":url}
    background_tasks.add_task(run_yt_dlp, jid, url, audio_only, to_gif, ua, proxy, selection or None, format_id or None)
    return JSONResponse({"job_id": jid})

@app.get("/api/stream/{jid}")
async def api_stream(jid:str):
    if jid not in JOBS: raise HTTPException(404, "Job not found.")
    async def gen():
        last=None
        while True:
            st=JOBS.get(jid)
            if not st: break
            payload={k:st.get(k) for k in("status","progress","file","gif","error")}
            s=json.dumps(payload, ensure_ascii=False)
            if payload!=last: 
                yield f"data: {s}\n\n"; last=payload
            if st.get("status") in ("done","error"): break
            await asyncio.sleep(1.0)
    return StreamingResponse(gen(), media_type="text/event-stream")

@app.get("/api/history")
async def history():
    items=[]
    for jid,d in list(JOBS.items())[-200:]:
        if d.get("status") in("done","error"):
            items.append({"job_id":jid,"status":d["status"],"file":d.get("file"),"gif":d.get("gif")})
    items.reverse(); return JSONResponse(items)

@app.get("/d/{filename}")
async def download_file(filename:str):
    p=DOWNLOAD_DIR/filename
    if not p.exists(): raise HTTPException(404,"File not found.")
    return FileResponse(str(p), filename=filename)

# Robots.txt for basic compliance
@app.get("/robots.txt")
async def robots(): return HTMLResponse("User-agent: *\nDisallow: /\n", media_type="text/plain")
PY

  # ============================ UI/UX ================================
  cat > "${APP_DIR}/backend/templates/index.html" <<'HTML'
<!doctype html><html lang="en"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"/>
<title>{{ appname or 'MediaSnap' }}</title>
<style>
:root{
  color-scheme:light dark; --bg:#0b1220; --card:#0f172a; --line:#1f2937; --muted:#9ca3af; --text:#e5e7eb;
  --ig:#C13584; --tt:#000000; --yt:#FF0000; --fb:#1877f2; --pin:#E60023; --tw:#1DA1F2; --ok:#22c55e; --err:#ef4444; --brand:#2563eb;
}
*{box-sizing:border-box} body{font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:var(--bg);color:var(--text);margin:0;}
.wrap{max-width:1080px;margin:32px auto;padding:0 16px;}
header{display:flex;gap:14px;align-items:center;margin-bottom:18px}
.logo{width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,#6ee7b7,#3b82f6)}
h1{font-size:26px;margin:0}.muted{color:var(--muted);font-size:14px}
.grid{display:grid;grid-template-columns:1fr;gap:16px}@media(min-width:1000px){.grid{grid-template-columns:2fr 1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px}
label{display:block;font-weight:600;margin:0 0 8px}
input[type="text"]{width:100%;padding:14px 12px;border:1px solid #334155;border-radius:12px;background:var(--bg);color:var(--text)}
.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-top:10px}
select,button{padding:12px 16px;border-radius:12px;border:1px solid #334155;background:#0b1220;color:var(--text)}
.btn{background:var(--brand);border:0;color:#fff;font-weight:600;cursor:pointer}
.btn:disabled{opacity:.6;cursor:not-allowed}
.status{margin-top:12px;padding:12px;background:var(--bg);border:1px dashed #334155;border-radius:12px;min-height:44px;white-space:pre-wrap}
.bar{height:10px;background:var(--bg);border:1px solid #334155;border-radius:999px;overflow:hidden;margin-top:8px}
.bar>i{display:block;height:100%;width:0%;background:linear-gradient(90deg,#22c55e,#3b82f6)}
.ok{box-shadow:0 0 12px rgba(34,197,94,.35) inset}.err{box-shadow:0 0 12px rgba(239,68,68,.35) inset}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin:10px 0}.chip{font-size:12px;padding:6px 8px;background:#0b1220;border:1px solid #334155;border-radius:999px}
.preview{display:grid;grid-template-columns:1fr;gap:12px;margin-top:14px}
.preview-item{display:flex;gap:12px;align-items:center;border:1px dashed #334155;border-radius:12px;padding:10px}
img.thumb{width:84px;height:84px;object-fit:cover;border-radius:10px}
small.hint{color:#94a3b8}
footer{margin-top:24px;color:#94a3b8;font-size:12px}
.platform-ig{border-color:var(--ig)} .platform-tt{border-color:var(--tt)} .platform-yt{border-color:var(--yt)} .platform-fb{border-color:var(--fb)} .platform-pin{border-color:var(--pin)} .platform-tw{border-color:var(--tw)}
</style></head>
<body>
<div class="wrap">
<header><div class="logo"></div>
  <div><h1>{{ appname or 'MediaSnap' }}</h1>
    <div class="muted">Paste a public link. Preview first. Then download in the quality you want.</div></div></header>

<div class="grid">
  <div class="card">
    <form id="f">
      <label for="url">Post URL</label>
      <input id="url" name="url" type="text" inputmode="url" placeholder="https://www.instagram.com/reel/... or https://x.com/... or https://www.tiktok.com/..." required/>
      <div class="chips">
        <div class="chip">Instagram</div><div class="chip">TikTok</div><div class="chip">X/Twitter</div>
        <div class="chip">Pinterest</div><div class="chip">Facebook</div><div class="chip">YouTube Shorts</div>
      </div>

      <div class="row">
        <select id="format">
          <option value="">Best (video+audio)</option>
          <option value="audio">Audio MP3</option>
        </select>
        <label style="display:flex;align-items:center;gap:6px;"><input type="checkbox" id="gif"/> Video → GIF</label>
        <input id="items" type="text" placeholder="Items (e.g., 1-3 or 1,3)" title="For carousels/playlists"/>
        <button class="btn" id="preview" type="button">Preview</button>
        <button class="btn" id="go" type="submit">Download</button>
      </div>
      <small class="hint">Only download content you’re allowed to. Robots.txt and copyright rules still apply.</small>
    </form>

    <div id="out" class="status" style="display:none;"></div>
    <div class="bar" aria-hidden="true"><i id="p"></i></div>
    <div id="previewBox" class="preview"></div>
    <p id="link"></p>
  </div>

  <div class="card">
    <strong>Recent Jobs</strong>
    <div id="hist" class="muted" style="margin-top:8px;">No finished jobs yet.</div>
  </div>
</div>

<footer>
  <p>Disclaimer: This tool is for downloading content you have rights to. We do not store user data or media. No accounts, GDPR-friendly.</p>
</footer>
</div>

<script>
const urlEl=document.getElementById('url'), out=document.getElementById('out'), p=document.getElementById('p'), link=document.getElementById('link'), hist=document.getElementById('hist'), previewBtn=document.getElementById('preview'), previewBox=document.getElementById('previewBox'), items=document.getElementById('items');
const form=document.getElementById('f'), fmt=document.getElementById('format'), gif=document.getElementById('gif'), go=document.getElementById('go');

function platformClass(u){
  const x=u.toLowerCase();
  if(x.includes('instagram.')) return 'platform-ig';
  if(x.includes('tiktok.')) return 'platform-tt';
  if(x.includes('youtu')) return 'platform-yt';
  if(x.includes('facebook.')||x.includes('fb.watch')) return 'platform-fb';
  if(x.includes('pinterest.')||x.includes('pin.it')) return 'platform-pin';
  if(x.includes('twitter.')||x.includes('x.')) return 'platform-tw';
  return '';
}

async function refreshHistory(){try{const r=await fetch('/api/history');if(!r.ok)return;const d=await r.json();if(!d.length){hist.textContent='No finished jobs yet.';return}
let h='<ul style="list-style:none;padding:0;margin:6px 0">';for(const it of d){h+=`<li style="margin:6px 0">${it.status==='done'?'✅':'⚠️'} ${(it.file??'').replace(/</g,'&lt;')} ${it.file?`— <a href="/d/${encodeURIComponent(it.file)}" download>Download</a>`:''} ${it.gif?` | <a href="/d/${encodeURIComponent(it.gif)}" download>GIF</a>`:''}</li>`}h+='</ul>';hist.innerHTML=h}catch{}}
refreshHistory();

previewBtn.addEventListener('click', async ()=>{
  previewBox.innerHTML=''; out.style.display='block'; out.textContent='Fetching preview...';
  const fd=new FormData(); fd.append('url', urlEl.value); fd.append('selection', items.value||'');
  const r=await fetch('/api/preview',{method:'POST',body:fd});
  if(!r.ok){ out.textContent='Preview failed: '+(await r.text()); return }
  const d=await r.json(); out.textContent = (d.title? d.title+'\n':'') + (d.platform? ('Platform: '+d.platform):'');
  const cls=platformClass(urlEl.value);
  if(d.entries && d.entries.length){ d.entries.forEach(e=>{ previewBox.innerHTML+=`
    <div class="preview-item ${cls}"><img class="thumb" src="${e.thumbnail||d.thumbnail||''}" alt="">
      <div><div><strong>${(e.title||d.title||'').replace(/</g,'&lt;')}</strong></div>
      <small class="hint">Item #${e.index}</small></div></div>`; }); }
  else { previewBox.innerHTML=`<div class="preview-item ${cls}"><img class="thumb" src="${d.thumbnail||''}" alt=""><div><div><strong>${(d.title||'').replace(/</g,'&lt;')}</strong></div><small class="hint">Ready.</small></div></div>`; }
  // Populate format picks (optional advanced UI)
  if(d.formats && d.formats.length){
    const sel = document.createElement('select'); sel.id='fmtId'; sel.innerHTML='<option value="">Auto (best)</option>'+d.formats.map(f=>`<option value="${f.id}">${f.res} • ${f.ext}</option>`).join('');
    previewBox.appendChild(sel);
  }
});

form.addEventListener('submit', async e=>{
  e.preventDefault(); out.style.display='block'; out.textContent='Starting...'; link.textContent=''; p.style.width='0%'; p.className=''; go.disabled=true;
  const fd=new FormData(form);
  const fmtIdEl=document.getElementById('fmtId'); if(fmtIdEl) fd.append('format_id', fmtIdEl.value||'');
  fd.set('to_gif', gif.checked ? 'true':'false');
  if(fmt.value==='audio'){ fd.set('audio_only','true'); } else { fd.set('audio_only','false'); }
  fd.set('selection', items.value||'');
  const r=await fetch('/api/download',{method:'POST',body:fd});
  if(!r.ok){ out.textContent='Error: '+(await r.text()); go.disabled=false; return }
  const {job_id}=await r.json(); const es=new EventSource('/api/stream/'+job_id);
  es.onmessage=(ev)=>{ try{ const data=JSON.parse(ev.data); const pct=parseFloat((data.progress||'0').toString().replace('%',''))||0; p.style.width=Math.max(0,Math.min(100,pct))+'%';
    out.textContent=`Status: ${data.status}${data.error?' — '+data.error:''}`;
    if(data.status==='done'&&data.file){ p.className='ok'; link.innerHTML=`<a href="/d/${encodeURIComponent(data.file)}" download>⬇️ Download</a>` + (data.gif?` • <a href="/d/${encodeURIComponent(data.gif)}" download>GIF</a>`:''); es.close(); go.disabled=false; refreshHistory(); }
    else if(data.status==='error'){ p.className='err'; es.close(); go.disabled=false; }
  }catch{} };
});
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
      - APP_NAME=${APP_NAME}
      - RATE_LIMIT_RPM=${RATE_LIMIT_RPM}
      - PROXY_LIST=${PROXY_LIST}
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
  if command -v ufw >/dev/null 2>&1; then
    ufw status | grep -q inactive || { ufw allow 80/tcp || true; ufw allow 443/tcp || true; ufw allow ${HOST_PORT}/tcp || true; }
  fi
}

make_service(){
  ok "Creating systemd unit..."
  cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=${APP_NAME} (${SERVICE}) via Docker Compose
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

  tee /etc/nginx/sites-available/mediasnap_default >/dev/null <<NGINX
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
  ln -sf /etc/nginx/sites-available/mediasnap_default /etc/nginx/sites-enabled/000-mediasnap
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
  certbot --nginx -d "${DOMAIN}" --redirect -m "${EMAIL}" --agree-tos -n || warn "Certbot failed — confirm DNS A -> this server, then retry."
}

summary(){
  echo
  ok "${APP_NAME} is ready."
  local ip="$(hostname -I | awk '{print $1}')"
  echo "Open:   http://${ip}/   (via Nginx)"
  echo "Local:  http://127.0.0.1:${HOST_PORT}/"
  [[ -n "$DOMAIN" ]] && echo "Domain: https://${DOMAIN}/"
  echo "Path:   ${APP_DIR}"
  echo "DL dir: ${APP_DIR}/downloads"
  echo
  echo "Useful:"
  echo "  docker compose -f ${APP_DIR}/docker-compose.yml logs -f"
  echo "  systemctl status ${SERVICE}"
  echo
  echo "Tip: set PROXY_LIST env if you need IP rotation. Example:"
  echo "  PROXY_LIST='http://1.2.3.4:8080,https://5.6.7.8:8443'"
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
  cat > "${APP_DIR}/.env" <<ENV
APP_NAME=${APP_NAME}
RATE_LIMIT_RPM=${RATE_LIMIT_RPM}
PROXY_LIST=${PROXY_LIST}
ENV
  cat > "${APP_DIR}/.env.example" <<ENV
APP_NAME=MediaSnap
RATE_LIMIT_RPM=30
PROXY_LIST=
ENV

  # docker-compose with environment injection
  cat > "${APP_DIR}/docker-compose.yml" <<COMPOSE
services:
  web:
    build:
      context: ./backend
    image: ${IMAGE}
    container_name: ${SERVICE}
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:8080"
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

  build_and_run
  open_firewall
  make_service
  setup_nginx
  setup_https
  summary
}
main "$@"
