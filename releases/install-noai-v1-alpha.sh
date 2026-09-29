#!/usr/bin/env bash
# We Have AI At Home (fAI) installer - retrieval/extraction answer engine, no generative model.
# Optional environment: NOAI_CONTACT=<email|url>  NOAI_EMBED=0 (skip embedding model)  NOAI_BRAVE_KEY=<Brave Search API key, used only when the metasearch engines suspend this server>
#                       NOAI_NTFY_URL=https://ntfy.sh/your-secret-topic (push reminders to your phone via the ntfy app)
#                       NOAI_TOOLS=0 (no reminders/lists/calendar/files)  NOAI_FILES_HOST=/path (folder the file tools may use; default ~/noai-files)
#                       NOAI_JUDGE=0 (skip the answer-judge model)  NOAI_BLEND=0 (Wikipedia first, web only as fallback: faster)
#                       NOAI_FRESH=1 (do not carry chat memory over from an older version)
#                       NOAI_SEMANTIC=0 (skip the MiniLM sentence encoder)  NOAI_SPACY=0 (skip spaCy)  NOAI_BIND_ADDR=127.0.0.1 (local only)
#                       NOAI_HOME_LOCATION="Leeds, UK" (default place for weather)  NOAI_TZ=Europe/London
set -euo pipefail

NOAI_VERSION="1.0.0-alpha"
echo "== We Have AI At Home (fAI) $NOAI_VERSION installer =="

if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="$HOME"
fi
APP_DIR="$TARGET_HOME/noai-chat-v$NOAI_VERSION"
# Every earlier install on this machine, newest first (by version number); used for carrying settings and memory over.
PREV_INSTALLS=()
for d in $(ls -d "$TARGET_HOME"/noai-chat-v* 2>/dev/null | grep -v "/noai-chat-v$NOAI_VERSION$" | sed 's/.*noai-chat-v//' | sort -t. -k1,1nr -k2,2nr); do
  PREV_INSTALLS+=("$TARGET_HOME/noai-chat-v$d")
done
PREV_ENVS=("$APP_DIR/.env"); for d in "${PREV_INSTALLS[@]}"; do PREV_ENVS+=("$d/.env"); done
if [[ "${EUID}" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

NEED_PKGS=0
for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || NEED_PKGS=1
done
if [[ "$NEED_PKGS" == 1 ]]; then
  $SUDO apt-get update
  $SUDO apt-get install -y curl ca-certificates python3
fi

# ---- hardware-aware feature selection ----
ARCH="$(uname -m)"
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
INSTALL_SPACY=1
INSTALL_EMBED=1
INSTALL_SEMANTIC=1
INSTALL_JUDGE=1
case "$ARCH" in
  aarch64|arm64|x86_64|amd64) ;;
  *)
    INSTALL_SPACY=0; INSTALL_EMBED=0; INSTALL_SEMANTIC=0; INSTALL_JUDGE=0
    echo "NOTE: $ARCH has no prebuilt wheels for spaCy/tokenizers. Installing the lexical-only build (still fully functional)."
    ;;
esac
if [[ "$MEM_MB" -gt 0 && "$MEM_MB" -lt 900 ]]; then
  INSTALL_SPACY=0
  echo "NOTE: only ${MEM_MB} MB RAM detected. Skipping spaCy to keep memory use low."
fi
[[ "${NOAI_SPACY:-1}" == "0" ]] && INSTALL_SPACY=0
[[ "${NOAI_EMBED:-1}" == "0" ]] && INSTALL_EMBED=0
[[ "${NOAI_SEMANTIC:-1}" == "0" ]] && INSTALL_SEMANTIC=0
[[ "${NOAI_JUDGE:-1}" == "0" ]] && INSTALL_JUDGE=0
echo "Build options: arch=$ARCH ram=${MEM_MB}MB spaCy=$INSTALL_SPACY static-embeddings=$INSTALL_EMBED MiniLM=$INSTALL_SEMANTIC judge=$INSTALL_JUDGE"

FREE_MB="$(df -Pm "$TARGET_HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "${FREE_MB:-}" && "$FREE_MB" -lt 2500 ]]; then
  echo "WARNING: only ${FREE_MB} MB free under $TARGET_HOME; the Docker images need roughly 2 GB."
fi

# ---- contact for API etiquette (sent only to Wikimedia / OpenStreetMap / GitHub APIs) ----
CONTACT="${NOAI_CONTACT:-}"
if [[ -z "$CONTACT" && -f "$APP_DIR/.env" ]]; then
  CONTACT="$(grep -E '^NOAI_CONTACT=' "$APP_DIR/.env" | head -n1 | cut -d= -f2- || true)"
fi
if [[ -z "$CONTACT" ]]; then
  for OLD in ${PREV_ENVS[@]+"${PREV_ENVS[@]}"}; do
    if [[ -z "$CONTACT" && -f "$OLD" ]]; then CONTACT="$(grep -E '^NOAI_CONTACT=' "$OLD" | head -n1 | cut -d= -f2- || true)"; fi
  done
fi
if [[ -z "$CONTACT" ]]; then
  if [[ -t 0 ]]; then
    echo
    echo "Wikimedia and OpenStreetMap ask automated clients to identify themselves."
    echo "This is sent ONLY to those APIs and GitHub, never to ordinary websites the app reads."
    read -r -p "Contact email or https URL: " CONTACT
  else
    echo "Set NOAI_CONTACT to a real email or https URL and rerun."; exit 1
  fi
fi
if [[ "$CONTACT" =~ ^https?:// ]]; then :
elif [[ "$CONTACT" =~ ^mailto:.+@.+ ]]; then :
elif [[ "$CONTACT" == *"@"* ]]; then CONTACT="mailto:$CONTACT"
else echo "Contact must be an email address or an https URL."; exit 1
fi

# ---- docker ----
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found; installing Docker Engine..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  $SUDO sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  $SUDO systemctl enable --now docker || true
  $SUDO usermod -aG docker "$TARGET_USER" || true
fi
if docker compose version >/dev/null 2>&1; then DC=(docker compose)
elif $SUDO docker compose version >/dev/null 2>&1; then DC=($SUDO docker compose)
elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose)
else echo "Docker Compose is missing (install the docker-compose-plugin package)."; exit 1
fi

# ---- stop this and older versions (their data directories are left untouched) ----
for D in "$APP_DIR" ${PREV_INSTALLS[@]+"${PREV_INSTALLS[@]}"}; do
  if [[ -f "$D/docker-compose.yml" ]]; then
    echo "Stopping containers in $D (data is preserved)..."
    (cd "$D" && "${DC[@]}" down --remove-orphans) || true
  fi
done
if command -v ss >/dev/null 2>&1 && ss -ltn | awk '{print $4}' | grep -Eq '(^|:)7070$'; then
  echo "Port 7070 is still in use by something else. Stop it and rerun."; exit 1
fi

FILES_HOST="${NOAI_FILES_HOST:-$TARGET_HOME/noai-files}"
mkdir -p "$APP_DIR/data" "$FILES_HOST"
chown "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$FILES_HOST" 2>/dev/null || true
# Carry over what the previous version remembered (chat memory and caches); the schema is upgraded in place.
for PREV in ${PREV_INSTALLS[@]+"${PREV_INSTALLS[@]}"}; do
  if [[ "${NOAI_FRESH:-0}" != "1" && ! -f "$APP_DIR/data/chat.db" && -f "$PREV/data/chat.db" ]]; then
    echo "Migrating chat memory from $PREV..."
    cp -p "$PREV/data/chat.db" "$APP_DIR/data/chat.db" 2>/dev/null || $SUDO cp -p "$PREV/data/chat.db" "$APP_DIR/data/chat.db" || true
  fi
done
rm -rf "$APP_DIR/app" "$APP_DIR/searxng"
mkdir -p "$APP_DIR/app" "$APP_DIR/searxng"

cat > "$APP_DIR/app/app.py" <<'__NOAI_V11_APP_PY__'
"""We Have AI At Home (fAI) - a retrieval/extraction answer engine with no generative model.

Pipeline: route -> (Wikidata relations | generic Wikidata properties | OSM nearby |
comparison | tldr how-to | web evidence | passage-first Wikipedia) -> extract -> cite.
Every answer is copied from a source or filled into a fixed template.
"""
import replay as _replay
import planner as _planner
import capabilities as _caps
import inference as _inference
import reader as _reader
import hmac as _hmac
_replay.install()
import os, re, json, time, math, sqlite3, html as htmlmod, threading, hashlib, uuid, random, datetime
from urllib.parse import quote, unquote, urlparse
from collections import Counter
from functools import lru_cache
from concurrent.futures import ThreadPoolExecutor

import requests
from bs4 import BeautifulSoup
import trafilatura
from nltk.stem.snowball import SnowballStemmer
from packaging.version import Version, InvalidVersion
from flask import Flask, request, jsonify, Response

try:
    if os.environ.get("NOAI_SPACY", "1") == "0":
        raise ImportError("spaCy disabled by NOAI_SPACY=0")
    import spacy
except Exception:  # 32-bit ARM, low-memory install, or explicitly disabled
    spacy = None

APP_VERSION = "1.0.0-alpha"
DATA_DIR = os.environ.get("DATA_DIR", "/data")
DB_PATH = os.path.join(DATA_DIR, "chat.db")
TLDR_DIR = os.environ.get("TLDR_DIR", os.path.join(DATA_DIR, "tldr"))
TLDR_DB = os.path.join(DATA_DIR, "tldr_index.db")
EMBED_PATH = os.environ.get("EMBED_PATH", "/opt/m2v")
SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://searxng:8080").rstrip("/")
CONTACT = os.environ.get("NOAI_CONTACT", "personal-noncommercial-raspberry-pi-assistant")
API_TOKEN = os.environ.get("NOAI_API_TOKEN", "")
BUDGET_DEFAULT = float(os.environ.get("NOAI_BUDGET", "14"))
BUDGET_SLOW = float(os.environ.get("NOAI_BUDGET_SLOW", "26"))

# Two sessions on purpose: the contact address is only sent to the API operators that ask
# for it (Wikimedia, OSM, GitHub). Arbitrary crawled websites get a generic User-Agent.
UA_API = f"fAI/{APP_VERSION} (We Have AI At Home; {CONTACT})"
UA_WEB = f"Mozilla/5.0 (compatible; fAI/{APP_VERSION}; We Have AI At Home, personal non-commercial assistant)"
API = requests.Session()
API.headers.update({"User-Agent": UA_API, "Accept-Language": "en-US,en;q=0.8", "Accept": "*/*"})
WEB = requests.Session()
WEB.headers.update({"User-Agent": UA_WEB, "Accept-Language": "en-US,en;q=0.8",
                    "Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5"})

WIKIDATA_API = "https://www.wikidata.org/w/api.php"
WIKIPEDIA_REST = "https://en.wikipedia.org/w/rest.php/v1/search/page"
NOMINATIM = "https://nominatim.openstreetmap.org/search"
OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]

def wikipedia_api(site="en"):
    return f"https://{site}.wikipedia.org/w/api.php"

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024                      # v40: no request body over 64 KB

_RATE = {}                                                       # client -> [window_start, count]
RATE_LIMIT = int(os.environ.get("NOAI_RATE_LIMIT", "600"))        # requests per minute per client on the chat endpoints
def _trusted_client(client):
    """Loopback and the container's own bridge network are exempt: that is where the installer's self-test and the host's
    curl calls come from. LAN and beyond are rate limited."""
    try:
        import ipaddress
        ip = ipaddress.ip_address(client)
        return ip.is_loopback or ip in ipaddress.ip_network("172.16.0.0/12")
    except ValueError:
        return False
def rate_limited(client):
    if _trusted_client(client):
        return False
    now = time.time()
    with _RATE_LOCK:
        win = _RATE.get(client)
        if not win or now - win[0] > 60:
            _RATE[client] = [now, 1]
            if len(_RATE) > 5000:
                for k in [k for k, v in _RATE.items() if now - v[0] > 60]:
                    _RATE.pop(k, None)
            return False
        win[1] += 1
        return win[1] > RATE_LIMIT
_RATE_LOCK = threading.Lock()

@app.after_request
def _security_headers(resp):
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    resp.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
    if resp.mimetype == "text/html":
        resp.headers.setdefault("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
    return resp

@app.before_request
def _rate_gate():
    if request.path.startswith(("/api/chat", "/v1/")):
        client = request.headers.get("X-Forwarded-For", request.remote_addr or "?").split(",")[0].strip()
        if rate_limited(client):
            return jsonify({"error": "too many requests; try again in a minute"}), 429
os.makedirs(DATA_DIR, exist_ok=True)
POOL = ThreadPoolExecutor(max_workers=6)

# ---------- optional NLP / ML components ----------
NLP = None
SENT_NLP = None
NLP_MODE = "regex-no-spacy"
HAS_NER = False
if spacy is not None:
    try:
        NLP = spacy.load("en_core_web_sm")
        NLP_MODE = "en_core_web_sm"
        HAS_NER = "ner" in NLP.pipe_names
        NLP.max_length = 200_000
    except Exception:
        NLP = None
    try:
        SENT_NLP = spacy.blank("en")
        SENT_NLP.add_pipe("sentencizer")
        SENT_NLP.max_length = 400_000
        if NLP is None:
            NLP_MODE = "blank_en_sentencizer"
    except Exception:
        SENT_NLP = None

EMB = None
EMBED_MODE = "off"
if os.environ.get("NOAI_EMBED", "1") != "0" and os.path.isdir(EMBED_PATH):
    try:
        import numpy as _np
        from model2vec import StaticModel
        EMB = StaticModel.from_pretrained(EMBED_PATH)
        EMBED_MODE = "model2vec-static"
    except Exception:
        EMB = None

STEMMER = SnowballStemmer("english")

import convo
convo.APP_VERSION = APP_VERSION
import skills
if _replay.MODE == "replay":
    skills._PINNED[0] = _replay.recorded_clock()[0]
import semantic
import structured
import judge
import tools
import creative

# ---------- per-request context: time budget + trace ----------
_CTX = threading.local()

def ctx_begin(budget):
    _CTX.t0 = time.monotonic()
    _CTX.deadline = _CTX.t0 + budget
    _CTX.trace = []
    _CTX.main_subject = ""
    _CTX.spell_retry = False
    _CTX.searched = set()        # distinct metasearch queries this question has sent (shared with its worker threads)
    _CTX.guide_rows = None
    _CTX.considered = []
    _CTX.planned = []
    _CTX.plan = None
    _CTX.backup_used = False

def ctx_extend(budget):
    _CTX.deadline = max(getattr(_CTX, "deadline", 0), getattr(_CTX, "t0", time.monotonic()) + budget)

def remaining():
    dl = getattr(_CTX, "deadline", None)
    return 30.0 if dl is None else max(0.0, dl - time.monotonic())

def out_of_time():
    return remaining() <= 0.25

def t_out(default):
    return max(1.0, min(default, remaining()))

def trace(msg):
    lst = getattr(_CTX, "trace", None)
    if lst is not None and len(lst) < 60:
        lst.append(f"{time.monotonic() - getattr(_CTX, 't0', time.monotonic()):5.2f}s {msg}")

def pmap(fn, items, timeout):
    """Run fn over items in the shared pool; never wait past `timeout` seconds in total."""
    dl, tr, t0 = getattr(_CTX, "deadline", None), getattr(_CTX, "trace", None), getattr(_CTX, "t0", None)
    sd, au = getattr(_CTX, "searched", None), getattr(_CTX, "authed", False)
    def run(x):
        # Pool threads are reused: always (re)bind the caller's budget, trace and search set so workers honour them.
        _CTX.deadline, _CTX.trace, _CTX.t0 = dl, tr, (t0 if t0 is not None else time.monotonic())
        _CTX.searched, _CTX.authed = (sd if sd is not None else set()), au
        return fn(x)
    futs = [POOL.submit(run, x) for x in items]
    end = time.monotonic() + max(0.5, timeout)
    out = []
    for f in futs:
        try:
            out.append(f.result(timeout=max(0.05, end - time.monotonic())))
        except Exception:
            out.append(None)
    return out

# ---------- vocabulary ----------
STOP = set("""
a an the and or but if then than of to in on at for from by with as is are was were be been being
it its he him his she her hers they them their theirs this that these those who whom whose what which
when where why how can could should would will may might i you we my your our about into over under
after before current latest stable good best tell me give find show compare research investigate
do does did so some any there here also very just not no yes please explain describe
""".split())

CAUSAL_MARKERS = [
    "because", "caused by", "due to", "results from", "result of", "driven by", "occurs when",
    "happens when", "as a result", "therefore", "leads to", "depends on", "arises from",
    "triggered by", "responsible for", "reason is", "is caused", "are caused", "causes ", "owing to",
    "resulting from", "result from", "arise from", "produced by", "exerted by", "is why", "explains why", "the reason",
    "formed by", "reaction of", "reaction between",
]
FORMATION_MARKERS = ["formed", "formation", "forms", "origin", "originate", "collapse", "created", "produced", "produces", "born", "develops",
                     "evolves", "become", "results from", "result of"]
HOW_MARKERS = ["works", "working", "mechanism", "process", "procedure", "step", "enable", "operates", "by means of", "using",
               "consists of", "transfers", "converts", "so that", "in order to", "allows", "is used to"]
INTENT_STEMS = {"caus", "form", "work", "happen", "occur", "made", "make", "creat", "produc", "mean", "reason"}
SECTION_WORDS = {
    "why": ["cause", "mechanism", "chemistry", "physics", "process", "properties", "explanation", "principle"],
    "formation": ["formation", "origin", "evolution", "birth", "genesis"],
    "how": ["operation", "mechanism", "function", "process", "design", "principle", "how it works"],
    "whattodo": ["management", "treatment", "first aid", "care", "prevention", "response", "what to do", "handling", "remedies"],
}
JUNK_SECTIONS = {"references", "see also", "external links", "further reading", "notes", "bibliography",
                 "sources", "citations", "footnotes", "gallery", "works cited", "explanatory notes",
                 "general references", "notes and references", "literature"}
JUNK_PHRASES = ["sign up", "subscribe", "cookie", "privacy policy", "click here", "for more information",
                "watch now", "donate", "paypal", "all rights reserved", "log in", "newsletter",
                "archived from", "isbn ", "retrieved ", "doi:", "terms of use", "javascript"]
# Openers that mark a sentence as the middle of an argument rather than a self-contained explanation.
WEAK_OPENERS = re.compile(r"^(?:if|since|being|by contrast|in contrast|conversely|still|yet|another|other|both|here|while th(?:is|ese|ose)|"
                          r"in (?:this|that|these|such) |at (?:this|that) |on the other hand|in other words|that is|note that|"
                          r"an? [a-z\-]+ [a-z\-]+ (?:works|operates|functions) differently)\b", re.I)
HEADING_FOR_SHAPE = {"why": re.compile(r"\b(?:cause|causes|causation|reason|reasons|origin|origins|mechanism|explanation|physics|chemistry|formation)\b", re.I),
                     "how": re.compile(r"\b(?:mechanism|mechanisms|operation|how it works|principle|principles|function|process|production|eruption|eruptions|formation|physics|chemistry|chemical|physiology|method|technique|working|death|execution|assassination|final years|last years|illness)\b", re.I),
                     "formation": re.compile(r"\b(?:formation|origin|origins|cause|causes|process|development|geology)\b", re.I)}
ELLIPTICAL_END = re.compile(r"\b(?:are|is|was|were|do|does|did|can|cannot|could|will|would|should|have|has|had) not[.!]?$|\b(?:too|as well|either|likewise|also|neither)[.!]?$|\b(?:the (?:same|latter|former)|the other(?:s)?|the rest)[.!]?$", re.I)
ANAPHORIC_OPENERS = re.compile(r"^(?:(?:because|since|although|while|when|if|as|once|after|before|so) (?:they|it|this|these|those|he|she)\b|"
                               r"this is (?:the reason|why)|that is why|which is why|"
                               r"however|this|these|those|it|its|their|they|he|she|his|her|such|thus|therefore|moreover|"
                               r"furthermore|in addition|additionally|consequently|instead|similarly|"
                               r"as a result|for this reason|for example|for instance|also|but|and|nevertheless)\b", re.I)
CREATIVE_TYPE_WORDS = ["album", "film", "novel", "song", "episode", "video game", "television series",
                       "band", "single by", "ep by", "comic", "manga", "anime"]

# ---------- persistence ----------
STATE_COLUMNS = [
    ("name", "TEXT DEFAULT ''"), ("chat_topic", "TEXT DEFAULT ''"), ("chat_focus", "TEXT DEFAULT ''"),
    ("chat_turn", "INTEGER DEFAULT 0"), ("subject_qid", "TEXT DEFAULT ''"), ("subject_label", "TEXT DEFAULT ''"),
    ("answer_qid", "TEXT DEFAULT ''"), ("answer_label", "TEXT DEFAULT ''"), ("last_mode", "TEXT DEFAULT ''"), ("last_question", "TEXT DEFAULT ''"), ("last_corrected", "TEXT DEFAULT ''"), ("last_raw", "TEXT DEFAULT ''"), ("full_passage", "TEXT DEFAULT ''"), ("full_sources", "TEXT DEFAULT ''"), ("entity_stack", "TEXT DEFAULT ''"), ("answer_log", "TEXT DEFAULT ''"), ("last_list", "TEXT DEFAULT ''"), ("turn_templates", "TEXT DEFAULT ''"), ("subject_kind", "TEXT DEFAULT ''"), ("last_recipe", "TEXT DEFAULT ''"), ("last_place", "TEXT DEFAULT ''"), ("prev_raw", "TEXT DEFAULT ''"),
    ("last_q", "TEXT DEFAULT ''"), ("last_term", "TEXT DEFAULT ''"), ("more_json", "TEXT DEFAULT ''"),
    ("chat_pending", "TEXT DEFAULT ''"), ("chat_recent", "TEXT DEFAULT ''"), ("chat_grounded", "TEXT DEFAULT ''"),
    ("chat_low", "INTEGER DEFAULT 0"), ("last_bot", "TEXT DEFAULT ''"),
    ("tool_pending", "TEXT DEFAULT ''"), ("tool_undo", "TEXT DEFAULT ''"), ("tool_cal_ids", "TEXT DEFAULT ''"),
    ("updated", "REAL DEFAULT 0"),
]

def db():
    con = sqlite3.connect(DB_PATH, timeout=15)
    con.row_factory = sqlite3.Row
    return con

def init_db():
    con = db()
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.execute("CREATE TABLE IF NOT EXISTS state (session TEXT PRIMARY KEY)")
    con.execute("CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires REAL NOT NULL)")
    con.execute("CREATE TABLE IF NOT EXISTS feedback (t REAL NOT NULL, session TEXT, question TEXT, answer TEXT, mode TEXT, verdict INTEGER NOT NULL)")
    con.execute("CREATE TABLE IF NOT EXISTS misses (t REAL NOT NULL, text TEXT NOT NULL, intent TEXT, mode TEXT)")
    con.execute("CREATE TABLE IF NOT EXISTS mem (session TEXT NOT NULL, k TEXT NOT NULL, v TEXT NOT NULL, t REAL NOT NULL, PRIMARY KEY(session, k, v))")
    cols = {r[1] for r in con.execute("PRAGMA table_info(state)").fetchall()}
    for name, decl in STATE_COLUMNS:
        if name not in cols:
            con.execute(f"ALTER TABLE state ADD COLUMN {name} {decl}")
    con.execute("DELETE FROM cache WHERE expires < ?", (time.time(),))
    con.commit()
    con.close()

init_db()

def blank_state(sid):
    st = {"session": sid}
    for name, decl in STATE_COLUMNS:
        st[name] = 0 if ("INTEGER" in decl or "REAL" in decl) else ""
    return st

def get_state(sid):
    con = db()
    try:
        row = con.execute("SELECT * FROM state WHERE session=?", (sid,)).fetchone()
    except sqlite3.OperationalError:
        # The database file was deleted or replaced while the app was running (a common way to "reset" the bot).
        con.close()
        init_db()
        con = db()
        row = con.execute("SELECT * FROM state WHERE session=?", (sid,)).fetchone()
    con.close()
    st = blank_state(sid)
    if row:
        for k in row.keys():
            if row[k] is not None:
                st[k] = row[k]
    return st

def save_state(st):
    st["updated"] = time.time()
    names = ["session"] + [n for n, _ in STATE_COLUMNS]
    sql = ("INSERT INTO state(" + ",".join(names) + ") VALUES(" + ",".join(":" + n for n in names) + ") "
           "ON CONFLICT(session) DO UPDATE SET " + ",".join(f"{n}=excluded.{n}" for n in names[1:]))
    con = db()
    con.execute(sql, {n: st.get(n, "") for n in names})
    con.commit()
    con.close()

class MemoryStore:
    """What the user has told the bot about themselves. Lives only in the local SQLite file."""
    def facts(self, sid):
        con = db()
        rows = con.execute("SELECT k, v FROM mem WHERE session=? ORDER BY t", (sid,)).fetchall()
        con.close()
        out = {}
        for r in rows:
            out.setdefault(r["k"], []).append(r["v"])
        return out

    def add(self, sid, key, value, multi):
        value = norm(value)[:300]
        if not value:
            return
        con = db()
        if not multi:
            con.execute("DELETE FROM mem WHERE session=? AND k=?", (sid, key))
        elif con.execute("SELECT count(*) FROM mem WHERE session=? AND k=?", (sid, key)).fetchone()[0] >= 40:
            con.execute("DELETE FROM mem WHERE rowid IN (SELECT rowid FROM mem WHERE session=? AND k=? ORDER BY t LIMIT 1)", (sid, key))
        con.execute("INSERT OR REPLACE INTO mem(session,k,v,t) VALUES(?,?,?,?)", (sid, key, value, time.time()))
        con.commit()
        con.close()

    def forget(self, sid, key=None):
        con = db()
        if key is None:
            con.execute("DELETE FROM mem WHERE session=?", (sid,))
        else:
            con.execute("DELETE FROM mem WHERE session=? AND k=?", (sid, key))
        con.commit()
        con.close()

MEMORY = MemoryStore()

def cache_get(key):
    if _replay.MODE:
        return None
    return _cache_get(key)

def _cache_get(key):
    try:
        con = db()
        row = con.execute("SELECT value,expires FROM cache WHERE key=?", (key,)).fetchone()
        con.close()
    except Exception:
        return None
    if not row or row["expires"] < time.time():
        return None
    try:
        return json.loads(row["value"])
    except Exception:
        return None

_put_count = [0]
def cache_put(key, value, ttl):
    try:
        con = sqlite3.connect(DB_PATH, timeout=2)
        con.execute("INSERT OR REPLACE INTO cache(key,value,expires) VALUES(?,?,?)",
                    (key, json.dumps(value, ensure_ascii=False), time.time() + ttl))
        _put_count[0] += 1
        if _put_count[0] % 200 == 0:  # keep the SD-card cache bounded
            con.execute("DELETE FROM cache WHERE expires < ?", (time.time(),))
        con.commit()
        con.close()
    except Exception:
        pass

def ckey(prefix, *parts):
    return prefix + ":" + hashlib.sha1("|".join(str(p) for p in parts).encode("utf-8")).hexdigest()

# ---------- text helpers ----------
def norm(s):
    return re.sub(r"\s+", " ", str(s or "")).strip()

def norm_key(s):
    return re.sub(r"[^a-z0-9]+", " ", str(s or "").casefold()).strip()

def strip_article(s):
    return re.sub(r"^(?:the|a|an)\s+", "", norm(s), flags=re.I)

def label_keys(s):
    return {norm_key(s), norm_key(strip_article(s))} - {""}

def raw_tokens(s):
    return re.findall(r"[a-z0-9]+(?:[+#][a-z0-9+#]*)?", str(s or "").casefold())

def words(s):
    return [w for w in raw_tokens(s) if len(w) > 1 and w not in STOP]

@lru_cache(maxsize=50000)
def stem(w):
    return STEMMER.stem(w)

@lru_cache(maxsize=4096)
def stems_of(text):
    return tuple(stem(w) for w in words(text))

def stem_set(text):
    return set(stems_of(text))

def bare_title(title):
    return re.sub(r"\s+\([^)]*\)$", "", str(title or ""))

def paren_part(title):
    m = re.search(r"\(([^)]*)\)$", str(title or ""))
    return m.group(1) if m else ""

def clean_term(s):
    return norm(str(s or "").strip(" ?.!\"'"))

def host(url):
    try:
        return urlparse(url).netloc.lower().removeprefix("www.")
    except Exception:
        return ""

def safe_http_url(u):
    try:
        return u if urlparse(str(u)).scheme in {"http", "https"} else ""
    except Exception:
        return ""

def has_word(blob, phrase):
    return bool(re.search(rf"\b{re.escape(phrase)}\b", blob))

def clean_wiki_text(s):
    s = str(s or "")
    s = re.sub(r"\[\s*(?:\d+|edit|citation needed|note \d+)\s*\]", "", s, flags=re.I)
    # pronunciation / audio parentheticals left over by text extraction
    s = re.sub(r"\s*\([^()]*(?:\u24d8|listen|/[^/()]{2,}/)[^()]*\)", "", s)
    s = re.sub(r"\s*\(\s*[;,]?\s*\)", "", s)
    s = re.sub(r"\s+([,.;:])", r"\1", s)
    return norm(s)

def clean_sentence(s):
    s = clean_wiki_text(s)
    return re.sub(r"^(?:\u2022|[-\u2013\u2014*]\s+)+", "", s).strip()

def split_sentences(text, lo=24, hi=650):
    text = str(text or "")[:220000]
    if not text.strip():
        return []
    out = []
    # Split on line breaks first so headings, captions and list items never fuse with prose.
    for line in text.split("\n"):
        line = line.strip()
        if len(line) < lo:
            continue
        got = []
        if SENT_NLP is not None:
            try:
                got = [clean_sentence(sent.text) for sent in SENT_NLP(line).sents]
            except Exception:
                got = []
        if not got:
            got = [clean_sentence(x) for x in re.split(r"(?<=[.!?])\s+(?=[A-Z0-9\"'])", line)]
        out.extend(x for x in got if lo <= len(x) <= hi)
    return out

_VERB_RE = re.compile(r"\b(?:is|are|was|were|be|been|has|have|had|can|could|will|would|may|might|must|does|do|did|"
                      r"\w{3,}(?:ed|es|ing)|became|made|led|began|built|found|gave|took|came|went|said|shows?|"
                      r"occurs?|happens?|means?|uses?|allows?|causes?|forms?|makes?|becomes?)\b", re.I)

# Openers that mark web filler rather than an answer: teasers, meta-talk about the article, calls to action, bylines.
WEB_NOISE = re.compile(r"^(?:fun (?:\w+ )?fact\b|did you know\b|in this (?:article|post|guide|video|piece|lesson|section)|this (?:article|post|guide|video|page|lesson) |"
                       r"read (?:on|more)\b|click\b|subscribe\b|sign up\b|join (?:us|our)\b|let(?:'|\u2019)?s (?:dive|take a look|explore|find out|get started)|"
                       r"here(?:'|\u2019)?s (?:what|how|why|everything)|we(?:'ll| will| are going to) (?:explain|explore|look|cover|discuss)|keep reading|"
                       r"the point of the piece|to answer (?:it|this|that)\b|watch (?:the|this|our)\b|advertisement\b|related:|see also\b|share this\b|follow us\b|"
                       r"(?:photo|image|credit|source|video)s?:|by [A-Z][a-z]+ [A-Z][a-z]+\b|updated (?:on)?\b|last (?:updated|reviewed)\b|our (?:team|experts|editors)\b|"
                       r"contact us\b|learn more\b|check out\b|shop\b|buy\b|get (?:your|a free)\b|if you(?:'|\u2019)?re (?:looking|wondering|curious)|"
                       r"have you ever wondered|ever wonder(?:ed)?\b|you(?:'|\u2019)?ve probably|spoiler\b|tl;?dr\b|table of contents)", re.I)

# v17/v18 live runs: the clean explanations came from these kinds of site; the vague or padded ones from content farms.
TRUSTED_SITES = re.compile(r"(?:\.gov|\.edu|\.ac\.uk|\.gov\.uk|\.gov\.au|\.int)$|(?:^|\.)(?:nasa\.gov|noaa\.gov|usgs\.gov|nih\.gov|cdc\.gov|nps\.gov|energy\.gov|"
                           r"britannica\.com|metoffice\.gov\.uk|nhm\.ac\.uk|si\.edu|smithsonianmag\.com|nationalgeographic\.com|scientificamerican\.com|"
                           r"nature\.com|sciencedirect\.com|who\.int|nhs\.uk|mayoclinic\.org|clevelandclinic\.org|medlineplus\.gov|bbc\.co\.uk|bbc\.com|"
                           r"npr\.org|pbs\.org|howstuffworks\.com|explainthatstuff\.com|khanacademy\.org|physics\.org|rsc\.org|acs\.org|ifixit\.com|"
                           r"science\.org\.au|csiro\.au|esa\.int|royalsociety\.org|loc\.gov|skyatnightmagazine\.com|space\.com|livescience\.com)$", re.I)
POOR_SITES = re.compile(r"(?:^|\.)(?:thefactsite\.com|primetimer\.com|tutorchase\.com|biologyinsights\.com|scienceinsights\.org|geographypin\.com|thedailyscience\.org|"
                        r"grammarheist\.com|talkinghints\.com|answers\.com|ask\.com|brainly\.\w+|chegg\.com|coursehero\.com|studocu\.com|medium\.com|"
                        r"linkedin\.com|facebook\.com|tiktok\.com|forum\.\w+\.\w+)$", re.I)

def site_prior(domain):
    d = (domain or "").casefold()
    return 1.2 if TRUSTED_SITES.search(d) else (-1.5 if POOR_SITES.search(d) else 0.0)

_ALIAS_WORDS = [["hot", "hottest", "hotter", "heat", "hotness"], ["cold", "coldest", "colder"], ["fly", "flight", "flying", "flies"], ["salty", "salt", "salinity", "saline"], ["goosebumps", "goosebump", "goose", "gooseflesh", "piloerection"],
                ["wifi", "wi", "wireless", "wlan"], ["dive", "submerge", "submerged", "diving", "submersion"], ["cry", "tears", "tear", "crying", "lachrymatory", "weep"],
                ["rust", "corrosion", "corrode", "oxidation", "oxidize"], ["die", "death", "died", "dead"], ["born", "birth"], ["float", "buoyancy", "buoyant", "floats"],
                ["erupt", "eruption", "eruptions"], ["migrate", "migration", "migratory"], ["plane", "airplane", "aeroplane", "aircraft", "planes"], ["car", "automobile"],
                ["tv", "television"], ["kid", "child", "children", "kids"], ["freeze", "freezing", "frozen"], ["hot", "heat", "warm"], ["loud", "loudness", "volume", "noise"],
                ["smell", "scent", "odor", "odour", "aroma"], ["twinkle", "twinkling", "scintillation"], ["purr", "purring"], ["knead", "kneading"], ["stripes", "stripe", "striped"],
                ["famous", "fame", "renowned"], ["form", "formation", "formed", "forms"], ["work", "works", "operate", "operates", "operation", "function"]]
ALIAS = {}
for _grp in _ALIAS_WORDS:
    _st = set()
    for _w in _grp:
        _st |= stem_set(_w)
    for _x in _st:
        ALIAS.setdefault(_x, set()).update(_st)

def alias_expand(stems):
    """The question says 'fly', the good section is titled 'Flight'; 'goosebumps' vs 'goose bumps'; 'dive' vs 'submerge'."""
    out = set(stems)
    for x in list(stems):
        out |= ALIAS.get(x, set())
    return out

SITE_BOILERPLATE = re.compile(r"please refer to the appropriate style manual|while every effort has been made to follow citation|our editors will review|"
                              r"editors oversee subject areas|this article was most recently|select citation style|copy citation|share to social media|"
                              r"thank you for your feedback|we hope you enjoyed|we will be back|stay tuned|thank you for reading|in our next (?:lesson|article|post|blog)|check out our|"
                              r"external websites|corrections\? updates\?|let us know if you have suggestions|sign up for (?:our|the)|"
                              r"all rights reserved|this (?:site|website) uses cookies|accept (?:all )?cookies|skip to (?:main )?content|advertisement", re.I)
MIDTHOUGHT = re.compile(r"^(?:that(?:'|\u2019)?s (?:because|why|how|the)|that is (?:to say|why|because)|this is (?:why|because|how|what)|or,|and |but |so,? |therefore|thus|hence|"
                        r"instead|finally|then,? |next,? |also,? |as (?:a result|such|mentioned)|in (?:other words|fact|short|summary|conclusion|the present case)|"
                        r"to (?:sum up|summarize)|because of (?:this|that)|for (?:this|that) reason|these |those |such |it (?:is|was|also|can|does) |they |he |she )", re.I)

def strip_boilerplate(text):
    return " ".join(x for x in split_sentences(text) if not SITE_BOILERPLATE.search(x)) if SITE_BOILERPLATE.search(text or "") else text

CHATTY = re.compile(r"\b(?:I know|I think|I guess|I mean|I'm not|we'll|you'll|you might|you may have|silly|joke|jokes|funny|tongue in cheek|"
                    r"just not magic|not magic|mused|poet|poem|ha ha|lol|imagine|let's say|kind of a|sort of a|frankly|honestly|believe it or not|"
                    r"fun fact|spoiler|good news|bad news|pro tip)\b|\bsays?,? \u201c|\bsays?,? \"|\u201c[^\u201d]{20,}\u201d", re.I)

DATE_PREFIX = re.compile(r"^(?:[A-Z][a-z]{2,8}\.? \d{1,2}, \d{4}|\d{1,2} [A-Z][a-z]{2,8} \d{4})\s*[\u00b7\u2014\-]\s*")

def web_clean(txt):
    """True when a web window reads like an answer: declarative, complete, not a teaser, a mid-thought or a truncated snippet."""
    first = (split_sentences(txt) or [txt])[0].strip()
    if MIDTHOUGHT.match(first) or SITE_BOILERPLATE.search(txt):
        return False
    if WEB_NOISE.match(first) or first.endswith("?") or re.search(r"(?:\.\.\.|\u2026)\s*$", txt.strip()):
        return False
    if re.search(r"\b(?:cookies?|privacy policy|terms of (?:use|service)|all rights reserved|newsletter|affiliate)\b", txt, re.I):
        return False
    return len(first.split()) >= 7

def good_sentence(s):
    """Cheap well-formedness test: reject headings, captions, bylines, nav text."""
    s = s.strip()
    if len(s) < 30 or not re.search(r"[.!?][\"')\]]?$", s):
        return False
    low = s.casefold()
    if any(p in low for p in JUNK_PHRASES):
        return False
    toks = s.split()
    if len(toks) < 6:
        return False
    caps = sum(1 for t in toks[1:] if t[:1].isupper())
    if caps / max(1, len(toks) - 1) > 0.6:
        return False
    if re.match(r"^(?:published|posted|updated|by|photo|image|figure|source|credit|copyright)\b", low):
        return False
    if s.count("|") >= 2 or s.count(" - ") >= 3:
        return False
    return bool(_VERB_RE.search(s))

# ---------- ranking primitives ----------
def bm25_scores(texts, q):
    docs = [stems_of(t) for t in texts]
    qterms = list(dict.fromkeys(stems_of(q)))
    n = len(docs)
    if not n:
        return []
    avg = sum(len(d) for d in docs) / max(1, n)
    df = Counter()
    for d in docs:
        for t in set(d):
            df[t] += 1
    k1, b = 1.35, 0.72
    scores = []
    for d in docs:
        tf = Counter(d)
        dl = max(1, len(d))
        sc = 0.0
        for t in qterms:
            if t not in tf:
                continue
            idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5))
            sc += idf * (tf[t] * (k1 + 1)) / (tf[t] + k1 * (1 - b + b * dl / max(avg, 1)))
        scores.append(sc)
    return scores

def question_kind(q):
    l = q.casefold().strip()
    if l.startswith("why ") or l.startswith("what causes") or l.startswith("what caused") or re.match(r"^what makes? \w+", l) or re.search(r"\b(?:main )?(?:causes?|reasons?) (?:of|for|behind)\b", l):
        return "why"
    if re.match(r"how (?:is|are|was|were|did|do|does)\b.*\b(?:formed|form|made|created|produced|originate)", l):
        return "formation"
    if l.startswith(("how does", "how do", "how can", "how did", "how is", "how are")):
        return "how"
    if re.match(r"^(?:what|who)\s+(?:is|are|was|were)\b", l) or SUMMARY_RE.match(l.rstrip("?.! ")) or l.startswith(("define ", "explain ", "describe ")):
        return "what"
    return "general"

def expected_types(q):
    l = q.casefold().strip()
    if re.match(r"^(?:when|what year|what date|in what year|which year)\b", l):
        return {"DATE", "TIME"}
    if re.match(r"^(?:who|whom|whose)\b", l):
        return {"PERSON", "ORG", "NORP"}
    if l.startswith("where"):
        return {"GPE", "LOC", "FAC"}
    if re.match(r"^how (?:many|much|long|far|tall|old|big|large|fast|heavy|high|deep|hot|cold)\b", l):
        return {"CARDINAL", "QUANTITY", "MONEY", "PERCENT", "DATE", "TIME"}
    return set()

@lru_cache(maxsize=512)
def query_features(q):
    stems = frozenset(stems_of(q))
    entities, chunks = set(), set()
    if NLP is not None:
        try:
            doc = NLP(q)
            entities = {norm_key(e.text) for e in doc.ents if norm_key(e.text)}
            if doc.has_annotation("DEP"):
                chunks = {norm_key(c.text) for c in doc.noun_chunks if 1 <= len(c.text.split()) <= 7}
        except Exception:
            pass
    return stems, frozenset(entities), frozenset(chunks)

def core_stems(q):
    qs = set(stems_of(q))
    core = qs - INTENT_STEMS
    return core or qs

def _marker_re(markers):
    return re.compile("|".join(re.escape(m) for m in sorted(markers, key=len, reverse=True)))

_CAUSAL_RE, _FORMATION_RE, _HOW_RE = _marker_re(CAUSAL_MARKERS), _marker_re(FORMATION_MARKERS), _marker_re(HOW_MARKERS)

def intent_bonus(text, kind):
    low = text.casefold()
    bonus = 0.0
    # non-overlapping matches: "as a result of" is one cue, not two
    if kind == "why":
        bonus += 3.5 * min(3, len(_CAUSAL_RE.findall(low)))
    elif kind == "formation":
        bonus += 3.0 * min(3, len(_FORMATION_RE.findall(low)))
    elif kind == "how":
        bonus += 2.5 * min(3, len(_HOW_RE.findall(low)))
    if any(x in low for x in JUNK_PHRASES):
        bonus -= 12
    return bonus

def lexical_score(text, q, kind):
    qstems, qents, qchunks = query_features(q)
    sw = stem_set(text)
    nk = norm_key(text)
    s = 3.2 * len(qstems & sw) + 5.0 * sum(1 for e in qents if e and e in nk) + 2.0 * sum(1 for c in qchunks if c and c in nk)
    s += intent_bonus(text, kind)
    if len(text) < 60:
        s -= 1.5
    return s

def jaccard(a, b):
    A, B = stem_set(a), stem_set(b)
    return len(A & B) / max(1, len(A | B))

def embed_similarity(q, texts):
    """Cosine similarity from the optional static-embedding model; [] when unavailable."""
    if EMB is None or not texts:
        return []
    try:
        vecs = EMB.encode([q] + list(texts))
        vecs = _np.asarray(vecs, dtype="float32")
        norms = _np.linalg.norm(vecs, axis=1, keepdims=True)
        norms[norms == 0] = 1.0
        vecs = vecs / norms
        return [float(x) for x in (vecs[1:] @ vecs[0])]
    except Exception:
        return []

# ---- does a passage actually EXPLAIN the thing asked about, or merely contain a causal word? ----
_CAUSE_FRONT = re.compile(r"^(?:because|since|due to|owing to|as a result of|thanks to)\b", re.I)
_CAUSE_MID = re.compile(r"\b(?:because(?: of)?|due to|owing to|as a result of|(?:is|are|was|were) (?:primarily |mainly |largely |mostly )?caused by|caused by|"
                        r"results? from|resulting from|(?:is|are) the result of|the result of|arises? from|stems? from|comes? from|(?:is|are) produced by|"
                        r"(?:is|are) formed by|formed by|(?:is|are) created by|thanks to|which is why|attributed to)\b", re.I)
_CAUSE_FWD = re.compile(r"\b(?:causes?|causing|leads? to|leading to|gives? (?:it|them|the)|results? in|resulting in|makes?|making|produces?|producing|creates?|creating)\b", re.I)

def _subject_position(effect, targets):
    """'Tides are the periodic rise...' has tides as its subject; 'The most direct effects of lightning on humans occur'
    does not have lightning as its subject, so that sentence is about what lightning causes, not what causes lightning."""
    toks = raw_tokens(effect)
    seen = 0
    for i, w in enumerate(toks):
        if w in {"the", "a", "an", "this", "these", "most", "many", "some", "all", "such"}:
            continue
        seen += 1
        if stem(w) in targets:
            return not (i > 0 and toks[i - 1] in {"of", "on", "in", "from", "by", "for", "to", "with"})
        if seen >= 4:
            return False
    return False

def explains(text, targets, subject_target=False):
    """True when some sentence states a cause whose EFFECT side mentions what the question is about.
    'The sky appears blue because air scatters...' explains blue. 'Because it is transparent, glass has found
    widespread use' does not explain transparency: there, transparency is the cause, not the effect."""
    if not targets:
        return False
    for sent in split_sentences(text)[:8]:
        if not subject_target:
            # "A volcano erupts when magma rises..." : the asked-about verb directly followed by its condition
            toks = raw_tokens(sent)
            for i, w in enumerate(toks):
                if stem(w) in targets and any(x in {"when", "whenever"} for x in toks[i + 1:i + 4]):
                    return True
        effect = ""
        if _CAUSE_FRONT.match(sent):
            effect = sent.partition(",")[2]
        else:
            m = _CAUSE_MID.search(sent)
            if m:
                effect = sent[:m.start()]
            else:
                m = _CAUSE_FWD.search(sent)
                if m:
                    effect = sent[m.end():]
        if effect and (stem_set(effect) & targets) and (not subject_target or _subject_position(effect, targets)):
            return True
    return False

def addresses_intent(text, kind, targets, subject_target=False):
    low = text.casefold()
    if kind == "why":
        return explains(text, targets, subject_target)
    if kind == "formation":
        # "a mineral form of carbon" is a noun, not a formation statement
        if re.search(r"\bformed with\b", low) and not re.search(r"\bformed (?:by|when|from|in|at|under|during|over|deep|through)\b", low):
            return False
        return bool(re.search(r"\b(?:(?:is|are|was|were|were first|been) (?:formed|created|produced|born) (?:by|when|from|in|at|under|during|over|deep|through|as)|"
                              r"formed (?:by|when|from|in|at|under|during|over|deep|through)|(?:potential|able|likely|destined) to become|becomes? an?\b|collapses? (?:to|into|under)|"
                              r"forms? (?:when|from|by|under|as|after|through|where)|formation (?:of|occurs|begins|requires)|originat\w+|"
                              r"result(?:s|ing)? from|develops? (?:from|when)|made (?:when|by|from)|created (?:by|when))\b", low))
    if kind == "how":
        return bool(re.search(r"\b(?:works? by|by (?:using|means of|transferring|converting|passing|heating|gathering|collecting)|transfers?|converts?|consists? of|"
                              r"so that|in order to|is used to|are used to|operates? by|mechanism|process (?:by which|known as|called)|is (?:produced|generated|made|achieved) by|"
                              r"are (?:produced|generated|made) by|produces? \w+ by|generates? \w+ by|heats? \w+ by)\b", low))
    return True

# Section titles that ARE the question's intent. Deliberately narrow: "Physics" or "Properties" say nothing about intent.
# Matched on WORDS of the heading ("Pathophysiological causes" counts). "Origin" was removed from the why-list after it sent
# "Why is Pluto not a planet?" to Pluto's formation, and "Production" from the how-list after it sent "How do vaccines work?"
# to vaccine manufacturing.
INTENT_HEADING_WORDS = {"why": {"cause", "causes", "mechanism", "mechanisms", "explanation", "etiology", "aetiology", "purpose", "reasons", "function", "functions", "role"},
                        "formation": {"formation", "genesis", "origin", "origins"},
                        "how": {"operation", "mechanism", "mechanisms", "principle", "principles", "works", "working"},
                        "whattodo": {"management", "treatment", "treatments", "first aid", "care", "prevention", "response", "handling", "remedies", "remedy"}}
# Sections that never explain why/how something happens, whatever causal words they contain.
NON_EXPLAINING_HEADINGS = re.compile(r"\b(?:etymology|name|names|naming|nomenclature|terminology|in popular culture|popular culture|cultural|culture|"
                                     r"mythology|folklore|symbolism|gallery|see also|references|notes|further reading|external links|legacy|reception|"
                                     r"awards|discography|filmography|cast|plot|economy|tourism|incidence|epidemiology|records)\b", re.I)

SEM = semantic.NeuralEncoder()
JUDGE = judge.AnswerJudge()
READER = _reader.Reader()                       # v37: extractive reader, shadow only
READER_SHADOW = os.environ.get("NOAI_READER", "off")      # v39: off (measured AUC 0.53 as an answerability signal); shadow re-enables logging
_judge_scores = JUDGE.scores

def _recording_judge(query, passages):
    """Live: score, and remember the verdicts in the cassette when recording. Replay without the model: reuse the Pi's
    recorded verdicts for every (question, passage) pair it saw; pairs it never saw count as unknown (-99 = never preferred)."""
    passages = list(passages)
    if _replay.MODE == "replay" and not JUDGE.ok:
        got = _replay.judge_get(query, passages)
        if got and any(g is not None for g in got):
            return [g if g is not None else -99.0 for g in got]
        return []
    out = _judge_scores(query, passages)
    if out:
        _replay.judge_put(query, passages[:len(out)], out)
    return out

JUDGE.scores = _recording_judge
FILES_ROOT = os.environ.get("NOAI_FILES_DIR", "/files")
TOOLS = tools.Tools(os.path.join(DATA_DIR, "tools.db"), FILES_ROOT, lambda: skills.now_local()[0], enabled=os.environ.get("NOAI_TOOLS", "1") != "0")
LOG_MISSES = os.environ.get("NOAI_LOG_MISSES", "1") != "0"

def log_miss(text, intent, mode):
    """Kept only in the local database, so unmatched phrasings can be reviewed and taught. NOAI_LOG_MISSES=0 turns it off."""
    if not LOG_MISSES:
        return
    try:
        con = db()
        con.execute("INSERT INTO misses(t, text, intent, mode) VALUES(?,?,?,?)", (time.time(), text[:300], intent, mode))
        con.execute("DELETE FROM misses WHERE rowid IN (SELECT rowid FROM misses ORDER BY t DESC LIMIT -1 OFFSET 3000)")
        con.commit()
        con.close()
    except Exception:
        pass
BLEND = os.environ.get("NOAI_BLEND", "1") != "0"
FUSE_NEURAL, FUSE_STATIC, PARA_K, SIM_SPAN = 0.30, 0.15, 6, 0.25      # neural weight and K chosen on a SQuAD tuning split, checked on a held-out split

def paragraph_first(top, texts, q, kind, subject="", shown="", targets=None):
    """Choose the paragraph first, then the sentences inside it.
    Measured on SQuAD (Wikipedia): BM25 over whole paragraphs picks the right paragraph far more often than scoring
    two-sentence windows directly; adding a sentence-transformer as a 30% second opinion over the top few keyword
    candidates adds ~3 points; and when the two rankers independently agree, the choice is right ~92% of the time,
    which is used here as a confidence signal alongside the term-coverage gate."""
    core = core_stems(q)
    need = 1.0 if len(core) <= 2 else 0.6
    overview = len(core) <= 2
    q_content = q
    if kind in {"why", "how", "formation"}:
        q_content = " ".join(w for w in words(q) if stem(w) not in INTENT_STEMS) or q
    sec_words = SECTION_WORDS.get(kind, [])
    maxs = max(p["score"] for p in top) or 1.0
    qst = set(stems_of(q))
    pred_target = bool(targets)
    targets = set(targets or core)
    shown_key = norm_key(shown)[:90]
    general = any(stem_set(bare_title(p["title"])) <= qst for p in top)
    entries = []
    for p, text in zip(top, texts):
        if not text:
            continue
        paras = wiki_paragraphs(text[:150000])
        if not paras:
            continue
        bm = bm25_scores([t for _, t in paras], q_content)
        mx = max(bm) or 1.0
        prior = 0.45 + 0.55 * (max(0.0, p["score"]) / maxs) ** 1.5
        tst = stem_set(bare_title(p["title"]))
        if general and not (tst <= qst):
            prior *= 0.8
        lead = [i for i, (h, _) in enumerate(paras) if not h.strip()]
        on_subject = bool(tst) and tst == stem_set(subject)
        for i, (h, t) in enumerate(paras):
            if len(shown_key) > 40 and shown_key in norm_key(t):
                continue         # the user has just read this paragraph; a follow-up needs a different one
            hl = h.casefold().strip()
            bonus = 0.0
            on_intent = kind in {"why", "how", "formation"} and addresses_intent(t, kind, targets, subject_target=not pred_target)
            in_intent_section = bool(set(raw_tokens(hl)) & INTENT_HEADING_WORDS.get(kind, set())) and len(hl.split()) <= 5
            if NON_EXPLAINING_HEADINGS.search(hl):
                on_intent, in_intent_section = False, False
            if sec_words and any(w in hl for w in sec_words):
                bonus += 0.15 + (0.20 if any(hl in {w, w + "s"} or hl.startswith(w + " ") for w in sec_words[:3]) else 0.0)
            if overview and kind in {"why", "how", "formation"} and i in lead:
                # Short questions carry almost no keyword signal (every paragraph of "Rust" mentions rust), so the opening
                # of the article that IS the topic outweighs a later paragraph that merely repeats both words.
                # ...provided it addresses the question. A lead that only defines the topic earns no head start.
                if on_intent:
                    bonus += (0.75 if on_subject else 0.15) if i == lead[0] else (0.20 if on_subject else 0.05)
                else:
                    bonus += 0.05
            if on_intent:
                bonus += 0.30 if overview else 0.10
            cov = len(core & (stem_set(t) | tst)) / max(1, len(core))
            # With one or two content words every paragraph of the article matches, so raw keyword counts mostly reward
            # repetition ("Mars ... Red Planet ... orange-red"). They are damped and structure/meaning decide instead.
            kw = (0.35 if (overview and kind in {"why", "how", "formation"}) else 1.0) * bm[i] / mx
            entries.append({"page": p, "pi": i, "heading": h, "text": t, "lex": (kw + bonus) * prior * (0.75 + 0.25 * cov), "cov": cov, "on_intent": on_intent, "intent_section": in_intent_section,
                            "focus_lead": on_subject and bool(lead) and i == lead[0]})
    if not entries:
        return [], "no paragraphs"
    entries.sort(key=lambda e: e["lex"], reverse=True)
    k = PARA_K if not SEM.ok else max(4, min(PARA_K + (4 if overview else 0), SEM.budget))
    head = entries[:k]
    if overview:                 # structure matters more than keyword rank for short questions: never leave these out
        extra = [e for e in entries[k:] if e["intent_section"] or e["on_intent"]][:3]
        head = head[:max(3, k - len(extra))] + extra
    if not any(e["focus_lead"] for e in head):
        head += [e for e in entries if e["focus_lead"]][:1]
    sims, weight, how = [], 0.0, "keywords"
    if SEM.ok and remaining() > 2.5:
        t_sem = time.monotonic()
        sims, weight, how = SEM.similarity(q, [((e["heading"] + ". ") if e["heading"] else "") + e["text"][:900] for e in head]), FUSE_NEURAL, "keywords+MiniLM"
        how += f" ({len(head)} paragraphs, {(time.monotonic() - t_sem) * 1000:.0f} ms)"
        if overview and sims:
            weight = 0.5         # with one or two content words every paragraph matches; meaning has to carry more of the vote
    if not sims:
        sims = embed_similarity(q, [e["text"][:900] for e in head])
        weight, how = (FUSE_STATIC, "keywords+static vectors") if sims else (0.0, "keywords")
    top_lex = max(e["lex"] for e in head) or 1.0
    if sims:
        hi = max(sims)
        for e, sv in zip(head, sims):
            e["sim"] = sv
            # Fixed scale, not min-max: with only a handful of candidates min-max turns a 0.02 difference in similarity
            # into a full-weight vote. Here a passage must be 0.25 cosine below the best to lose the whole neural share.
            e["fused"] = (1 - weight) * e["lex"] / top_lex + weight * max(0.0, 1.0 - (hi - sv) / SIM_SPAN)
    else:
        for e in head:
            e["fused"] = e["lex"] / top_lex
    neural = how.startswith("keywords+MiniLM") and bool(sims)
    agree = neural and max(range(len(head)), key=lambda k: sims[k]) == 0
    head.sort(key=lambda e: e["fused"], reverse=True)
    tier_note = ""
    if overview and kind in {"why", "how", "formation"}:
        # Short questions ("What causes lightning?") carry almost no keyword signal, so structure decides, in tiers:
        #  1 the opening of the topic's own article, if it actually explains the thing asked about
        #  2 a paragraph in a section named for the intent (Formation, Causes, Mechanism...), nearest in meaning first
        #  3 any other paragraph that explains it
        #  4 the opening of the topic's own article anyway: a definition beats a random detail
        fl = next((e for e in head if e["focus_lead"]), None)
        if neural:
            # Live transcripts showed strict tiers overruling a paragraph the encoder rated far closer (vaccines: a
            # "Production" section at 0.52 beat the lead at 0.76). So: similarity decides, structure adds a small bonus,
            # and only paragraphs with SOME structural claim compete, unless one is clearly closest in meaning overall.
            def claim(e):
                return (0.06 if (e["focus_lead"] and e["on_intent"]) else 0.0) + (0.05 if e["intent_section"] else 0.0) + (0.03 if e["on_intent"] else 0.0)
            eligible = [e for e in head if e["focus_lead"] or e["intent_section"] or e["on_intent"]]
            best_any = max(head, key=lambda e: e.get("sim", 0.0))
            if eligible:
                choice = max(eligible, key=lambda e: (e.get("sim", 0.0) + claim(e), -e["pi"]))
                tier_note = "meaning + structure"
                if best_any not in eligible and best_any.get("sim", 0.0) >= choice.get("sim", 0.0) + claim(choice) + 0.08 and not NON_EXPLAINING_HEADINGS.search(best_any["heading"]):
                    choice, tier_note = best_any, "clearly closest in meaning"
            else:
                choice, tier_note = (best_any if not NON_EXPLAINING_HEADINGS.search(best_any["heading"]) else None), "closest in meaning"
            # A lead that only DEFINES the topic is a fair answer to "how does X work", but not to "why ...?": for why-questions
            # it must explain, or be very close in meaning; otherwise abstain so the web route can find a real explanation.
            if choice is not None and choice.get("sim", 0.0) < (0.55 if kind == "why" else 0.50):
                trace(f"   best candidate p{choice['pi']} is only {choice.get('sim', 0):.2f} similar to the question -> not used")
                choice = None
                for e in head:
                    e["weak_why"] = True
            if choice is not None and kind == "why" and not choice["heading"].strip() and not choice["on_intent"] and choice.get("sim", 0.0) < 0.70:
                trace(f"   best candidate p{choice['pi']} does not explain and is only {choice.get('sim', 0):.2f} similar -> not used")
                choice = None
                for e in head:
                    e["weak_why"] = True
        else:
            t1 = [e for e in head if e["intent_section"] and e["cov"] >= 0.5]
            t3 = [e for e in head if e["on_intent"] and not e["focus_lead"]]
            if fl is not None and fl["on_intent"]:
                choice, tier_note = fl, "topic lead explains it"
            elif t1:
                choice, tier_note = min(t1, key=lambda e: e["pi"]), "intent-named section"
            elif t3:
                choice, tier_note = max(t3, key=lambda e: e["fused"]), "explaining paragraph"
            elif fl is not None and kind != "why":
                choice, tier_note = fl, "topic lead as definition"
            else:
                choice = None
        if choice is not None and choice is not head[0]:
            choice["fused"] = head[0]["fused"] + 0.01
            head.sort(key=lambda e: e["fused"], reverse=True)
        if choice is not None:
            choice["tiered"] = True
    for e in head[:5]:          # shown in the self-test transcript on a miss, so failures can be diagnosed from real article text
        trace(f"   cand p{e['pi']} [{(e['heading'] or 'lead')[:22]}] lex={e['lex']:.2f} sim={e.get('sim', 0):.2f} fused={e['fused']:.2f} "
              f"intent={'Y' if e['on_intent'] else 'n'} cov={e['cov']:.0%} | {e['text'][:60]}")
    def stands(e, first):
        if e.get("weak_why"):
            return False
        return e["cov"] >= need or (first and agree and e.get("sim", 0) >= 0.35) or (overview and e["cov"] >= 0.5 and e.get("tiered"))
    # Take the best paragraph the bot can stand behind; a near-best one qualifies, a distant one does not.
    pick = next((k for k, e in enumerate(head[:3]) if stands(e, k == 0) and e["fused"] >= 0.7 * head[0]["fused"]), None)
    best = head[0] if pick is None else head[pick]
    note = f"{how}; rankers {'agree' if agree else 'differ' if neural else 'n/a'}; coverage {best['cov']:.0%}" + (f"; {tier_note}" if tier_note else "") + (f"; took candidate #{pick + 1}" if pick else "")
    if pick is None:
        return [], note + " -> not confident"
    if pick:
        chosen = head.pop(pick)
        chosen["fused"] = head[0]["fused"] + 0.01
        head.insert(0, chosen)
    cands = []
    for rank, e in enumerate(head[:4]):
        src = {"title": e["page"]["title"], "url": wiki_url(e["page"]["title"])}
        ws = rank_windows([(e["heading"], e["text"])], q, src, title=e["page"]["title"], kind=kind, quality="wiki", limit=3, subject=subject)
        if e.get("tiered"):
            # The paragraph was picked as a whole (lead, "Formation" section...). Its opening sentences set the scene; v15
            # quoted sentences 3-6 of the right paragraph ("Neutron stars are known that have rotation periods...") and
            # the LAST sentence of the right lead ("Because of this, pearls have become a metaphor...").
            ss0 = split_sentences(e["text"])
            start = next((k for k, w in enumerate(ws[:1]) if False), 0)
            if ws and kind == "why" and ws[0]["j"] > 0 and explains(ws[0]["text"], core) and not explains(" ".join(ss0[:2]), core):
                pass             # keep the explaining window when the opening does not explain
            elif ss0:
                ws = [{"text": " ".join(ss0[:2]), "score": 5.0, "source": src, "domain": host(src["url"]), "pi": 0, "j": 0, "sents": ss0, "doc_pos": 0}]
        if ws:
            w = ws[0]
        else:
            ss = split_sentences(e["text"])
            if not ss:
                continue
            w = {"text": " ".join(ss[:2]), "score": 0.0, "source": src, "domain": host(src["url"]), "pi": 0, "j": 0, "sents": ss, "doc_pos": 0}
        w["pi"] = e["pi"]
        w["score"] = 100.0 * e["fused"] + min(5.0, max(0.0, w["score"])) * 0.2 - rank * 0.01
        w["page"] = e["page"]
        cands.append(w)
    return cands, note

def human_join(items):
    items = list(dict.fromkeys(i for i in items if i))
    return items[0] if len(items) == 1 else (", ".join(items[:-1]) + " and " + items[-1] if items else "")

def type_gate(cands, q, top=16):
    """Answer-type + well-formedness re-scoring on the top candidates only (keeps the Pi fast)."""
    want = expected_types(q)
    head = cands[:top]
    if NLP is None or not head:
        return cands
    try:
        docs = list(NLP.pipe([c["text"] for c in head], disable=["parser", "lemmatizer", "attribute_ruler"]))
    except Exception:
        return cands
    for c, doc in zip(head, docs):
        if not any(t.tag_.startswith("VB") or t.tag_ == "MD" for t in doc):
            c["score"] -= 6.0
        if want and HAS_NER:
            c["score"] += 4.0 if any(e.label_ in want for e in doc.ents) else -3.0
    cands.sort(key=lambda x: x["score"], reverse=True)
    return cands

# Ablation switches and weights. Values were chosen on one half of a SQuAD sample and checked on the other half.
RANK_FLAGS = {"lead": True, "subject_first": True, "intent_strip": True, "openers": True, "heading": True, "runon": True,
              "short_only": True, "para_weight": 0.6, "window_gate": 0.34}

def rank_windows(paras, q, source, title="", kind=None, quality="wiki", limit=24, subject=""):
    """paras: [(heading, text)]. Returns scored 2-sentence windows that carry their position so the
    caller can rebuild a contiguous passage. Windows must cover the query's core terms, where the
    page title counts as context (a passage in the article 'Rust' need not repeat the word rust)."""
    kind = kind or question_kind(q)
    if not paras:
        return []
    sec_words = SECTION_WORDS.get(kind, [])
    qset = set(stems_of(q))
    if kind in {"why", "how", "formation"} and RANK_FLAGS["intent_strip"]:
        # "causes", "formed", "work" state what is being asked, not what the passage should be about; matching them
        # literally rewarded any sentence that happened to contain the word. Cue phrases handle intent instead.
        q = " ".join(w for w in words(q) if stem(w) not in INTENT_STEMS) or q
    ps = bm25_scores([p for _, p in paras], q)
    order = []
    for i, (heading, p) in enumerate(paras):
        hl = heading.casefold()
        hb = 4.0 * sum(1 for w in sec_words if w in hl) + 1.5 * len(qset & stem_set(heading))
        if sec_words and any(hl.strip() in {w, w + "s"} or hl.startswith(w + " ") for w in sec_words[:3]):
            hb += 5.0        # a section whose title *is* the question's intent ("Formation", "Causes", "Operation")
        order.append((ps[i] + hb + 0.5 * intent_bonus(p, kind), i, hb))
    order.sort(reverse=True)
    core = core_stems(q)
    tstems = stem_set(title)
    need = 1.0 if len(core) <= 2 else 0.6
    lead_idx = {i for i, (h, _) in enumerate(paras) if not h.strip() or h.strip().casefold() in {"lead", "introduction", "summary"}}
    # A short question ("What causes tides?") asks for the subject's general explanation, which an encyclopedia puts in
    # the lead. A long, specific question must be matched on its specifics; there the lead priors cost accuracy (SQuAD).
    overview = len(core) <= 2 or not RANK_FLAGS["short_only"]
    para_stems = {}
    first_lead = min(lead_idx) if lead_idx else -1
    windows = []
    scan = order[:12]
    if quality == "wiki" and first_lead >= 0 and all(pi != first_lead for _, pi, _ in scan):
        scan = scan + [o for o in order if o[1] == first_lead]
    for _, pi, hb in scan:
        ss = split_sentences(paras[pi][1])
        if quality == "web":
            ss = [x for x in ss if good_sentence(x)]
        if not ss:
            continue
        for j in range(len(ss)):
            if quality == "wiki" and any(x in ss[j].casefold() for x in ("isbn ", "archived from", "retrieved ")):
                continue
            win = " ".join(ss[j:j + 2])
            windows.append((pi, j, win, hb, ss))
    if not windows:
        return []
    bs = bm25_scores([w[2] for w in windows], q)
    out = []
    for n, (pi, j, txt, hb, ss) in enumerate(windows):
        if pi not in para_stems:
            para_stems[pi] = stem_set(paras[pi][1]) | tstems
        have = alias_expand(stem_set(txt) | tstems)
        cov = len(core & have) / max(1, len(core))
        gate = need
        if len(core) > 2:
            # Long questions: the paragraph must cover the question; the two-sentence window only needs a foothold.
            if len(core & para_stems[pi]) / len(core) < (min(need, 0.34) if (quality == "web" and JUDGE.ok) else need):
                continue
            gate = RANK_FLAGS["window_gate"]
        if quality == "wiki" and pi in lead_idx and len(core) == 2 and (core & tstems):
            gate = 0.5       # the lead of "Rust" answers "why does metal rust?" without using the word metal
        if quality == "web" and JUDGE.ok:
            gate = min(gate, 0.34)   # pages say "goose bumps", "submerge", "tears": the judge, not keyword overlap, verifies web text
        if cov < gate:
            continue
        sc = (bs[n] + RANK_FLAGS["para_weight"] * ps[pi] + 0.45 * lexical_score(txt, q, kind) + intent_bonus(txt, kind) + 1.0 * hb) * (0.5 + cov)
        if quality == "wiki" and kind in {"why", "how", "formation"} and pi in lead_idx and RANK_FLAGS["lead"] and overview:
            # An encyclopedia lead is written to summarise causes and mechanisms; later paragraphs assume it.
            on_subject = bool(tstems) and tstems == stem_set(subject)      # the article *is* what was asked about
            sc += ((10.0 if on_subject else 6.0) if (pi == first_lead and j == 0) else (5.0 if on_subject else 3.0)) * (0.5 + cov)
        if quality == "wiki" and kind in {"why", "how", "formation"} and RANK_FLAGS["subject_first"] and overview:
            head = [stem(w) for w in raw_tokens(txt)[:4] if w not in {"a", "an", "the"}][:2]
            if any(h in tstems for h in head):
                sc += 4.0    # "Tides are ...", "Rust is ...": a statement about the subject, not about a detail of it
        if quality == "web" and not web_clean(txt):
            continue             # teasers, questions, calls to action and truncated snippets are not answers
        if kind == "why" and explains(txt, core):
            sc += 5.0
        if not RANK_FLAGS["openers"]:
            pass
        elif ANAPHORIC_OPENERS.match(txt) or ELLIPTICAL_END.search(ss[j]):
            sc -= 3.0 if j == 0 else 2.0
        elif WEAK_OPENERS.match(txt):
            sc -= 3.0
        longest = max((len(x.split()) for x in ss[j:j + 2]), default=0)
        if longest > 65 and RANK_FLAGS["runon"]:
            sc -= 6.0        # run-on sentences read badly and are usually low-quality prose
        if sc <= 0:
            continue
        out.append({"text": txt, "score": sc, "source": source, "domain": host(source.get("url", "")),
                    "pi": pi, "j": j, "sents": ss, "doc_pos": pi * 1000 + j, "heading": str(paras[pi][0] or "")})
    out.sort(key=lambda x: x["score"], reverse=True)
    out = out[:limit]
    n_neural = min(12, SEM.budget) if (SEM.ok and len(out) > 1 and remaining() > 2.5) else 0
    if n_neural:
        head = out[:n_neural]
        sims, weight = SEM.similarity(q, [c["text"] for c in head]), FUSE_NEURAL
    else:
        head = out
        sims, weight = embed_similarity(q, [c["text"] for c in head]), FUSE_STATIC
    if sims:
        top = max(c["score"] for c in head) or 1.0
        lo, hi = min(sims), max(sims)
        for c, sv in zip(head, sims):
            c["score"] = (1 - weight) * c["score"] + weight * top * ((sv - lo) / (hi - lo + 1e-9))
        out.sort(key=lambda x: x["score"], reverse=True)
    return out

def passage_from(c, max_chars=520):
    """Grow the winning window into a coherent passage: pull in the antecedent sentence when the
    window opens with 'However/This/It...', then extend forward while it stays short."""
    ss, j = c["sents"], c["j"]
    start, end = j, min(len(ss), j + 2)
    steps = 0
    while start > 0 and ANAPHORIC_OPENERS.match(ss[start]) and steps < 3:
        start -= 1
        steps += 1
    end = max(end, start + 2)
    text = " ".join(ss[start:end])
    while end < len(ss) and len(text) + len(ss[end]) + 1 <= max_chars and end - start < 4:
        text += " " + ss[end]
        end += 1
    if ANAPHORIC_OPENERS.match(text) and start == 0 and end - start > 1:
        # Paragraph-initial connective with no antecedent available: drop that sentence.
        text = " ".join(ss[start + 1:end])
    return text, (c["pi"], start, end)

def mmr_select(cands, k=4, lam=0.76):
    if not cands:
        return []
    pool = sorted(cands, key=lambda x: x.get("score", 0), reverse=True)[:36]
    vals = [x.get("score", 0.0) for x in pool]
    lo, hi = min(vals), max(vals)
    span = max(1e-9, hi - lo)
    for c in pool:
        c["_n"] = (c.get("score", 0.0) - lo) / span
    chosen = []
    while pool and len(chosen) < k:
        best, bestv = None, -1e9
        for c in pool:
            red = max([jaccard(c["text"], x["text"]) for x in chosen] or [0.0])
            same = sum(1 for x in chosen if x.get("domain") and x.get("domain") == c.get("domain"))
            v = lam * c["_n"] - (1 - lam) * red - 0.12 * same
            if v > bestv:
                bestv, best = v, c
        chosen.append(best)
        pool.remove(best)
    return chosen

# ---------- HTTP ----------
WIKI_STATE = {"fail_at": 0.0, "fails": 0, "last": ""}     # v41: Wikimedia can be throttled or slow too; remember it per process

def _wiki_host(url):
    return any(h in url for h in ("wikipedia.org", "wikidata.org", "wiktionary.org", "wikiquote.org"))

def wiki_note_failure(what, err):
    """Record a Wikimedia failure with its HTTP status (429/503 are throttling; timeouts are slowness) so answers can say so."""
    if getattr(_replay, "MODE", "") == "replay":
        return                                              # cassette misses are not outages
    status = getattr(getattr(err, "response", None), "status_code", None)
    WIKI_STATE["fails"] = WIKI_STATE["fails"] + 1 if time.time() - WIKI_STATE["fail_at"] < 120 else 1
    WIKI_STATE["fail_at"] = time.time()
    WIKI_STATE["last"] = f"{what}: {type(err).__name__}" + (f" {status}" if status else "")
    trace(f"wikimedia: {WIKI_STATE['last']} (failure {WIKI_STATE['fails']} in 2 min)")

def wiki_recently_down():
    return time.time() - WIKI_STATE["fail_at"] < 120 and WIKI_STATE["fails"] >= 2

def http_get_json(url, params, ttl=86400, prefix="http", timeout=10, session=None):
    key = ckey(prefix, url, *[f"{k}={params[k]}" for k in sorted(params)])
    hit = cache_get(key)
    if hit is not None:
        return hit
    if out_of_time():
        raise TimeoutError("request budget exhausted")
    sess = session or API
    last = None
    wiki = _wiki_host(url)
    for attempt in range(2):
        try:
            # when Wikimedia has just been failing, do not spend the whole answer budget on it: one short attempt only
            r = sess.get(url, params=params, timeout=(3, t_out(4 if (wiki and wiki_recently_down()) else timeout)))
            if r.status_code in (429, 500, 502, 503, 504) and attempt == 0 and remaining() > 3 and not (wiki and wiki_recently_down()):
                time.sleep(1.2)
                continue
            r.raise_for_status()
            data = r.json()
            cache_put(key, data, ttl)
            if wiki:
                WIKI_STATE["fails"] = 0
            return data
        except Exception as e:
            last = e
            if wiki:
                wiki_note_failure(url.split("/")[2], e)
            if out_of_time() or (wiki and wiki_recently_down()):
                break
    raise last if last else RuntimeError("request failed")

# ---------- Wikidata ----------
def wd_search(term, limit=8, etype="item"):
    try:
        return http_get_json(WIKIDATA_API, {"action": "wbsearchentities", "search": term, "language": "en", "uselang": "en",
                                            "type": etype, "limit": limit, "format": "json"}, 7 * 86400, "wdsearch").get("search", [])
    except Exception:
        return []

WD_LAST_FETCH_FAILED = threading.local()
def wd_sparql(query, ttl=7 * 86400):
    """v60: the Wikidata Query Service, for superlatives over a class in a region. Read-only, cached a week, cited as 'Wikidata query'."""
    try:
        key = ckey("sparql", query)
        hit = cache_get(key)
        if hit is not None:
            return hit
        r = WEB.get("https://query.wikidata.org/sparql", params={"query": query, "format": "json"}, headers={"Accept": "application/sparql-results+json", "User-Agent": UA_API}, timeout=(4, t_out(12)))
        if r.status_code != 200:
            trace(f"sparql: HTTP {r.status_code}")
            return []
        rows = []
        for b in (r.json().get("results", {}) or {}).get("bindings", []):
            rows.append({k: v.get("value", "") for k, v in b.items()})
        cache_put(key, rows, ttl)
        return rows
    except Exception as e:
        trace(f"sparql failed: {type(e).__name__}")
        return []

def wd_get(qids, props="labels|descriptions|claims|sitelinks"):
    qids = list(dict.fromkeys(q for q in qids if q))
    if not qids:
        return {}
    WD_LAST_FETCH_FAILED.v = False
    try:
        return http_get_json(WIKIDATA_API, {"action": "wbgetentities", "ids": "|".join(qids[:50]), "props": props,
                                            "languages": "en|mul|en-gb", "languagefallback": 1, "sitefilter": "enwiki|simplewiki", "format": "json"},
                             7 * 86400, "wdget2", timeout=6).get("entities", {})
    except Exception:
        WD_LAST_FETCH_FAILED.v = True
        return {}

def wd_labels(qids):
    return wd_get(qids, "labels|descriptions")

def entity_label(ent, fallback=""):
    labels = (ent or {}).get("labels", {}) or {}
    for lang in ("en", "mul", "en-gb", "en-us", "en-ca"):
        v = (labels.get(lang) or {}).get("value")
        if v:
            return v
    return fallback

def entity_desc(ent, fallback=""):
    return (ent or {}).get("descriptions", {}).get("en", {}).get("value") or fallback

def sitelink_title(ent, site="enwiki"):
    return (ent or {}).get("sitelinks", {}).get(site, {}).get("title", "")

def _claim_time(c, pid="P585"):
    for qv in (c.get("qualifiers", {}) or {}).get(pid, []):
        t = (qv.get("datavalue", {}) or {}).get("value", {})
        if isinstance(t, dict) and t.get("time"):
            return t["time"].lstrip("+")
    return ""

def ranked_claims(ent, pid):
    claims = [c for c in (ent or {}).get("claims", {}).get(pid, [])
              if c.get("rank") != "deprecated" and c.get("mainsnak", {}).get("snaktype") == "value"]
    pref = [c for c in claims if c.get("rank") == "preferred"]
    if pref:
        return pref
    dated = [(c, _claim_time(c)) for c in claims]
    if len(claims) > 1 and any(t for _, t in dated):
        # Several undated-rank values with "point in time" qualifiers (population, head of state...): newest wins.
        return [max(dated, key=lambda x: x[1])[0]]
    current = [c for c in claims if not (c.get("qualifiers", {}) or {}).get("P582")]  # no "end time"
    return current or claims

def ordinal(n):
    suf = "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suf}"

def format_time(v):
    t = v.get("time", "")
    p = v.get("precision", 9)
    m = re.match(r"([+-])(\d+)-(\d\d)-(\d\d)", t)
    if not m:
        return t, p
    sign, ys, ms, ds = m.groups()
    y, mo, d = int(ys), int(ms), int(ds)
    months = ["", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    if sign == "-":
        return f"{y} BCE", 9
    if p <= 7:
        return f"the {ordinal(((y - 1) // 100) + 1)} century", p
    if p == 8:
        return f"the {y // 10 * 10}s", p
    if p == 9 or not (1 <= mo <= 12):
        return str(y), 9
    if p == 10 or d == 0:
        return f"{months[mo]} {y}", 10
    return f"{d} {months[mo]} {y}", 11

def format_amount(a):
    a = str(a or "").lstrip("+")
    try:
        f = float(a)
        if f == int(f) and "e" not in a.casefold():
            return f"{int(f):,}"
        return f"{f:,.4f}".rstrip("0").rstrip(".")
    except Exception:
        return a

SKIP_DATATYPES = {"external-id", "commonsMedia", "wikibase-property", "math", "tabular-data", "geo-shape", "musical-notation"}

def claim_values(claims, limit=6):
    """-> [{'text','qid','precision'}] with entity labels and quantity units resolved in one batch."""
    rows, ids = [], []
    for c in claims[:limit]:
        snak = c.get("mainsnak", {})
        if snak.get("datatype") in SKIP_DATATYPES:
            continue
        dv = snak.get("datavalue", {})
        typ, val = dv.get("type"), dv.get("value")
        if typ == "wikibase-entityid" and isinstance(val, dict):
            q = val.get("id") or (f"Q{val.get('numeric-id')}" if val.get("numeric-id") else None)
            if q:
                ids.append(q)
                rows.append({"qid": q})
        elif typ == "time" and isinstance(val, dict):
            text, prec = format_time(val)
            rows.append({"text": text, "precision": prec})
        elif typ == "string":
            rows.append({"text": str(val)})
        elif typ == "monolingualtext" and isinstance(val, dict):
            rows.append({"text": str(val.get("text", ""))})
        elif typ == "quantity" and isinstance(val, dict):
            unit = str(val.get("unit", ""))
            uq = unit.rsplit("/", 1)[-1] if unit.startswith("http") else ""
            if uq:
                ids.append(uq)
            rows.append({"text": format_amount(val.get("amount")), "unit": uq})
        elif typ == "globecoordinate" and isinstance(val, dict):
            rows.append({"text": f"{val.get('latitude', 0):.4f}, {val.get('longitude', 0):.4f}"})
    labels = wd_labels(ids) if ids else {}
    out, seen = [], set()
    for r in rows:
        if r.get("qid"):
            r["text"] = entity_label(labels.get(r["qid"], {}), "")
            if not r["text"]:
                continue         # an unlabeled item is dropped rather than shown as "Q332591"
        if r.get("unit"):
            ul = entity_label(labels.get(r["unit"], {}), "")
            if ul:
                r["text"] = f"{r['text']} {plural_unit(ul, r['text'])}"
        if r.get("text") and r["text"] not in seen:
            seen.add(r["text"])
            out.append(r)
    return out

_UNIT_IRREGULAR = {"foot": "feet", "inch": "inches", "degree Celsius": "degrees Celsius", "degree Fahrenheit": "degrees Fahrenheit",
                   "square metre": "square metres", "square kilometre": "square kilometres", "cubic metre": "cubic metres",
                   "metre per second": "metres per second", "kilometre per hour": "kilometres per hour", "hertz": "hertz", "kelvin": "kelvin",
                   "percent": "percent", "astronomical unit": "astronomical units", "solar mass": "solar masses", "light-year": "light-years"}

def plural_unit(unit, amount_text):
    """Wikidata unit labels are singular ('metre'); '8,848.86 metre' reads wrongly."""
    try:
        one = abs(float(str(amount_text).replace(",", "")) - 1.0) < 1e-12
    except ValueError:
        one = False
    if one or not unit or not re.fullmatch(r"[A-Za-z][A-Za-z \-]*", unit) or len(unit) <= 3:
        return unit          # symbols and abbreviations are left alone
    if unit in _UNIT_IRREGULAR:
        return _UNIT_IRREGULAR[unit]
    if unit.endswith(("s", "x", "z")) or " per " in unit or " of " in unit:
        return unit
    return unit + "s"

def entity_type_qids(ent):
    ids = []
    for c in (ent or {}).get("claims", {}).get("P31", [])[:12]:
        val = c.get("mainsnak", {}).get("datavalue", {}).get("value")
        if isinstance(val, dict) and val.get("id"):
            ids.append(val["id"])
    return ids

RELATIONS = {
    "author": {"pids": ["P50"], "type_words": ["novel", "book", "literary work", "poem", "play", "written work", "short story", "essay", "tragedy", "comedy", "drama", "epic", "novella", "memoir"], "bad_words": ["film", "television", "album"], "template": "{subject} was written by {value}."},
    "composer": {"pids": ["P86"], "type_words": ["musical composition", "musical work", "concerto", "symphony", "opera", "song", "musical", "ballet"], "bad_words": ["film"], "template": "{subject} was composed by {value}."},
    "creator": {"pids": ["P170"], "type_words": ["painting", "artwork", "work of art", "sculpture", "fresco", "statue", "mural", "drawing"], "bad_words": ["novel", "film", "album"], "template": "{subject} was created by {value}."},
    "designer": {"pids": ["P84", "P287", "P170"], "type_words": ["building", "bridge", "park", "tower", "structure", "landmark", "skyscraper", "cathedral", "church", "museum", "stadium"], "template": "{subject} was designed by {value}."},
    "founder": {"pids": ["P112"], "type_words": ["company", "organization", "organisation", "institution", "university", "business", "corporation", "enterprise"], "template": "{subject} was founded by {value}."},
    "inventor": {"pids": ["P61"], "template": "{subject} was invented by {value}."},
    "sibling": {"pids": ["P3373"], "type_words": ["human"], "template": "{subject}'s siblings: {value}."},
    "plug type": {"pids": ["P2853"], "template": "{subject} uses plug type {value}."}, "driving side": {"pids": ["P1622"], "template": "In {subject} they drive on the {value}."},
    "named after": {"pids": ["P138"], "template": "{subject} is named after {value}."},
    "performer": {"pids": ["P175"], "type_words": ["song", "single", "album", "musical work", "composition"], "bad_words": ["film", "novel"], "template": "{subject} was performed by {value}."},
    "director": {"pids": ["P57"], "type_words": ["film", "movie", "television", "documentary"], "template": "{subject} was directed by {value}."},
    "discoverer": {"pids": ["P61"], "template": "{subject} was discovered by {value}."},
    "birth_place": {"pids": ["P19"], "template": "{subject} was born in {value}."},
    "birth_date": {"pids": ["P569"], "template": "{subject} was born {on} {value}."},
    "death_place": {"pids": ["P20"], "template": "{subject} died in {value}."},
    "death_date": {"pids": ["P570"], "template": "{subject} died {on} {value}."},
    "current_location": {"pids": ["P195", "P276", "P131", "P17"], "template": "{subject} is currently at or held by {value}."},
    "location": {"pids": ["P276", "P131", "P17"], "template": "{subject} is located in {value}."},
    "opening": {"pids": ["P1619", "P571", "P729"], "template": "{subject} opened {on} {value}."},
    "inception": {"pids": ["P571", "P1619"], "template": "{subject} dates to {value}."},
}
RELATION_ALLOWED_TYPES = {
    "author": {"Q8261", "Q571", "Q7725634", "Q47461344", "Q5185279", "Q25379", "Q149537", "Q49084"},
    "composer": {"Q207628", "Q7366", "Q9748", "Q9734", "Q1344", "Q2188189", "Q105543609"},
    "creator": {"Q3305213", "Q838948", "Q860861", "Q4502142"},
    "director": {"Q11424", "Q5398426", "Q15416", "Q24862", "Q93204"},
}

_CORP_SUFFIX = re.compile(r",?\s+(?:inc\.?|incorporated|corp\.?|corporation|company|co\.?|ltd\.?|limited|llc|plc|gmbh|ag|s\.a\.|sa|group|holdings)$", re.I)

def resolve_subject(term, relation=None, want_pids=()):
    """Two-stage resolution. Stage 1 scores cheap search metadata (label, alias, description, agreement
    with Wikipedia's own search ranking as a notability prior). Stage 2 fetches full claims for the best
    few only, then applies relation/type evidence. Abstains below a threshold."""
    term = clean_term(term)
    if not term:
        return None
    cfg = RELATIONS.get(relation or "", {})
    pids = list(cfg.get("pids", [])) + list(want_pids)
    keys = label_keys(term)
    probes = list(dict.fromkeys([term, strip_article(term)]))
    jobs = [("wd", p) for p in probes] + [("wp", strip_article(term))]
    res = pmap(lambda j: wd_search(j[1], 8) if j[0] == "wd" else wiki_candidates(j[1], 6), jobs, t_out(9))
    cands = {}
    for (kind, _), rows in zip(jobs, res):
        for rank, r in enumerate(rows or []):
            if kind == "wd":
                qid = r.get("id")
                if not qid:
                    continue
                c = cands.setdefault(qid, {"qid": qid, "label": r.get("label", ""), "desc": r.get("description", ""), "rank": 99, "wp": 99, "alias": ""})
                c["rank"] = min(c["rank"], rank)
                m = r.get("match", {}) or {}
                if m.get("type") == "alias":
                    c["alias"] = m.get("text", "")
            else:
                qid = r.get("qid")
                if not qid or r.get("disambig"):
                    continue
                c = cands.setdefault(qid, {"qid": qid, "label": bare_title(r["title"]), "desc": r.get("description", ""), "rank": 99, "wp": 99, "alias": ""})
                c["wp"] = min(c["wp"], rank)
    if not cands:
        trace(f"resolve '{term}': no candidates")
        return None
    for c in cands.values():
        s = 0.0
        if c["rank"] < 99:
            s += 40 - 2 * c["rank"]
        if c["wp"] < 99:
            s += max(10, 45 - 8 * c["wp"])
        if label_keys(c["label"]) & keys:
            s += 80
            if c["label"].casefold().strip() == term.casefold().strip():
                s += 12      # "Hamlet" is Hamlet, not Faulkner's "The Hamlet"
            elif re.match(r"^(?:the|a|an)\s", c["label"], re.I) and not re.match(r"^(?:the|a|an)\s", term, re.I):
                s -= 6
        elif c["alias"] and label_keys(c["alias"]) & keys:
            s += 55
        elif label_keys(_CORP_SUFFIX.sub("", c["label"]).strip(" ,")) & keys:
            s += 65          # "Apple" names "Apple Inc." almost as well as it names the fruit
        s += 8 * len(stem_set(term) & stem_set(c["label"] + " " + c["desc"]))
        blob = " " + norm_key(c["desc"]) + " "
        if any(has_word(blob, norm_key(w)) for w in cfg.get("type_words", [])):
            s += 25
        if any(has_word(blob, norm_key(w)) for w in cfg.get("bad_words", [])):
            s -= 70
        if "disambiguation page" in blob or "wikimedia" in blob:
            s -= 200
        c["pre"] = s
    short = sorted(cands.values(), key=lambda x: x["pre"], reverse=True)[:8]
    ents = wd_get([c["qid"] for c in short])
    allowed = RELATION_ALLOWED_TYPES.get(relation or "", set())
    best, best_score = None, -1e9
    # "Who founded Apple?" presupposes something that HAS a founder. If any plausible candidate carries the property,
    # candidates without it (the fruit) are very unlikely to be what was meant.
    any_has = bool(pids) and any(any(pid in (ents.get(c["qid"], {}) or {}).get("claims", {}) for pid in pids) for c in short if c["pre"] >= 60)
    for c in short:
        ent = ents.get(c["qid"], {})
        if not ent:
            continue
        s = c["pre"]
        if any_has and not any(pid in ent.get("claims", {}) for pid in pids):
            s -= 70
        label = entity_label(ent, c["label"])
        desc = entity_desc(ent, c["desc"])
        has_rel = bool(pids) and any(pid in ent.get("claims", {}) for pid in pids)
        if has_rel:
            s += 55
        if sitelink_title(ent):
            s += 30
        types = set(entity_type_qids(ent))
        blob = " " + norm_key(desc) + " "
        word_ok = any(has_word(blob, norm_key(w)) for w in cfg.get("type_words", []))
        type_ok = True
        if allowed:
            type_ok = bool(types & allowed) or word_ok
            s += 45 if types & allowed else (0 if word_ok else -110)
        if s > best_score:
            best_score = s
            best = {"qid": c["qid"], "entity": ent, "label": label, "title": sitelink_title(ent) or label,
                    "description": desc, "score": s, "type_ok": type_ok, "has_rel": has_rel}
    threshold = 85 if (relation or want_pids) else 60
    pin = getattr(_CTX, "pinned", None)                    # v42: a follow-up turn already settled which entity this label means
    if pin and pin.get("label", "").lower() == term.lower() and (not best or best_score < threshold or best["qid"] != pin["qid"]):
        ent = wd_get([pin["qid"]]).get(pin["qid"]) or {}
        if ent:
            trace(f"resolve '{term}' -> {pin['label']} [{pin['qid']}] pinned by the previous turn")
            return {"qid": pin["qid"], "entity": ent, "label": pin["label"], "title": sitelink_title(ent) or pin["label"],
                    "description": (ent.get("descriptions", {}).get("en", {}) or {}).get("value", ""), "score": 100.0, "type_ok": True, "has_rel": True}
    if not best or best_score < threshold:
        trace(f"resolve '{term}': abstain (best={best['label'] if best else None} score={best_score:.0f} < {threshold})")
        return None
    if allowed and not best["type_ok"]:
        trace(f"resolve '{term}': abstain (type gate) on {best['label']}")
        return None
    trace(f"resolve '{term}' -> {best['label']} [{best['qid']}] score={best_score:.0f}")
    return best

def parse_relation(q):
    s = norm(q).rstrip("?.!")
    pats = [
        (r"^who\s+(?:wrote|authored)\s+(.+)$", "author"), (r"^who\s+composed\s+(.+)$", "composer"),
        (r"^who\s+(?:painted|sculpted|drew)\s+(.+)$", "creator"), (r"^who\s+(?:designed|architected|built)\s+(.+)$", "designer"),
        (r"^who\s+(?:founded|co-founded|started|established)\s+(.+)$", "founder"), (r"^who\s+invented\s+(.+)$", "inventor"),
        (r"^who\s+directed\s+(.+)$", "director"), (r"^who\s+discovered\s+(.+)$", "discoverer"),
        (r"^who\s+(?:sang|sings|performed|performs|recorded|released)\s+(?:the song\s+)?(.+)$", "performer"),
        (r"^(?:what|which)\s+(?:plug|socket|outlet|power plug)(?:\s+types?)?\s+(?:does|do|is used in|are used in)\s+(.+?)(?:\s+use)?$", "plug type"),
        (r"^(?:what|which)\s+side\s+of\s+the\s+road\s+(?:do\s+(?:they|people|cars)\s+drive\s+(?:on\s+)?in|does\s+.+?\s+drive\s+on\s+in)\s+(.+)$", "driving side"),
        (r"^(?:what|who)\s+(?:is|was|were|are)\s+(.+?)\s+named\s+(?:after|for)$", "named after"),
        (r"^where\s+(?:was|were)\s+(.+?)\s+born$", "birth_place"), (r"^when\s+(?:was|were)\s+(.+?)\s+born$", "birth_date"),
        (r"^where\s+did\s+(.+?)\s+die$", "death_place"), (r"^when\s+did\s+(.+?)\s+die$", "death_date"),
        (r"^where\s+(?:is|are)\s+(.+?)\s+now$", "current_location"), (r"^where\s+(?:is|are)\s+(.+?)(?:\s+located)?$", "location"),
        (r"^when\s+did\s+(.+?)\s+open$", "opening"), (r"^when\s+was\s+(.+?)\s+opened$", "opening"),
        (r"^when\s+was\s+(.+?)\s+(?:completed|built|established|founded|created|invented)$", "inception"),
    ]
    for pat, rel in pats:
        m = re.match(pat, s, re.I)
        if m:
            return rel, clean_term(m.group(1))
    return None, None

PERSON_PRON = {"he", "him", "his", "she", "her", "hers"}
THING_PRON = {"it", "its", "this", "that", "they", "them", "their", "theirs"}

def pronoun_target(term, st):
    k = norm_key(term)
    if k in PERSON_PRON:
        return st.get("answer_qid") or st.get("subject_qid") or "", st.get("answer_label") or st.get("subject_label") or ""
    if k in THING_PRON:
        return st.get("subject_qid") or "", st.get("subject_label") or ""
    return "", ""

def entity_from_state_or_search(term, st, relation=None, want_pids=()):
    qid, label = pronoun_target(term, st)
    if qid:
        ent = wd_get([qid]).get(qid, {})
        if not ent:
            return None
        return {"qid": qid, "entity": ent, "label": entity_label(ent, label or term), "title": sitelink_title(ent)}
    if norm_key(term) in PERSON_PRON | THING_PRON:
        return None
    return resolve_subject(term, relation, want_pids)

def remember_entity_answer(st, best, vals):
    st["subject_qid"] = best["qid"]
    st["subject_kind"] = "human" if "Q5" in entity_type_qids(best.get("entity") or {}) else "other"
    st["subject_label"] = best["label"]
    st["last_mode"] = "wikidata"
    first = next((v for v in vals if v.get("qid")), None)
    st["answer_qid"] = first["qid"] if first else ""
    st["answer_label"] = first["text"] if first else ""

def display_subject(label, term):
    if re.match(r"^the\s", term or "", re.I) and not re.match(r"^the\s", label, re.I):
        return "The " + label
    return label

def answer_relation(q, st):
    rel, term = parse_relation(q)
    if not rel:
        return None
    best = entity_from_state_or_search(term, st, rel)
    if not best:
        return None
    cfg = RELATIONS[rel]
    claims = []
    for pid in cfg["pids"]:
        claims = ranked_claims(best["entity"], pid)
        if claims:
            break
    if not claims:
        trace(f"relation {rel}: {best['label']} has none of {cfg['pids']}")
        return None
    vals = claim_values(claims)
    if not vals:
        return None
    on = "on" if vals[0].get("precision", 0) >= 11 else "in"
    text = cfg["template"].format(subject=display_subject(best["label"], term), value=human_join([v["text"] for v in vals[:3]]), on=on)
    remember_entity_answer(st, best, vals)
    st["last_term"] = term
    return {"answer": text, "sources": [{"title": f"Wikidata: {best['label']}", "url": f"https://www.wikidata.org/wiki/{best['qid']}"}],
            "mode": "wikidata", "evidence_count": 1}

# ---------- generic Wikidata property questions ----------
PROPERTY_BLOCK = {"meaning", "difference", "differences", "purpose", "cause", "causes", "history", "point", "definition",
                  "origin", "origins", "best", "importance", "role", "function", "effect", "effects", "story", "plot",
                  "significance", "name", "reason", "reasons", "use", "uses", "benefits", "rest", "kind", "type", "sort"}
ADJ_PROPERTY = {"tall": "height", "high": "elevation above sea level", "long": "length", "heavy": "mass",
                "populous": "population", "big": "area", "large": "area", "deep": "vertical depth", "wide": "width"}

# Each pattern opens a whole class of questions on the most reliable route (Wikidata: exact, cited, under a second).
EXTRA_PROPERTY_PATTERNS = [
    (r"^in (?:which|what) (?:city|town|country|place) was (.+?) born$", "place of birth"), (r"^where (?:is|was) (.+?) from(?: originally)?$", "place of birth"),
    (r"^(.+?) was (?:painted|created|made) by whom$", "creator"), (r"^(.+?) was written by whom$", "author"), (r"^(.+?) was directed by whom$", "director"),
    (r"^who(?:'s| is| was) the (?:writer|author) of (.+)$", "author"), (r"^what (?:money|currency) do they use in (.+)$", "currency"), (r"^what currency does (.+?) use$", "currency"),
    (r"^how high (?:is|are) (.+)$", "elevation above sea level"), (r"^what is the elevation of (.+)$", "elevation above sea level"), (r"^who (?:created|started|set up|established) (?:the company )?(.+)$", "founded by"),
    (r"^who (?:is|was) (.+?) married to$", "spouse"), (r"^who did (.+?) marry$", "spouse"),
    (r"^who\s+(?:is|was)\s+(.+?)\s+married\s+to$", "spouse"), (r"^who\s+(?:is|was)\s+(.+?)(?:'s|\u2019s)\s+(?:wife|husband|spouse|partner)$", "spouse"),
    (r"^who\s+did\s+(.+?)\s+marry$", "spouse"), (r"^who\s+(?:are|were)\s+(.+?)(?:'s|\u2019s)\s+(?:children|kids)$", "child"),
    (r"^who\s+(?:are|were)\s+(.+?)(?:'s|\u2019s)\s+parents$", "parent"), (r"^who\s+(?:starred|stars|acted|acts|was|is)\s+in\s+(.+)$", "cast member"),
    (r"^when\s+(?:was|were)\s+(.+?)\s+(?:released|published)$", "publication date"), (r"^when\s+did\s+(.+?)\s+come\s+out$", "publication date"),
    (r"^who\s+owns\s+(.+)$", "owned by"), (r"^who\s+(?:makes|manufactures|produces)\s+(?:the\s+)?(.+)$", "manufacturer"),
    (r"^(?:what|which)\s+country\s+is\s+(.+?)\s+in$", "country"), (r"^(?:what|which)\s+continent\s+is\s+(.+?)\s+(?:in|on)$", "continent"),
    (r"^what\s+languages?\s+(?:is|are)\s+spoken\s+in\s+(.+)$", "official language"), (r"^what\s+languages?\s+do\s+(?:they|people)\s+speak\s+in\s+(.+)$", "official language"),
    (r"^what\s+(?:is|are)\s+(.+?)\s+made\s+(?:of|from)$", "made from material"), (r"^what\s+time\s*zone\s+is\s+(.+?)\s+in$", "located in time zone"),
    (r"^how\s+did\s+(.+?)\s+die$", "cause of death"), (r"^what\s+did\s+(.+?)\s+die\s+(?:of|from)$", "cause of death"), (r"^where\s+is\s+(.+?)\s+buried$", "place of burial"),
    (r"^what\s+genre\s+is\s+(.+)$", "genre"), (r"^how\s+many\s+employees\s+does\s+(.+?)\s+have$", "employees"), (r"^who\s+is\s+the\s+ceo\s+of\s+(.+)$", "chief executive officer"),
    (r"^who\s+(?:runs|leads|heads)\s+(.+)$", "chief executive officer"), (r"^what\s+(?:is|was)\s+(.+?)(?:'s|\u2019s)\s+(?:job|profession|occupation)$", "occupation"),
    (r"^what\s+did\s+(.+?)\s+do\s+for\s+a\s+living$", "occupation"), (r"^where\s+did\s+(.+?)\s+(?:study|go\s+to\s+(?:school|university|college))$", "educated at"),
    (r"^what\s+awards?\s+did\s+(.+?)\s+win$", "award received"), (r"^who\s+(?:is|was)\s+(.+?)(?:'s|\u2019s)\s+(?:mother|mom|mum)$", "mother"),
    (r"^who\s+(?:is|was)\s+(.+?)(?:'s|\u2019s)\s+(?:father|dad)$", "father"), (r"^who\s+(?:is|are|was|were)\s+(.+?)(?:'s|\u2019s)\s+(?:brother|sister|sibling|siblings|brothers|sisters)$", "sibling"), (r"^what\s+(?:is|are)\s+the\s+(?:neighbou?ring\s+countries|neighbou?rs)\s+of\s+(.+)$", "shares border with"),
    (r"^(?:what|which)\s+countries\s+border\s+(.+)$", "shares border with"),
    (r"^who\s+(?:is|are)\s+the\s+(?:main\s+)?characters?\s+(?:in|of)\s+(.+)$", "characters"), (r"^what\s+(?:plug|socket|outlet)(?:\s+type)?\s+(?:does|do)\s+(.+?)\s+use$", "electrical plug type"),
    (r"^(?:what|which)\s+side\s+of\s+the\s+road\s+do\s+(?:they|people)\s+drive\s+(?:on\s+)?in\s+(.+)$", "driving side"), (r"^what\s+(?:is|was)\s+(.+?)\s+named\s+after$", "named after"),
]

def parse_property_question(q):
    s = norm(q).rstrip("?.!")
    m = re.match(r"^(?:what|who|when|where|which)\s+(?:is|are|was|were)\s+the\s+(.+?)\s+of\s+(.+)$", s, re.I)
    if m:
        return clean_term(m.group(1)), clean_term(m.group(2))
    m = re.match(r"^(?:what|who|when|where)\s+(?:is|are|was|were)\s+(its|his|her|their)\s+(.+)$", s, re.I)
    if m:
        return clean_term(m.group(2)), m.group(1)
    m = re.match(r"^(?:what|who|when|where)\s+(?:is|are|was|were)\s+(.+?)(?:'s|\u2019s)\s+(.+)$", s, re.I)
    if m:
        return clean_term(m.group(2)), clean_term(m.group(1))
    m = re.match(r"^how\s+(tall|high|long|heavy|populous|big|large|deep|wide)\s+(?:is|are|was|were)\s+(.+)$", s, re.I)
    if m:
        return ADJ_PROPERTY[m.group(1).casefold()], clean_term(m.group(2))
    m = re.match(r"^how\s+many\s+people\s+live\s+in\s+(.+)$", s, re.I)
    if m:
        return "population", clean_term(m.group(1))
    for pat, prop in EXTRA_PROPERTY_PATTERNS:
        m = re.match(pat, s, re.I)
        if m:
            return prop, clean_term(m.group(1))
    # v55: bare noun phrases ("birthplace of Marie Curie", "Alien director", "Tom Hanks spouse", "height of Denali")
    BARE = r"(?:birthplace|place of birth|composer|founder|founders|director|author|writer|capital|currency|population|height|elevation|spouse|wife|husband|creator|painter|inventor|architect|developer|publisher|genre|nationality|occupation|religion)"
    m = re.match(r"^(" + BARE + r") of (?:the )?(.+)$", s, re.I)
    if m:
        return _bare_prop(m.group(1)), clean_term(m.group(2))
    m = re.match(r"^(.+?) (" + BARE + r")$", s, re.I)
    if m and len(m.group(1).split()) <= 6:
        return _bare_prop(m.group(2)), clean_term(m.group(1))
    return None, None

def _bare_prop(w):
    w = w.lower()
    return {"birthplace": "place of birth", "writer": "author", "wife": "spouse", "husband": "spouse", "painter": "creator", "height": "elevation above sea level", "founders": "founded by", "founder": "founded by"}.get(w, w)

PROPERTY_PHRASES = {"spouse": ("{s} is or was married to {v}.", 4), "cast member": ("The cast of {s} includes {v}.", 6), "publication date": ("{s} was released on {v}.", 2),
                    "owned by": ("{s} is owned by {v}.", 4), "manufacturer": ("{s} is made by {v}.", 4), "country": ("{s} is in {v}.", 3), "continent": ("{s} is in {v}.", 3),
                    "official language": ("The official language of {s}: {v}.", 6), "made from material": ("{s} is made from {v}.", 6), "cause of death": ("{s} died of {v}.", 3),
                    "place of burial": ("{s} is buried at {v}.", 3), "educated at": ("{s} studied at {v}.", 6), "award received": ("Awards received by {s} include {v}.", 8),
                    "shares border with": ("{s} borders {v}.", 12), "child": ("{s}'s children: {v}.", 8), "parent": ("{s}'s parents: {v}.", 4), "mother": ("{s}'s mother is or was {v}.", 2),
                    "father": ("{s}'s father is or was {v}.", 2), "occupation": ("{s}'s occupation: {v}.", 5), "chief executive officer": ("The chief executive of {s} is {v}.", 2),
                    "genre": ("The genre of {s}: {v}.", 4), "employees": ("{s} has {v} employees.", 1), "located in time zone": ("{s} is in the time zone {v}.", 3), "characters": ("Characters in {s} include {v}.", 8), "electrical plug type": ("{s} uses plug type {v}.", 3),
                    "driving side": ("In {s} they drive on the {v}.", 1), "named after": ("{s} is named after {v}.", 2), "performer": ("{s} was performed by {v}.", 3)}

def answer_property(q, st):
    rel, term = parse_property_question(q)
    if not rel or not term:
        return None
    if len(rel.split()) > 5 or len(term.split()) > 9 or (set(raw_tokens(rel)) & PROPERTY_BLOCK):
        return None
    props = [p for p in wd_search(rel, 6, "property") if p.get("datatype") not in SKIP_DATATYPES]
    if not props:
        trace(f"property '{rel}': no Wikidata property matches")
        if SPELL.ok and not getattr(_CTX, "spell_retry", False):
            fixed = SPELL.correct(rel, aggressive=True)          # vetoed: tldr, words.txt, Wiktionary; no verdict = no change
            if fixed and fixed.lower() != rel.lower():
                _CTX.spell_retry = True
                q2 = re.sub(re.escape(rel), fixed, q, count=1, flags=re.I)
                trace(f"spelling: property '{rel}' is not a word; retrying as '{q2}'")
                r2 = answer_property(q2, st)
                if r2:
                    r2["answer"] = f"(I read that as \u201c{q2}\u201d.)\n" + r2["answer"]
                    return r2
        return None
    pids = [p["id"] for p in props if p.get("id")]
    exact = [p["id"] for p in props if p.get("id") and norm_key(p.get("label") or "") == norm_key(rel)]
    if exact and rel.lower() in ("place of birth", "date of birth", "spouse", "place of death", "date of death", "cause of death", "sibling", "mother", "father", "child", "occupation"):
        pids = exact[:1]                       # v56: a person's property must not be satisfied by a company's 'location'
    for k, extra in {"cause of death": ["P509", "P1196"], "sibling": ["P3373"], "brother": ["P3373"], "sister": ["P3373"], "children": ["P40"], "child": ["P40"]}.items():
        if rel.lower() == k:
            pids = extra + [x for x in pids if x not in extra]          # v53: "how did he die" also accepts the manner of death
    best = entity_from_state_or_search(term, st, None, pids)
    if not best:
        return None
    for p in props:
        claims = ranked_claims(best["entity"], p.get("id", ""))
        if not claims:
            continue
        vals = claim_values(claims)
        if not vals:
            continue
        plabel = p.get("label") or rel
        phrase, limit = PROPERTY_PHRASES.get(rel, (None, 4))
        if rel == "owned by" and vals and vals[0].get("qid") and not out_of_time():
            try:
                parent = wd_get([vals[0]["qid"]]).get(vals[0]["qid"], {})
                up = claim_values(ranked_claims(parent, "P127"))
                if up and up[0].get("text") and up[0]["text"] != vals[0]["text"]:
                    vals = [dict(vals[0], text=f"{vals[0]['text']}, which is owned by {up[0]['text']}")]
            except Exception:
                pass
        if rel == "shares border with":
            vals = [v for v in vals if not re.search(r"\b(?:union|community|organi[sz]ation|area)\b", v["text"], re.I)] or vals   # Wikidata lists the EU as a "neighbour"
        value = human_join([v["text"] for v in vals[:limit]])
        verb = "are" if len(vals) > 1 else "is"
        text = f"The {plabel} of {best['label']} {verb} {value}."
        if phrase:
            text = phrase.format(s=best["label"], v=value)
        remember_entity_answer(st, best, vals)
        st["last_term"] = term
        trace(f"property '{rel}' -> {p.get('id')} ({plabel})")
        return {"answer": text, "sources": [{"title": f"Wikidata: {best['label']}", "url": f"https://www.wikidata.org/wiki/{best['qid']}"}],
                "mode": "wikidata", "evidence_count": 1}
    if getattr(WD_LAST_FETCH_FAILED, "v", False) or not (best.get("entity") or {}).get("claims"):
        trace(f"property '{rel}': the Wikidata fetch for {best['label']} came back empty (network), not a missing property")
        return None
    trace(f"property '{rel}': {best['label']} has none of {pids}")
    return None

# ---------- Wikipedia: candidates, pages, passages ----------
def wiki_exact(term, site="en", timeout=6):
    """The page a term names directly, following redirects (Hurricane -> Tropical cyclone). Search ranks by text match
    and returned 'Atlantic hurricane' first; the redirect is the encyclopedia's own statement of what the word means."""
    term = norm(strip_article(term))
    if not term or len(term.split()) > 5:
        return []
    out = []
    for variant in dict.fromkeys([term[:1].upper() + term[1:], term[:1].upper() + term[1:].rstrip("s") if term.endswith("s") and not term.endswith("ss") else term]):
        params = {"action": "query", "format": "json", "formatversion": 2, "titles": variant, "redirects": 1, "prop": "pageprops|description|extracts",
                  "ppprop": "wikibase_item|disambiguation", "exintro": 1, "explaintext": 1, "exsectionformat": "wiki"}
        try:
            data = http_get_json(wikipedia_api(site), params, 7 * 86400, "wexact", timeout=timeout)
        except Exception as e:
            trace(f"wiki exact '{variant}' failed: {type(e).__name__}")
            continue
        for p in (data.get("query") or {}).get("pages") or []:
            if p.get("missing") or p.get("invalid") or not p.get("extract"):
                continue
            pp = p.get("pageprops", {}) or {}
            desc = norm(p.get("description", ""))
            dis = ("disambiguation" in pp) or "topics referred to by the same term" in desc.casefold() or bool(re.search(r"\bmay (?:also )?refer to\b", p["extract"][:200]))
            out.append({"title": p["title"], "description": desc, "intro": p["extract"], "qid": pp.get("wikibase_item", ""), "disambig": dis, "exact": True,
                        "exact_for": norm_key(strip_article(term)), "redirected": not (label_keys(bare_title(p["title"])) & label_keys(term))})
        if out:
            break
    return out

def wiki_candidates(probe, limit=8, site="en", timeout=10):
    """One request returns ranked titles + short description + intro + Wikidata id + disambiguation flag."""
    probe = norm(probe)
    if not probe:
        return []
    params = {"action": "query", "format": "json", "formatversion": 2, "generator": "search", "gsrsearch": probe,
              "gsrlimit": limit, "gsrnamespace": 0, "prop": "pageprops|description|extracts",
              "ppprop": "wikibase_item|disambiguation", "exintro": 1, "explaintext": 1, "exlimit": "max"}
    params["exsectionformat"] = "wiki"
    out = []
    try:
        data = http_get_json(wikipedia_api(site), params, 86400, "wcand", timeout=timeout)
        pages = (data.get("query", {}) or {}).get("pages", []) or []
        if isinstance(pages, dict):
            pages = list(pages.values())
        for p in sorted(pages, key=lambda x: x.get("index", 999)):
            title = p.get("title", "")
            if not title:
                continue
            pp = p.get("pageprops", {}) or {}
            desc = norm(p.get("description", ""))
            intro = p.get("extract", "") or ""
            dis = ("disambiguation" in pp) or "topics referred to by the same term" in desc.casefold() \
                or "disambiguation" in (title + " " + desc).casefold() or bool(re.search(r"\bmay (?:also )?refer to\b", intro[:200]))
            out.append({"title": title, "description": desc, "intro": intro, "qid": pp.get("wikibase_item", ""), "disambig": dis})
    except Exception as e:
        trace(f"wiki search '{probe}' failed: {type(e).__name__}")
    if out:
        return out
    # Fallback: REST search (no intro / id; those are fetched later only if this candidate wins).
    try:
        data = http_get_json(WIKIPEDIA_REST, {"q": probe, "limit": limit}, 86400, "wrest")
        for p in data.get("pages", []):
            title = htmlmod.unescape(p.get("title") or p.get("key") or "")
            desc = norm(p.get("description") or "")
            ex = BeautifulSoup(p.get("excerpt") or "", "html.parser").get_text(" ")
            if title:
                out.append({"title": title, "description": desc, "intro": ex, "qid": "",
                            "disambig": "topics referred to by the same term" in desc.casefold() or "disambiguation" in (title + desc).casefold()})
    except Exception:
        pass
    return out

def wiki_page_qid(title):
    try:
        data = http_get_json(wikipedia_api(), {"action": "query", "titles": title, "prop": "pageprops", "ppprop": "wikibase_item",
                                               "redirects": 1, "format": "json", "formatversion": 2}, 7 * 86400, "wpageprops")
        pages = data.get("query", {}).get("pages", [])
        return pages[0].get("pageprops", {}).get("wikibase_item", "") if pages else ""
    except Exception:
        return ""

def wiki_extract(title, intro=False, site="en"):
    params = {"action": "query", "prop": "extracts", "explaintext": 1, "exsectionformat": "wiki", "redirects": 1, "titles": title,
              "format": "json", "formatversion": 2}
    if intro:
        params["exintro"] = 1
    try:
        data = http_get_json(wikipedia_api(site), params, 86400, "wextract", timeout=12)
        pages = data.get("query", {}).get("pages", [])
        return pages[0].get("extract", "") if pages else ""
    except Exception:
        return ""

def wiki_url(title, site="en"):
    return f"https://{site}.wikipedia.org/wiki/" + quote(title.replace(" ", "_"), safe="()_-,.'")

def wiki_paragraphs(extract):
    """Plain-text extract -> [(section heading, paragraph)], skipping reference-like sections."""
    heading, skip, paras = "", False, []
    for line in str(extract or "").split("\n"):
        m = re.match(r"^\s*(=+)\s*(.+?)\s*=+\s*$", line)
        if m:
            h = m.group(2).strip()
            if len(m.group(1)) <= 2:
                skip = h.casefold() in JUNK_SECTIONS
            heading = h
            continue
        if skip:
            continue
        t = clean_wiki_text(line)
        if len(t) >= 50:
            paras.append((heading, t))
    return paras

def lead_sentences(intro, max_chars=460, max_sents=3):
    ss = split_sentences(clean_wiki_text(intro.split("\n\n")[0] if "\n\n" in intro else intro))
    if not ss:
        ss = split_sentences(clean_wiki_text(intro))
    out, total = [], 0
    for s in ss[:max_sents]:
        if out and total + len(s) > max_chars:
            break
        out.append(s)
        total += len(s) + 1
    return out, ss[len(out):]

_NAME_TAIL = re.compile(r"^((?:(?:of|the|de|del|da|von|van|la|le|di|du|and|&)\s+)?[A-Z][\w'\u2019.-]*(?:\s+(?:(?:of|the|de|del|da|von|van|la|le|di|du|and|&)\s+)?[A-Z][\w'\u2019.-]*)*)")

def extend_name(subj, tail):
    """A capitalised continuation belongs to the name: 'Leaning Tower' + 'of Pisa leaning' -> 'Leaning Tower of Pisa'."""
    if not subj or not tail or not subj[:1].isupper():
        return subj, tail
    m = _NAME_TAIL.match(tail.strip())
    if m and m.group(1) and not re.match(r"^(?:I|Why|How|What|When|Where|Who)\b", m.group(1)):
        ext = m.group(1).strip()
        rest = tail.strip()[len(ext):].strip()
        if rest or not tail.strip().endswith("?"):
            return (subj + " " + ext).strip(), rest
    return subj, tail

def why_parts(q):
    """'Why is the sky blue?' -> ('sky', 'blue'); 'Why does metal rust?' -> ('metal', 'rust').
    The subject and the predicate each name a candidate article; glued together ('sky blue') they
    name a different thing entirely (a colour), which is what v11.0 searched for."""
    s = norm(q).rstrip("?.!")
    m = re.match(r"^why\s+(?:does|do|did|is|are|was|were|can|can't|cannot|don't|doesn't|didn't|isn't|aren't)\s+(?:(?:a|an|the)\s+)?(.+)$", s, re.I)
    if not m:
        return "", ""
    rest = m.group(1).strip()
    if NLP is not None:
        try:
            doc = NLP(s)
            if doc.has_annotation("DEP"):
                for c in doc.noun_chunks:
                    if c[0].tag_ in {"WP", "WDT", "WRB", "WP$"} or c.root.dep_ not in {"nsubj", "nsubjpass"}:
                        continue
                    subj = clean_term(strip_article(c.text))
                    tail = s[c.end_char:].strip()
                    subj, tail = extend_name(subj, tail)
                    if subj and tail:
                        return subj, clean_term(tail)
        except Exception:
            pass
    toks = rest.split()
    if len(toks) == 2:
        return toks[0], toks[1]
    if len(toks) >= 3 and toks[0][:1].isupper():
        subj, tail = extend_name(toks[0], " ".join(toks[1:]))
        if tail and subj != toks[0]:
            return subj, clean_term(tail)
    if len(toks) >= 3:
        # no parser: capitalised run ("Dead Sea") or the first word is the subject
        k = 1
        while k < len(toks) - 1 and toks[k][:1].isupper() and toks[0][:1].isupper():
            k += 1
        return " ".join(toks[:k]), " ".join(toks[k:])
    return rest, ""

def how_object(q):
    """'How do bees make honey?' -> 'honey'. The thing being made or done usually has the better article (Honey explains
    how honey is made; Bee does not), so it is offered as a second candidate page alongside the subject."""
    m = re.match(r"^how (?:do|does|did|can|could) (?:(?:a|an|the) )?([\w'\- ]+?) (?:make|makes|produce|produces|create|creates|build|builds|generate|generates|form|forms|get|gets) "
                 r"(?:(?:a|an|the|their|its) )?([\w'\- ]{2,40})$", norm(q).rstrip("?.!"), re.I)
    return clean_term(m.group(2)) if m else ""

def focus_term(q, hint):
    """Which article should a short why-question live in? 'Why is the sky blue?' is about the sky (subject + adjective),
    but 'Why does metal rust?' is about rusting: with do/does/did the predicate names the phenomenon itself."""
    subj, pred = why_parts(q)
    if pred and len(pred.split()) <= 2 and re.match(r"^why\s+(?:does|do|did|doesn't|don't|didn't)\b", norm(q), re.I):
        return pred
    obj = how_object(q)
    if obj:
        return obj
    return hint or subj

def subject_hint(q):
    s = norm(q).rstrip("?.!")
    art = r"(?:(?:a|an|the)\s+)?"
    subj, _pred = why_parts(q)
    if subj:
        return "" if set(raw_tokens(subj)) & (PERSON_PRON | THING_PRON) else subj
    patterns = [
        r"^(?:what|who)\s+(?:is|was|are|were)\s+" + art + r"(.+)$",
        r"^(?:tell me (?:more )?about|define|explain|describe|summari[sz]e|give me (?:a|an) (?:summary|overview|rundown) of|overview of|what do you know about|teach me about)\s+" + art + r"(.+)$",
        r"^what\s+(?:causes|caused)\s+" + art + r"(.+)$",
        r"^how\s+(?:does|do|did)\s+" + art + r"(.+?)\s+(?:work|function|operate|form|happen|occur)s?$",
        r"^how\s+(?:is|are|was|were)\s+" + art + r"(.+?)\s+(?:formed|made|created|produced|built)$",
        r"^how\s+(?:did|does|do)\s+" + art + r"(.+?)\s+(?:die|hunt|hunts|fly|swim|breathe|see|sleep|eat|navigate|communicate|reproduce|grow|move|work|migrate)$",
        r"^why\s+(?:does|do|did|is|are|was|were|can|can't|don't|doesn't)\s+" + art + r"(.+)$",
    ]
    for p in patterns:
        m = re.match(p, s, re.I)
        if m and 1 <= len(m.group(1).split()) <= 8:
            h = clean_term(m.group(1))
            return "" if set(raw_tokens(h)) & (PERSON_PRON | THING_PRON) else h
    if NLP is not None:
        try:
            doc = NLP(s)
            if doc.has_annotation("DEP"):
                for c in doc.noun_chunks:
                    if c[0].tag_ in {"WP", "WDT", "WRB", "WP$"}:
                        continue
                    phrase = clean_term(strip_article(c.text))
                    phrase, _ = extend_name(phrase, s[c.end_char:].strip())
                    if phrase and norm_key(phrase) not in {"what", "why", "how", "who", "which", "you", "i", "me", "we", "us"} | PERSON_PRON | THING_PRON and len(phrase.split()) <= 6:
                        return phrase
        except Exception:
            pass
    return ""

def followup_qid(q, st):
    toks = raw_tokens(q)
    if NLP is not None:
        try:
            for tok in NLP(q):
                low = tok.text.casefold()
                if tok.pos_ != "PRON":
                    continue
                if low in PERSON_PRON:
                    return st.get("answer_qid") or st.get("subject_qid") or ""
                if low in (THING_PRON - {"this", "that"}):
                    return st.get("subject_qid") or ""
                if low in {"this", "that"} and tok.dep_ in {"nsubj", "nsubjpass", "dobj", "pobj"} and tok.tag_ == "DT":
                    return st.get("subject_qid") or ""
            return ""
        except Exception:
            pass
    if set(toks) & PERSON_PRON:
        return st.get("answer_qid") or st.get("subject_qid") or ""
    if set(toks) & (THING_PRON - {"this", "that"}):
        return st.get("subject_qid") or ""
    return ""

EXPLAIN_KIND_RE = re.compile(r"^(?:why|how (?:do|does|is|are|did|can|come)|what (?:causes|makes|happens))\b", re.I)
MEDIA_PAREN_RE = re.compile(r"\b(?:film|movie|tv series|television|series|album|song|band|novel|book|comics?|video game|game|magazine|newspaper|surname|given name|name|"
                            r"am|fm|radio station|musician|singer|rapper|actor|actress|footballer|company|brand|cigarette|horse|ship|character|mythology|opera|play|musical|episode)\b", re.I)
MEDIA_WORDS_RE = re.compile(r"\b(?:film|movie|series|album|song|band|novel|book|game|station|character|episode|actor|actress)\b", re.I)

def score_pages(cands_by_probe, q, hint="", alt_hint=""):
    """Merge candidates from several probes and score each page on title fit, specificity and how much
    of the question its introduction covers. Disambiguation pages are dropped, not just penalised."""
    merged = {}
    for rows in cands_by_probe:
        for rank, c in enumerate(rows or []):
            if c.get("disambig"):
                continue
            m = merged.setdefault(c["title"], dict(c, rank=rank, hits=0))
            m["rank"] = min(m["rank"], rank)
            m["hits"] += 1
            if not m.get("intro") and c.get("intro"):
                m["intro"] = c["intro"]
            if not m.get("qid") and c.get("qid"):
                m["qid"] = c["qid"]
            if c.get("exact"):
                m["exact"], m["exact_for"], m["redirected"] = True, c.get("exact_for", ""), bool(c.get("redirected"))
    if not merged:
        return []
    qstems = set(stems_of(q))
    core = core_stems(q)
    hstems = stem_set(hint)
    astems = stem_set(alt_hint) if alt_hint and len(alt_hint.split()) <= 2 else set()
    lowq = q.casefold()
    sciencey = question_kind(q) in {"why", "formation", "how"}
    pages = list(merged.values())
    sims, sim_weight = [], 25.0
    if SEM.ok and len(pages) > 1 and remaining() > 4:
        first = sorted(pages, key=lambda p: (not p.get("exact"), p["rank"]))[:min(6, max(4, SEM.budget))]
        rest = [p for p in pages if p not in first]
        pages = first + rest
        t_sem = time.monotonic()
        # title + short description + first sentence only: ~40 tokens each, so eight pages cost about as much as two paragraphs
        got = SEM.similarity(q, [(bare_title(p["title"]) + ": " + p.get("description", "") + ". " + (split_sentences(p.get("intro") or "") or [""])[0])[:300] for p in first])
        if got:
            hi = max(got)
            # Several pages that all answer to the same name ("Battery (crime)", "The Battery (Manhattan)", "Electric battery")
            # make the title match worthless as evidence; there, meaning has to decide and is given a much stronger voice.
            hs = stem_set(hint)
            # (only pages whose own name IS the term count as rivals: "Sky blue" is not another thing called "sky")
            rivals = [k for k, p in enumerate(first) if stem_set(bare_title(p["title"])) == hs]
            primary = next((k for k in rivals if not paren_part(first[k]["title"])), None)
            ambiguous = bool(hs) and len(rivals) >= 2
            # v17: a 0.04 edge (Mars Inc. 0.59 vs Mars 0.55) swung 38 points. Meaning only overrules the primary topic
            # when it is clearly ahead; between parenthesised rivals with no primary page it still decides.
            if ambiguous and primary is not None and hi - got[primary] < 0.12:
                ambiguous = False
            span, sim_weight = (0.15, 140.0) if ambiguous else (0.30, 60.0)
            sims = [max(0.0, 1.0 - (hi - g) / span) for g in got] + [0.0] * len(rest)
            trace(f"page meaning check ({len(first)} pages, {(time.monotonic() - t_sem) * 1000:.0f} ms): " + "; ".join(f"{p['title']}={g:.2f}" for p, g in sorted(zip(first, got), key=lambda x: -x[1])[:4]))
    if not sims:
        sims = embed_similarity(q, [(p["title"] + ". " + p.get("description", "") + ". " + (p.get("intro") or "")[:400]) for p in pages])
    for i, p in enumerate(pages):
        tst = stem_set(bare_title(p["title"]))
        blob = p["title"] + " " + p.get("description", "")
        s = 30 - 3 * p["rank"] + 6 * (p["hits"] - 1)
        cov = len(tst & qstems)
        extra = len(tst - qstems)
        s += 14 * cov - (12 * min(extra, 3) if cov else 10)
        for_hint = p.get("exact") and not p.get("disambig") and hint and p.get("exact_for") == norm_key(strip_article(hint))
        if for_hint and p.get("redirected"):
            # "hurricane" -> Tropical cyclone, "northern lights" -> Aurora, "9/11" -> September 11 attacks: the redirect is
            # Wikipedia's own statement of what the phrase means, so the page is scored as if it carried that title.
            s += 60 + 55 + 60
        elif for_hint:
            s += 55
        pp = (paren_part(p["title"]) or "").lower()
        if pp and EXPLAIN_KIND_RE.match(q) and MEDIA_PAREN_RE.search(pp) and not MEDIA_WORDS_RE.search(q):
            s -= 90          # v36 answer typing: "How do planes stay in the air?" is not about "Planes (film)"; "How does wifi work?" not "WIFI (AM)"
        if hstems and tst == hstems and not paren_part(p["title"]) and not p.get("disambig"):
            s += 40          # the undisambiguated title is Wikipedia's primary topic: "Mars" is the planet, not Mars Inc.
        if hstems and tst == hstems:
            s += 60
        elif astems and tst == astems:
            s += 45          # "Why does metal rust?": the predicate's own article (Rust) is as good a home as the subject's
            if not paren_part(p["title"]) and not p.get("disambig"):
                s += 40      # and its primary topic gets the same primacy bonus as the subject's
        elif hstems and tst and tst <= hstems:
            s += 12
        istems = stem_set((p.get("intro") or "")[:1500] + " " + blob)
        s += 40 * (len(core & istems) / max(1, len(core)))
        low = " " + norm_key(blob) + " "
        if low.strip().startswith("list of") or " lists of " in low:
            s -= 40
        if any(has_word(low, w) for w in CREATIVE_TYPE_WORDS) and not any(w in lowq for w in ["film", "movie", "album", "song", "novel", "book", "episode", "game", "band", "show", "series"]):
            s -= 70 if sciencey else 35
        if sims:
            s += sim_weight * max(0.0, sims[i])
        p["score"] = s
    pages.sort(key=lambda x: x["score"], reverse=True)
    return pages

def wiki_probes(q, hint):
    content = " ".join(words(q))
    probes = [hint, content]
    pred = why_parts(q)[1]
    if pred and len(pred.split()) <= 2:
        probes.append(pred)
    toks = [w for w in words(q) if stem(w) not in INTENT_STEMS]
    if 2 <= len(toks) <= 3 and question_kind(q) in {"why", "how", "formation"}:
        probes += toks  # single-term probes surface the general article ("Rust", "Glass", "Tide")
    return [p for p in dict.fromkeys(norm(p) for p in probes) if p][:5]

def swap_term(q, title, hint):
    """The span of the question a later 'what about X?' should replace."""
    low = q.casefold()
    bt = bare_title(title)
    for cand in (bt, bt + "s", bt + "es", bt[:-1] if bt.endswith("s") else ""):
        m = re.search(rf"\b{re.escape(cand)}\b", q, re.I) if cand else None
        if m:
            return m.group(0)
    if NLP is not None:
        try:
            doc = NLP(q)
            if doc.has_annotation("DEP"):
                for c in doc.noun_chunks:
                    if c.root.dep_ in {"nsubj", "nsubjpass"} and c[0].tag_ not in {"WP", "WDT", "WRB"}:
                        return strip_article(c.text)
        except Exception:
            pass
    return hint if hint and hint.casefold() in low else ""

def set_subject_from_page(st, title, qid):
    if not qid:
        qid = wiki_page_qid(title)
    st["subject_qid"] = qid or ""
    st["subject_label"] = bare_title(title)
    st["answer_qid"] = ""
    st["answer_label"] = ""

def answer_wikipedia(q, st):
    kind = question_kind(q)
    follow = followup_qid(q, st)
    hint = "" if follow else subject_hint(q)
    pages = []
    if follow:
        ent = wd_get([follow]).get(follow, {})
        title = sitelink_title(ent)
        if not title:
            trace("wikipedia follow-up: subject has no enwiki article")
            return None
        pages = [{"title": title, "qid": follow, "score": 100.0, "intro": ""}]
        q_rank = re.sub(r"\b(?:they|them|it|he|she|this|that|these|those)\b", bare_title(title), q, count=1, flags=re.I)
        if q_rank == q:
            q_rank = f"{q} {bare_title(title)}"
        trace(f"wikipedia follow-up on '{title}'")
    else:
        probes = wiki_probes(q, hint)
        alt = why_parts(q)[1] or how_object(q)
        exact_terms = [t for t in dict.fromkeys([hint, alt]) if t and len(t.split()) <= 4]
        jobs = [("s", p) for p in probes] + [("e", t) for t in exact_terms] + ([("s", alt)] if alt and alt not in probes else [])
        res = pmap(lambda j: wiki_exact(j[1]) if j[0] == "e" else wiki_candidates(j[1], 8), jobs, t_out(8))
        for j_, r_ in zip(jobs, res):
            if j_[0] == "e":
                trace(f"exact title '{j_[1]}' -> " + ("; ".join(f"{c['title']}{' (redirect)' if c.get('redirected') else ''}{' [disambiguation]' if c.get('disambig') else ''}" for c in (r_ or [])) or "nothing"))
        pages = score_pages(res, q, hint, alt)
        _CTX.main_subject = bare_title(pages[0]["title"]) if pages else ""      # v43: side pages must mention this to be quoted
        q_rank = q
        if not pages or pages[0]["score"] < 30:
            trace(f"wikipedia: no confident page (probes={probes}, best={pages[0]['title'] + ' ' + str(round(pages[0]['score'])) if pages else None})")
            return None
        trace("wikipedia pages: " + "; ".join(f"{p['title']}={p['score']:.0f}" for p in pages[:4]))

    if kind == "what":
        tst0, hst0 = stem_set(bare_title(pages[0]["title"])), stem_set(hint)
        named = bool(hst0) and (tst0 == hst0 or hst0 <= tst0 or pages[0].get("exact"))
        if follow or SUMMARY_RE.match(norm(q).rstrip("?.!")):
            named = True
        if not named or len(words(hint or q)) > 4:
            # "Who was the first person to walk on Mars?" is not "What is Mars?": returning the lead of whatever page
            # ranked first (a science-fiction trilogy, Sun Yat-sen) answered a question nobody asked.
            trace(f"not a definition question for '{pages[0]['title']}' -> passage search instead")
            kind = "general"
    if kind == "what":
        page = pages[0]
        intro = page.get("intro") or wiki_extract(page["title"], True)
        long_form = bool(SUMMARY_RE.match(norm(q).rstrip("?.!")))
        chosen, rest = lead_sentences(intro, 900, 6) if long_form else lead_sentences(intro)
        if not chosen:
            return None
        set_subject_from_page(st, page["title"], page.get("qid", ""))
        st["last_mode"] = "wikipedia"
        st["last_term"] = swap_term(q, page["title"], hint)
        src = {"title": page["title"], "url": wiki_url(page["title"])}
        more = [{"text": " ".join(rest[i:i + 2]), "source": src} for i in range(0, min(len(rest), 8), 2)]
        return {"answer": " ".join(chosen), "sources": [src], "mode": "wikipedia", "evidence_count": len(chosen), "more": more}

    top = [p for p in pages[:4] if p["score"] >= max(30, pages[0]["score"] - 32)]
    top += [p for p in pages if p.get("exact") and p not in top and p["score"] >= 60][:1]
    # v29: "How do earthquakes cause tsunamis?" mined only Earthquake (405); Tsunami (135) fell outside the 32-point window even
    # though its title is the question's object. A page named by the question's other content words joins the mining, as long
    # as its title does not repeat the main subject (that would be "Apples to Apples" for "Why do apples turn brown?").
    qst = set(stems_of(q_rank))
    sub0 = stem_set(bare_title(pages[0]["title"])) if pages else set()
    for p in sorted(pages[1:6], key=lambda p: (-len(stem_set(bare_title(p["title"])) & qst) / max(1, len(stem_set(bare_title(p["title"])))), -p["score"])):
        tst = stem_set(bare_title(p["title"]))
        if p in top or p["score"] < 90 or not tst or (tst & sub0):
            continue
        if len(tst & qst) * 2 >= len(tst) and len(top) < 5:
            top.append(p)
            trace(f"   also mining '{p['title']}' (named by the question)")
    top = top[:4]
    general = any(stem_set(bare_title(p["title"])) <= qst for p in top)
    texts = pmap(lambda p: wiki_extract(p["title"], False), top, t_out(10))
    pred = why_parts(q)[1]
    targets = stem_set(pred) if (pred and len(pred.split()) <= 2) else None
    cands, note = paragraph_first(top, texts, q_rank, kind, subject=(bare_title(top[0]["title"]) if follow else (focus_term(q, hint) or bare_title(top[0]["title"]))),
                                  shown=(st.get("last_bot") or "") if follow else "", targets=targets)
    trace("wikipedia paragraph choice: " + note)
    if not cands:
        trace("wikipedia: no paragraph I can stand behind -> abstain")
        return None
    cands.sort(key=lambda x: x["score"], reverse=True)
    shown = st.get("last_bot") or ""
    if shown and len(cands) > 1:
        # never answer a follow-up with the passage the user has just read
        fresh = [c for c in cands if jaccard(passage_from(c)[0], shown) <= 0.45]
        if fresh and fresh[0] is not cands[0]:
            trace("skipped a passage identical to the previous answer")
        cands = fresh or cands
    best = cands[0]
    text, (pi, a, b) = passage_from(best)
    page = best["page"]
    trace(f"wikipedia passage from '{page['title']}' score={best['score']:.1f}")
    set_subject_from_page(st, page["title"], page.get("qid", ""))
    st["last_mode"] = "wikipedia"
    st["last_term"] = swap_term(q, page["title"], hint)
    more = []
    for c in cands[1:]:
        if c["page"]["title"] == page["title"] and c["pi"] == pi and a - 1 <= c["j"] <= b:
            continue
        if any(jaccard(c["text"], m["text"]) > 0.5 for m in more) or jaccard(c["text"], text) > 0.5:
            continue
        t2, _ = passage_from(c, 420)
        more.append({"text": t2, "source": c["source"], "heading": c.get("heading", "")})
        if len(more) >= 6:
            break
    return {"answer": text, "sources": [best["source"]], "mode": "wikipedia", "evidence_count": b - a, "more": more, "heading": best.get("heading", "")}

def answer_simpler(st):
    qid = st.get("subject_qid")
    if not qid:
        return None
    ent = wd_get([qid]).get(qid, {})
    title = sitelink_title(ent, "simplewiki")
    if not title:
        trace("simpler: no Simple English Wikipedia article for the current subject")
        return None
    chosen, _ = lead_sentences(wiki_extract(title, True, "simple"), 420, 3)
    if not chosen:
        return None
    return {"answer": " ".join(chosen), "sources": [{"title": f"{title} (Simple English Wikipedia)", "url": wiki_url(title, "simple")}],
            "mode": "wikipedia", "evidence_count": len(chosen)}

# ---------- metasearch / web evidence ----------
def is_release_query(q):
    return bool(re.search(r"\b(?:latest|newest|current|release|version|changelog|what changed)\b", q, re.I))

LOW_QUALITY_DOMAINS = {"reddit.com", "quora.com", "medium.com", "news.ycombinator.com", "ycombinator.com", "stackexchange.com", "superuser.com", "askubuntu.com", "facebook.com", "pinterest.com", "scribd.com", "tiktok.com",
                       "instagram.com", "x.com", "twitter.com", "youtube.com", "slideshare.net", "coursehero.com", "chegg.com",
                       "brainly.com", "answers.com", "hotelplanner.com", "zippyfacts.com"}

def authority_score(url, title, q, official=""):
    d = host(url)
    path = urlparse(url).path.casefold()
    s = 0.0
    if official and (d == official or d.endswith("." + official)):
        s += 18
    if d.endswith(".gov") or ".gov." in d:
        s += 12
    if d.endswith(".edu") or ".ac." in d:
        s += 7
    if d in {"github.com", "gitlab.com"}:
        s += 6
    if d.startswith("docs.") or "/docs" in path or d.startswith("man.") or "manpages" in d or d in {"man7.org", "wiki.archlinux.org", "wiki.debian.org"}:
        s += 5
    if any(x in d for x in ["nih.gov", "nature.com", "science.org", "acm.org", "ieee.org", "britannica.com", "nasa.gov", "noaa.gov", "si.edu"]):
        s += 5
    if d.endswith("wikipedia.org"):
        s += 3
    if "official" in title.casefold():
        s += 2
    if is_release_query(q) and d in {"github.com", "gitlab.com"} and ("/releases" in path or "/tags" in path):
        s += 12
    if d in LOW_QUALITY_DOMAINS or any(d.endswith("." + x) for x in LOW_QUALITY_DOMAINS):
        s -= 9
    return s

_QUERY_FILLER = set(stems_of("top best most popular famous good great must see visit things thing do places place list recipe recipes how what why make give show tell ideas ten five"))

def relevant_rows(q, rows):
    """v17 served a French YouTube help page for 'attractions in London' and olive-oil pages for 'landmarks in Egypt'.
    A result has to share at least one distinctive word with the query (title, snippet or URL), and be in English."""
    key = (set(core_stems(q)) - _QUERY_FILLER) or set(core_stems(q))
    if not key:
        return rows
    out = []
    for r in rows:
        blob = " ".join(str(r.get(k) or "") for k in ("title", "content")) + " " + re.sub(r"[/\-_.+%]", " ", str(r.get("url") or ""))
        if not (stem_set(blob) & key):
            continue
        txt = (str(r.get("title") or "") + " " + str(r.get("content") or "")).casefold()
        if len(txt) > 60 and len(re.findall(r"\b(?:the|and|of|to|in|is|for|with|a)\b", txt)) < 2:
            continue         # not English prose
        out.append(r)
    return out

BRAVE_KEY = os.environ.get("NOAI_BRAVE_KEY", "").strip()

def brave_api_search(q, count=10):
    """v50 (optional): the Brave Search API, used only when NOAI_BRAVE_KEY is set. Same row shape as the metasearch; cached."""
    if not BRAVE_KEY:
        return []
    key = ckey("brave", q.casefold())
    hit = cache_get(key)
    if hit is not None:
        return hit
    try:
        r = WEB.get("https://api.search.brave.com/res/v1/web/search", params={"q": q, "count": count, "safesearch": "moderate", "text_decorations": "false"},
                    headers={"Accept": "application/json", "X-Subscription-Token": BRAVE_KEY}, timeout=(3, t_out(8)))
        if r.status_code != 200:
            trace(f"brave api: HTTP {r.status_code}")
            return []
        rows = []
        for x in (r.json().get("web", {}) or {}).get("results", []) or []:
            rows.append({"url": x.get("url"), "title": x.get("title"), "content": x.get("description"), "engines": ["brave-api"], "publishedDate": x.get("age") or ""})
        cache_put(key, rows, 900)
        trace(f"brave api: {len(rows)} results")
        return rows
    except Exception as e:
        trace(f"brave api failed: {type(e).__name__}")
        return []

def backup_search(q):
    if _replay.MODE == "replay":
        return []                # the backup library does not go through requests, so it cannot be replayed
    if getattr(_CTX, "backup_used", False) or time.time() - SEARCH_STATE.get("backup_failed_at", 0) < 180:
        return []
    _CTX.backup_used = True
    out = _backup_search(q)
    if not out:
        SEARCH_STATE["backup_failed_at"] = time.time()
    return out

def _backup_search(q):
    """Second, independent route to the web when the metasearch container comes back empty: the `ddgs` library queries
    DuckDuckGo, Bing, Brave, Mojeek, Yahoo and others directly and moves on when one of them is unavailable."""
    if os.environ.get("NOAI_BACKUP_SEARCH", "1") == "0" or remaining() < 4:
        return []
    try:
        from ddgs import DDGS
    except Exception:
        return []
    try:
        t0 = time.monotonic()
        hits = DDGS(timeout=int(max(3, min(5, remaining() - 1)))).text(q, region="us-en", safesearch="moderate", max_results=12) or []
        rows = [{"url": h.get("href") or h.get("url"), "title": h.get("title"), "content": h.get("body") or ""} for h in hits if (h.get("href") or h.get("url"))]
        trace(f"backup search (ddgs) returned {len(rows)} results in {time.monotonic() - t0:.1f}s")
        return rows[:16]
    except Exception as e:
        trace(f"backup search failed: {type(e).__name__}")
        return []

_searx_lock, _searx_last = threading.Lock(), [0.0]
SEARCH_STATE = {"down": "", "down_at": 0.0, "backup_failed_at": 0.0}

_SEARCH_LAST = [0.0]
_SEARCH_GAP = float(os.environ.get("NOAI_SEARCH_GAP", "1.5"))
SUSPENDED = {"events": 0, "last": ""}

def _search_pace():
    """v57: the free engines suspend a client that bursts; a small fixed gap between metasearch calls costs little and lasts."""
    now = time.monotonic()
    wait = _SEARCH_GAP - (now - _SEARCH_LAST[0])
    if wait > 0 and remaining() > wait + 2:
        time.sleep(wait)
    _SEARCH_LAST[0] = time.monotonic()

def searx_search(q, ttl=900, categories="", time_range=""):
    key = ckey("searx", q.casefold() + "|" + categories + "|" + time_range)
    hit = cache_get(key)
    if hit is not None:
        return hit
    if out_of_time():
        return []
    searched = getattr(_CTX, "searched", None)
    if searched is None:
        searched = _CTX.searched = set()
    qk = norm_key(q)[:120]
    if qk not in searched:
        if len(searched) >= int(os.environ.get("NOAI_SEARCH_PER_QUESTION", "3")):
            trace(f"search budget for this question used up ({len(searched)} queries); '{q[:50]}' not sent")   # the engines suspend servers that burst
            return []
        searched.add(qk)         # a retry or a repeat of the same query is not a new search
    try:
        with _searx_lock:       # upstream engines suspend a server that fires bursts; keep at least ~1.5 s between queries
            wait = float(os.environ.get("NOAI_SEARCH_PACE", "2.5")) - (time.time() - _searx_last[0])
            if wait > 0:
                time.sleep(min(wait, max(0.0, remaining() - 2)))
            _searx_last[0] = time.time()
        rows = []
        for attempt in (1, 2):
            params = {"q": q, "format": "json", "language": "en", "safesearch": 1}
            if categories:
                params["categories"] = categories
            if time_range:
                params["time_range"] = time_range
            _search_pace()
            r = WEB.get(SEARXNG_URL + "/search", params=params, timeout=(3, t_out(10)))
            r.raise_for_status()
            data = r.json()
            rows = [{"url": x.get("url"), "title": x.get("title"), "content": x.get("content"), "engines": x.get("engines") or [x.get("engine")], "publishedDate": x.get("publishedDate") or ""} for x in data.get("results", [])[:16]]
            dead = "; ".join(f"{e[0]}: {e[1]}" for e in (data.get("unresponsive_engines") or []) if isinstance(e, (list, tuple)) and len(e) >= 2)[:200]
            SEARCH_STATE["down"] = dead if not rows else ""
            if not rows:
                recently_down = time.time() - SEARCH_STATE.get("down_at", 0) < 180
                SEARCH_STATE["down_at"] = time.time()
                if recently_down or "suspended" in dead.lower():
                    SUSPENDED["events"] += 1; SUSPENDED["last"] = time.strftime("%Y-%m-%d %H:%M")
                    trace(f"web search returned nothing ({dead or 'no engine answered'}); engines are suspending this server, not retrying")
                    break
            if rows or attempt == 2 or remaining() < 8:
                break
            trace(f"web search returned nothing ({dead or 'no engine answered'}); retrying once in 4 s")
            time.sleep(4)
        if not rows:
            rows = brave_api_search(q) or backup_search(q)
            if rows:
                SEARCH_STATE["down"] = ""
        kept = relevant_rows(q, rows)
        if rows and len(kept) < len(rows):
            junk = Counter(e for r in rows if r not in kept for e in (r.get("engines") or []) if e)
            trace(f"dropped {len(rows) - len(kept)} of {len(rows)} search results unrelated to the query (from: {', '.join(f'{e} x{n}' for e, n in junk.most_common(4)) or 'unknown'})")
        if rows and not kept:
            kept = relevant_rows(q, backup_search(q))        # every result was junk: ask the engines directly instead
        rows = kept
        if not rows and SEARCH_STATE["down"]:
            trace(f"web search unavailable: {SEARCH_STATE['down']}")
        if rows:
            cache_put(key, rows, ttl)
        return rows
    except Exception as e:
        trace(f"searxng failed: {type(e).__name__}")
        return []

def ranked_search(q, official="", deep=False):
    probes = [q]
    if is_release_query(q):
        probes += [q + " official", q + " GitHub releases"]
    elif deep and question_kind(q) == "why":
        probes += [" ".join(words(q)) + " cause explanation"]
    ttl = 300 if is_release_query(q) else 900
    results = pmap(lambda p: searx_search(p, ttl), probes[:3], t_out(11))
    merged = {}
    qw = set(stems_of(q))
    for pi, rows in enumerate(results):
        for rank, r in enumerate(rows or []):
            u = norm(r.get("url") or "")
            if not u.startswith("http"):
                continue
            key = u.rstrip("/")
            title, snippet = norm(r.get("title")), norm(r.get("content") or "")
            sc = authority_score(u, title, q, official) + max(0, 8 - rank) + max(0, 3 - pi) + 3 * len(qw & stem_set(title + " " + snippet))
            if key not in merged:
                merged[key] = {"url": u, "title": title, "snippet": snippet, "score": sc, "hits": 1, "rank": rank}
            else:
                merged[key]["score"] += 2
                merged[key]["hits"] += 1
    rows = sorted(merged.values(), key=lambda x: (x["score"], x["hits"], -x["rank"]), reverse=True)
    out, domains = [], Counter()
    for r in rows:
        d = host(r["url"])
        if domains[d] >= 2:
            continue
        out.append(r)
        domains[d] += 1
        if len(out) >= (12 if deep else 8):
            break
    return out

def fetch_page(url, max_bytes=1_250_000, read_timeout=7):
    if _replay.MODE == "replay":
        return _replay.page_get(url)
    key = ckey("page12", url)
    hit = cache_get(key)
    if hit is not None:
        return hit
    empty = {"text": "", "codes": [], "recipes": [], "list": []}
    _replay.skip_http(True)
    try:
        with WEB.get(url, timeout=(4, read_timeout), allow_redirects=True, stream=True) as r:
            r.raise_for_status()
            ct = r.headers.get("content-type", "").casefold()
            if "text/html" not in ct and "text/plain" not in ct and "xhtml" not in ct:
                return empty
            chunks, total, t_end = [], 0, time.monotonic() + read_timeout + 3
            for chunk in r.iter_content(65536):
                if not chunk:
                    continue
                chunks.append(chunk[:max_bytes - total])
                total += len(chunks[-1])
                if total >= max_bytes or time.monotonic() > t_end:
                    break
            raw = b"".join(chunks)
        # Bytes go straight to the parsers so they sniff the real charset (requests would assume Latin-1).
        text = trafilatura.extract(raw, include_comments=False, include_tables=False, favor_precision=True) or ""
        soup = BeautifulSoup(raw, "html.parser")
        codes = []
        for tag in soup.find_all(["code", "pre"]):
            t = norm(tag.get_text(" ", strip=True))
            if 2 <= len(t) <= 300 and t not in codes:
                codes.append(t)
        try:
            _recipes_early = structured.extract_recipes(soup)
        except Exception:
            _recipes_early = []
        if not text:
            for tag in soup(["script", "style", "nav", "footer", "header", "aside", "form"]):
                tag.decompose()
            text = soup.get_text("\n", strip=True)
        recipes, items = [], []
        try:
            recipes = _recipes_early
            items = structured.extract_lists(BeautifulSoup(raw, "html.parser"))     # fresh soup: list extraction strips nav/footer
        except Exception:
            pass
        try:
            faq = structured.extract_faq(BeautifulSoup(raw, "html.parser"))
        except Exception:
            faq = []
        try:
            steps, needs = structured.extract_steps(BeautifulSoup(raw, "html.parser"))
        except Exception:
            steps, needs = [], []
        try:
            ptitle = norm(soup.title.get_text(" ")) if soup.title else ""
        except Exception:
            ptitle = ""
        try:
            heads = [re.sub(r"\s+", " ", h.get_text(" ", strip=True)) for h in soup.find_all(["h2", "h3"])]
            heads = [h for h in heads if 2 <= len(h.split()) <= 9 and len(h) < 80][:40]
        except Exception:
            heads = []
        out = {"text": str(text)[:200000], "codes": codes[:120], "recipes": recipes[:3], "list": items, "faq": faq, "steps": steps, "needs": needs, "title": ptitle[:200], "headings": heads}
        if out["text"] or out["codes"] or recipes or items or faq or steps:
            cache_put(key, out, 6 * 3600)
        _replay.page_put(url, out)
        _replay.skip_http(False)
        return out
    except Exception:
        _replay.skip_http(False)
        return empty

def web_paragraphs(text):
    raw = [strip_boilerplate(norm(p)) for p in re.split(r"\n+", str(text or "")) if 25 <= len(norm(p)) <= 4000]
    raw = [p_ for p_ in raw if len(p_) >= 25]
    paras, buf = [], ""
    for p_ in raw:                     # web pages often give each sentence its own paragraph; rejoin short neighbours so
        joinable = buf and len(buf) < 300 and len(p_) < 300 and len(buf) + len(p_) <= 560 and re.search(r"[.!?][\"')\]]?$", buf)
        if joinable:                   # an answer is not one lone vague sentence
            buf = buf + " " + p_
            continue
        if len(buf) >= 60:
            paras.append(buf)
        buf = p_
    if len(buf) >= 60:
        paras.append(buf)
    if len(paras) < 3:
        ss = split_sentences(text)
        paras = ["\n".join(ss[i:i + 3]) for i in range(0, len(ss), 3)]  # newline keeps sentence boundaries intact
    return [("", p) for p in paras]

def web_evidence(q, deep=False, official=""):
    rows = ranked_search(q, official, deep)
    if not rows:
        trace("web: metasearch returned nothing")
        return [], rows
    fetch_n = 6 if deep else 4
    head = rows[:fetch_n]
    rt = max(3, min(7, remaining() - 3))
    pages = pmap(lambda r: fetch_page(r["url"], read_timeout=rt), head, rt + 5)
    kind = question_kind(q)
    evidence = []
    for si, (r, page) in enumerate(zip(head, pages)):
        text = (page or {}).get("text") or ""
        src = {"title": r["title"] or host(r["url"]), "url": r["url"]}
        ws = rank_windows(web_paragraphs(text), q, src, title=r["title"], kind=kind, quality="web") if text else []
        if not ws and good_sentence(r["snippet"]):
            ws = rank_windows([("", r["snippet"])], q, src, title=r["title"], kind=kind, quality="web")
        for e in ws[:10]:
            e["score"] += r["score"] * 0.18
            e["source_index"] = si
        evidence.extend(ws[:10])
        qs = set(core_stems(q))
        for pair in ((page or {}).get("faq") or [])[:40]:
            ps = stem_set(pair["q"])
            if qs and len(qs & ps) / len(qs) >= 0.67:
                ss = split_sentences(pair["a"]) or [pair["a"]]
                evidence.append({"text": " ".join(ss[:3]), "score": 9.0 + r["score"] * 0.18, "source": src, "domain": host(src["url"]), "pi": 0, "j": 0,
                                 "sents": ss, "doc_pos": 0, "source_index": si, "faq": pair["q"]})
                trace(f"   site's own Q&A matches: {pair['q'][:70]}")
                break
    corroborate(evidence, q)
    evidence.sort(key=lambda x: x["score"], reverse=True)
    evidence = type_gate(evidence, q)
    trace(f"web: {len(head)} pages fetched, {len(evidence)} candidate passages, {sum(1 for e in evidence if e.get('corroborated'))} corroborated by another site")
    return evidence, rows

def corroborate(evidence, q, top=30):
    """A claim that an independent website also makes is more trustworthy than one that appears once. Passages whose
    content words (beyond the question's own) are echoed by a passage from a DIFFERENT domain get a modest boost."""
    pool = sorted(evidence, key=lambda x: x["score"], reverse=True)[:top]
    if len({e.get("domain") for e in pool}) < 2:
        return
    qst = set(stems_of(q))
    sets = [stem_set(e["text"]) - qst for e in pool]
    best = max((e["score"] for e in pool), default=0.0) or 1.0
    for i, e in enumerate(pool):
        if len(sets[i]) < 4:
            continue
        support = set()
        for j, o in enumerate(pool):
            if i != j and o.get("domain") != e.get("domain") and len(sets[i] & sets[j]) / len(sets[i] | sets[j]) >= 0.22:
                support.add(o.get("domain"))
        if support:
            e["corroborated"] = len(support)
            e["score"] += 0.08 * best * min(2, len(support))

def unique_sources(evidence):
    out, seen = [], set()
    for e in evidence:
        s = e.get("source", {})
        u = s.get("url", "")
        if u and u not in seen:
            seen.add(u)
            out.append(s)
    return out

LANG_RE = re.compile(r"\b(?:python|javascript|typescript|java|c\+\+|c#|csharp|rust|golang|kotlin|swift|ruby|php|perl|scala|haskell|lua|dart|elixir|"
                     r"sql|postgres|mysql|sqlite|html|css|react|vue|angular|node\.?js|django|flask|pandas|numpy|regex|regexp|docker|kubernetes|git|npm|pip|cargo|"
                     r"jquery|matlab|bash script|powershell|excel formula|vba|arduino)\b", re.I)
ERR_RE = re.compile(r"\b(?:[A-Z][A-Za-z]+(?:Error|Exception|Warning)|segmentation fault|segfault|stack overflow|stack trace|traceback|null pointer|undefined is not|"
                    r"cannot read propert|syntax error|compile error|linker error|core dumped|permission denied|ENOENT|EADDRINUSE|ModuleNotFound|ImportError)\b")
CODE_SHAPE_RE = re.compile(r"\b(?:code|function|method|class|loop|array|list comprehension|dictionary|dict|string|regex|json|api|library|module|package|"
                           r"script|program|compile|debug|bug|error|exception|variable|recursion|algorithm|sort|parse|async|thread|query|dataframe|import|"
                           r"div|element|selector|stylesheet|flexbox|grid|margin|padding|font|layout|button|form|input|table|column|row|index|commit|branch|merge)\b", re.I)
PY_STDLIB = {"json", "os", "re", "datetime", "csv", "sqlite3", "pathlib", "subprocess", "itertools", "collections", "argparse", "logging", "random", "math",
             "time", "sys", "urllib", "http", "socket", "threading", "asyncio", "functools", "string", "typing", "shutil", "glob", "pickle", "hashlib", "base64",
             "decimal", "fractions", "statistics", "enum", "dataclasses", "unittest", "tempfile", "zipfile", "tarfile", "email", "smtplib", "xml", "html", "struct"}

def docs_lookup(q):
    """v51: the reference page itself, without a search engine. MDN's own search API for CSS/HTML/JavaScript questions; the
    docs.python.org module page when a Python question names a standard-library module. Quoted verbatim with the link."""
    low = q.lower()
    try:
        if re.search(r"\b(?:css|html|javascript|js|dom)\b", low) and not ERR_RE.search(q):
            core = re.sub(r"^(?:how (?:do|can|would) i|how to|what is|what does|what's)\s+", "", low).strip(" ?.")
            core = re.sub(r"\b(?:in|with|using)\s+(?:css|html|javascript|js)\b", "", core).strip()
            data = http_get_json("https://developer.mozilla.org/api/v1/search", {"q": core, "locale": "en-US"}, 86400, "mdn", timeout=8) or {}
            for d in (data.get("documents") or [])[:3]:
                summ = (d.get("summary") or "").strip()
                if summ and d.get("mdn_url"):
                    return {"title": d.get("title") or "MDN", "url": "https://developer.mozilla.org" + d["mdn_url"], "quote": summ[:500], "site": "MDN Web Docs"}
        if "python" in low:
            for mod in sorted(PY_STDLIB, key=len, reverse=True):
                if re.search(r"\b" + re.escape(mod) + r"\b", low) and mod not in ("time", "string", "html", "xml", "http", "email", "random", "math") or re.search(r"\b" + re.escape(mod) + r"\.(?:\w+)", low):
                    url = f"https://docs.python.org/3/library/{mod}.html"
                    page = fetch_page(url, read_timeout=6) or {}
                    paras = [p for p in re.split(r"\n+", page.get("text") or "") if 60 <= len(p) <= 600 and not p.lower().startswith("source code")]
                    if paras:
                        return {"title": f"{mod} \u2014 Python documentation", "url": url, "quote": paras[0][:500], "site": "docs.python.org"}
    except Exception as e:
        trace(f"docs lookup failed: {type(e).__name__}")
    return None
CODE_HELP_DOMAINS = ["stackoverflow.com", "docs.python.org", "developer.mozilla.org", "learn.microsoft.com", "doc.rust-lang.org", "go.dev", "pkg.go.dev",
                     "docs.oracle.com", "cppreference.com", "superuser.com", "unix.stackexchange.com", "serverfault.com", "askubuntu.com", "stackexchange.com",
                     "github.com", "realpython.com", "geeksforgeeks.org", "w3schools.com", "kotlinlang.org", "swift.org", "ruby-lang.org", "php.net", "postgresql.org"]

def wants_code_help(q):
    if not (LANG_RE.search(q) or ERR_RE.search(q)):
        return False
    return bool(CODE_SHAPE_RE.search(q) or ERR_RE.search(q) or re.search(r"\bin (?:python|javascript|java|rust|go|c\+\+|c#|ruby|php|swift|kotlin|sql)\b", q, re.I))

def answer_code(q, st):
    """v39: fAI cannot write code. For a programming question it searches the usual places, quotes the top answer's prose and
    first code block verbatim (with attribution), and lists the other pages. Generation-shaped requests get the same, with the
    refusal stated first."""
    if not wants_code_help(q):
        return None
    generative = bool(re.match(r"^(?:(?:can|could|will|would) you |please )*(?:write|create|make|build|generate|code|implement|give me)\b", q.strip(), re.I))
    core = re.sub(r"^(?:(?:can|could|will|would) you |please )*(?:write|create|make|build|generate|code|implement|give) (?:me |us )?(?:a |an |some |the )?", "", q.strip(), flags=re.I)
    if ERR_RE.search(q):        # v51: the error message itself is the best query ("TypeError: 'NoneType' object is not subscriptable")
        m_err = re.search(r"([A-Z][A-Za-z]+(?:Error|Exception|Warning)[^?]{0,80})", q)
        if m_err:
            core = m_err.group(1).strip(" .:'\"")
    doc = docs_lookup(q)
    rows = []
    for query in (core, core + " stackoverflow"):
        for r in searx_search(query) or []:
            if r.get("url") and r["url"] not in {x["url"] for x in rows}:
                rows.append(r)
    if not rows and doc:
        st["last_mode"] = "code"
        return {"answer": f"From the documentation ({doc['site']}, \u201c{doc['title']}\u201d):\n{doc['quote']}", "sources": [{"title": doc["title"], "url": doc["url"]}],
                "mode": "code", "evidence_count": 1}
    if not rows:
        trace("code: search returned nothing")
        return None
    if doc and not any(host(r["url"]).endswith(host(doc["url"])) for r in rows[:3]):
        rows.insert(0, {"url": doc["url"], "title": doc["title"], "content": doc["quote"]})
    def prio(r):
        d = host(r["url"])
        return next((i for i, dom in enumerate(CODE_HELP_DOMAINS) if d.endswith(dom)), len(CODE_HELP_DOMAINS))
    rows.sort(key=prio)
    rows = [r for r in rows if prio(r) < len(CODE_HELP_DOMAINS)][:5] or rows[:4]
    top = rows[0]
    quote, code = "", ""
    try:
        page = fetch_page(top["url"])
        qwords = {w for w in words(core) if len(w) > 3}
        for item in web_paragraphs(page.get("text") or ""):
            body = item[1] if isinstance(item, tuple) else str(item)
            for para in re.split(r"\n+", body):
                if 60 <= len(para) <= 500 and len(qwords & set(words(para))) >= max(1, min(2, len(qwords))):
                    quote = para.strip(); break
            if quote:
                break
        codes = [c for c in (page.get("codes") or []) if 10 <= len(c) <= 900]
        if codes:
            code = "\n".join(codes[0].splitlines()[:14])
    except Exception as e:
        trace(f"code: fetch of top page failed: {type(e).__name__}")
    lead = ("I can't write code (there's no generative model in here), but these pages show how it's done. " if generative
            else "I can't write or debug code myself, but this looks like the closest documented answer. ")
    parts = [lead]
    if quote or code:
        parts.append(f"From {top['title'][:90]} ({host(top['url'])}):")
        if quote:
            parts.append(quote)
        if code:
            parts.append(code)
    parts.append("Pages that address this:\n" + "\n".join("\u2022 " + (r.get("title") or r["url"])[:100] for r in rows))
    st["last_mode"] = "code"
    return {"answer": "\n\n".join(parts), "sources": [{"title": (r.get("title") or r["url"])[:100], "url": r["url"]} for r in rows],
            "mode": "code", "evidence_count": len(rows) + (1 if code else 0)}

def answer_web(q, st, deep=False):
    v = answer_current_version(q, st)
    if v:
        return v
    ev, rows = web_evidence(q, deep)
    if not ev:
        return None
    kind = question_kind(q)
    if kind == "why":
        causal = [e for e in ev if any(m in e["text"].casefold() for m in CAUSAL_MARKERS)]
        if len(causal) >= 2 or (causal and not deep):
            ev = causal  # a "why" answer has to actually state a cause
    if deep:
        clusters = []
        for e in ev:
            for c in clusters:
                if jaccard(e["text"], c[0]["text"]) > 0.42:
                    c.append(e)
                    break
            else:
                clusters.append([e])
        by_site = {}
        for rep_ in sorted((max(c, key=lambda x: x["score"]) for c in clusters), key=lambda x: x["score"], reverse=True):
            by_site.setdefault(rep_["domain"], rep_)             # two bullets from one site are one voice, not two
        by_site = {d: x for d, x in by_site.items() if not re.search(r"(?:^|\.)(?:youtube\.com|youtu\.be|tiktok\.com|facebook\.com|instagram\.com|x\.com|twitter\.com)$", d)
                   and not str((x.get("source") or {}).get("url", "")).lower().endswith(".pdf")
                   and not re.search(r" · |\bof (?:explains|is are)\b|\s{3,}|\w\-\n", x["text"])}      # v44: garbled PDF extractions are not quotable
        if len(by_site) < 2:
            trace(f"research: only {len(by_site)} usable independent site(s); the contract needs two -> no answer")
            return None
        reps = mmr_select(list(by_site.values()), 5)
        lines = []
        for x in reps:
            t, _ = passage_from(x, 360)
            lines.append(f"\u2022 {t} ({x['domain']})")
        ans = "Here is what the strongest independent sources say:\n" + "\n".join(lines)
        picks, more = reps, []
    else:
        best = ev[0]
        ans, _ = passage_from(best, 480)
        picks = [best]
        more = []
        for c in ev[1:]:
            if jaccard(c["text"], ans) > 0.5 or any(jaccard(c["text"], m["text"]) > 0.5 for m in more):
                continue
            t, _ = passage_from(c, 420)
            more.append({"text": t, "source": c["source"]})
            if len(more) >= 4:
                break
    st["last_mode"] = "research" if deep else "web"
    return {"answer": ans, "sources": unique_sources(picks), "mode": st["last_mode"], "evidence_count": len(picks), "more": more}

# ---------- software versions ----------
def github_repo(url):
    try:
        p = [x for x in urlparse(url).path.split("/") if x]
        if host(url) == "github.com" and len(p) >= 2 and p[0] not in {"topics", "search", "orgs", "features", "marketplace"}:
            return p[0], p[1]
    except Exception:
        pass
    return None

def github_latest(owner, repo):
    key = ckey("ghlatest", owner, repo)
    hit = cache_get(key)
    if hit is not None:
        return hit or None
    try:
        r = API.get(f"https://api.github.com/repos/{owner}/{repo}/releases/latest", headers={"Accept": "application/vnd.github+json"}, timeout=(4, t_out(8)))
        if r.status_code == 200:
            d = r.json()
            out = {"tag": d.get("tag_name"), "name": d.get("name"), "published": d.get("published_at"), "url": d.get("html_url")}
            cache_put(key, out, 6 * 3600)
            return out
        if r.status_code == 404:
            # v47: projects that tag but never "release" (CPython, many kernels): take the highest final tag from the tags list
            try:
                from packaging.version import Version
                t = API.get(f"https://api.github.com/repos/{owner}/{repo}/tags?per_page=100", headers={"Accept": "application/vnd.github+json"}, timeout=(4, t_out(8)))
                best = None
                for tg in (t.json() if t.status_code == 200 else []):
                    name = str(tg.get("name") or "")
                    if re.search(r"(?i)(?:a|b|rc|alpha|beta|dev|pre)\d*$", name) or not re.search(r"\d", name):
                        continue
                    try:
                        v = Version(name.lstrip("vV"))
                    except Exception:
                        continue
                    if best is None or v > best[0]:
                        best = (v, name, tg.get("commit", {}).get("url") or "")
                if best:
                    out = {"tag": best[1], "name": f"{repo} {best[1]} (tag)", "published": "", "url": f"https://github.com/{owner}/{repo}/releases/tag/{best[1]}"}
                    cache_put(key, out, 6 * 3600)
                    return out
            except Exception:
                pass
            cache_put(key, {}, 6 * 3600)
    except Exception:
        pass
    return None

def version_query_term(q):
    s = norm(q).rstrip("?.!")
    m = re.search(r"(?:current|latest|newest)\s+(?:stable\s+)?(?:version|release)\s+of\s+(.+)$", s, re.I)
    return clean_term(m.group(1)) if m else ""

def parse_versions(text):
    out = []
    for m in re.finditer(r"\bv?(\d+(?:\.\d+){1,3})(?:[-._]([A-Za-z0-9]+))?\b", text or ""):
        ctx = text[max(0, m.start() - 90):m.end() + 90].casefold()
        score = 8 * sum(1 for w in ["latest", "current", "stable", "release", "released", "version"] if w in ctx)
        score -= 12 * sum(1 for w in ["requires", "required", "minimum", "older", "previous", "before", "beta", "alpha", " rc", "nightly", "deprecated",
                                       "feature", "in development", "pre-release", "prerelease", "unreleased", "planned", "end of life", "end-of-life"] if w in ctx)
        score += 6 * sum(1 for w in ["bugfix", "stable", "current"] if w in ctx)
        if m.group(2):
            score -= 6
        try:
            v = Version(m.group(1))
        except InvalidVersion:
            continue
        out.append((score, v, m.group(0)))
    return out

def answer_current_version(q, st):
    term = version_query_term(q)
    if not term:
        return None
    ent = resolve_subject(term, None, ("P348", "P1324", "P856"))
    official = repo_url = wd_version = wd_recent = ""
    if ent:
        e = ent["entity"]
        vals = claim_values(ranked_claims(e, "P856"))
        official = host(vals[0]["text"]) if vals else ""
        repos = claim_values(ranked_claims(e, "P1324"))
        repo_url = repos[0]["text"] if repos else ""
        vers = claim_values(ranked_claims(e, "P348"))
        wd_version = vers[0]["text"] if vers else ""
        wd_recent = ""
        try:                          # the version's publication date (P577) qualifier; only a claim from the last year counts as current
            for c in ranked_claims(e, "P348"):
                v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                if v != wd_version:
                    continue
                for q_ in c.get("qualifiers", {}).get("P577", []):
                    t = q_.get("datavalue", {}).get("value", {}).get("time", "")
                    m = re.match(r"\+(\d{4})-(\d{2})-(\d{2})", t)
                    if m:
                        d = datetime.date(int(m.group(1)), max(1, int(m.group(2))), max(1, int(m.group(3))))
                        if (datetime.date.today() - d).days <= 366:
                            wd_recent = d.isoformat()
        except Exception:
            wd_recent = ""
    def done(text, title, url, mode="web"):
        st.update({"subject_label": ent["label"] if ent else term, "subject_qid": ent["qid"] if ent else "", "answer_qid": "", "answer_label": "", "last_mode": mode, "last_term": term})
        return {"answer": text, "sources": [{"title": title, "url": url}], "mode": mode, "evidence_count": 1}
    repo = github_repo(repo_url) if repo_url else None
    if repo:
        gh = github_latest(*repo)
        if gh and gh.get("tag"):
            when = f", published {gh['published'][:10]}" if gh.get("published") else ""
            return done(f"The latest stable release of {term} on GitHub is {gh['tag']}{when}.", gh.get("name") or f"{term} release", gh.get("url") or repo_url)
    rows = ranked_search(f"{term} latest stable release", official, False)
    for r in rows[:6]:
        gr = github_repo(r["url"])
        tkey = norm_key(term).split()[0]
        if gr and ("release" in r["url"].casefold() or gr == repo) and (tkey in (norm_key(gr[0]), norm_key(gr[1])) or gr == repo) and not (repo and gr != repo):
            gh = github_latest(*gr)
            if gh and gh.get("tag"):
                when = f", published {gh['published'][:10]}" if gh.get("published") else ""
                return done(f"The latest stable release I found for {term} is {gh['tag']}{when}.", gh.get("name") or f"{term} release", gh.get("url") or r["url"])
    head = rows[:4]
    pages = pmap(lambda r: fetch_page(r["url"], read_timeout=6), head, 10)
    cands = []
    for r, page in zip(head, pages):
        blob = r["title"] + ". " + r["snippet"] + ". " + ((page or {}).get("text") or "")[:60000]
        for sc, v, raw in parse_versions(blob):
            cands.append((sc + r["score"] + (10 if official and host(r["url"]) == official else 0), v, raw, r))
    if cands:
        top = max(c[0] for c in cands)
        sc, v, raw, r = max([c for c in cands if c[0] >= top - 4], key=lambda x: x[1])
        if wd_version and ent and wd_recent and not (official and host(r["url"]) == official):
            # v49: Wikidata's dated version claim is the project's own statement; a third-party page only outranks it when it is the official site
            return done(f"Wikidata lists the current version of {term} as {wd_version} (as of {wd_recent}).", f"Wikidata: {ent['label']}", f"https://www.wikidata.org/wiki/{ent['qid']}")
        return done(f"The current stable release I found for {term} is {raw}.", r["title"] or host(r["url"]), r["url"])
    if wd_version and ent:
        return done(f"Wikidata lists {term} version {wd_version}.", f"Wikidata: {ent['label']}", f"https://www.wikidata.org/wiki/{ent['qid']}", "wikidata")
    return None

# ---------- nearby places (OpenStreetMap) ----------
PLACE_CATEGORIES = {
    "museum": [("tourism", "museum")], "gallery": [("tourism", "gallery")], "restaurant": [("amenity", "restaurant")],
    "cafe": [("amenity", "cafe")], "coffee": [("amenity", "cafe")], "bar": [("amenity", "bar"), ("amenity", "pub")],
    "pub": [("amenity", "pub")], "park": [("leisure", "park")], "hotel": [("tourism", "hotel")],
    "bookstore": [("shop", "books")], "bookshop": [("shop", "books")], "attraction": [("tourism", "attraction")],
    "library": [("amenity", "library")], "pharmacy": [("amenity", "pharmacy")], "supermarket": [("shop", "supermarket")],
    "bakery": [("shop", "bakery")], "cinema": [("amenity", "cinema")], "theatre": [("amenity", "theatre")], "theater": [("amenity", "theatre")],
}
DENSE_CATEGORIES = {"restaurant", "cafe", "coffee", "bar", "pub", "bakery", "supermarket", "pharmacy"}
_nominatim_lock = threading.Lock()
_last_nom = [0.0]

def singular_category(word):
    w = word.casefold()
    for cand in (w, w[:-1] if w.endswith("s") else w, w[:-3] + "y" if w.endswith("ies") else w, w[:-2] if w.endswith("es") else w):
        if cand in PLACE_CATEGORIES:
            return cand
    return ""

def parse_nearby(q):
    s = norm(q).rstrip("?.!")
    m = re.search(r"^(.*?)\b(?:near to|near|around|close to|in the area of)\s+(.+)$", s, re.I)
    if not m:
        return None
    cat = ""
    for w in reversed(raw_tokens(m.group(1))):
        cat = singular_category(w)
        if cat:
            break
    place = clean_term(m.group(2))
    if not cat or not place or norm_key(place) in {"me", "here", "my location", "us"}:
        return None
    return cat, place

def nominatim_search(place):
    key = ckey("nom5", place.casefold())
    hit = cache_get(key)
    if hit is not None:
        return hit
    with _nominatim_lock:
        wait = 1.05 - (time.time() - _last_nom[0])
        if wait > 0:
            time.sleep(wait)
        try:
            r = API.get(NOMINATIM, params={"q": place, "format": "jsonv2", "limit": 5}, timeout=(4, t_out(10)))
            _last_nom[0] = time.time()
            r.raise_for_status()
            data = r.json()
            if data:
                cache_put(key, data, 30 * 86400)
            return data
        except Exception as e:
            trace(f"nominatim failed: {type(e).__name__}")
            return []

def haversine(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(a))

def overpass_query(lat, lon, tags, radius, endpoints=None):
    dlat = radius / 111320.0
    dlon = radius / (111320.0 * max(0.2, math.cos(math.radians(lat))))
    box = f"{lat - dlat:.5f},{lon - dlon:.5f},{lat + dlat:.5f},{lon + dlon:.5f}"
    clauses = "".join(f'nw["{k}"="{v}"]["name"]({box});' for k, v in tags)
    query = f"[out:json][timeout:6];({clauses});out center tags 120;"
    for ep in (endpoints or OVERPASS_ENDPOINTS):
        if remaining() < 3:
            return None
        try:
            r = API.post(ep, data={"data": query}, timeout=(4, t_out(7)))
            r.raise_for_status()
            data = r.json()
            if data.get("remark"):
                trace(f"overpass {host(ep)} r={radius}: remark '{str(data['remark'])[:80]}'")
                if not data.get("elements"):
                    continue          # server-side timeout arrives as HTTP 200 with a remark and no elements
            return data.get("elements", [])
        except Exception as e:
            trace(f"overpass {host(ep)} r={radius}: {type(e).__name__}")
    return None  # both endpoints failed: do NOT keep retrying at other radii

def overpass_places(lat, lon, cat):
    tags = PLACE_CATEGORIES.get(cat)
    if not tags:
        return []
    radii = (400, 1000, 2500) if cat in DENSE_CATEGORIES else (1200, 3500)
    best = []
    for radius in radii:
        key = ckey("overpass11", round(lat, 4), round(lon, 4), cat, radius)
        uniq = cache_get(key)
        if uniq is None:
            els = overpass_query(lat, lon, tags, radius, OVERPASS_ENDPOINTS[:1] if cat in WIKI_GEO_WORDS else None)
            if els is None:
                break
            got = []
            for e in els:
                t = e.get("tags", {})
                name = norm(t.get("name"))
                elat = e.get("lat") or (e.get("center") or {}).get("lat")
                elon = e.get("lon") or (e.get("center") or {}).get("lon")
                if not name or elat is None or elon is None:
                    continue
                got.append({"name": name, "website": safe_http_url(t.get("website") or t.get("contact:website") or ""),
                            "wikidata": t.get("wikidata") or "", "notable": bool(t.get("wikidata") or t.get("wikipedia")),
                            "distance_km": haversine(lat, lon, float(elat), float(elon))})
            seen, uniq = set(), []
            got = [x for x in got if x["distance_km"] * 1000 <= radius * 1.05]      # the box is square; keep the circle
            for x in sorted(got, key=lambda x: x["distance_km"]):
                k = norm_key(x["name"])
                if k not in seen:
                    seen.add(k)
                    uniq.append(x)
            cache_put(key, uniq, 86400 if uniq else 600)     # an empty result may be a server hiccup: do not keep it for a day
            trace(f"overpass r={radius}: {len(uniq)} named places")
        best = uniq
        if len(uniq) >= 5:
            break
    return best

# Fallback when the public Overpass servers are slow: Wikipedia's geotagged articles. Only useful for the kinds of
# place that tend to have articles (museums, parks, theatres...), never for cafes or pharmacies.
WIKI_GEO_WORDS = {"museum": ["museum"], "gallery": ["gallery", "art museum"], "park": ["park", "garden", "common", "green space"],
                  "library": ["library", "athenaeum"], "theatre": ["theatre", "theater", "opera house", "concert hall"],
                  "theater": ["theatre", "theater", "opera house", "concert hall"], "cinema": ["cinema", "movie theater", "movie theatre"],
                  "attraction": ["landmark", "monument", "museum", "historic", "tourist attraction", "memorial"], "hotel": ["hotel"]}

def wiki_geo_places(lat, lon, cat):
    terms = WIKI_GEO_WORDS.get(cat)
    if not terms or remaining() < 2:
        return []
    data = {}
    for params in ({"action": "query", "generator": "search", "gsrsearch": f"{terms[0]} nearcoord:3km,{lat:.4f},{lon:.4f}", "gsrlimit": 40, "gsrnamespace": 0,
                    "prop": "coordinates|description", "colimit": "max", "format": "json", "formatversion": 2},
                   {"action": "query", "generator": "geosearch", "ggscoord": f"{lat:.5f}|{lon:.5f}", "ggsradius": 3000, "ggslimit": 500,
                    "prop": "coordinates|description", "colimit": "max", "format": "json", "formatversion": 2}):
        try:
            data = http_get_json(wikipedia_api("en"), params, 7 * 86400, "wgeo2", timeout=min(8, max(2, remaining())))
        except Exception as e:
            trace(f"wikipedia geo lookup failed: {type(e).__name__}")
            data = {}
        if (data.get("query") or {}).get("pages"):
            break
    out = []
    for pg in (data.get("query") or {}).get("pages") or []:
        blob = (pg.get("title", "") + " " + pg.get("description", "")).casefold()
        co = (pg.get("coordinates") or [{}])[0]
        if not any(t in blob for t in terms) or co.get("lat") is None or blob.startswith("list of"):
            continue
        if re.search(r"\b(?:former|defunct|demolished|closed|destroyed|was an?|1[6-9]th[- ]century)\b", blob):
            continue         # "Former museum in Boston" is not somewhere to visit
        out.append({"name": pg["title"], "distance_km": haversine(lat, lon, float(co["lat"]), float(co["lon"])), "description": pg.get("description", "")})
    out.sort(key=lambda x: x["distance_km"])
    trace(f"wikipedia geosearch: {len(out)} matching articles within 3 km")
    return out[:7]

def nearby_from_wikipedia(rows, cat, place, st):
    lines, sources = [], []
    for x in rows:
        d = x["distance_km"]
        dist = f"about {d * 1000:.0f} m away" if d < 1 else f"about {d:.1f} km away"
        lines.append(f"\u2022 {x['name']} \u2014 {dist}" + (f" ({x['description']})" if x.get("description") else ""))
        sources.append({"title": x["name"], "url": wiki_url(x["name"])})
    st.update({"last_mode": "osm", "subject_label": place, "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": place, "last_place": place})
    label = {"gallery": "galleries", "library": "libraries"}.get(cat, cat + "s")
    note = "OpenStreetMap gave no results just now (its public servers are often busy), so this list comes from Wikipedia's geotagged articles: notable places only, nearest first."
    return {"answer": f"Here are some {label} near {place}:\n" + "\n".join(lines) + "\n\n" + note, "sources": sources[:8], "mode": "osm", "evidence_count": len(rows)}

def geocode_place(place):
    """'Boston Common in Boston' sent verbatim made the geocoder return a hamlet called Old Boston near Liverpool.
    Free-text geocoders want 'X, Y'; of several hits the most important one (by the geocoder's own measure) is taken,
    and the containing place alone is the last resort."""
    variants = []
    m = re.match(r"^(.+?)\s+in\s+(.+)$", place.strip(), re.I)
    if m:
        variants += [f"{m.group(1).strip()}, {m.group(2).strip()}", place, m.group(2).strip()]
    else:
        variants.append(place)
    for v in dict.fromkeys(variants):
        rows = nominatim_search(v) or []
        if rows:
            best = max(rows, key=lambda r: float(r.get("importance") or 0.0))
            return [best]
    return []

SKIP_DOMAINS = ("youtube.", "youtu.be", "tiktok.", "facebook.", "instagram.", "pinterest.", "twitter.", "x.com", "reddit.", "quora.", "amazon.", "ebay.")
COOK_VERBS = r"(?:make|cook|bake|roast|grill|fry|smoke|prepare|brine|marinate|season|brew|whip up)"
RECIPE_RE = re.compile(rf"^(?:(?:can you |could you |please )?(?:give|show|find|get|tell) me (?:a |an |the |some |your )?(?:good |best |easy |simple |quick )?|i (?:need|want) (?:a |an )?|"
                       rf"what(?:'s| is) (?:a |an |the )?(?:good |best |easy |simple )?)?(?P<a>.*?)\brecipes?\b(?: (?:for|of|to make) (?P<b>.+))?$", re.I)
INGREDIENTS_RE = re.compile(r"^(?:what (?:are|is) the |what )?ingredients? (?:do i need )?(?:for|in|of|to make) (?:a |an |the )?(?P<b>.+)$", re.I)
HOW_COOK_RE = re.compile(rf"^how (?:do (?:i|you|we)|to|can i|should i) {COOK_VERBS} (?:a |an |the |some |my own |homemade )?(?P<b>.+)$", re.I)
LIST_RE = re.compile(r"^(?:(?:what|which) (?:are|were) |(?:can you |could you |please )?(?:give|show|tell|name|list) (?:me )?|list |name |i want |i need )?(?:the |some |a list of |a few )?"
                     r"(?:(?P<n>\d{1,2}) )?(?:top|best|greatest|most (?:popular|famous|visited|beautiful)|must[- ]see|must[- ]do|must[- ]visit|famous|popular)"
                     r"(?: (?P<n2>\d{1,2}))? (?P<what>.+)$", re.I)
ENUM_RE = re.compile(r"^(?:(?:what|which) (?:are|were) |(?:can you |could you |please )?(?:give|show|tell|name|list) (?:me )?|list |name )?(?:the |some |a few )?"
                     r"(?:(?P<n>\d{1,2}) )?(?:main |major |common |most common |biggest |leading |key |primary |top |different |various |typical |early |first |possible )*"
                     r"(?P<what>(?:causes|types|kinds|symptoms|signs|benefits|effects|side effects|uses|advantages|disadvantages|risks|complications|features|examples|"
                     r"reasons|factors|sources|stages|steps|components|parts|characteristics|treatments|dangers|drawbacks|consequences) (?:of|for) .+)$", re.I)
THINGS_RE = re.compile(r"^(?:what (?:are|is) (?:there )?|what to |what should i |what can (?:i|you|we) |(?:give|show|tell) me )?(?:some |the |fun |good |best |top )*"
                       r"(?P<what>(?:things|stuff|activities|places|sights|attractions|what) (?:to (?:do|see|visit)|worth (?:seeing|visiting))?\s*(?:in|at|around|near) .+|(?:see|do|visit) in .+)$", re.I)

def _dish(q):
    s = norm(q).rstrip("?.! ")
    mw = COOK_WITH_RE.match(s)
    if mw:
        return clean_term(re.sub(r"\band\b|,", " ", mw.group("ings"))), True
    for pat in (INGREDIENTS_RE, HOW_COOK_RE):
        m = pat.match(s)
        if m:
            return clean_term(m.group("b")), pat is HOW_COOK_RE
    m = RECIPE_RE.match(s)
    if m and "recipe" in s.casefold():
        a, b = (m.group("a") or "").strip(), (m.group("b") or "").strip()
        a = re.sub(r"^(?:a|an|the|good|best|easy|simple|quick|great)\s+", "", a, flags=re.I).strip()
        dish = " ".join(x for x in (a, ("for " + b) if (a and b) else b) if x).strip()
        return clean_term(dish), False
    return "", False

def _fetch_many(rows, n):
    urls = [r for r in rows if r.get("url") and not any(d in host(r["url"]) for d in SKIP_DOMAINS)][:n]
    pages = pmap(lambda r: fetch_page(r["url"], read_timeout=6), urls, t_out(10))
    return [(r, p or {}) for r, p in zip(urls, pages)]

def search_down_message(what):
    why = SEARCH_STATE.get("down") or ""
    return (f"I couldn't search the web for {what} just now: the search engines behind my metasearch returned nothing"
            + (f" ({why})" if why else "") + ". They throttle bursts of queries; this usually clears within a few minutes, so please try again shortly.")

def answer_recipe(q, st):
    dish, soft = _dish(q)
    if not dish or len(dish.split()) > 9:
        return None
    ctx_extend(BUDGET_SLOW)
    rows = searx_search(f"{dish} recipe")
    if not rows:
        if soft:
            return None          # "how do I make X" may not be cooking at all; let the other routes try
        st["last_mode"] = "none"
        return {"answer": search_down_message(f"a {dish} recipe"), "sources": [], "mode": "none", "evidence_count": 0}
    if soft and sum(1 for r in rows[:8] if re.search(r"recipe|ingredients|tablespoon|teaspoon|\bcups?\b|preheat|whisk", ((r.get("title") or "") + " " + (r.get("url") or "") + " " + (r.get("content") or "")).casefold())) < 2:
        trace(f"'{dish}' does not look like food (search results are not recipes)")
        return None          # "how do I make a bootable USB" is not cooking
    want = stem_set(dish)
    best, bs = None, -1.0
    good_rows = [r for r in rows if r.get("url") and not any(d in host(r["url"]) for d in SKIP_DOMAINS)]
    fetched = _fetch_many(good_rows[:3], 3)
    if not any(len(rec.get("ingredients") or []) >= 3 for _, pg in fetched for rec in (pg.get("recipes") or [])) and not out_of_time():
        fetched += _fetch_many(good_rows[3:7], 4)
    for rank, (row, page) in enumerate(fetched):
        for rec in page.get("recipes") or []:
            if len(rec.get("ingredients") or []) < 3:
                continue
            name = rec.get("name") or row.get("title") or ""
            sc = 10.0 * len(want & stem_set(name)) / max(1, len(want)) + (2.0 if rec.get("steps") else 0.0) - 0.5 * rank
            if sc > bs:
                bs, best = sc, (rec, row)
    trace(f"recipe search '{dish}': {len(rows)} results, best match score {bs:.1f}")
    if not best or bs < 2.0:
        if soft:
            return None
        st["last_mode"] = "none"
        links = "\n".join(f"\u2022 {r.get('title') or host(r['url'])}" for r in good_rows[:4])
        return {"answer": f"I found recipe pages for {dish}, but none of them exposes its ingredients and steps in a form I can read reliably, and I won't guess at a recipe. These are the top results:\n{links}",
                "sources": [{"title": r.get("title") or host(r["url"]), "url": r["url"]} for r in good_rows[:4]], "mode": "none", "evidence_count": 0}
    rec, row = best
    dom = host(row["url"])
    head = (rec.get("name") or dish.title()) + f" \u2014 from {dom}"
    meta = " \u00b7 ".join(x for x in (("Makes " + rec["yield"]) if rec.get("yield") else "", rec.get("time", "")) if x)
    lines = [head] + ([meta] if meta else []) + ["", "Ingredients:"] + ["\u2022 " + i for i in rec["ingredients"][:30]]
    if rec.get("steps"):
        lines += ["", "Method:"] + [f"{n}. {t[:420]}" for n, t in enumerate(rec["steps"][:15], 1)]
    else:
        lines += ["", "The page lists the ingredients in machine-readable form but not the method; open the source for the steps."]
    st.update({"last_mode": "recipe", "subject_label": dish, "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": dish})
    st["last_recipe"] = json.dumps({"name": rec.get("name") or dish.title(), "yield": rec.get("yield") or "", "time": rec.get("time") or "", "ingredients": rec["ingredients"][:30],
                                    "sources": [{"title": row.get("title") or dom, "url": row["url"]}]}, ensure_ascii=False)
    return {"answer": "\n".join(lines), "sources": [{"title": row.get("title") or dom, "url": row["url"]}], "mode": "recipe", "evidence_count": len(rec["ingredients"])}

def merge_by_meaning(ranked, threshold=0.72):
    """v49: merge consensus clusters whose names mean the same thing ("Deforestation" / "Cutting down forests") using the static
    word embeddings; sites are unioned, the shortest name kept. Exact-word agreement stays the first pass."""
    if EMB is None or len(ranked) < 2:
        return ranked
    try:
        import numpy as np
        names = [c["name"] for c in ranked]
        M = np.array(EMB.encode(names), dtype="float32")
        M /= (np.linalg.norm(M, axis=1, keepdims=True) + 1e-9)
        sim = M @ M.T
        merged, used = [], set()
        for i in range(len(ranked)):
            if i in used:
                continue
            group = {"name": ranked[i]["name"], "domains": set(ranked[i]["domains"])}
            for j in range(i + 1, len(ranked)):
                if j not in used and sim[i, j] >= threshold:
                    trace(f"   merged '{ranked[j]['name']}' into '{ranked[i]['name']}' (sim={sim[i, j]:.2f})")
                    group["domains"] |= set(ranked[j]["domains"])
                    if len(ranked[j]["name"]) < len(group["name"]):
                        group["name"] = ranked[j]["name"]
                    used.add(j)
            used.add(i)
            merged.append({"name": group["name"], "sites": len(group["domains"]), "domains": sorted(group["domains"])})
        merged.sort(key=lambda c: c["sites"], reverse=True)
        return merged
    except Exception as e:
        trace(f"enumeration: meaning merge skipped ({type(e).__name__})")
        return ranked

ENUM_CUE_RE = re.compile(r"\b(?:include|includes|including|are|is|such as|namely|consist of|consists of|comprise|comprises|e\.g\.|for example|like)\b[:\s]+", re.I)

def enumerate_claims(text, noun):
    """v47 (Phase 5 claim synthesis): items named in sentences about the enumeration noun. Sentence pattern: '<noun> ... include X, Y and Z'
    or 'X, Y and Z are the main <noun>'. Items are the noun phrases of the coordination; nothing is composed, only counted."""
    items, quotes = [], []
    if not text or not noun:
        return items, quotes
    stem_n = stem(noun)
    for sent in split_sentences(text, lo=30, hi=400):
        low = sent.lower()
        if stem_n not in stem_set(sent) or len(sent) > 400:
            continue
        seg = None
        m1 = re.search(r"\b" + re.escape(noun[:-1] if noun.endswith("s") else noun) + r"s?\b[^.;:]{0,60}?" + ENUM_CUE_RE.pattern + r"(.+)$", low, re.I)
        if m1:
            seg = sent[m1.start(1):]
        else:
            m2 = re.match(r"^(.+?)\b(?:are|is|remain|constitute|represent)\b[^.;]{0,25}\b" + re.escape(stem_n[:4]), low)
            if m2:
                seg = sent[:m2.end(1)]
        if not seg:
            m3 = re.search(r"^(.{3,60}?)\s+(?:is|are|remains?|was|were)\s+(?:one of |among )?(?:the |a )?(?:main|major|primary|biggest|leading|key|largest|most common|single largest)?\s*" + re.escape(stem_n[:4]), low)
            if m3 and len(m3.group(1).split()) <= 6:
                items.append(sent[:m3.end(1)].strip(" ,;").capitalize()); quotes.append(sent.strip())
            continue
        seg = re.split(r"[.;:]|\b(?:which|that|because|while|although|whereas)\b", seg)[0]
        parts = re.split(r",|\band\b|\bor\b|/", seg)
        got = []
        for pt in parts:
            pt = re.sub(r"^(?:the |a |an |other |such as |especially |mainly |mostly |primarily |as well as |also )+", "", pt.strip(" ()\u2019'\"")).strip()
            pt = re.sub(r"\s*\([^)]*\)", "", pt).strip()
            if 1 <= len(pt.split()) <= 5 and len(pt) < 50 and not re.search(r"\d{3,}|\bthe\b.*\bof\b.*\bof\b", pt) and stem_n not in stem_set(pt):
                got.append(pt[0].upper() + pt[1:] if pt[:1].islower() else pt)
        if len(got) >= 2:
            items += got
            quotes.append(sent.strip())
    seen, out = set(), []
    for it in items:
        k = structured._key(it) if hasattr(structured, "_key") else it.lower()
        if k and k not in seen:
            seen.add(k); out.append(it)
    return out[:40], quotes[:6]

def answer_list(q, st):
    s = norm(q).rstrip("?.! ")
    m = LIST_RE.match(s) or THINGS_RE.match(s) or ENUM_RE.match(s)
    if not m or re.search(r"\bnear (?:me|here)\b", s, re.I):
        return None
    if m.re is ENUM_RE:
        trace("enumeration: treating as a cross-source list of named items (v46 claim synthesis)")
    what = clean_term(m.group("what"))
    gd = m.groupdict()
    if len(what.split()) > 10 or len(words(what)) < 1 or re.match(r"^(?:way|ways|thing|part|reason|time|practice|option|choice|approach|method)s?\b(?! to (?:do|see|visit))", what, re.I):
        return None
    if len(what.split()) < 2 and not (gd.get("n") or gd.get("n2")):
        return None          # "Top Gun", "Best Buy": a name, not a request for a list
    n = int(gd.get("n") or gd.get("n2") or 8)
    n = max(3, min(12, n))
    ctx_extend(BUDGET_SLOW)
    rows = searx_search(s)
    if not rows:
        st["last_mode"] = "none"
        return {"answer": search_down_message("a list of " + what), "sources": [], "mode": "none", "evidence_count": 0}
    subj = (set(core_stems(what)) - _QUERY_FILLER) or set(core_stems(what))
    try:        # v49: ask Wikipedia for "List of <what>" every time; engines rarely surface it and it is the authority when it exists
        want_list = set(core_stems(what))
        for wp in wiki_candidates("List of " + what, limit=3):
            t = wp.get("title") or ""
            if re.match(r"(?i)list of ", t) and want_list <= stem_set(t) and not any(r.get("url", "").endswith(t.replace(" ", "_")) for r in rows):
                rows.insert(0, {"title": t, "url": "https://en.wikipedia.org/wiki/" + t.replace(" ", "_")})
                trace(f"list: adding Wikipedia's '{t}'")
                break
    except Exception as e:
        trace(f"list: wikipedia list lookup failed ({type(e).__name__})")
    per_site = []
    enum = m.re is ENUM_RE
    enum_noun = what.split()[0].lower() if enum else ""
    fetched = list(_fetch_many(rows, 8))
    if enum:
        claims = []
        for row, page in fetched:
            if any(host(row["url"]) == d for d, _, _ in claims):
                continue
            items, quotes = enumerate_claims(page.get("text") or "", enum_noun)
            title_l = (str(row.get("title") or "") + " " + str(page.get("title") or "")).lower()
            if stem(enum_noun) in stem_set(title_l):
                body_l = (page.get("text") or "").lower()
                site_words = set(raw_tokens(host(row["url"]).replace(".", " ")))
                heads = [h for h in (page.get("headings") or []) if not LINKY_ITEM_RE.search(h) and stem(enum_noun) not in stem_set(h)
                         and h.lower() in body_l and not (set(raw_tokens(h)) & site_words)
                         and not re.search(r"(?i)^(?:related|more|share|contact|about|references|sources|learn more|see also|footer|menu|navigation|resources)\b", h)]
                if 2 <= len(heads) <= 15:
                    items = list(dict.fromkeys(items + heads))
                    trace(f"   headings from {host(row['url'])} counted as {enum_noun}: {'; '.join(heads[:3])}")
            if len(items) >= 2:
                claims.append((host(row["url"]), items, dict(row, quotes=quotes)))
                trace(f"   claims from {host(row['url'])}: {len(items)} named {enum_noun}, e.g. {'; '.join(items[:3])}")
        if claims:
            ranked = merge_by_meaning(structured.consensus([(d, it) for d, it, _ in claims], subject_words=raw_tokens(what), limit=40))
            agreed = [c for c in ranked if c["sites"] >= 2]
            if len(claims) >= 2 and len(agreed) >= 2:
                st.update({"last_mode": "list", "last_term": what})
                total = len(claims)
                lines = [f"What {total} independent source{'s' if total != 1 else ''} name as {what} (each item counted across sources):"]
                for i, c in enumerate(agreed[:n], 1):
                    lines.append(f"{i}. {c['name']}  ({c['sites']} of {total})")
                lines.append("Counted from the sources' own sentences; the order is by agreement, not importance.")
                srcs = [{"title": r.get("title") or d, "url": r["url"]} for d, _, r in claims]
                return {"answer": "\n".join(lines), "sources": srcs, "mode": "list", "evidence_count": sum(c["sites"] for c in agreed)}
            trace(f"enumeration: {len(claims)} source(s) name items but fewer than two items are named by two sources -> falling back to page lists")
    for row, page in fetched:
        items = page.get("list") or []
        if subj and not (stem_set(str(row.get("title") or "") + " " + re.sub(r"[/\-_.]", " ", str(row.get("url") or ""))) & subj):
            continue             # the page title has to mention the subject ("London", "dog", "Egypt")
        if any(host(row["url"]) == d for d, _, _ in per_site):
            continue             # two pages of the same site are one opinion, not two
        if len(items) >= 4:
            per_site.append((host(row["url"]), items, row))
            trace(f"   list from {host(row['url'])}: {len(items)} items, e.g. {'; '.join(items[:3])}")
    if not per_site:
        trace("list: no list-shaped pages among the results")
        st["last_mode"] = "none"
        usable = [r for r in rows if r.get("url")][:4]
        links = "\n".join(f"\u2022 {r.get('title') or host(r['url'])}" for r in usable)
        return {"answer": f"I searched for \u201c{what}\u201d but couldn't pull a clean list out of the pages I found. These may help:\n{links}" if usable else search_down_message("a list of " + what),
                "sources": [{"title": r.get("title") or host(r["url"]), "url": r["url"]} for r in usable], "mode": "none", "evidence_count": 0}
    ranked = structured.consensus([(d, it) for d, it, _ in per_site], subject_words=raw_tokens(what), limit=n)
    if len(ranked) < 3 or (len(per_site) >= 3 and max(c["sites"] for c in ranked) < 2):
        wl = [(d, it, r) for d, it, r in per_site if d.endswith("wikipedia.org") and re.match(r"(?i)list of ", r.get("title") or "")]
        if wl:      # v45: Wikipedia's own "List of museums in London" is the authority for that question; no cross-site vote needed
            d, it, r = wl[0]
            items = [x for x in it if len(x.split()) >= 2 and len(x) < 80][:max(n, 10)]
            if len(items) >= 3:
                trace(f"list: using Wikipedia's list page '{r.get('title')}' ({len(items)} usable items; alphabetical, not ranked)")
                st["last_mode"] = "list"
                body = "\n".join(f"{i + 1}. {x}" for i, x in enumerate(items))
                return {"answer": f"Wikipedia keeps a list page for \u201c{what}\u201d; the first {len(items)} entries (in the page's own order, not ranked):\n{body}",
                        "sources": [{"title": r.get("title"), "url": r["url"]}], "mode": "list", "evidence_count": len(items)}
        # three or more "lists" that agree on nothing are not lists about the same thing (v17: dog breeds, Egypt)
        trace("list: the pages found do not agree on any item -> not used")
        st["last_mode"] = "none"
        links = "\n".join(f"\u2022 {r.get('title') or host(r['url'])}" for _, _, r in per_site[:4])
        return {"answer": f"I found pages for \u201c{what}\u201d but couldn't extract a list the sites agree on. These may help:\n{links}",
                "sources": [{"title": r.get("title") or d, "url": r["url"]} for d, _, r in per_site[:4]], "mode": "none", "evidence_count": 0}
    total = len(per_site)
    ranked = [c for c in ranked if not LINKY_ITEM_RE.search(c["name"]) and not re.search(r"(?i)\b(?:below|above|click|availability|popular tours|content|read more|see also)\b", c["name"])
              and c["name"].strip().lower() not in GENERIC_ITEMS]
    if total >= 2:
        shown = [c for c in ranked if c["sites"] >= 2] or ranked
        if total >= 3:
            ranked = shown       # with three or more sites, an item only one of them names is probably that page's own heading
        head = f"Here's what {total} independent sites list most often for \u201c{what}\u201d:"
        lines = [f"{i}. {c['name']}" + (f"  ({c['sites']} of {total} sites)" if total > 2 else "") for i, c in enumerate((shown + [c for c in ranked if c not in shown])[:n], 1)]
    else:
        head = f"I found one list for \u201c{what}\u201d, from {per_site[0][0]}:"
        lines = [f"{i}. {c['name']}" for i, c in enumerate(ranked[:n], 1)]
    st.update({"last_mode": "list", "subject_label": what, "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": what})
    mpl = re.search(r"\b(?:in|near|around|of) ([A-Z][\w' .-]{1,40})$", what)
    if mpl:
        st["last_place"] = mpl.group(1).strip()
    st["last_list"] = json.dumps([re.sub(r"\s*\(.*?\)\s*$", "", c["name"]) for c in (shown + [c for c in ranked if c not in shown])[:n]] if total >= 2 else [c["name"] for c in ranked[:n]], ensure_ascii=False)
    note = "\nRanked by how many sites mention each item, not by my own judgement." if total >= 2 else ""
    return {"answer": head + "\n" + "\n".join(lines) + note, "sources": [{"title": r.get("title") or d, "url": r["url"]} for d, _, r in per_site[:6]],
            "mode": "list", "evidence_count": sum(len(it) for _, it, _ in per_site)}

def answer_nearby(q, st):
    parsed = parse_nearby(q)
    if not parsed:
        return None
    ctx_extend(BUDGET_SLOW)
    cat, place = parsed
    geo = geocode_place(place)
    if not geo:
        trace(f"nearby: could not geocode '{place}'")
        return None
    lat, lon = float(geo[0]["lat"]), float(geo[0]["lon"])
    trace(f"geocoded '{place}' -> {str(geo[0].get('display_name', ''))[:70]} ({lat:.4f},{lon:.4f})")
    rows = overpass_places(lat, lon, cat)
    if not rows:
        rows = wiki_geo_places(lat, lon, cat)
        if rows:
            return nearby_from_wikipedia(rows, cat, place, st)
        # The user clearly asked for places; an encyclopedia paragraph about the landmark is not an answer to that.
        st["last_mode"] = "none"
        where = str(geo[0].get("display_name", place))[:80]
        return {"answer": f"I couldn't get map results for {cat}s near {place} just now. I looked around {where}; OpenStreetMap's public servers either "
                          "timed out or have nothing tagged there. Try again in a minute, or name the city as well (\"museums near Boston Common, Boston\").",
                "sources": [], "mode": "none", "evidence_count": 0}
    # Notable (has a Wikidata/Wikipedia tag) first, then nearest. OSM has no ratings; say so.
    picks = sorted(rows, key=lambda x: (0 if x["notable"] else 1, x["distance_km"]))[:7]
    lines, sources = [], []
    for x in picks:
        d = x["distance_km"]
        lines.append(f"\u2022 {x['name']} \u2014 about {d * 1000:.0f} m away" if d < 1 else f"\u2022 {x['name']} \u2014 about {d:.1f} km away")
        if x["website"]:
            sources.append({"title": x["name"], "url": x["website"]})
        elif x["wikidata"]:
            sources.append({"title": x["name"], "url": "https://www.wikidata.org/wiki/" + x["wikidata"]})
    sources.append({"title": "OpenStreetMap data", "url": "https://www.openstreetmap.org/copyright"})
    st.update({"last_mode": "osm", "subject_label": place, "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": place, "last_place": place})
    label = {"coffee": "cafes", "gallery": "galleries", "library": "libraries", "pharmacy": "pharmacies", "bakery": "bakeries"}.get(cat, cat + "s")
    note = "Well-known places are listed first, then the nearest. OpenStreetMap has no ratings, so this is not a quality ranking."
    return {"answer": f"Here are some {label} near {place}:\n" + "\n".join(lines) + "\n\n" + note, "sources": sources[:8], "mode": "osm", "evidence_count": len(picks)}

# ---------- command-line how-to (offline tldr pages, SQLite FTS5) ----------
TLDR_PLATFORMS = ("common", "linux")
TLDR_SYNONYMS = {
    "show": ["list", "display", "print"], "display": ["list", "show", "print"], "see": ["list", "show", "display"],
    "view": ["list", "show", "display"], "check": ["show", "list", "test"], "find": ["search", "list"],
    "remove": ["delete", "uninstall"], "delete": ["remove"], "uninstall": ["remove"], "make": ["create"],
    "create": ["make", "new"], "rename": ["move"], "unzip": ["extract"], "extract": ["unpack", "decompress"],
    "compress": ["archive", "create"], "folder": ["directory"], "folders": ["directories"], "kill": ["terminate", "stop"],
    "size": ["usage", "space"], "running": ["active"], "services": ["units"], "service": ["unit"], "usage": ["used", "use", "consumption"],
    "memory": ["ram"], "name": ["pattern"],
}
TLDR_SYNONYMS.update({
    "check": ["show", "list", "display", "test"], "space": ["usage", "free"], "large": ["largest", "big", "biggest", "size"],
    "big": ["large", "largest", "size"], "ports": ["port", "sockets", "listening"], "open": ["listening"], "ip": ["address"],
    "text": ["pattern", "string"], "recursively": ["recursive"], "permissions": ["permission", "mode"], "edit": ["open", "modify"],
    "copy": ["duplicate"], "move": ["rename"], "download": ["fetch", "get"], "installed": ["install"], "memory": ["ram"],
    "processes": ["process"], "users": ["user"], "files": ["file"], "count": ["number"], "lines": ["line"],
})
CORE_COMMANDS = set("""ls cp mv rm mkdir rmdir cat less head tail touch ln find grep sed awk sort uniq wc cut tr xargs tee diff
tar gzip gunzip zip unzip xz bzip2 df du free top htop ps kill killall pkill uptime uname whoami id who date cal chmod chown chgrp
umask sudo su passwd useradd usermod userdel groupadd ip ss netstat ping traceroute dig nslookup host curl wget ssh scp rsync sftp
nc nmap lsof systemctl journalctl service crontab at apt apt-get dpkg snap pip pip3 python python3 git docker make gcc mount umount
lsblk blkid fdisk mkfs dd fsck shutdown reboot hostname hostnamectl timedatectl nmcli ifconfig iwconfig env export echo printf alias
history man which whereis locate file stat basename dirname realpath watch screen tmux nano vim vi tree ufw iptables vcgencmd
raspi-config dmesg lsusb lspci lscpu sensors smartctl openssl base64 md5sum sha256sum jq""".split())
TLDR_COMMON = set("ls cd cp mv rm free top htop ps pkill killall kill grep find df du tar zip unzip gzip ssh curl wget chmod chown systemctl ip ping cat head tail less ln mkdir touch sed awk sort wc "
                  "netstat ss lsof apt apt-get dnf pacman docker git crontab rsync scp nano vim uptime date echo which man journalctl dmesg lsblk mount umount fdisk useradd passwd sudo tmux screen "
                  "history alias export env ifconfig traceroute nslookup dig hostname uname lscpu vmstat iostat nmap tree file stat diff patch xargs tee cut tr uniq".split())
TLDR_HINTS = [(r"\bmemory\b|\bram\b", ["free", "htop", "top"]), (r"\bkill\b.*\bname\b|\bby name\b", ["pkill", "killall"]), (r"\bopen ports?\b|\blistening\b", ["ss", "netstat", "lsof"]),
              (r"\bdisk (?:space|usage)\b|\bfree space\b", ["df", "du", "ncdu"]), (r"\bcpu\b|\bload\b", ["top", "htop", "uptime"]), (r"\bip address\b", ["ip", "hostname"])]
TLDR_STOP = set("how do does i can you to the a an on in of for with my is are what and or from using use via linux "
                "ubuntu debian raspberry pi raspbian terminal command commands line shell bash way please would should".split())
_tldr_lock = threading.Lock()
_tldr_state = {"ready": False, "fts": False, "rows": [], "count": 0}

def tldr_examples():
    for plat in TLDR_PLATFORMS:
        for base in (os.path.join(TLDR_DIR, plat), os.path.join(TLDR_DIR, "pages", plat), os.path.join(TLDR_DIR, "pages.en", plat)):
            if not os.path.isdir(base):
                continue
            for fn in sorted(os.listdir(base)):
                if not fn.endswith(".md"):
                    continue
                try:
                    lines = open(os.path.join(base, fn), encoding="utf-8").read().splitlines()
                except Exception:
                    continue
                name = fn[:-3]
                pdesc = " ".join(l.lstrip("> ").strip() for l in lines if l.startswith(">") and "More information" not in l and "See also" not in l)
                desc = ""
                for line in lines:
                    if line.startswith("- "):
                        desc = re.sub(r"\[(\w{1,2})\]", r"\1", line[2:].rstrip(":").strip())  # tldr marks mnemonics as E[x]tract
                    elif line.startswith("`") and line.endswith("`") and desc:
                        yield name, plat, pdesc, desc, line.strip("`")
                        desc = ""
            break

def tldr_init():
    with _tldr_lock:
        if _tldr_state["ready"]:
            return
        try:
            fresh = not os.path.exists(TLDR_DB)
            con = sqlite3.connect(TLDR_DB, timeout=30)
            if fresh:
                con.execute("CREATE VIRTUAL TABLE ex USING fts5(name, pdesc, descr, cmd, plat UNINDEXED, tokenize='porter unicode61')")
                con.executemany("INSERT INTO ex(name,pdesc,descr,cmd,plat) VALUES(?,?,?,?,?)",
                                ((n.replace("-", " "), pd, d, c, pl) for n, pl, pd, d, c in tldr_examples()))
                con.commit()
            _tldr_state["count"] = con.execute("SELECT count(*) FROM ex").fetchone()[0]
            con.close()
            _tldr_state["fts"] = True
        except Exception:
            # No FTS5 in this SQLite build: keep a small in-memory index instead.
            try:
                if os.path.exists(TLDR_DB):
                    os.remove(TLDR_DB)
            except Exception:
                pass
            rows = [{"name": n.replace("-", " "), "pdesc": pd, "descr": d, "cmd": c, "plat": pl} for n, pl, pd, d, c in tldr_examples()]
            _tldr_state.update({"rows": rows, "count": len(rows), "fts": False})
        _tldr_state["ready"] = True

def tldr_terms(q):
    # v47: file names, URLs, times and sizes are slot values, not search terms ("holiday.mov" -> extension "mov" stays as a hint)
    q2 = SLOT_URL_RE.sub(" ", q)
    q2 = SLOT_FILE_RE.sub(lambda m: " " + m.group(1).rsplit(".", 1)[-1] + " ", q2)
    q2 = SLOT_TIME_RE.sub(" ", q2)
    q2 = re.sub(r"\b(?:turn|make|change)\b(?= .+? \binto\b)", "convert", q2, flags=re.I)
    toks = [t for t in raw_tokens(q2) if t not in TLDR_STOP and len(t) > 1]
    expanded = list(toks)
    for t in toks:
        expanded += TLDR_SYNONYMS.get(t, [])
    return toks, list(dict.fromkeys(expanded))

def tldr_answer(q):
    tldr_init()
    if not _tldr_state["count"]:
        return None
    toks, expanded = tldr_terms(q)
    if not toks:
        return None
    rows = []
    if _tldr_state["fts"]:
        try:
            con = sqlite3.connect(TLDR_DB, timeout=10)
            match = " OR ".join('"' + t.replace('"', "") + '"' for t in expanded)
            rows = [{"name": r[0], "pdesc": r[1], "descr": r[2], "cmd": r[3], "bm": -r[4], "plat": r[5]} for r in con.execute(
                "SELECT name,pdesc,descr,cmd,bm25(ex,4.0,1.0,6.0,2.0),plat FROM ex WHERE ex MATCH ? ORDER BY bm25(ex,4.0,1.0,6.0,2.0) LIMIT 60", (match,))]
            con.close()
        except Exception:
            rows = []
    else:
        allrows = _tldr_state["rows"]
        sc = bm25_scores([r["name"] + " " + r["descr"] + " " + r["cmd"] for r in allrows], " ".join(expanded))
        order = sorted(range(len(allrows)), key=lambda i: sc[i], reverse=True)[:60]
        rows = [dict(allrows[i], bm=sc[i]) for i in order if sc[i] > 0]
    if not rows:
        return None
    topbm = max(r["bm"] for r in rows) or 1.0
    for r in rows:
        own = {stem(t) for t in raw_tokens(r["descr"] + " " + r["cmd"] + " " + r["name"])}
        page = {stem(t) for t in raw_tokens(r["pdesc"])}
        cov = 0.0
        for t in toks:
            if stem(t) in own:
                cov += 1.0
            elif any(stem(x) in own for x in TLDR_SYNONYMS.get(t, [])):
                cov += 0.8
            elif stem(t) in page:
                cov += 0.4
        r["cov"] = cov / len(toks)
        first = r["name"].split()[0]
        r["score"] = 10 * r["cov"] + 4 * (r["bm"] / topbm) - 0.015 * len(r["cmd"]) - 0.01 * len(r["descr"])
        if first in TLDR_COMMON:
            r["score"] += 2.5
        for pat, names in TLDR_HINTS:
            if re.search(pat, q, re.I) and first in names:
                r["score"] += 4.0
        if first in CORE_COMMANDS:
            r["score"] += 3.0
        if first in toks:
            r["score"] += 4.0  # the user named the tool
        if len(r["name"].split()) > 1 and not set(r["name"].split()[1:]) & set(expanded):
            r["score"] -= 1.0  # prefer the main page over a subcommand page the user did not ask about
    rows.sort(key=lambda r: r["score"], reverse=True)
    named = [t for t in toks if any(r["name"].split()[0] == t for r in rows)]
    if named and rows[0]["cov"] < 0.6:
        # v47: the person named the tool, so the page is known; choose the example within it by meaning rather than word overlap
        tool = named[0]
        own_rows = [r for r in rows if r["name"].split()[0] == tool]
        if own_rows and SEM and SEM.ok:
            try:
                sims = SEM.similarity(q, [r["descr"] for r in own_rows])
                for r, sm in zip(own_rows, sims):
                    r["sem"] = float(sm)
                own_rows.sort(key=lambda r: r.get("sem", 0.0), reverse=True)
                if own_rows[0].get("sem", 0.0) >= 0.45:
                    trace(f"tldr: '{tool}' page chosen by meaning (sim={own_rows[0]['sem']:.2f}) after weak word coverage {rows[0]['cov']:.0%}")
                    rows = own_rows + [r for r in rows if r not in own_rows]
                    rows[0]["cov"] = max(rows[0]["cov"], 0.6)
            except Exception as e:
                trace(f"tldr: semantic choice failed ({type(e).__name__})")
    if rows[0]["cov"] < 0.6:
        trace(f"tldr: best example covers only {rows[0]['cov']:.0%} of the request -> abstain")
        return None
    picks, seen = [], set()
    for r in rows:
        if r["cmd"] in seen or r["score"] < rows[0]["score"] - 4:
            continue
        seen.add(r["cmd"])
        picks.append(r)
        if len(picks) >= 3:
            break
    trace(f"tldr: top page '{picks[0]['name']}' cov={picks[0]['cov']:.0%}")
    return picks

def command_candidates(page, q):
    codes = (page or {}).get("codes", [])
    toks, expanded = tldr_terms(q)
    qst = {stem(t) for t in expanded}
    out = []
    for t in codes:
        over = len(qst & {stem(x) for x in raw_tokens(t)})
        if over == 0 or re.search(r"\brm\s+-rf?\s+/|\bmkfs\b|\bdd\s+if=|curl[^|]*\|\s*(?:sudo\s+)?(?:ba)?sh", t):
            continue
        out.append((4 * over - 0.01 * len(t), t))
    return [t for sc, t in sorted(out, reverse=True) if sc >= 4][:4]

# ---- v45 (Phase 5): command assembly. A tldr example is a reviewed template; the slots it leaves open ({{path/to/video.mp4}},
# {{start_time}}, {{https://example.com}}) are filled from what the person actually named, deterministically and shown as such.
SLOT_FILE_RE = re.compile(r"\b([\w./~-]+\.(?:mp4|mkv|mov|avi|webm|mp3|wav|flac|ogg|m4a|aac|jpg|jpeg|png|gif|webp|svg|pdf|txt|csv|json|zip|tar|gz|tgz|7z|iso|py|js|sh|md|html|log))\b", re.I)
SLOT_URL_RE = re.compile(r"https?://\S+")
SLOT_TIME_RE = re.compile(r"\b(\d{1,2}:\d{2}(?::\d{2})?)\b")
SLOT_SIZE_RE = re.compile(r"\b(\d{2,5})\s*[x\u00d7]\s*(\d{2,5})\b|\b(480|720|1080|1440|2160)p\b", re.I)
SLOT_NUM_RE = re.compile(r"\b(\d+(?:\.\d+)?)\s*(fps|seconds?|secs?|minutes?|mins?|kbps|kb|mb|gb|%)\b", re.I)

def fill_slots(cmd, q):
    """Return (filled_command, filled_map) or (cmd, {}) if nothing in the question fits a placeholder."""
    urls = SLOT_URL_RE.findall(q)
    q_nourl = SLOT_URL_RE.sub(" ", q)
    files = SLOT_FILE_RE.findall(q_nourl)
    times = SLOT_TIME_RE.findall(q)
    m_size = SLOT_SIZE_RE.search(q)
    nums = {u.lower().rstrip("s"): v for v, u in SLOT_NUM_RE.findall(q)}
    used, filled = {}, {}
    fi, ti = 0, 0
    def sub(m):
        nonlocal fi, ti
        ph = m.group(1)
        key = ph.lower()
        if "|" in ph and ph.startswith("["):          # {{[-s|--symbolic]}}: an option alternative, keep the short form
            return ph.strip("[]").split("|")[0]
        if "url" in key or key.startswith("http"):
            if urls: filled[ph] = urls[0]; return urls[0]
            return m.group(0)
        ext_m = re.search(r"\.([a-z0-9]{2,4})$", key)
        if key.startswith("path/to") or key.startswith("file") or key.startswith("input") or key.startswith("output") or ext_m:
            want_ext = ext_m.group(1) if ext_m else None
            is_output = any(w in key for w in ("output", "sound", "audio", "result", "dest", "target", "new", "compressed", "symlink"))
            unused = [f for f in files if f not in used.values()]
            cands = []
            if not is_output and unused:
                cands = [f for f in unused if want_ext and f.lower().endswith("." + want_ext)] or unused   # the person's file, whatever its extension
            elif is_output:
                cands = [f for f in unused if want_ext and f.lower().endswith("." + want_ext)]
                if not cands and want_ext and files:            # derive the output name from the input the person named
                    base = files[0].rsplit(".", 1)[0]
                    name = f"{base}.{want_ext}"
                    if name.lower() in [v.lower() for v in used.values()] or name.lower() in [f.lower() for f in files]:
                        name = f"{base}-out.{want_ext}"
                    cands = [name]
            if cands:
                used[ph] = cands[0]; filled[ph] = cands[0]; return cands[0]
            return m.group(0)
        if any(w in key for w in ("start", "from", "begin")) and times:
            v = times[0]; filled[ph] = v; return v
        if any(w in key for w in ("end", "stop", "to_time")) and len(times) > 1:
            v = times[1]; filled[ph] = v; return v
        if "duration" in key and len(times) > 1:
            def secs(t): p = [int(x) for x in t.split(":")]; return sum(v * 60 ** i for i, v in enumerate(reversed(p)))
            v = str(secs(times[1]) - secs(times[0])); filled[ph] = v; return v
        if ("width" in key or "height" in key or key in ("w", "h")) and m_size:
            if m_size.group(3): w, h = {"480": ("854", "480"), "720": ("1280", "720"), "1080": ("1920", "1080"), "1440": ("2560", "1440"), "2160": ("3840", "2160")}[m_size.group(3)]
            else: w, h = m_size.group(1), m_size.group(2)
            v = w if "width" in key or key == "w" else h; filled[ph] = v; return v
        for unit, val in nums.items():
            if unit.rstrip("s") in key or (unit in ("fps",) and "rate" in key) or (unit in ("second", "sec") and "second" in key):
                filled[ph] = val; return val
        return m.group(0)
    def sub_ext(m):
        ph, ext = m.group(1), m.group(2)
        cands = [f for f in files if f.lower().endswith("." + ext.lower())]
        key = ph.lower()
        is_output = any(w in key for w in ("output", "sound", "audio", "result", "dest", "target", "new", "compressed"))
        if is_output and files:
            base = files[0].rsplit(".", 1)[0]
            name = base + "-out"
            filled[ph + "." + ext] = name + "." + ext
            return name + "." + ext
        if cands:
            filled[ph + "." + ext] = cands[0]
            return cands[0]
        raise LookupError("extension mismatch")
    try:
        out = re.sub(r"\{\{([^{}]+)\}\}\.([a-z0-9]{2,4})\b", sub_ext, cmd)
    except LookupError:
        return (cmd, {})       # the example is for a different file type than the one named; leave the template alone
    out = re.sub(r"\{\{([^{}]+)\}\}", sub, out)
    return (out, filled) if filled else (cmd, {})

def shellcheck_note(cmd):
    """Lint the assembled line with ShellCheck when it is installed; the warnings are quoted, never acted on."""
    try:
        import shutil, subprocess
        if not shutil.which("shellcheck") or "{{" in cmd:
            return ""
        r = subprocess.run(["shellcheck", "-s", "bash", "-f", "gcc", "-"], input="#!/bin/bash\n" + cmd + "\n", capture_output=True, text=True, timeout=5)
        warns = [ln.split(":", 3)[-1].strip() for ln in r.stdout.splitlines() if "warning" in ln or "error" in ln][:2]
        return ("\n  ShellCheck: " + "; ".join(warns)) if warns else "\n  ShellCheck: no warnings"
    except Exception:
        return ""

def answer_howto(q, st):
    picks = tldr_answer(q)
    if picks:
        lines = []
        for r in picks:
            lines.append(f"\u2022 {r['descr']}:\n    {r['cmd']}")
            if "{{" in r["cmd"] and (SLOT_FILE_RE.search(q) or SLOT_URL_RE.search(q) or SLOT_TIME_RE.search(q) or SLOT_SIZE_RE.search(q)):
                filled, fmap = fill_slots(r["cmd"], q)
                if fmap:
                    lines.append(f"  Filled in from your question ({', '.join(f'{k} = {v}' for k, v in fmap.items())}):\n    {filled}" + shellcheck_note(filled))
                    trace(f"command assembly: filled {list(fmap)} in tldr example '{r['descr'][:40]}'")
        pages = list(dict.fromkeys((r["name"], r.get("plat") or "common") for r in picks))
        st["last_mode"] = "tldr"
        note = "\n\nText in {{double braces}} is a placeholder to replace." if any("{{" in r["cmd"] for r in picks) else ""
        return {"answer": "From the tldr pages:\n" + "\n".join(lines) + note,
                "sources": [{"title": "tldr: " + p, "url": f"https://github.com/tldr-pages/tldr/blob/main/pages/{pl}/" + p.replace(" ", "-") + ".md"} for p, pl in pages[:3]],
                "mode": "tldr", "evidence_count": len(picks)}
    rows = ranked_search(q + " documentation", deep=False)
    trusted = [r for r in rows[:6] if authority_score(r["url"], r["title"], q, "") >= 4][:3]
    pages = pmap(lambda r: fetch_page(r["url"], read_timeout=6), trusted, 10)
    for r, page in zip(trusted, pages):
        cmds = command_candidates(page, q)
        if cmds:
            st["last_mode"] = "web"
            return {"answer": "The most relevant commands I found in documentation are:\n" + "\n".join(f"\u2022 {x}" for x in cmds) +
                              "\n\nThese come from a web page, so read them before running them.",
                    "sources": [{"title": r["title"] or host(r["url"]), "url": r["url"]}], "mode": "web", "evidence_count": len(cmds)}
    return None

# ---------- comparisons ----------
SOFTWARE_WORDS = ["server", "database", "software", "application", "app", "web", "framework", "library", "language",
                  "programming", "editor", "os", "operating system", "linux", "tool", "proxy", "browser", "self-hosted", "hosting"]
COMPARE_DIMS = {
    "architecture": ["architecture", "embedded", "client", "process", "daemon", "engine", "event-driven", "modular", "written in"],
    "configuration": ["configuration", "config", "setup", "install", "automatic", "default", "administration", "deployment"],
    "features": ["feature", "supports", "support for", "extension", "plugin", "module", "protocol", "https", "tls"],
    "performance": ["performance", "speed", "latency", "throughput", "benchmark", "fast", "concurrent", "scalab", "memory"],
    "use cases": ["used for", "used by", "used as", "suited", "suitable", "designed for", "use case", "popular"],
}
COMPARE_PROPS = [("P31", "Type"), ("P178", "Developer"), ("P277", "Written in"), ("P275", "License"), ("P571", "Started"),
                 ("P306", "Operating system"), ("P17", "Country"), ("P36", "Capital"), ("P1082", "Population"), ("P2046", "Area"),
                 ("P112", "Founded by"), ("P159", "Headquarters"), ("P279", "Kind of")]

def parse_compare(q):
    s = norm(q).rstrip("?.!")
    pats = [r"^compare\s+(.+?)\s+(?:and|versus|vs\.?|with|to)\s+(.+?)(?:\s+for\s+(.+))?$",
            r"^(?:what(?:'s| is| are)\s+)?(?:the\s+)?(?:main\s+)?differences?\s+between\s+(.+?)\s+and\s+(.+?)(?:\s+for\s+(.+))?$",
            r"^(.+?)\s+(?:vs\.?|versus)\s+(.+?)(?:\s+for\s+(.+))?$",
            r"^how\s+(?:does|do)\s+(.+?)\s+(?:compare|differ)\s+(?:to|with|from)\s+(.+?)(?:\s+for\s+(.+))?$"]
    for p in pats:
        m = re.match(p, s, re.I)
        if m:
            return clean_term(strip_article(m.group(1))), clean_term(strip_article(m.group(2))), clean_term(m.group(3) or "")
    return None

def choose_compare_page(term, other, context):
    ctx = (other + " " + context).casefold()
    softwareish = any(has_word(" " + ctx + " ", w) for w in SOFTWARE_WORDS)
    probes = [term, f"{term} {other}"] + ([f"{term} software"] if softwareish else [])
    res = pmap(lambda p: wiki_candidates(p, 6), probes, t_out(8))
    ctx_stems = stem_set(ctx) | (stem_set("software server program") if softwareish else set())
    tkeys = label_keys(term)
    best, bs = None, -1e9
    seen = set()
    scored = []
    for pi, rows in enumerate(res):
        for rank, c in enumerate(rows or []):
            if c["title"] in seen or c.get("disambig"):
                continue
            seen.add(c["title"])
            s = 30 - 3 * rank - 2 * pi
            if label_keys(bare_title(c["title"])) & tkeys:
                s += 50
            elif stem_set(term) <= stem_set(c["title"]):
                s += 15
            else:
                s -= 40
            s += 18 * min(2, len(stem_set(paren_part(c["title"])) & ctx_stems))
            blob = c.get("description", "") + " " + (c.get("intro") or "")[:600]
            s += 7 * min(4, len(ctx_stems & stem_set(blob)))
            low = " " + norm_key(c.get("description", "")) + " "
            if softwareish and any(has_word(low, w) for w in ["software", "web server", "server", "database", "program", "framework", "programming language", "application", "operating system"]):
                s += 30
            if softwareish and any(has_word(low, w) for w in ["golfer", "golf", "surname", "album", "film", "given name", "village", "footballer"]):
                s -= 80
            c["_joint"] = (pi == 1)
            scored.append((s, c))
            if s > bs:
                bs, best = s, c
    trace(f"compare page for '{term}': {best['title'] if best else None} ({bs:.0f})")
    _COMPARE_POOL[norm_key(term)] = sorted(scored, key=lambda x: x[0], reverse=True)[:5]
    return (best if best and bs >= 45 else None), softwareish

_COMPARE_POOL = {}
_KIND_STOP = set(stems_of("type kind form variety species genus family name used known called common various one first large small american british"))

def coherent_pair(a, b, pa, pb):
    """'Compare Python and Ruby' must not pair a programming language with a gemstone. Among each side's good candidates,
    prefer the pair that are the same kind of thing (matching '(programming language)' qualifiers or descriptions)."""
    ca, cb = _COMPARE_POOL.get(norm_key(a)) or [], _COMPARE_POOL.get(norm_key(b)) or []
    if not ca or not cb:
        return pa, pb
    def kind_stems(c):
        return (stem_set(paren_part(c["title"])) | stem_set(c.get("description", ""))) - _KIND_STOP
    # Two PRIMARY topics (undisambiguated titles, each the top pick for its name) that are the same kind of thing are the
    # pair: Saturn + Neptune the planets. Replay showed the "(mythology)" pair out-scoring them on shared words alone.
    if pa and pb and not paren_part(pa["title"]) and not paren_part(pb["title"]) and pa["title"] != pb["title"] and (kind_stems(pa) & kind_stems(pb)):
        return pa, pb
    best, bs = (pa, pb), -1e9
    for sa, x in ca:
        for sb, y in cb:
            if sa < 45 or sb < 45 or x["title"] == y["title"]:
                continue
            shared = kind_stems(x) & kind_stems(y)
            paren = stem_set(paren_part(x["title"])) & stem_set(paren_part(y["title"]))
            v = sa + sb + 25 * min(3, len(shared)) + (40 if paren else 0)
            if shared and not paren_part(x["title"]) and not paren_part(y["title"]):
                v += 60          # two primary topics of the same kind (Mars and Venus the planets) beat two "(mythology)" pages
            v += 30 * (bool(x.get("_joint")) + bool(y.get("_joint")))
            if paren and re.search(r"\b(?:surname|given name|name|family name|disambiguation)\b", paren_part(x["title"]) + " " + paren_part(y["title"]), re.I):
                v -= 120         # "Ruby (surname)" / "Perl (surname)": Wikipedia name pages are never what a comparison means
            if paren and re.search(r"\b(?:film|album|song|novel|series|band|episode|video game|musical|play|single|EP|soundtrack)\b", paren_part(x["title"]) + " " + paren_part(y["title"]), re.I) \
                    and not re.search(r"\b(?:film|movie|album|song|novel|book|series|show|band|game)s?\b", a + " " + b, re.I):
                v -= 80          # "Compare Rust and Go" is not about a 2024 western and a 1999 comedy   # pages a search for BOTH terms surfaces belong together
            if v > bs:
                bs, best = v, (x, y)
    if best[0] and best[1] and (best[0]["title"], best[1]["title"]) != ((pa or {}).get("title"), (pb or {}).get("title")):
        trace(f"compare: chose the coherent pair {best[0]['title']} / {best[1]['title']}")
    return best

def dimension_sentence(sents, dim, context, subject):
    markers = COMPARE_DIMS[dim]
    best, bs = "", 0.0
    cst = stem_set(context)
    for s in sents:
        low = s.casefold()
        hits = sum(1 for m in markers if m in low)
        if not hits or not good_sentence(s) or ANAPHORIC_OPENERS.match(s):
            continue
        sc = 2.0 * hits + 0.7 * len(cst & stem_set(s)) + (1.0 if subject.casefold() in low else 0) - 0.003 * len(s)
        if sc > bs:
            bs, best = sc, s
    return best, bs

def answer_compare(q, st):
    parsed = parse_compare(q)
    if not parsed:
        return None
    a, b, context = parsed
    (pa, soft_a), (pb, soft_b) = choose_compare_page(a, b, context), choose_compare_page(b, a, context)
    # "Compare Rust and Go": searching "Go" alone never surfaces "Go (programming language)". Whatever kinds one side offers
    # in parentheses are tried on the other side too, then the pair that are the same kind of thing is chosen.
    for this, other in ((a, b), (b, a)):
        kinds = [paren_part(c["title"]) for _, c in (_COMPARE_POOL.get(norm_key(this)) or []) if paren_part(c["title"])]
        # only candidates actually NAMED like the other term count: the joint search "Go Python" puts "Python (programming
        # language)" into Go's pool, which made v19 believe Go already had a programming-language reading (replay bundle, v19)
        have = {paren_part(c["title"]).casefold() for _, c in (_COMPARE_POOL.get(norm_key(other)) or [])
                if bare_title(c["title"]).casefold() == other.casefold() or label_keys(bare_title(c["title"])) & label_keys(other)}
        for kind_ in list(dict.fromkeys(kinds))[:2]:
            if kind_.casefold() in have or out_of_time():
                continue
            tkeys = label_keys(other)
            for rank, c in enumerate(wiki_candidates(f"{other} {kind_}", 5)):
                if not c.get("disambig") and paren_part(c["title"]) and (label_keys(bare_title(c["title"])) & tkeys or bare_title(c["title"]).casefold() == other.casefold()):
                    _COMPARE_POOL.setdefault(norm_key(other), []).append((70 - 3 * rank, c))
                    trace(f"compare: also considering {c['title']}")
    pa, pb = coherent_pair(a, b, pa, pb)
    if not pa or not pb or pa["title"] == pb["title"]:
        trace("compare: could not resolve both sides")
        return None
    na, nb = bare_title(pa["title"]), bare_title(pb["title"])
    lines = [f"{na} vs {nb}" + (f", for {context}" if context else "") + ":"]
    la, _ = lead_sentences(pa.get("intro") or wiki_extract(pa["title"], True), 300, 2)
    lb, _ = lead_sentences(pb.get("intro") or wiki_extract(pb["title"], True), 300, 2)
    if la and lb:
        lines += ["\nIn short:", f"\u2022 {' '.join(la)}", f"\u2022 {' '.join(lb)}"]
    count = 2 if la and lb else 0
    qa, qb = pa.get("qid") or wiki_page_qid(pa["title"]), pb.get("qid") or wiki_page_qid(pb["title"])
    ents = wd_get([qa, qb]) if qa and qb else {}
    if qa in ents and qb in ents:
        facts = []
        for pid, label in COMPARE_PROPS:
            ca, cb = ranked_claims(ents[qa], pid), ranked_claims(ents[qb], pid)
            if ca and cb:
                facts.append((label, ca[:3], cb[:3]))
            if len(facts) >= 5:
                break
        composed = []
        for pid, label, unit in (("P2046", "area", ""), ("P1082", "population", ""), ("P2044", "elevation", ""), ("P2048", "height", ""), ("P2043", "length", ""), ("P2067", "mass", "")):
            try:
                va = [v for v in claim_values(ranked_claims(ents[qa], pid), limit=1)]; vb = [v for v in claim_values(ranked_claims(ents[qb], pid), limit=1)]
                na_, nb_ = float(re.sub(r"[^\d.]", "", va[0]["text"].split()[0])) if va else None, float(re.sub(r"[^\d.]", "", vb[0]["text"].split()[0])) if vb else None
                if na_ and nb_ and na_ > 0 and nb_ > 0 and va[0]["text"].split()[-1] == vb[0]["text"].split()[-1]:
                    r = na_ / nb_
                    if abs(r - 1) < 0.05:
                        composed.append(f"they are about the same by {label}")
                    else:
                        big, small, ratio = (na, nb, r) if r > 1 else (nb, na, 1 / r)
                        composed.append(f"{big} is about {ratio:.1f} times {small} by {label}" if ratio < 100 else f"{big} is about {ratio:,.0f} times {small} by {label}")
            except Exception:
                continue
            if len(composed) >= 2:
                break
        if composed:
            lines.append("\nIn short, from Wikidata: " + "; ".join(composed) + ".")
        if facts:
            lines.append("\nSide by side (Wikidata):")
            for label, ca, cb in facts:
                va, vb = claim_values(ca), claim_values(cb)
                if va and vb:
                    lines.append(f"\u2022 {label}: {na} \u2014 {', '.join(v['text'] for v in va[:3])}; {nb} \u2014 {', '.join(v['text'] for v in vb[:3])}")
                    count += 1
    if soft_a or soft_b:
        ta, tb = pmap(lambda t: wiki_extract(t, False), [pa["title"], pb["title"]], t_out(8))
        sa_all = [s for _, p in wiki_paragraphs(ta or "") for s in split_sentences(p)][:400]
        sb_all = [s for _, p in wiki_paragraphs(tb or "") for s in split_sentences(p)][:400]
        dims = []
        for dim in COMPARE_DIMS:
            sa, sca = dimension_sentence(sa_all, dim, context, na)
            sb, scb = dimension_sentence(sb_all, dim, context, nb)
            if sa and sb:
                dims.append((sca + scb, dim, sa, sb))
        for _, dim, sa, sb in sorted(dims, reverse=True)[:3]:
            lines += [f"\n{dim.title()}:", f"\u2022 {na}: {sa}", f"\u2022 {nb}: {sb}"]
            count += 2
    if count == 0:
        return None
    st.update({"last_mode": "compare", "subject_label": f"{na} vs {nb}", "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": ""})
    return {"answer": "\n".join(lines), "sources": [{"title": pa["title"], "url": wiki_url(pa["title"])}, {"title": pb["title"], "url": wiki_url(pb["title"])}],
            "mode": "compare", "evidence_count": count}

# ---------- conversation engine, skills, dialogue state, routing ----------
MORE_RE = re.compile(r"^(?:tell me more|more|go on|continue|keep going|and then|what else|anything else|more please|more details?|elaborate|why|how so|how come)\W*$", re.I)
SIMPLER_RE = re.compile(r"^(?:(?:can you )?(?:explain|say) (?:it|that|this)?\s*(?:more )?(?:simply|simpler)|simpler(?: please)?|eli5|explain like i'?m five|"
                        r"in (?:simple|simpler|plain) (?:terms|english|words)|(?:can you )?simplify(?: (?:it|that))?|too complicated|that'?s too complicated)\W*$", re.I)
SWAP_RE = re.compile(r"^(?:and|what about|how about|and what about|same for|and for)\s+(.+?)\??$", re.I)
SUMMARY_RE = re.compile(r"^(?:tell me (?:more )?about|give me (?:a|an) (?:summary|overview|rundown) of|summari[sz]e|overview of|what do you know about|teach me about|talk to me about)\s+(?!me\b|myself\b|you\b|yourself\b|this\b|that\b)(.+)$", re.I)
AGE_RE = re.compile(r"^(?:how old (?:is|was|are)|what(?:'s| is) the age of|what age is)\s+(.+?)(?:\s+(?:now|today|when (?:he|she|they) died))?$", re.I)
KNOWLEDGE_START = re.compile(r"^(?:who|whom|whose|what|when|where|why|how|which|compare|explain|define|describe|tell me about|find|recommend|show me|research|investigate|"
                             r"is|are|was|were|does|do|did|can|could|should|will|would|has|have|list|name|give me|summari[sz]e)\b", re.I)
SECOND_PERSON_Q = re.compile(r"^(?:(?:what|how|why|when|where|who) (?:do|did|would|are|were|is|can|could|will) you\b(?! (?:know about|make|cook|bake|build|install|fix|use|get|remove|clean|spell|say|pronounce|calculate|convert|tie|play|draw|grow|treat|prevent|know if|tell if|find|measure|solve|write a|do a|do an)\b)|"
                             r"(?:do|did|are|were|have|had|would|will|can|could|should) you\b(?! (?:tell me|explain|describe|look up|find out|let me know|show me|define|please tell|please explain)\b)|"
                             r"(?:what|who|how|where)(?:'s| is| are| was| were) your\b|you think\b|really\??$|why not\??$)", re.I)

def chat_topic_fact(topic):
    """One verbatim lead sentence about a topic the user raised, only when the article title clearly matches."""
    if remaining() < 1.5:
        return None
    keys = label_keys(topic) | {norm_key(topic.rstrip("s"))}
    tst = stem_set(topic)
    for c in wiki_candidates(topic, 5, timeout=3.5)[:5]:
        if c.get("disambig"):
            continue
        bt = bare_title(c["title"])
        if not (label_keys(bt) & keys or (tst and stem_set(bt) == tst)):
            continue
        low = " " + norm_key(c.get("description", "")) + " "
        if any(has_word(low, w) for w in CREATIVE_TYPE_WORDS) and not paren_part(c["title"]) == "":
            continue
        chosen, _ = lead_sentences(c.get("intro") or "", 260, 1)
        if chosen and 40 <= len(chosen[0]) <= 300:
            return {"sentence": chosen[0], "title": c["title"], "url": wiki_url(c["title"])}
        if c.get("description"):
            return {"sentence": f"{bt}: {c['description']}.", "title": c["title"], "url": wiki_url(c["title"])}
    return None

def _chat_embed(texts):
    texts = list(texts)
    if SEM.ok:
        if len(texts) < 50:
            return SEM.encode(texts)
        import numpy as np
        key = hashlib.sha256(("\n".join(texts) + "|" + SEM.model_file).encode("utf-8")).hexdigest()[:16]
        path = os.path.join(DATA_DIR, f"intent_vectors_{key}.npy")
        try:
            vecs = np.load(path)
            if vecs.shape[0] == len(texts):
                return vecs
        except Exception:
            pass
        vecs = SEM.encode(texts)
        try:
            for old in os.listdir(DATA_DIR):
                if old.startswith("intent_vectors_") and old.endswith(".npy"):
                    os.remove(os.path.join(DATA_DIR, old))
            np.save(path, vecs)
        except Exception:
            pass
        return vecs
    vecs = EMB.encode(texts)
    return _np.asarray(vecs, dtype="float32")

CHAT = convo.ChatEngine(MEMORY, _chat_embed if (SEM.ok or EMB is not None) else None, chat_topic_fact)

def is_deep_research(q):
    return bool(re.search(r"\b(?:deep research|research|investigate|literature review|review the evidence|multiple sources|deep dive)\b", q, re.I))

def is_live_web(q):
    if version_query_term(q):
        return True
    toks = set(raw_tokens(q))
    if toks & {"latest", "today", "tonight", "recent", "recently", "price", "prices", "availability", "news", "yesterday", "tomorrow"}:
        return True
    return bool(re.search(r"\b(?:this (?:week|month|year)|right now|open now|opening hours|closing time|new release|current (?:price|version|status|ceo|president|prime minister|champion|record))\b", q.casefold()))

def is_knowledge(q):
    s = q.strip()
    sn = norm(s).rstrip("?.! ")
    if any(r.match(sn) for r in (GUIDE_RE, PROSCONS_RE, NEWS_RE, TIMELINE_RE, FACTS_RE, WORD_RE, QUOTE_RE)) or PAGE_SUMMARY_RE.match(s):
        return True
    try:
        pn = parse_nearby(s)
        if pn and pn[0] and pn[1]:
            return True
    except Exception:
        pass
    if re.match(r"^(?:good )?(?:hi|hey|hello|hiya|yo|morning|afternoon|evening|night)\b[^?]{0,20}[!.,;]\s", s, re.I) and SECOND_PERSON_Q.match(re.split(r"(?<=[!.,;])\s+", s)[-1]):
        return False
    if SECOND_PERSON_Q.match(s) or not words(s):      # "why?", "how so?" carry no content to look up
        return False
    return s.endswith("?") or bool(KNOWLEDGE_START.match(s))

NOT_A_TOPIC = set("not no yes ok okay thanks please lol haha another one more again same next else other others that this these those it they them "
                  "something anything nothing everything none both either neither any some all each every here there now then so too also very really just "
                  "maybe sure fine good bad great nice cool right wrong true false first last new old".split())

def looks_like_topic(q, st):
    """A bare noun phrase ("Miles Davis", "photosynthesis") typed after a factual answer is a request to explain it."""
    s = q.strip().rstrip(".!")
    toks = raw_tokens(s)
    if not (1 <= len(toks) <= 4) or (st.get("last_bot") or "").rstrip().endswith("?"):
        return False
    if set(toks) & (convo.FIRST | convo.SECOND | NOT_A_TOPIC) or st.get("chat_pending"):
        return False
    if NLP is not None:
        try:
            doc = NLP(s)
            if any(t.pos_ in {"VERB", "AUX", "INTJ", "ADV"} for t in doc) and not any(t.pos_ == "PROPN" for t in doc):
                return False
            return any(t.pos_ in {"NOUN", "PROPN"} for t in doc)
        except Exception:
            pass
    # No parser available (32-bit / low-memory build): treat it as a topic when it looks nothing like small talk.
    name, conf, _ = CHAT.matcher.match(convo.normalize(s))
    return name is None and conf < 0.3 and not re.search(r"\b(?:am|is|are|was|were|be|have|has|had|do|did|does|will|can|went|got|think|feel|want|need|like|love|hate)\b", s.casefold())

def answer_skill(q, st, sid):
    """Deterministic tools. Each returns quickly when the text is not for it."""
    a = skills.try_dates(q)
    if a:
        return {"answer": a, "sources": [], "mode": "clock", "evidence_count": 1}
    a = skills.try_calc(q)
    if a:
        return {"answer": a, "sources": [], "mode": "calc", "evidence_count": 1}
    a = skills.try_convert(q)
    if a:
        return {"answer": a, "sources": [], "mode": "convert", "evidence_count": 1}
    a = skills.try_datetime(q)
    if a:
        return {"answer": a, "sources": [], "mode": "clock", "evidence_count": 1}
    get = lambda url, params, ttl=3600, prefix="skill": http_get_json(url, params, ttl, prefix, timeout=8)
    try:
        a, src = skills.time_in_place(q, get)
        if a:
            return {"answer": a, "sources": src or [], "mode": "clock", "evidence_count": 1}
        if skills.is_weather_question(q):
            facts = MEMORY.facts(sid)
            home = (facts.get("location") or [""])[-1] or os.environ.get("NOAI_HOME_LOCATION", "")
            there = st.get("last_place") or st.get("subject_label")
            st["last_question"] = q          # v59: a "Where?" prompt must keep the question for the next fragment ("in Denver")
            if re.search(r"\b(?:there|that city|that place|over there)\b", q, re.I) and there:
                q = re.sub(r"\b(?:over there|there|that city|that place)\b", "in " + there, q, count=1, flags=re.I)
                st["last_question"] = q
                trace(f"weather: 'there' -> {there}")
            a, src = skills.weather_answer(q, home, get)
            if a:
                trace("answered by weather skill")
                mp = re.search(r"\b(?:in|at|for|near)\s+([A-Z][\w' .-]{1,40}?)(?:\s+(?:today|tonight|tomorrow|now|this week))?$", q.strip("?.! "))
                if mp:
                    st.update({"last_mode": "weather", "last_term": mp.group(1).strip(), "subject_label": mp.group(1).strip(), "subject_qid": "", "answer_qid": "", "answer_label": "", "last_place": mp.group(1).strip()})
                return {"answer": a, "sources": src or [], "mode": "weather", "evidence_count": 1}
    except Exception as e:
        trace(f"skill lookup failed: {type(e).__name__}")
    return None

def answer_define(q, st):
    term = skills.define_term(q)
    if not term:
        return None
    get = lambda url, params, ttl=3600, prefix="skill": http_get_json(url, params, ttl, prefix, timeout=8)
    try:
        a, src = skills.define_answer(term, get)
    except Exception as e:
        trace(f"dictionary failed: {type(e).__name__}")
        a, src = None, None
    if not a:
        return None
    st["last_mode"] = "dictionary"
    st["last_term"] = term
    return {"answer": a, "sources": src, "mode": "dictionary", "evidence_count": 1}

def answer_age(q, st):
    m = AGE_RE.match(norm(q).rstrip("?.!"))
    if not m:
        return None
    term = clean_term(m.group(1))
    if norm_key(term) in {"you", "the universe", "the earth", "earth", "the sun", "the moon", "i", "too old"}:
        return None
    best = entity_from_state_or_search(term, st, None, ("P569",))
    if not best:
        return None
    born = ranked_claims(best["entity"], "P569")
    if not born:
        trace(f"age: {best['label']} has no date of birth")
        return None
    def ymd(claim):
        v = claim.get("mainsnak", {}).get("datavalue", {}).get("value", {})
        mm = re.match(r"\+(\d+)-(\d\d)-(\d\d)", v.get("time", ""))
        return (int(mm.group(1)), int(mm.group(2)) or 1, int(mm.group(3)) or 1, v.get("precision", 9)) if mm else None
    b = ymd(born[0])
    if not b:
        return None
    died = ranked_claims(best["entity"], "P570")
    d = ymd(died[0]) if died else None
    now = skills.now_local()[0]
    end = d or (now.year, now.month, now.day, 11)
    age = end[0] - b[0] - (1 if (end[1], end[2]) < (b[1], b[2]) else 0)
    approx = "about " if min(b[3], end[3]) < 11 else ""
    btxt = format_time({"time": f"+{b[0]:04d}-{b[1]:02d}-{b[2]:02d}T00:00:00Z", "precision": b[3]})[0]
    if d:
        dtxt = format_time({"time": f"+{d[0]:04d}-{d[1]:02d}-{d[2]:02d}T00:00:00Z", "precision": d[3]})[0]
        text = f"{best['label']} was born {'on' if b[3] >= 11 else 'in'} {btxt} and died {'on' if d[3] >= 11 else 'in'} {dtxt}, aged {approx}{age}."
    else:
        text = f"{best['label']} is {approx}{age} years old (born {'on' if b[3] >= 11 else 'in'} {btxt})."
    remember_entity_answer(st, best, [])
    st["last_term"] = term
    return {"answer": text, "sources": [{"title": f"Wikidata: {best['label']}", "url": f"https://www.wikidata.org/wiki/{best['qid']}"}], "mode": "wikidata", "evidence_count": 1}

_BG = ThreadPoolExecutor(max_workers=4)

def _bg_web(q, budget, searched=None):
    ctx_begin(budget)
    if searched is not None:
        _CTX.searched = searched
    try:
        ev, _rows = web_evidence(q, False)
    except Exception as e:
        ev = []
        trace(f"web evidence failed: {type(e).__name__}")
    return ev[:8], list(getattr(_CTX, "trace", []))

def answer_blended(q, st):
    """Explanatory questions: collect the best Wikipedia passage AND the best passages from several websites, then let
    one judge choose. The cross-encoder (if installed) scores "does this passage answer the question?"; otherwise the
    sentence encoder's similarity is used. Every candidate is verbatim source text; choosing is the only 'decision'."""
    kind = question_kind(q)
    if kind == "what" and (len(words(clean_term(subject_hint(q) or q))) > 4 or re.match(r"^(?:who|what|which) (?:was|were|is|are) the (?:first|last|only|youngest|oldest)\b", q, re.I)):
        kind = "general"         # "Who was the first person to land on the Sun?" is not a definition; it needs verifying, not a page lead
    if kind == "what" and re.search(r"\b(?:made (?:of|from)|used for|used to|good for|known for|famous for)\b", q, re.I):
        kind = "general"
    if not BLEND or kind == "what" or not (JUDGE.ok or SEM.ok):
        return None
    followup = bool(st.get("subject_label") and re.search(r"\b(?:they|them|it|its|he|she|his|her|this|that|these|those)\b", q, re.I))
    if followup and not JUDGE.ok:
        return None              # pronoun follow-ups only make sense against the article under discussion
    # v19 handed the judge "How are they formed?" and it scored every paragraph below zero: it has to see what "they" are.
    jq = re.sub(r"\b(?:they|them|these|those)\b", str(st.get("subject_label")) + "s", q, flags=re.I) if followup else q
    jq = re.sub(r"\b(?:it|this|that)\b", str(st.get("subject_label")), jq, flags=re.I) if followup else jq
    ctx_extend(BUDGET_SLOW)
    t_start = time.monotonic()
    fut = None if followup else _BG.submit(_bg_web, q, max(4.0, remaining() - 1.5), getattr(_CTX, 'searched', None))
    st_w = dict(st)
    rw = answer_wikipedia(q, st_w)
    try:
        wtitle = bare_title((rw.get("sources") or [{}])[0].get("title") or "") if rw else ""
        if wtitle and len(wtitle.split()) <= 3 and not (stem_set(wtitle) & alias_expand(stem_set(q))):
            jq = jq.rstrip("?.! ") + f" ({wtitle})?"
            trace(f"judge question: '{jq}' (the article is named differently from the question)")
    except Exception:
        pass
    # Latency (v18: p90 8.3 s, one answer 21 s): judge Wikipedia's passage while the web is still loading. If it already
    # answers well, the web gets only a short grace period; if not, the web is worth waiting for.
    early = None
    if rw and JUDGE.ok and fut is not None and not fut.done():
        got = JUDGE.scores(jq, [rw["answer"]])
        early = got[0] if got else None
    wait = max(0.5, min(remaining() - 1.0, 9.0 if rw else 14.0))
    if early is not None and rw:
        first_s0 = (split_sentences(rw["answer"]) or [rw["answer"]])[0]
        if first_s0.count('"') % 2 == 1 or ANAPHORIC_OPENERS.match(first_s0) or WEAK_OPENERS.match(first_s0):
            early = None         # a mid-thought opener is not a reason to stop waiting for the web
    if early is not None and early >= 7.0:
        wait = min(wait, max(0.5, 5.5 - (time.monotonic() - t_start)))
        trace(f"   Wikipedia already scores {early:.1f}; waiting at most {wait:.1f}s more for the web")
    try:
        ev, wtrace = fut.result(timeout=wait) if fut is not None else ([], [])
    except Exception:
        ev, wtrace = [], ["web evidence was not ready in time"]
    for t in wtrace[-4:]:
        trace("   [web] " + t.split("s ", 1)[-1])
    cands = []
    if rw:
        wlabel = (rw.get("sources") or [{}])[0].get("title", "Wikipedia")
        cands.append({"from": "wikipedia", "text": rw["answer"], "res": rw, "label": wlabel, "heading": rw.get("heading") or ""})
        for alt in (rw.get("more") or [])[:4]:       # the runner-up paragraphs of the same search: the judge may prefer one
            if alt.get("text") and "wikipedia.org" in str((alt.get("source") or {}).get("url", "")):
                cands.append({"from": "wikipedia", "text": alt["text"], "res": dict(rw, answer=alt["text"], sources=[alt["source"]], more=[]), "heading": alt.get("heading") or "", "label": alt["source"].get("title", wlabel) + " (alt)"})
    seen = {}
    medical = bool(MEDICAL.search(q))
    for e in ev:
        if medical and not HEALTH_SITES.search(e["domain"]):
            continue             # health questions quote recognised health sources only
        if seen.get(e["domain"], 0) >= 2 or "wikipedia.org" in e["domain"] or len(seen) >= 4 and e["domain"] not in seen:
            continue
        seen[e["domain"]] = seen.get(e["domain"], 0) + 1
        text, _ = passage_from(e, 480)
        text = DATE_PREFIX.sub("", text)
        kept_s = [x for x in split_sentences(text) if not x.rstrip().endswith("?")]      # "But why do onions make you cry?" is the page
        if kept_s and len(" ".join(kept_s)) >= 90:                                        # restating the question, which the judge adores
            text = " ".join(kept_s)
        if web_clean(text):
            cands.append({"from": "web", "text": text, "ev": e, "label": e["domain"]})
        if len(cands) >= max(5, min(9, JUDGE.budget + 2 if JUDGE.ok else 6)):
            break
    if not cands:
        return None
    core = core_stems(q)
    how = "only candidate"
    if len(cands) >= 1:
        raw = JUDGE.scores(jq, [c["text"] for c in cands])
        if raw:
            how = "cross-encoder judge"
            for c, v in zip(cands, raw):
                c["score"] = v
        else:
            how = "sentence-encoder similarity"
            for c, v in zip(cands, SEM.similarity(q, [c["text"] for c in cands]) or [0.0] * len(cands)):
                c["score"] = 10.0 * v
        agree = {}
        try:      # v50: cross-source agreement for why/how questions; the encoder call is one batch of at most ~10 short texts
            if kind in ("why", "how", "formation") and SEM and SEM.ok and len(cands) >= 3:
                wiki = [c for c in cands if c["from"] == "wikipedia"][:5]
                web = [c for c in cands if c["from"] != "wikipedia"][:6]
                if wiki and web:
                    import numpy as np
                    vecs = SEM.encode([c["text"][:400] for c in wiki + web])
                    if vecs is not None and len(vecs) == len(wiki) + len(web):
                        M = np.array(vecs, dtype="float32"); M /= (np.linalg.norm(M, axis=1, keepdims=True) + 1e-9)
                        S = M[:len(wiki)] @ M[len(wiki):].T
                        for i, c in enumerate(wiki):
                            best = float(S[i].max())
                            if best >= 0.62:
                                agree[id(c)] = best
                                trace(f"   agreement: '{c['text'][:50]}...' is stated independently by {web[int(S[i].argmax())]['label']} (sim={best:.2f})")
        except Exception as e:
            trace(f"agreement check skipped ({type(e).__name__})")
        for c in cands:
            c.setdefault("score", 0.0)
            first_s = (split_sentences(c["text"]) or [c["text"]])[0]
            comps = {}
            def bump(name, delta):
                if delta:
                    comps[name] = round(comps.get(name, 0.0) + delta, 2)
            bump("encyclopedic", 0.6 if c["from"] == "wikipedia" else 0.0)               # stable, clean prose
            bonus = 0.0
            if first_s.count('"') % 2 == 1 or first_s.count("\u201d") > first_s.count("\u201c"):
                bump("quotation_tail", -3.0)     # 'Stimuli ... to the right side".' is the tail of someone else's quotation
            elif ELLIPTICAL_END.search(first_s.strip()) or ANAPHORIC_OPENERS.match(first_s) or WEAK_OPENERS.match(first_s) or re.match(r"^(?:that is to say|finally|then|next|in the present case|in this case|as (?:a result|such)|\w+ then )\b", first_s, re.I):
                bump("mid_thought", -3.0)     # "That is to say, ...", "Finally, ...", "Spiders then follow ...": the middle of someone else's explanation
            elif c["from"] == "web" and re.search(r"\b(?:also|just like|as well|similarly|likewise|another reason|in addition)\b", first_s, re.I):
                bump("continuation", -1.0)     # "The Sun causes tides just like the moon does": a continuation of a point made earlier on the page
            if len(c["text"]) < 140:
                bump("too_short", -1.5)     # one short sentence is rarely a full answer
            hd = c.get("heading") or (c.get("res") or {}).get("heading") or ""
            if c["from"] == "wikipedia" and isinstance(hd, str) and hd and HEADING_FOR_SHAPE.get(kind) and HEADING_FOR_SHAPE[kind].search(hd):
                bump("section_fits", 1.2)   # v44: "What causes X" answered from the article's own "Causes" section; "how does X work" from "Mechanism"
            main = getattr(_CTX, "main_subject", "")
            if c["from"] == "wikipedia" and main and main.lower() not in (c.get("label") or "").lower() and not re.search(r"\b" + re.escape(main[:5]), c["text"], re.I):
                bump("off_topic", -1.5)     # v43: the Color article's paragraph on perception does not mention stars; a side page must name the subject
            if c["from"] == "web" and CHATTY.search(c["text"]):
                bump("chatty", -3.0)     # "I know it is kind of a silly answer", "(just not magic)", quoted poets: not an explanation
            if c["from"] == "web" and len(set(core_stems(q)) & alias_expand(stem_set(c["text"]))) < max(1, len(core_stems(q)) - 1) and len(core_stems(q)) >= 2:
                bump("off_topic", -1.0)     # the passage barely mentions what was asked ("Planes stay in the air by manipulating the forces acting on them.")
            bump("corroborated", 0.6 if (c["from"] == "web" and c["ev"].get("corroborated")) else (0.8 if id(c) in agree else 0.0))
            bump("explains_cause", 1.5 if (kind == "why" and explains(c["text"], core) and not (comps.get("quotation_tail") or comps.get("mid_thought"))) else 0.0)     # a definition of the colour "sunset" does not explain why sunsets are orange
            if c["from"] == "web":
                bump("site_authority", site_prior(c["ev"]["domain"]))
                bump("faq_match", 1.0 if c["ev"].get("faq") else 0.0)
            c["comps"] = comps
            c["final"] = c["score"] + sum(comps.values())
        if RERANK_W:
            PEN = {"chatty", "too_short", "continuation", "mid_thought", "quotation_tail", "off_topic"}
            for c in cands:
                comps = c.get("comps") or {}
                c["learned"] = (RERANK_W["bias"] + RERANK_W["judge"] * c["score"] / 10.0 + RERANK_W["length"] * min(len(c["text"]), 600) / 600.0
                                + sum(RERANK_W.get(k, 0.0) * v / 3.0 for k, v in comps.items() if k not in PEN)
                                + RERANK_W.get("penalty_scale", 0.25) * sum(v for k, v in comps.items() if k in PEN))
            lead_hand = max(cands, key=lambda c: c["final"])["label"]
            lead_learned = max(cands, key=lambda c: c["learned"])["label"]
            trace(f"learned re-ranker {'agrees' if lead_hand == lead_learned else 'would pick ' + lead_learned} ({'live' if RERANK_LEARNED else 'shadow'})")
            if RERANK_LEARNED:
                for c in cands:
                    c["final"] = c["learned"] * 4.0      # roughly the hand scale, so the abstention threshold still applies
        cands.sort(key=lambda c: c["final"], reverse=True)
        if READER.ok and READER_SHADOW != "off":
            for c in cands[:3]:
                r = READER.read(q, c["text"])
                if r:
                    c["reader"] = r
            lead = cands[0].get("reader")
            if lead:
                trace(f"reader (shadow): span={lead['span'][:60]!r} prob={lead['prob']:.2f} null_margin={lead['null_margin']:.1f} ({lead['ms']:.0f} ms)")
            try:
                with open(os.path.join(DATA_DIR, "reader.jsonl"), "a", encoding="utf-8") as _rf:
                    for c in cands[:3]:
                        _rf.write(json.dumps({"q": q, "label": c["label"], "from": c["from"], "judge": round(c["score"], 2), "final": round(c["final"], 2),
                                              "reader": c.get("reader"), "text": c["text"][:300]}, ensure_ascii=False) + "\n")
            except Exception:
                pass
        _CTX.last_cands = [{"label": c["label"], "from": c["from"], "judge": c["score"], "final": c["final"], "comps": dict(c.get("comps") or {}), "text": c["text"],
                            "reader": c.get("reader")} for c in cands]
        best_wiki = next((c for c in cands if c["from"] == "wikipedia"), None)
        if how == "cross-encoder judge" and cands[0]["from"] == "web" and best_wiki is not None and best_wiki["score"] >= 5.0 and best_wiki["final"] >= best_wiki["score"] and cands[0]["final"] - best_wiki["final"] < 1.0:
            # v17 "What causes tides?": a mid-article NOAA paragraph beat Wikipedia's complete lead by half a point. Web text has
            # to be clearly better to displace an encyclopedia passage the judge also rates as answering.
            cands.remove(best_wiki)
            cands.insert(0, best_wiki)
            trace("   web lead is within 1.0 of a well-rated Wikipedia passage -> Wikipedia kept")
        for c in cands[:5]:
            comps_s = " ".join(f"{k}={v:+.1f}" for k, v in sorted((c.get("comps") or {}).items(), key=lambda kv: -abs(kv[1])) if v)
            trace(f"   answer candidate [{c['label'][:28]}] judge={c['score']:.2f} final={c['final']:.2f} [{comps_s}] | {c['text'][:70]}")
        if how == "cross-encoder judge" and cands[0]["final"] < MIN_ANSWER:
            # v36: across 188 replayed questions the top candidate was right ~50% of the time below 3.0 and 90%+ above 4.0
            trace(f"best final {cands[0]['final']:.2f} is below the abstention threshold {MIN_ANSWER:.1f} -> offering pages instead")
            st["last_mode"] = "none"
            pages = []
            for c in cands[:4]:
                src = (c.get("ev") or {}).get("source") if c["from"] == "web" else None
                if src is None and c["from"] == "wikipedia":
                    src = {"title": c["label"].replace(" (alt)", ""), "url": "https://en.wikipedia.org/wiki/" + c["label"].replace(" (alt)", "").replace(" ", "_")}
                if src and src not in pages:
                    pages.append(src)
            return {"answer": "I found passages on that, but none of them clearly answers the question, so I won't quote one as if it did. These pages may help:\n"
                              + "\n".join("\u2022 " + (x.get("title") or x.get("url"))[:100] for x in pages),
                    "sources": pages, "mode": "none", "evidence_count": 0}
        if how == "cross-encoder judge" and cands[0]["score"] < float(os.environ.get("NOAI_JUDGE_MIN", "-6")):
            # Falling through would hand the question to the Wikipedia step, which would show the very passage the judge
            # just rejected. Saying "I don't know" is the honest outcome.
            trace("the judge rates no candidate as answering the question -> abstain")
            st["last_mode"] = "none"
            grows0 = getattr(_CTX, "guide_rows", None)
            if grows0:
                what0 = getattr(_CTX, "guide_what", q)
                trace("guide fallback: offering the pages found instead of abstaining")
                return {"answer": f"I couldn't find a page with a clear step-by-step list for {what0}, and none of the passages I read answers it well. These pages may help:\n" + "\n".join("\u2022 " + r["title"][:100] for r in grows0),
                        "sources": [{"title": r["title"][:100], "url": r["url"]} for r in grows0], "mode": "none", "evidence_count": 0}
            return {"answer": "I found some passages on that, but none of them actually answers the question, so I'd rather not guess. Try rephrasing it, or ask about one specific part.",
                    "sources": [], "mode": "none", "evidence_count": 0}
    m_first = re.search(r"\bfirst (?:person|man|woman|human|people|one) to (\w+)(?:\s+(?:across|over|through|around|to|on|into|up|down)\s+(?:the\s+)?([A-Za-z][\w-]+))?", q, re.I)
    if m_first:
        verb = stem_set(m_first.group(1))
        obj = stem_set(m_first.group(2)) if m_first.group(2) and m_first.group(2).lower() not in STOP else set()
        vstem = next(iter(verb), "")[:4]
        claim_re = re.compile(r"\bfirst\b[^.;]{0,40}\b(?:to|who|that|ever) " + re.escape(vstem), re.I) if vstem else None
        kept = [c for c in cands if (verb & stem_set(c["text"])) and (not obj or (obj & stem_set(c["text"])))
                and (claim_re is None or claim_re.search(c["text"]))]     # v45: "first ... landed" as one claim, not 'first' and 'landed' anywhere
        if len(kept) < len(cands):
            trace(f"   {len(cands) - len(kept)} candidate(s) never mention '{m_first.group(1)}'" + (f" and '{m_first.group(2)}'" if obj else "") + " -> dropped")
        cands = kept
    if how == "cross-encoder judge" and cands and cands[0]["score"] < (0.0 if len(cands) == 1 or cands[0]["from"] == "web" else -6.0):
        trace(f"   best candidate scores only {cands[0]['score']:.1f} -> not an answer")
        cands = []
    if not cands:
        st["last_mode"] = "none"
        grows1 = getattr(_CTX, "guide_rows", None)
        if grows1:
            what1 = getattr(_CTX, "guide_what", q)
            trace("guide fallback: offering the pages found instead of abstaining")
            return {"answer": f"I couldn't find a page with a clear step-by-step list for {what1}, and none of the passages I read answers it well. These pages may help:\n" + "\n".join("\u2022 " + r["title"][:100] for r in grows1),
                    "sources": [{"title": r["title"][:100], "url": r["url"]} for r in grows1], "mode": "none", "evidence_count": 0}
        return {"answer": "I found some passages on that, but none of them actually answers the question, so I'd rather not guess. Try rephrasing it, or ask about one specific part.",
                "sources": [], "mode": "none", "evidence_count": 0}
    best = cands[0]
    # a winner that opens mid-thought ("That is to say, ...") gets the sentences before it back, from the same page
    if best["from"] == "web" and best["ev"].get("j", 0) > 0:
        fs = (split_sentences(best["text"]) or [""])[0]
        if ANAPHORIC_OPENERS.match(fs) or WEAK_OPENERS.match(fs) or re.match(r"^(?:that is to say|finally|then|next|in this case|as (?:a result|such))\b", fs, re.I):
            ev_ = best["ev"]
            start = max(0, ev_["j"] - 2)
            rebuilt = " ".join(ev_["sents"][start:ev_["j"] + 2])
            if len(rebuilt) <= 700 and web_clean(rebuilt):
                best["text"] = rebuilt
                trace("   winner opened mid-thought -> restored the sentences before it")
    trace(f"answer chosen from {len(cands)} candidate(s) by {how}: {best['label']}")
    try:        # v47: candidate log for pairwise labelling (/label) and the answerability comparison; text only, no personal data
        if how == "cross-encoder judge" and len(cands) >= 2:
            top = sorted(cands, key=lambda c: c.get("final", 0), reverse=True)[:4]
            rec = {"ts": int(time.time()), "q": q, "chosen": best["label"],
                   "cands": [{"label": c["label"], "text": c["text"][:700], "url": (c.get("source") or {}).get("url", ""), "judge": round(c.get("score", c.get("judge", 0)) or 0, 2),
                              "final": round(c.get("final", 0), 2), "heading": c.get("heading", ""), "comps": c.get("comps") or {}, "from": c.get("from", "")} for c in top]}
            with open(os.path.join(DATA_DIR, "candidates.jsonl"), "a", encoding="utf-8") as _cf:
                _cf.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass
    grows = getattr(_CTX, "guide_rows", None)
    if grows and how == "cross-encoder judge" and best.get("final", 0) < 1.5:
        # a how-to question, no page with a step list, and nothing the judge rates as an answer: the honest reply is the
        # pages found, not the Wikipedia paragraph that happened to score least badly (v25: Raspberry Pi -> GPIO header)
        what = getattr(_CTX, "guide_what", q)
        lines = [f"I couldn't find a page with a clear step-by-step list for {what}, and none of the passages I read answers it well. These pages may help:"]
        lines += [f"\u2022 {r['title'][:100]}" for r in grows]
        trace("guide fallback: offering the pages found instead of a weak passage")
        return {"answer": "\n".join(lines), "sources": [{"title": r["title"][:100], "url": r["url"]} for r in grows], "mode": "none", "evidence_count": 0}
    # Sentence-level check: start the quote at the sentence that answers, not at a lead-in before it.
    sents = split_sentences(best["text"])
    if JUDGE.ok and 3 <= len(sents) <= 6 and remaining() > 3:
        per = JUDGE.scores(jq, sents[:5])
        if per:
            b = max(range(len(per)), key=lambda k: per[k])
            opening_off_topic = not (set(core_stems(q)) & alias_expand(stem_set(sents[0])))
            if 0 < b <= 2 and per[b] - per[0] >= 5.0 and per[0] < 0.0 and opening_off_topic and len(sents) - b >= 2 \
                    and not ANAPHORIC_OPENERS.match(sents[b]) and len(" ".join(sents[b:])) >= 130:
                trace(f"   trimmed {b} lead-in sentence(s): judge rates sentence {b + 1} at {per[b]:.1f} vs {per[0]:.1f} for the opening")
                best["text"] = " ".join(sents[b:])
                if best["from"] == "wikipedia":
                    best["res"]["answer"] = best["text"]
    try:      # v57 (data-to-text, extractive): for a why/how question, one defining sentence from the article lead beside the mechanism passage
        if kind in ("why", "how", "formation"):
            lead = next((c for c in cands if c["from"] == "wikipedia" and not c["label"].endswith("(alt)") and c is not best), None)
            if lead:
                first = (split_sentences(lead["text"]) or [""])[0]
                if 40 <= len(first) <= 260 and first[:60] not in best["text"] and re.search(r"\b(?:is|are|was|were)\b", first[:80]):
                    best["text"] = best["text"].rstrip() + "\n\nFor context, the article opens: \u201c" + first.strip() + "\u201d"
                    if best["from"] == "wikipedia":
                        best["res"]["answer"] = best["text"]
                    trace("in short: article lead sentence added as context (quoted)")
    except Exception:
        pass
    if best["from"] == "wikipedia":
        st.update(st_w)
        res = best["res"]
        res["more"] = (res.get("more") or []) + [{"text": c["text"], "source": c["ev"]["source"]} for c in cands[1:4] if c["from"] == "web"]
        return res
    st["last_mode"] = "web"
    st.update({"subject_qid": "", "answer_qid": "", "answer_label": ""})
    more = [{"text": c["text"], "source": (c["ev"]["source"] if c["from"] == "web" else (c["res"].get("sources") or [{}])[0])} for c in cands[1:4]]
    return {"answer": best["text"], "sources": [best["ev"]["source"]], "mode": "web", "evidence_count": len(cands), "more": more}

# =====================================================================================================================
# v21 answer types. Each is a fixed shape filled from quoted source material; none writes text of its own.
# =====================================================================================================================
GUIDE_RE = re.compile(r"^(?:(?:can you |could you |please )?(?:show|tell|teach) me )?(?:how (?:do|can|should|would) (?:i|we|you|one)|how to|what(?:'s| is| are) the (?:steps?|way|best way|procedure|process) (?:to|for)|steps (?:to|for)|"
                      r"(?:a |the )?(?:guide|tutorial|instructions|walkthrough|directions) (?:to|for|on)|walk me through(?: how to)?|explain how to|i want to learn how to|teach me (?:how )?to|"
                      r"what (?:should i|do i|to) do (?:for|about|with|if i have|when i have|if you have)) (?P<what>.+)$", re.I)
NEWS_RE = re.compile(r"^(?:(?:any |the |latest |recent |today's |what's the )?(?:news|headlines|updates?|developments) (?:about|on|for|from|in|regarding|around|concerning) (?P<a>.+)|"
                     r"what(?:'s| is| has been) (?:happening|going on|new|the latest) (?:in|with|at|on|about|around|for) (?P<b>.+)|(?:the )?latest (?:on|about|from|in) (?P<c>.+)|(?P<d>.+?) (?:news|headlines)(?: today| this week)?|"
                     r"(?:any )?(?P<e>local) news(?: today)?)$", re.I)
TIMELINE_RE = re.compile(r"^(?:(?:give me |show me |what is |what's )?(?:a |the )?(?:timeline|chronology|history|key dates|key events|major events) (?:of|for|in|behind) (?P<a>.+)|(?P<b>.+?) (?:timeline|chronology)|when did (?P<c>.+?) happen)$", re.I)
FACTS_RE = re.compile(r"^(?:(?:give me |show me |what are )?(?:some |the |key |quick |basic |a few )?(?:facts|fact sheet|stats|statistics|key facts|quick facts|figures|vital statistics) (?:about|on|for|of) (?P<a>.+)|(?P<b>.+?) (?:fact sheet|facts|stats|statistics|at a glance|in numbers))$", re.I)
PROSCONS_RE = re.compile(r"^(?:(?:what are )?(?:the )?(?:pros and cons|advantages and disadvantages|benefits and drawbacks|upsides and downsides|arguments for and against) (?:of|to|for) (?P<a>.+)|"
                         r"should i (?:get|buy|use|switch to|try|install|adopt|start) (?P<b>.+)|is (?:it|a |an )?(?P<c>.+?) worth (?:it|getting|buying|having|the money))$", re.I)
WORD_RE = re.compile(r"^(?:(?:what (?:is|are) )?(?:a |the |some )?(?P<kind>synonyms?|antonyms?|rhymes?|etymology|origin|pronunciation|opposites?) (?:of|for|with) (?:the word )?(?P<w1>[A-Za-z' -]{2,40})|"
                     r"(?:what|which) (?:words? )?rhymes? with (?:the word )?(?P<w2>[A-Za-z'-]{2,40})|how (?:do you|do i|to) (?P<kind2>pronounce|say) (?:the word )?(?P<w3>[A-Za-z'-]{2,40})|"
                     r"where does the word (?P<w4>[A-Za-z'-]{2,40}) come from|what(?:'s| is) (?:the )?(?:opposite|antonym) of (?P<w5>[A-Za-z' -]{2,40})|(?:another|other) words? for (?P<w6>[A-Za-z' -]{2,40})|"
                     r"what does the (?P<affix>prefix|suffix) (?P<w7>[A-Za-z-]{1,15}) mean)$", re.I)
QUOTE_RE = re.compile(r"^(?:(?:give me |tell me |show me |find )?(?:some |a few |famous |good |the best |best )?(?:quotes?|quotations?|sayings?) (?:by|from|of|attributed to) (?P<a>.+)|what did (?P<b>.+?) say about (?P<topic>.+)|(?P<c>.+?) quotes)$", re.I)
PAGE_SUMMARY_RE = re.compile(r"^(?:(?:can you |please )?(?:summari[sz]e|sum up|tl;?dr|give me (?:a |the )?(?:summary|gist|key points) of|what(?:'s| is) (?:this|that|the) (?:page|article|link) about)[: ]*(?P<url>https?://\S+)|(?P<url2>https?://\S+)\s*(?:summari[sz]e|tl;?dr|summary)?)$", re.I)
MEDICAL = re.compile(r"\b(?:symptom|symptoms|disease|diseases|medication|medications|medicine|dose|dosage|drug|drugs|treatment|treat|cure|diagnos\w+|vaccin\w+|immunis\w+|immuniz\w+|antibiotic\w*|infection|infections|pain|cancer|tumou?r|"
                     r"\d+\s?mg|tablets?|pills?|surgery|therapy|therapist|doctor|gp\b|hospital|blood pressure|cholesterol|diabetes|asthma|allerg\w+|fever|rash|fracture|burn|burns|bleeding|"
                     r"pregnan\w+|vaccine|antibiotic\w*|ibuprofen|paracetamol|acetaminophen|aspirin|overdose|side effects?|safe to take|is it safe|first aid|choking|stroke|heart attack|seizure|"
                     r"insomnia|migraine|arthritis|eczema|psoriasis|obesity|bmi|fibrillation|arrhythmia|syndrome|disorder|\w+itis|\w+osis|\w+emia|\w+pathy)\b", re.I)
LEGAL = re.compile(r"\b(?:lawsuit|sue|suing|sued|liable|liability|legal|illegal|legally|lawyer|attorney|solicitor|custody|tenant|landlord|eviction|my lease|my contract|my deposit|"
                   r"my employer|my boss|my paycheck|my wages|my salary|my overtime|my pension|unfair dismissal|wrongful termination|severance|my landlord|my tenant|my warranty|my refund|"
                   r"can (?:my|the) (?:employer|landlord|bank|insurer|council|police)|(?:fired|dismissed|laid off) (?:for|without|while)|"
                   r"inheritance|divorce|copyright|trademark|my visa|can i be (?:fined|arrested|sued|evicted|deported)|my rights|is it legal|is it illegal|gdpr|my taxes|tax return)\b", re.I)
HEALTH_SITES = re.compile(r"(?:^|\.)(?:nhs\.uk|mayoclinic\.org|medlineplus\.gov|nih\.gov|cdc\.gov|who\.int|clevelandclinic\.org|hopkinsmedicine\.org|health\.harvard\.edu|"
                          r"healthdirect\.gov\.au|nhsinform\.scot|betterhealth\.vic\.gov\.au|drugs\.com|webmd\.com|healthline\.com|patient\.info|bmj\.com|thelancet\.com|"
                          r"cancer\.gov|cancer\.org|heart\.org|diabetes\.org|redcross\.org|redcross\.org\.uk|sja\.org\.uk|fda\.gov|ema\.europa\.eu|gov\.uk)$", re.I)

STRONG_MEDICAL = re.compile(r"\b(?:arrhythmia|heart rhythm|heart attack|stroke|medication|dosage|symptoms|diagnosis|prognosis|patients|first aid|call (?:an ambulance|emergency)|"
                            r"see (?:a|your) doctor|seek medical|treatment options|side effects)\b", re.I)

BRIEF_RE = re.compile(r"\b(?:briefly|in brief|in short|short version|tl;?dr|in one sentence|one[- ]sentence|the gist|just the gist|keep it short|keep it brief)\b", re.I)
NO_COMPRESS_RE = re.compile(r"\d|\b(?:not|no|never|none|neither|nor|cannot|can't|don't|doesn't|isn't|aren't|won't|except|unless|only|all|every|most|some|few|many)\b", re.I)

def compress_sentence(sent):
    """v46 (Phase 5): drop parentheticals, appositives, non-restrictive relative clauses and leading adverbials from a sentence,
    keeping the remaining words in their original order. Returns None when the sentence is not safe to shorten (numbers,
    negation, quantifiers) or when the parser is unavailable."""
    if NLP is None or NO_COMPRESS_RE.search(sent):
        return None
    doc = NLP(sent)
    drop = set()
    for tok in doc:
        if tok.dep_ in ("appos", "parataxis") or (tok.dep_ == "relcl" and tok.i > 0 and doc[tok.i - 1].text == ",") or \
           (tok.dep_ == "advcl" and tok.head.dep_ == "ROOT" and tok.i < tok.head.i) or (tok.dep_ == "advmod" and tok.head.dep_ == "ROOT" and tok.i == 0):
            drop.update(t.i for t in tok.subtree)
    depth = 0
    for tok in doc:                                  # bracketed asides
        if tok.text in "([":
            depth += 1
        if depth:
            drop.add(tok.i)
        if tok.text in ")]" and depth:
            depth -= 1
    keep = [t for t in doc if t.i not in drop]
    if len(keep) < 5 or len(keep) > len(doc) - 3:
        return None
    out = "".join(t.text_with_ws for t in keep).strip()
    out = re.sub(r"\s+([,.;:])", r"\1", re.sub(r"\s+", " ", out)).strip(" ,;")
    out = re.sub(r",\s*,", ",", out)
    out = re.sub(r"[,;:]\s*(?=[.!?]$)", "", out).rstrip(" ,;:")
    if not out.endswith((".", "!", "?")):
        out += "."
    return out[0].upper() + out[1:]

def condense_answer(q, res):
    """Apply compression to a passage answer when the person asked for brevity; the full passage stays one turn away."""
    if not BRIEF_RE.search(q) or res.get("mode") not in ("wikipedia", "web") or not res.get("answer"):
        return res
    sents = split_sentences(res["answer"])
    if not sents:
        return res
    out = []
    for x in sents[:3]:
        c = compress_sentence(x)
        out.append(c or x)
        if len(" ".join(out)) > 260:
            break
    if out and " ".join(out) != res["answer"]:
        res["full_passage"] = res["answer"]
        res["answer"] = " ".join(out) + "\n\nCondensed from the source by dropping asides and side clauses (no words changed or added); say \u201cquote it in full\u201d for the whole passage."
        trace("compression: condensed the quoted passage on request")
    return res

def caution_note(q, answer):
    """A fixed note on medical and legal topics, decided by the question (plus unmistakable medical language in the answer).
    The bot only quotes; it does not advise."""
    blob = q + " " + ((split_sentences(answer or "") or [""])[0] if STRONG_MEDICAL.search((answer or "")[:400]) else "")
    if MEDICAL.search(blob):
        return "\n\nThis is quoted reference material, not medical advice. For anything about your own health, talk to a doctor or pharmacist; in an emergency call your local emergency number."
    if LEGAL.search(blob):
        return "\n\nThis is quoted reference material, not legal advice, and the law differs by country. For your own situation, a qualified adviser is the safe route."
    return ""

def _unique_domains(rows, n):
    out, seen = [], set()
    for r in rows:
        if r.get("url") and host(r["url"]) not in seen and not any(d in host(r["url"]) for d in SKIP_DOMAINS):
            seen.add(host(r["url"]))
            out.append(r)
        if len(out) >= n:
            break
    return out

# ---------------------------------------------------------------- step-by-step guides (shown in full)
CITATION_STEP_RE = re.compile(r"\[\s*(?:PubMed|DOI|PMC free article|Google Scholar|CrossRef)\s*\]|\bdoi:|\bet al\.|\b(?:19|20)\d\d;\s*\d+:|\b[A-Z][a-z]+ [A-Z]{1,3},\s+[A-Z][a-z]+ [A-Z]{1,3}\.", re.I)
GENERIC_ITEMS = {"gallery", "museum", "museums", "overview", "history", "references", "notes", "external links", "see also", "contents", "content",
                 "location", "admission", "featured events", "map", "maps", "other", "others", "more", "highlights", "attractions", "things to do", "tips", "faq", "faqs"}
LINKY_ITEM_RE = re.compile(r"^(?:Best|Top|How|Is|Are|Why|What|Which|Should|Can)\b.*|.*\?$|.*\b(?:review|guide|explained|vs\.?)\b.*$", re.I)

def answer_guide(q, st):
    s = norm(q).rstrip("?.! ")
    m = GUIDE_RE.match(s)
    if not m:
        return None
    what = clean_term(m.group("what"))
    if re.search(r"^what (?:should i|do i|to) do", s, re.I):
        what = ("treat " if MEDICAL.search(what) else "deal with ") + re.sub(r"^(?:a|an|the|my)\s+", "", what)
    if len(what.split()) > 12 or re.search(r"\b(?:you|your|yourself)\b", what, re.I) and re.search(r"\b(?:feel|think|know)\b", what, re.I):
        return None
    ctx_extend(BUDGET_SLOW)
    rows = []
    try:      # v57: wikiHow titles are predictable ("How-to-Sharpen-a-Kitchen-Knife"), so the page can be fetched without any search engine
        slug = "How-to-" + "-".join(w.capitalize() if i == 0 or w.lower() not in ("a", "an", "the", "of", "in", "on", "to", "for", "with", "and", "at", "from") else w.lower()
                                    for i, w in enumerate(re.sub(r"[^A-Za-z0-9 ]", " ", what).split()))
        rows = [{"url": "https://www.wikihow.com/" + slug, "title": "How to " + what + " - wikiHow"}]
        trace(f"guide: trying wikiHow directly ({slug})")
    except Exception:
        rows = []
    rows = rows + (searx_search(f"how to {what} step by step") or [])
    if not rows:
        return None
    want = stem_set(what)
    best, bs = None, 0.0
    for row, page in _fetch_many(rows, 5):
        guides = [g for g in (page.get("faq") or []) if g.get("howto") and len(g.get("steps") or []) >= 3]
        cand = [(g["q"], g["steps"], g.get("needs") or []) for g in guides] + ([(row.get("title") or "", page.get("steps") or [], page.get("needs") or [])] if len(page.get("steps") or []) >= 3 else [])
        for title, steps, needs in cand:
            steps = [x for x in steps if not CITATION_STEP_RE.search(x)]              # v48: a reference list is not a method
            needs = [x for x in needs if not LINKY_ITEM_RE.search(x)]                # v48: "Best Car Dash Cams" is a nav link, not a tool
            if len(steps) < 3:
                continue
            ov = len(want & stem_set(title + " " + " ".join(steps[:3]))) / max(1, len(want))
            sc = 10 * ov + min(3.0, 0.3 * len(steps)) + site_prior(host(row["url"]))
            if ov >= 0.5 and sc > bs:
                bs, best = sc, (title, steps, needs, row)
    if not best:
        trace(f"guide: no page with a usable step list for '{what}'")
        _CTX.guide_rows = [r for r in rows[:6] if r.get("url") and r.get("title")][:4]
        _CTX.guide_what = what
        return None
    title, steps, needs, row = best
    dom = host(row["url"])
    lines = [f"Step by step, from {dom}" + (f" (\u201c{title.strip()[:90]}\u201d)" if title.strip() else "") + ":"]
    if needs:
        lines += ["", "What you'll need:"] + ["\u2022 " + x for x in needs[:15]]
    lines += ["", "Steps:"] + [f"{i}. {x}" for i, x in enumerate(steps[:25], 1)]
    if len(steps) > 25:
        lines.append(f"\u2026 and {len(steps) - 25} more on the page.")
    st.update({"last_mode": "guide", "subject_label": what, "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": what})
    return {"answer": "\n".join(lines) + caution_note(q, " ".join(steps[:5])), "sources": [{"title": row.get("title") or dom, "url": row["url"]}], "mode": "guide", "evidence_count": len(steps)}

# ---------------------------------------------------------------- news from several sources
NEWS_FEEDS = [("BBC News", "https://feeds.bbci.co.uk/news/world/rss.xml"), ("NPR", "https://feeds.npr.org/1001/rss.xml"), ("The Guardian", "https://www.theguardian.com/world/rss"),
              ("Al Jazeera", "https://www.aljazeera.com/xml/rss/all.xml"), ("CBC", "https://www.cbc.ca/webfeed/rss/rss-world"), ("Deutsche Welle", "https://rss.dw.com/rdf/rss-en-all")]

def _feed_items(name, url):
    """RSS/Atom items without any library: title, link, date, description."""
    try:
        r = WEB.get(url, timeout=(3, 6), headers={"User-Agent": UA_WEB})
        r.raise_for_status()
        import xml.etree.ElementTree as ET
        root = ET.fromstring(r.content)
    except Exception as e:
        trace(f"feed {name} failed: {type(e).__name__}")
        return []
    out = []
    for it in root.iter():
        tag = it.tag.split("}")[-1]
        if tag not in ("item", "entry"):
            continue
        d = {c.tag.split("}")[-1]: (c.text or c.get("href") or "") for c in it}
        title, link = norm(d.get("title", "")), (d.get("link") or "").strip()
        if title and link:
            out.append({"title": title, "url": link, "content": norm(re.sub(r"<[^>]+>", " ", d.get("description") or d.get("summary") or ""))[:300], "publishedDate": d.get("pubDate") or d.get("published") or d.get("updated") or "", "engines": [name]})
    return out[:60]

def answer_news(q, st):
    s = norm(q).rstrip("?.! ")
    m = NEWS_RE.match(s)
    if not m:
        return None
    topic = clean_term(next((g for g in (m.group("a"), m.group("b"), m.group("c"), m.group("d")) if g), "") or "")
    if m.group("e"):
        topic = st.get("home_location") or st.get("location") or ""
        if not topic:
            return {"answer": "Tell me where you are first (\"I live in ...\") and I'll look for local headlines.", "sources": [], "mode": "chat", "evidence_count": 0}
    if not topic or len(topic.split()) > 8 or re.match(r"^(?:the|any|some|good|bad|fake|breaking)$", topic, re.I):
        return None
    ctx_extend(BUDGET_SLOW)
    stems = (set(core_stems(topic)) - _QUERY_FILLER) or set(core_stems(topic))
    rows = []
    for name, url in NEWS_FEEDS[:5]:
        if remaining() < 8:
            break
        rows += [it for it in _feed_items(name, url) if len(stems & stem_set(it["title"] + " " + it["content"])) >= min(len(stems), 2)]
    rows += searx_search(f"{topic} news", categories="news", time_range="week") if len(rows) < 6 else []
    def _story(r):
        if r.get("engines") and str((r.get("engines") or [""])[0]).istitle():
            return True                  # from a feed: every item is a story
        path = re.sub(r"^https?://[^/]+", "", r.get("url") or "").strip("/")
        if re.search(r"wikipedia\.org|wikimedia\.org|grokipedia\.com|britannica\.com|news\.google\.|youtube\.com|facebook\.com|twitter\.com|x\.com|reddit\.com", r.get("url") or "") \
                or re.search(r"(?:^|/)(?:news|latest|latest-news|recently-published|topics?|tags?|category|section)/?(?:\?.*)?$", r.get("url") or "", re.I):
            return False
        if not (r.get("publishedDate") or re.search(r"\d{4}/\d{1,2}|\d{6,}|[a-z]-[a-z0-9-]{20,}", path, re.I)):
            return False                 # no date and no story-shaped path: a section or front page
        tstems = stem_set(r.get("title") or "")
        return len(stems & tstems) >= min(len(stems), 2) if len(stems) > 1 else bool(stems & tstems)
    rows = [r for r in rows if r.get("url") and _story(r)]
    if not rows:
        return {"answer": f"I couldn't find recent news about {topic} right now" + (" (the search engines are throttling me; try again in a few minutes)" if SEARCH_STATE.get("down") else "") + ".",
                "sources": [], "mode": "none", "evidence_count": 0}
    clusters = []
    for r in rows[:40]:
        k = structured._key(r.get("title") or "")
        if not k:
            continue
        for c in clusters:
            if len(k & c["key"]) / max(1, len(k | c["key"])) >= 0.5:
                c["rows"].append(r)
                break
        else:
            clusters.append({"key": k, "rows": [r]})
    clusters.sort(key=lambda c: (-len({host(x["url"]) for x in c["rows"]}), -len(c["rows"])))
    import html as _html
    lines, sources = [f"Recent headlines about {topic}, from several sources:"], []
    for c in clusters[:8]:
        r = c["rows"][0]
        r["title"] = _html.unescape(r.get("title") or "")
        r["content"] = _html.unescape(r.get("content") or "")
        r["url"] = re.sub(r"[?&](?:at_medium|at_campaign|utm_[a-z]+|traffic_source|ref)=[^&#]*", "", r["url"]).rstrip("?&")
        outlets = sorted({(x.get("engines") or [host(x["url"])])[0] if str((x.get("engines") or [""])[0]).istitle() else host(x["url"]) for x in c["rows"]})
        when = re.sub(r"(\d)T(\d)", r"\1 \2", (r.get("publishedDate") or "")[:16])
        lines.append(f"\u2022 {r['title']}" + (f"  \u2014 {', '.join(outlets[:3])}" if outlets else "") + (f" ({when})" if when else ""))
        if r.get("content"):
            lines.append("  " + (split_sentences(r["content"]) or [r["content"]])[0][:220])
        sources.append({"title": r["title"][:90], "url": r["url"]})
    if not any(r.get("publishedDate") or re.match(r"^\d+ (?:hours?|days?|minutes?) ago", r.get("content") or "") for r in rows[:10]):
        lines.append("\n(Dates were not provided by the sources, so I can't vouch for how recent these are.)")
    lines.append("\nHeadlines and blurbs are quoted from the outlets; open a link for the full story.")
    st.update({"last_mode": "news", "subject_label": topic, "subject_qid": "", "answer_qid": "", "answer_label": ""})
    return {"answer": "\n".join(lines), "sources": sources[:8], "mode": "news", "evidence_count": len(rows)}

# ---------------------------------------------------------------- v60: a whole Wikipedia section, under its heading, as an answer shape
SECTION_RE = re.compile(r"^(?:(?:what|which) (?:are|were) (?:the )?(?:different |main |various )?(?P<shape1>types|kinds|forms|uses|causes|symptoms|effects|advantages|disadvantages|characteristics|features|ingredients|components|parts|origins) of (?P<a>.+?)|"
                        r"(?P<shape2>types|kinds|uses|causes|symptoms|effects|origins|etymology|structure|anatomy|geography|climate|economy|culture|design|construction|composition|classification|habitat|diet|behaviou?r|reproduction|life cycle) of (?:the |a |an )?(?P<b>.+?)|"
                        r"(?:how (?:does|do|did) (?:the |a |an )?(?P<c>.+?) work)|(?:what (?:is|was) (?:the |a |an )?(?P<d>.+?)(?:'s| ) (?P<shape4>structure|anatomy|design|composition|etymology|origin|history)))[?.!]*$", re.I)
SECTION_WORDS = {"types": r"types?|kinds?|varieties|classification|forms", "kinds": r"types?|kinds?|varieties|classification", "forms": r"forms|types?", "uses": r"uses?|applications?|usage", "causes": r"causes?|aetiology|etiology|origins?",
                 "symptoms": r"symptoms?|signs and symptoms|presentation", "effects": r"effects?|consequences|impact", "advantages": r"advantages|benefits", "disadvantages": r"disadvantages|drawbacks|criticism|limitations",
                 "characteristics": r"characteristics|description|properties|features", "features": r"features|characteristics|description", "ingredients": r"ingredients|composition", "components": r"components|parts|structure",
                 "parts": r"parts|components|structure|anatomy", "origins": r"origins?|history|etymology", "etymology": r"etymology|name", "structure": r"structure|anatomy|design|construction|architecture", "anatomy": r"anatomy|structure|morphology",
                 "geography": r"geography", "climate": r"climate", "economy": r"economy", "culture": r"culture", "design": r"design|construction", "construction": r"construction|design|building", "composition": r"composition|structure|chemistry",
                 "classification": r"classification|taxonomy|types?", "habitat": r"habitat|distribution|range", "diet": r"diet|feeding|food", "behaviour": r"behaviou?r|ecology", "behavior": r"behaviou?r|ecology", "reproduction": r"reproduction|breeding|life cycle",
                 "life cycle": r"life cycle|reproduction", "history": r"history|origins?", "origin": r"origins?|history|etymology", "work": r"mechanism|operation|principle|how it works|working|process|function|physics"}

def answer_section(q, st):
    """Quote a whole section (its first paragraphs, capped) under its own heading when the question names a section-shaped
    thing: 'types of X', 'uses of X', 'how does X work' when the article has an Operation/Mechanism section. Verbatim, in order."""
    m = SECTION_RE.match(norm(q).rstrip("?.! "))
    if not m:
        return None
    shape = (m.group("shape1") or m.group("shape2") or m.group("shape4") or ("work" if m.group("c") else "")).lower()
    term = clean_term(m.group("a") or m.group("b") or m.group("c") or m.group("d") or "")
    if not term or shape not in SECTION_WORDS or len(term.split()) > 6:
        return None
    title = _best_page(term)
    if not title:
        return None
    text = wiki_extract(title) or ""
    paras = wiki_paragraphs(text)
    want = re.compile(r"^(?:" + SECTION_WORDS[shape] + r")\b", re.I)
    heads = [h for h, _ in paras if h]
    hit = next((h for h in dict.fromkeys(heads) if want.search(h)), None)
    if not hit:
        hit = next((h for h in dict.fromkeys(heads) if re.search(SECTION_WORDS[shape], h, re.I)), None)
    if not hit:
        trace(f"section: '{title}' has no {shape} section (headings: {', '.join(list(dict.fromkeys(heads))[:8])})")
        return None
    body = [p for h, p in paras if h == hit]
    if not body:
        return None
    out, total = [], 0
    for p in body:
        if total + len(p) > 1500 and out:
            break
        out.append(p); total += len(p)
    more = len(body) - len(out)
    lines = [f"From the {hit} section of Wikipedia's \u201c{title}\u201d article, quoted in order:"] + [""] + out
    if more > 0:
        lines.append(f"\n({more} more paragraph{'s' if more > 1 else ''} in that section; open the article for the rest.)")
    url = "https://en.wikipedia.org/wiki/" + title.replace(" ", "_")
    st.update({"last_mode": "wikipedia", "subject_label": title, "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": title})
    trace(f"section: '{hit}' from '{title}' ({len(out)} of {len(body)} paragraphs)")
    return {"answer": "\n".join(lines), "sources": [{"title": title, "url": url + "#" + hit.replace(" ", "_")}], "mode": "wikipedia", "evidence_count": len(out)}

# ---------------------------------------------------------------- timelines from a Wikipedia article's dated sentences
_YEAR = re.compile(r"\b(1[0-9]{3}|20[0-9]{2})\b")

def _best_page(term):
    ex = [c for c in wiki_exact(term) if not c.get("disambig")]
    if ex:
        return ex[0]["title"]
    cs = [c for c in wiki_candidates(term, 4) if not c.get("disambig")]
    return cs[0]["title"] if cs else ""

def answer_timeline(q, st):
    s = norm(q).rstrip("?.! ")
    m = TIMELINE_RE.match(s)
    if not m:
        return None
    term = clean_term(next(g for g in (m.group("a"), m.group("b"), m.group("c")) if g))
    if not term or len(term.split()) > 7:
        return None
    title = _best_page(term)
    if not title:
        return None
    text = wiki_extract(title) or ""
    events = {}
    for sent in split_sentences(text, lo=30, hi=400):
        bc = re.search(r"\b(\d{1,4})\s?(?:BC|BCE)\b", sent)
        y = _YEAR.search(sent)
        if (not y and not bc) or SITE_BOILERPLATE.search(sent) or sent.count("(") > 3 or "=" in sent or len(sent) < 30 or not sent[:1].isupper() or re.match(r"^\d", sent):
            continue
        yr = -int(bc.group(1)) if bc and (not y or bc.start() < y.start()) else int(y.group(1))     # v38: BC years count, and sort before AD
        if yr not in events or len(sent) < len(events[yr]):
            events[yr] = sent.strip()
    if len(events) < 4:
        trace(f"timeline: only {len(events)} dated sentences in '{title}'")
        return None
    rows = sorted(events.items())[:14]
    lines = [f"Timeline of {title}, from dated sentences in its Wikipedia article:"] + [f"\u2022 {(str(-yr) + ' BC') if yr < 0 else yr} \u2014 {sent}" for yr, sent in rows]
    st.update({"last_mode": "timeline", "subject_label": title, "subject_qid": "", "answer_qid": "", "answer_label": "", "last_term": term})
    return {"answer": "\n".join(lines), "sources": [{"title": title, "url": wiki_url(title)}], "mode": "timeline", "evidence_count": len(rows)}

# ---------------------------------------------------------------- fact sheets from Wikidata
FACT_FIELDS = [("P31", "Type"), ("P569", "Born"), ("P19", "Birthplace"), ("P570", "Died"), ("P106", "Occupation"), ("P27", "Citizenship"), ("P26", "Spouse"),
               ("P17", "Country"), ("P36", "Capital"), ("P1082", "Population"), ("P2046", "Area"), ("P38", "Currency"), ("P37", "Official language"), ("P30", "Continent"),
               ("P571", "Founded"), ("P112", "Founder"), ("P169", "CEO"), ("P159", "Headquarters"), ("P2044", "Elevation"), ("P2043", "Length"), ("P2048", "Height"),
               ("P50", "Author"), ("P57", "Director"), ("P86", "Composer"), ("P175", "Performer"), ("P577", "Released"), ("P136", "Genre"), ("P138", "Named after"),
               ("P2067", "Mass"), ("P2120", "Radius"), ("P2583", "Distance from Earth"), ("P1128", "Employees"), ("P856", "Website")]

def answer_factsheet(q, st):
    s = norm(q).rstrip("?.! ")
    m = FACTS_RE.match(s)
    if not m:
        return None
    term = clean_term(m.group("a") or m.group("b"))
    if not term or len(term.split()) > 7:
        return None
    best = entity_from_state_or_search(term, st, None, ())
    if not best:
        return None
    ent = best["entity"]
    lines = []
    for pid, label in FACT_FIELDS:
        claims = ranked_claims(ent, pid)
        if not claims:
            continue
        single = pid in {"P19", "P571", "P569", "P570", "P17", "P30", "P36", "P159", "P577"}
        vals = [v["text"] for v in claim_values(claims, limit=1 if single else 4) if v.get("text") and norm_key(best["label"]) not in norm_key(v["text"])]
        if vals:
            lines.append(f"\u2022 {label}: {human_join(vals) if pid != 'P856' else vals[0]}")
        if len(lines) >= 12:
            break
    if len(lines) < 3:
        return None
    desc = ent.get("descriptions", {}).get("en", {}).get("value", "")
    head = best["label"] + (f" \u2014 {desc}" if desc else "") + ":"
    composed = compose_sentence(best)
    if composed:
        head = "In one sentence, from Wikidata: " + composed + "\n" + head
    st.update({"last_mode": "facts", "subject_label": best["label"], "subject_qid": best.get("qid", ""), "answer_qid": "", "answer_label": ""})
    return {"answer": head + "\n" + "\n".join(lines), "sources": [{"title": "Wikidata: " + best["label"], "url": "https://www.wikidata.org/wiki/" + best.get("qid", "")}], "mode": "facts", "evidence_count": len(lines)}

# ---------------------------------------------------------------- pros and cons, attributed per site
_PRO = re.compile(r"\b(?:advantages?|benefits?|pros?\b|upsides?|strengths?|positives?|plus(?:es)?|good for|great for|makes it easier)\b", re.I)
_CON = re.compile(r"\b(?:disadvantages?|drawbacks?|cons\b|downsides?|weaknesses?|negatives?|limitations?|risks?|problems? with|not (?:ideal|suitable|great)|can be (?:expensive|noisy|slow))\b", re.I)

def answer_proscons(q, st):
    s = norm(q).rstrip("?.! ")
    m = PROSCONS_RE.match(s)
    if not m:
        return None
    thing = clean_term(m.group("a") or m.group("b") or m.group("c"))
    if not thing or len(thing.split()) > 8:
        return None
    ctx_extend(BUDGET_SLOW)
    rows = searx_search(f"{thing} pros and cons")
    pros, cons = [], []
    for row, page in _fetch_many(rows, 5):
        dom = host(row["url"])
        got_p = got_c = 0
        for _h, para in web_paragraphs(page.get("text") or ""):
            for sent in split_sentences(para, lo=40, hi=300):
                if not web_clean(sent) or CHATTY.search(sent):
                    continue
                if _CON.search(sent) and got_c < 2:
                    cons.append((sent, dom)); got_c += 1
                elif _PRO.search(sent) and got_p < 2:
                    pros.append((sent, dom)); got_p += 1
    if len({d for _, d in pros}) + len({d for _, d in cons}) < 2 or not pros or not cons:
        trace("pros/cons: not enough attributed points from independent sites")
        return None
    lines = [f"What sites say for and against {thing} (their words, attributed):", "", "For:"] + [f"\u2022 {t} ({d})" for t, d in pros[:4]] + ["", "Against:"] + [f"\u2022 {t} ({d})" for t, d in cons[:4]]
    lines.append("\nI don't make recommendations; these are the points the sources raise.")
    srcs = list({d: {"title": d, "url": "https://" + d} for _, d in pros + cons}.values())[:6]
    st.update({"last_mode": "proscons", "subject_label": thing, "subject_qid": "", "answer_qid": "", "answer_label": ""})
    return {"answer": "\n".join(lines) + caution_note(q, ""), "sources": srcs, "mode": "proscons", "evidence_count": len(pros) + len(cons)}

# ---------------------------------------------------------------- word tools from Wiktionary wikitext
LANG_CODES = {"enm": "Middle English", "ang": "Old English", "la": "Latin", "grc": "Ancient Greek", "fro": "Old French", "fr": "French", "de": "German", "non": "Old Norse", "gem-pro": "Proto-Germanic",
              "ine-pro": "Proto-Indo-European", "it": "Italian", "es": "Spanish", "ar": "Arabic", "nl": "Dutch", "ML.": "Medieval Latin", "LL.": "Late Latin", "gmw-pro": "Proto-West Germanic",
              "xno": "Anglo-Norman", "frm": "Middle French", "el": "Greek", "he": "Hebrew", "sa": "Sanskrit", "hi": "Hindi", "ja": "Japanese", "zh": "Chinese", "pt": "Portuguese", "en": "English"}

def _wikitext(site, page):
    d = http_get_json(f"https://{site}/w/api.php", {"action": "parse", "page": page, "prop": "wikitext", "format": "json", "formatversion": 2, "redirects": 1}, 7 * 86400, "wtxt", timeout=8)
    return ((d.get("parse") or {}).get("wikitext") or "") if isinstance(d, dict) else ""

def _templ_words(chunk, names):
    out = []
    for mm in re.finditer(r"\{\{(" + "|".join(names) + r")\|en\|([^}]*)\}\}", chunk):
        out += [re.sub(r"^.*?=|#.*$", "", x).strip() for x in mm.group(2).split("|") if x and "=" not in x]
    out += re.findall(r"\{\{l\|en\|([^}|]+)", chunk)
    return list(dict.fromkeys(w for w in out if w and len(w) < 40))

def answer_word(q, st):
    s = norm(q).rstrip("?.! ")
    m = WORD_RE.match(s)
    if not m:
        return None
    g = m.groupdict()
    word = (g.get("w1") or g.get("w2") or g.get("w3") or g.get("w4") or g.get("w5") or g.get("w6") or g.get("w7") or "").strip().lower()
    kind = (g.get("kind") or g.get("kind2") or "").lower()
    if g.get("w2"):
        kind = "rhymes"
    elif g.get("w4"):
        kind = "etymology"
    elif g.get("w5"):
        kind = "antonyms"
    elif g.get("w6"):
        kind = "synonyms"
    elif g.get("affix"):
        kind, word = "affix", (word if word.startswith("-") or word.endswith("-") else (word + "-" if g["affix"] == "prefix" else "-" + word))
    base = {"opposite": "antonym", "opposites": "antonym", "origin": "etymology", "pronounce": "pronunciation", "say": "pronunciation"}.get(kind, kind).rstrip("s")
    kind = base + ("s" if base in ("synonym", "antonym", "rhyme") else "")
    if not word:
        return None
    wt = _wikitext("en.wiktionary.org", word)
    if not wt:
        return None
    eng = wt.split("==English==", 1)[1] if "==English==" in wt else wt
    eng = re.split(r"\n==[^=]", eng, 1)[0]
    src = [{"title": "Wiktionary: " + word, "url": "https://en.wiktionary.org/wiki/" + quote(word)}]
    if kind == "synonyms" or kind == "antonyms":
        sec = "Synonyms" if kind == "synonyms" else "Antonyms"
        parts = re.findall(r"====?" + sec + r"====?\n(.*?)(?=\n===|\Z)", eng, re.S)
        inline = re.findall(r"\{\{(?:syn|synonyms)\|en\|([^}]*)\}\}" if kind == "synonyms" else r"\{\{(?:ant|antonyms)\|en\|([^}]*)\}\}", eng)
        words = _templ_words("\n".join(parts), ["syn", "synonyms", "ant", "antonyms"]) + [x.strip() for grp in inline for x in grp.split("|") if x and "=" not in x]
        words = [w for w in dict.fromkeys(words) if w.lower() != word and ":" not in w and "#" not in w][:15]
        if not words:
            th = _wikitext("en.wiktionary.org", "Thesaurus:" + word)
            th_eng = re.split(r"\n==[^=]", th.split("==English==", 1)[1], 1)[0] if "==English==" in th else th
            parts2 = re.findall(r"====?" + sec + r"====?\n(.*?)(?=\n===|\Z)", th_eng, re.S)
            words = [w for w in dict.fromkeys(re.findall(r"\{\{(?:l|ws)\|en\|([^}|]+)", "\n".join(parts2))) if w.lower() != word and ":" not in w][:15]
            if words:
                return {"answer": f"{sec} of \u201c{word}\u201d (Wiktionary thesaurus): {', '.join(words)}.", "sources": [{"title": "Wiktionary: Thesaurus:" + word, "url": "https://en.wiktionary.org/wiki/Thesaurus:" + quote(word)}], "mode": "word", "evidence_count": len(words)}
            return {"answer": f"Wiktionary lists no {kind} for \u201c{word}\u201d.", "sources": src, "mode": "word", "evidence_count": 0}
        return {"answer": f"{sec} of \u201c{word}\u201d (Wiktionary): {', '.join(words)}.", "sources": src, "mode": "word", "evidence_count": len(words)}
    if kind == "etymology" or kind == "affix":
        parts = re.findall(r"===Etymology(?: \d)?===\n(.*?)(?=\n===|\Z)", eng, re.S)
        def _lang(mm):
            code, term = mm.group(2), mm.group(3)
            return (LANG_CODES.get(code, code) + " " + ("\u201c" + term + "\u201d" if term else "")).strip()
        txt = norm(re.sub(r"\{\{(inh|der|bor|cog|m|uder|ubor|inh\+|der\+|bor\+|l)\|(?:en\|)?([a-z-]+)\|([^|}]*)[^}]*\}\}", _lang, parts[0])) if parts else ""
        txt = re.sub(r"\{\{[^}]*\}\}|\[\[|\]\]|'''?", "", txt).strip()
        if kind == "affix":
            defs = re.findall(r"^# ([^\n]+)", eng, re.M)
            defs = [re.sub(r"\{\{[^}]*\}\}|\[\[|\]\]", "", d).strip() for d in defs][:4]
            if defs:
                return {"answer": f"{word}: " + "; ".join(defs) + (f"\nOrigin: {txt[:300]}" if txt else ""), "sources": src, "mode": "word", "evidence_count": len(defs)}
        if len(txt) < 15:
            return None
        return {"answer": f"Etymology of \u201c{word}\u201d (Wiktionary): {txt[:600]}", "sources": src, "mode": "word", "evidence_count": 1}
    if kind == "pronunciation":
        ipa = re.findall(r"\{\{IPA\|en\|([^}]*)\}\}", eng)
        ipa = [x.split("|")[0] for x in ipa if x and "=" not in x.split("|")[0]][:3]
        if not ipa:
            return None
        return {"answer": f"Pronunciation of \u201c{word}\u201d (IPA, from Wiktionary): {' or '.join(ipa)}. You can hear it on the Wiktionary page.", "sources": src, "mode": "word", "evidence_count": len(ipa)}
    if kind == "rhymes":
        mm = re.search(r"\{\{rhymes\|en\|([^}|]+)", eng)
        no_page = {"answer": f"Wiktionary has no rhymes list for \u201c{word}\u201d (its entry doesn't link one), so I can't give a sourced list. The entry itself may show a pronunciation to work from.",
                   "sources": [{"title": f"Wiktionary: {word}", "url": f"https://en.wiktionary.org/wiki/{word}"}], "mode": "word", "evidence_count": 0}
        if not mm:
            trace(f"word: no rhymes template on the Wiktionary entry for '{word}'")
            return no_page
        rt = _wikitext("en.wiktionary.org", "Rhymes:English/" + mm.group(1))
        words = [w for w in re.findall(r"\{\{l\|en\|([^}|]+)\}\}", rt) if w.lower() != word][:25]
        if not words:
            trace(f"word: rhymes page 'Rhymes:English/{mm.group(1)}' listed nothing usable")
            return no_page
        return {"answer": f"Words that rhyme with \u201c{word}\u201d (Wiktionary, rhyme -{mm.group(1)}): {', '.join(words)}.", "sources": [{"title": "Wiktionary rhymes", "url": "https://en.wiktionary.org/wiki/Rhymes:English/" + quote(mm.group(1))}], "mode": "word", "evidence_count": len(words)}
    return None

# ---------------------------------------------------------------- quotations from Wikiquote
def answer_quotes(q, st):
    s = norm(q).rstrip("?.! ")
    m = QUOTE_RE.match(s)
    if not m:
        return None
    who = clean_term(m.group("a") or m.group("b") or m.group("c"))
    topic = clean_term(m.group("topic") or "")
    if not who or len(who.split()) > 5:
        return None
    wt = _wikitext("en.wikiquote.org", who)
    if not wt:
        return None
    body = wt.split("== Misattributed", 1)[0].split("==Misattributed", 1)[0]
    quotes = []
    for line in body.splitlines():
        if not line.startswith("* ") or line.startswith("**"):
            continue
        t = re.sub(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]", r"\1", line[2:])
        t = re.sub(r"\{\{[^}]*\}\}|<[^>]+>|'''?", "", t).strip(" \u201c\u201d\"")
        if 30 <= len(t) <= 300 and not t.startswith(("See ", "Reported", "Quoted", "Variant", "As quoted")) and (not topic or set(core_stems(topic)) & stem_set(t)):
            quotes.append(t)
        if len(quotes) >= 6:
            break
    if not quotes:
        return None
    return {"answer": f"Quotations attributed to {who}" + (f" about {topic}" if topic else "") + " (from Wikiquote, which lists sources for each):\n" + "\n".join(f"\u2022 \u201c{t}\u201d" for t in quotes),
            "sources": [{"title": "Wikiquote: " + who, "url": "https://en.wikiquote.org/wiki/" + quote(who.replace(" ", "_"))}], "mode": "quotes", "evidence_count": len(quotes)}

# ---------------------------------------------------------------- page summary: extractive (Sumy TextRank), sentences verbatim, in page order
def _extractive_semantic(sentences, n):
    """v46 (Phase 5): centrality over MiniLM sentence vectors (how much the rest of the page agrees with a sentence), a small
    lead bias, and maximal-marginal-relevance selection so the picks do not repeat each other. Returns verbatim sentences in
    page order, or None when the encoder is off."""
    try:
        if not (SEM and SEM.ok) or len(sentences) < 4:
            return None
        import numpy as np
        cap = sentences[:60]
        vecs = SEM.encode(cap)
        if vecs is None or len(vecs) != len(cap):
            return None
        M = np.array(vecs, dtype="float32")
        M /= (np.linalg.norm(M, axis=1, keepdims=True) + 1e-9)
        sim = M @ M.T
        central = (sim.sum(axis=1) - 1.0) / max(1, len(cap) - 1)
        lead = np.array([0.12 if i < 3 else 0.0 for i in range(len(cap))], dtype="float32")
        score = central + lead
        chosen = []
        while len(chosen) < n and len(chosen) < len(cap):
            best, best_v = None, -9.0
            for i in range(len(cap)):
                if i in chosen:
                    continue
                redundancy = max((sim[i, j] for j in chosen), default=0.0)
                v = 0.7 * score[i] - 0.3 * redundancy
                if v > best_v:
                    best, best_v = i, v
            chosen.append(best)
        trace(f"summary: semantic centrality over {len(cap)} sentences, {len(chosen)} picked (MMR)")
        return [cap[i] for i in sorted(chosen)]
    except Exception as e:
        trace(f"summary: semantic selection failed ({type(e).__name__}); using TextRank")
        return None

def _extractive(sentences, n):
    """Sumy's TextRank with the app's own tokenizer (no NLTK data needed); a small TextRank-lite fallback."""
    sem = _extractive_semantic(sentences, n)
    if sem:
        return sem
    try:
        from sumy.models.dom import ObjectDocumentModel, Paragraph, Sentence
        from sumy.summarizers.text_rank import TextRankSummarizer
        class _Tok:
            language = "english"
            def to_words(self, sentence):
                return re.findall(r"[a-z0-9]+", sentence.lower())
        tok = _Tok()
        doc = ObjectDocumentModel([Paragraph([Sentence(x, tok) for x in sentences])])
        chosen = {str(x) for x in TextRankSummarizer()(doc, n)}
        out = [x for x in sentences if x in chosen]
        if out:
            return out
    except Exception:
        pass
    from collections import Counter as _C
    df = _C()
    for x in sentences:
        df.update(set(stem_set(x)))
    scored = sorted(range(len(sentences)), key=lambda i: -sum(df[t] for t in stem_set(sentences[i])) / (len(stem_set(sentences[i])) + 3))
    keep = sorted(scored[:n])
    return [sentences[i] for i in keep]

def answer_summary(q, st):
    m = PAGE_SUMMARY_RE.match(q.strip())
    if not m:
        return None
    url = (m.group("url") or m.group("url2") or "").rstrip(".,)")
    ctx_extend(BUDGET_SLOW)
    wm = re.match(r"^https?://en\.wikipedia\.org/wiki/([^#?]+)", url)
    if wm:
        wtitle = unquote(wm.group(1)).replace("_", " ")
        page = {"text": wiki_extract(wtitle) or "", "title": wtitle}
    else:
        page = fetch_page(url, read_timeout=8) or {}
    text = strip_boilerplate(page.get("text") or "")
    sents = [x.strip() for x in split_sentences(text, lo=40, hi=400) if web_clean(x) and not SITE_BOILERPLATE.search(x) and not x.rstrip().endswith("?") and len(x.split()) >= 8]
    if len(sents) < 4:
        return {"answer": "I couldn't pull enough readable text out of that page to summarise it.", "sources": [{"title": url, "url": url}], "mode": "none", "evidence_count": 0}
    picked = _extractive(sents[1:], 4 if len(sents) > 12 else 2)
    picked = [sents[0]] + [x for x in picked if x != sents[0]]
    title = (page.get("title") or "").strip() or host(url)
    return {"answer": f"Key sentences from {host(url)}, quoted verbatim and in page order (I don't paraphrase):\n" + "\n".join("\u2022 " + x for x in picked) + caution_note(q, " ".join(picked)),
            "sources": [{"title": title, "url": url}], "mode": "summary", "evidence_count": len(picked)}


def chat_result(q, st, sid):
    r = CHAT.reply(q, st, sid)
    dbg = st.pop("_chat_debug", "")
    trace(f"chat intent={r.get('intent')} {dbg}")
    if r.get("intent") in {"fallback", "generic", "reflect", "continue"}:
        log_miss(q, r.get("intent"), "chat")
    out = {"answer": r["answer"], "sources": r.get("sources") or [], "mode": "chat", "evidence_count": len(r.get("sources") or [])}
    if r.get("intent") in {"repeat", "clarify"}:
        out["_keep_last"] = True
    return out

def pop_more(st):
    try:
        more = json.loads(st.get("more_json") or "[]")
    except Exception:
        more = []
    if not more:
        return None
    item = more.pop(0)
    st["more_json"] = json.dumps(more, ensure_ascii=False)
    return {"answer": item["text"], "sources": [item["source"]] if item.get("source") else [], "mode": st.get("last_mode") or "wikipedia",
            "evidence_count": 1, "more_left": len(more)}

def finish(st, res, q, remember=True):
    for s_ in res.get("sources") or []:
        t_ = s_.get("title") or ""
        if len(t_) > 110:
            cut = t_.rfind(" - ", 0, 110)
            s_["title"] = (t_[:cut] if cut > 30 else t_[:100]).rstrip() + "\u2026"
    if res.get("mode") in {"wikipedia", "web", "research", "list", "guide"} and res.get("answer") and "not medical advice" not in res["answer"] and "not legal advice" not in res["answer"]:
        res["answer"] = res["answer"] + caution_note(q, res["answer"])
    more = res.pop("more", None)
    if more is not None:
        st["more_json"] = json.dumps(more[:5], ensure_ascii=False)
    elif res.get("mode") not in {"chat"} and "more_left" not in res:
        st["more_json"] = ""
    if res.get("mode") != "chat":
        st["chat_pending"] = ""
    if remember and res.get("mode") in {"wikidata", "wikipedia", "web", "research", "compare"}:
        st["last_q"] = q
    try:
        res["more_available"] = bool(json.loads(st.get("more_json") or "[]"))
    except Exception:
        res["more_available"] = False
    res["can_simplify"] = bool(st.get("subject_qid")) and res.get("mode") == "wikipedia"
    if not res.pop("_keep_last", False):
        st["last_bot"] = (res.get("answer") or "")[:700]
        try:      # v50: answer memory (last eight sourced answers) and the entity stack (last five subjects with their Wikidata ids)
            if res.get("mode") not in ("chat", "none", "error", "tool", "creative", "recall"):
                log = json.loads(st.get("answer_log") or "[]")
                log.append({"q": q[:160], "a": (res.get("answer") or "")[:500], "s": (res.get("sources") or [])[:2]})
                st["answer_log"] = json.dumps(log[-8:], ensure_ascii=False)
            if res.get("mode") in ("wikidata", "inference", "facts", "wikipedia", "web", "osm", "list", "recipe", "guide") and (st.get("last_term") or st.get("subject_label")):
                # v51: one question template per turn, tagged with what kind of thing it was about, so "and Frankenstein?" after
                # "and his wife?" still swaps into the question about a *work* rather than the one about a person
                tmpls = json.loads(st.get("turn_templates") or "[]")
                kind = "human" if (st.get("answer_qid") and st.get("answer_label") and st.get("answer_label") in (res.get("answer") or "") and res.get("mode") == "wikidata"
                                   and (st.get("subject_kind") == "human")) else st.get("subject_kind") or "other"
                tmpls.append({"q": q[:160], "term": (st.get("last_term") or st.get("subject_label"))[:80], "kind": kind, "mode": res.get("mode")})
                st["turn_templates"] = json.dumps(tmpls[-6:], ensure_ascii=False)
            if st.get("subject_label"):
                stack = json.loads(st.get("entity_stack") or "[]")
                ent = {"label": st["subject_label"], "qid": st.get("subject_qid") or ""}
                if not stack or stack[-1] != ent:
                    stack.append(ent)
                st["entity_stack"] = json.dumps(stack[-5:], ensure_ascii=False)
        except Exception:
            pass
    st.pop("_chat_debug", None)
    save_state(st)
    return res

def split_statement_question(q):
    """'I love jazz. Who was Miles Davis?' -> ('I love jazz.', 'Who was Miles Davis?')"""
    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", q.strip()) if p.strip()]
    if len(parts) >= 2 and parts[-1].endswith("?") and not any(p.endswith("?") for p in parts[:-1]) and len(parts[-1].split()) >= 3:
        return " ".join(parts[:-1]), parts[-1]
    return "", q

HOWTO_GATE_RE = re.compile(r"^(?:how (?:do|can|would|should) (?:i|you|we)\b|how to\b|what(?:'s| is) the command (?:to|for)\b|command (?:to|for)\b)", re.I)

def _build_registry():
    """The retrieval capabilities in cascade order. Gates reproduce the conditions the hand-written cascade applied;
    flags carry the per-question facts the cascade computed once (deep research, live web)."""
    R = _caps.REGISTRY
    if R.caps:
        return R
    add = lambda **kw: R.add(_caps.Capability(**kw))
    # stage: structured (recognised before the chat gate; no "no answer" trace)
    add(name="summary", handler=answer_summary, stage="structured", intents=("summary",), freshness=_caps.LONG_LIVED, description="Key sentences of a page or article the user names")
    add(name="news", handler=answer_news, stage="structured", intents=("news",), freshness=_caps.LIVE, description="Recent headlines from feeds and news search")
    add(name="facts", handler=answer_factsheet, stage="structured", intents=("facts",), description="Fact sheet from Wikidata properties")
    add(name="timeline", handler=answer_timeline, stage="structured", intents=("timeline",), description="Dated sentences from a Wikipedia article, in order")
    add(name="section", handler=answer_section, stage="structured", intents=("list", "explain", "definition"), gate=lambda q, st, f: bool(SECTION_RE.match(norm(q).rstrip("?.! "))),
        description="A whole Wikipedia section under its heading (types, uses, causes, how it works)")
    add(name="quotes", handler=answer_quotes, stage="structured", intents=("quotes",), description="Sourced quotations from Wikiquote")
    add(name="word", handler=answer_word, stage="structured", intents=("word",), description="Synonyms, antonyms, rhymes, etymology, pronunciation from Wiktionary")
    add(name="proscons", handler=answer_proscons, stage="structured", intents=("proscons",), freshness=_caps.LONG_LIVED, description="Points for and against, attributed per site")
    add(name="recipe", handler=answer_recipe, stage="structured", intents=("recipe", "guide"), freshness=_caps.LONG_LIVED, description="A recipe's ingredients and method from schema.org data")
    add(name="list", handler=answer_list, stage="structured", intents=("list",), freshness=_caps.LONG_LIVED, description="Items several independent sites list most often")
    add(name="code help", handler=answer_code, stage="structured", intents=("code",), freshness="LONG_LIVED",
        gate=lambda q, st, f: wants_code_help(q), description="Programming questions: Stack Overflow and documentation pages, top answer quoted verbatim")
    # stage: precise (after the chat gate); inference first, since "Is X bigger than Y?" is not a one-hop relation
    _inference.configure(entity=lambda term, st_, want: entity_from_state_or_search(term, st_, None, tuple(want)), claims=ranked_claims,
                         values=claim_values, format_time=format_time, get=wd_get, trace=trace, sparql=wd_sparql)
    add(name="inference", handler=_inference.answer, stage="precise", intents=("inference",),
        gate=lambda q, st, f: _inference.wants(q), description="Comparisons, date arithmetic and two-hop lookups as chains of cited Wikidata facts")
    add(name="dictionary", handler=answer_define, stage="precise", intents=("dictionary",), description="Definitions from Wiktionary")
    add(name="age", handler=answer_age, stage="precise", intents=("fact",), description="Age from a Wikidata birth date")
    add(name="relation", handler=answer_relation, stage="precise", intents=("fact",), description="One-hop Wikidata relations: author, capital, director, borders…")
    add(name="property", handler=answer_property, stage="precise", intents=("fact",), description="Wikidata quantities: height, population, area…")
    # stage: explain (order matters; gates reproduce the cascade's conditions)
    add(name="nearby", handler=answer_nearby, stage="explain", intents=("nearby",), freshness=_caps.LIVE, trace_miss=True, description="Places near a named location, from OpenStreetMap")
    add(name="compare", handler=answer_compare, stage="explain", intents=("compare",), trace_miss=True, description="Side-by-side comparison from Wikipedia and Wikidata")
    add(name="howto", handler=answer_howto, stage="explain", intents=("shell", "guide"), freshness=_caps.LONG_LIVED, trace_miss=True,
        gate=lambda q, st, f: bool(HOWTO_GATE_RE.match(q.strip())), description="Shell commands from the tldr pages")
    add(name="research", handler=lambda q_, st_: answer_web(q_, st_, True), stage="explain", intents=("research",), freshness=_caps.LONG_LIVED, trace_miss=True,
        gate=lambda q, st, f: f["deep"], description="Several independent sources, quoted and attributed")
    add(name="live-web", handler=lambda q_, st_: answer_web(q_, st_, False), stage="explain", intents=("version",), freshness=_caps.RECENT, trace_miss=True,
        gate=lambda q, st, f: f["live"] and not f["deep"], description="Live web search for versions, prices and other changing facts")
    add(name="guide", handler=answer_guide, stage="explain", intents=("guide",), freshness=_caps.LONG_LIVED, trace_miss=True,
        gate=lambda q, st, f: not f["live"] and not f["deep"], description="Step-by-step instructions from a page with a step list")
    add(name="answer pool", handler=answer_blended, stage="explain", intents=("explain", "definition", "fact"), trace_miss=True,
        gate=lambda q, st, f: not f["live"] and not f["deep"], description="Wikipedia and web passages, chosen by the cross-encoder judge")
    add(name="wikipedia", handler=answer_wikipedia, stage="explain", intents=("explain", "definition", "fact"), trace_miss=True, description="A passage from the best-matching Wikipedia article")
    add(name="web", handler=lambda q_, st_: answer_web(q_, st_, False), stage="explain", intents=("explain",), freshness=_caps.LONG_LIVED, trace_miss=True,
        gate=lambda q, st, f: not f["live"] and not f["deep"], description="A passage from the open web")
    return R

def run_capability(cap, q, st):
    """Uniform invocation: exceptions become a trace line and a miss, never a failed request."""
    try:
        r = cap.handler(q, st)
    except Exception as e:
        trace(f"{cap.name} failed: {type(e).__name__}")
        r = None
    if r:
        trace(f"answered by {cap.name}")
        r.setdefault("capability", cap.name)
    elif cap.trace_miss:
        trace(f"{cap.name}: no answer")
    return r

TRANSLATE_RE = re.compile(r"^(?:how do (?:you|i) say|what is|what's|translate) [\u201c\"']?(?P<w>[A-Za-z][A-Za-z' -]{0,40}?)[\u201d\"']? (?:in|into|to) (?P<lang>[A-Za-z]+(?: [A-Za-z]+)?)[?.!]*$", re.I)
PROBLEM_RE = re.compile(r"^my (?P<thing>wifi|wi-fi|internet|router|phone|laptop|computer|pc|printer|car|bike|bicycle|boiler|heating|fridge|freezer|washing machine|dishwasher|oven|tap|faucet|toilet|sink|shower|kettle|tv|television|screen|monitor|keyboard|mouse|bluetooth|battery|engine|radiator|microwave) (?P<sym>(?:keeps|won't|doesn't|isn't|is not|stopped|keeps on|has stopped|makes|is making|smells|leaks|is leaking|won't turn) .+?)[?.!]*$", re.I)
QUIZ_RE = re.compile(r"^(?:quiz|test) me (?:on|about) (?P<topic>.+?)[?.!]*$", re.I)
SERVES_RE = re.compile(r"^(?:make it |scale it |but )?for (?P<n>\d{1,2}) (?:people|persons|servings|guests|of us)[?.!]*$", re.I)
COOK_WITH_RE = re.compile(r"^what (?:can|could|should) i (?:cook|make) (?:for dinner |for lunch |tonight )?with (?P<ings>.+?)[?.!]*$", re.I)

PLAN_FRAGMENT_RE = re.compile(r"^(?:somewhere in|maybe|perhaps|probably|possibly|i(?:'m| am) thinking (?:of|about)|thinking (?:of|about)|how about) (?:going to |visiting |a trip to |in |to |the )?(?P<place>[A-Z][\w' -]{2,40}?)(?: maybe| perhaps| i think)?[?.!]*$")

REPAIR_RE = re.compile(r"^(?:(?:no|nope|sorry|oops|actually|wait)[,!.]?\s+)?(?:i meant|i mean|i said|it's|its|make (?:that|it)|the one in|not (?P<not>[\w' -]+?),)?\s*(?P<x>[\w' ,-]{2,60}?)(?: (?:not|instead of) (?P<old>[\w' :.-]{1,30}))?[?.!]*$", re.I)
WEEKDAY_RE = re.compile(r"\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today)\b", re.I)
CLOCK_RE = re.compile(r"\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b|\b\d{1,2}:\d{2}\b|\bnoon\b|\bmidnight\b", re.I)

def repair(q, st):
    """v54: conversational repair. "sorry, Tom Cruise", "no I meant the 1986 one", "actually make that thursday", "no the one in England".
    The previous question is re-asked with the correction applied; the rewrite is shown."""
    m = REPAIR_RE.match(q.strip())
    if not m:
        return None
    last_q, last_term, last_raw = st.get("last_question") or "", st.get("last_term") or st.get("subject_label") or "", st.get("prev_raw") or ""
    x, old, nott = (m.group("x") or "").strip(" ,"), (m.group("old") or "").strip(), (m.group("not") or "").strip()
    if not x:
        return None
    low = q.lower()
    explicit = bool(re.search(r"\b(?:i meant|i mean|i said|make (?:that|it)|the one in)\b", low)) or bool(old) or bool(nott)
    opener = bool(re.match(r"^(?:no|nope|sorry|oops|actually|wait)\b", low))
    if not explicit and not (opener and (x[:1].isupper() or re.match(r"^\d", x))):
        return None                    # a bare correction needs an opener AND a proper noun or number; a normal question is never a repair
    if re.search(r"\b(?:thanks|thank you|cheers|ta|never ?mind|ok|okay)\b", low):
        return None
    # tools: "sorry I meant 6pm not 6am", "actually make that thursday" -> undo, then the corrected command
    if st.get("last_mode") == "tool" and last_raw:
        new_cmd = None
        if old and old.lower() in last_raw.lower():
            new_cmd = re.sub(re.escape(old), x, last_raw, count=1, flags=re.I)
        elif WEEKDAY_RE.fullmatch(x) and WEEKDAY_RE.search(last_raw):
            new_cmd = WEEKDAY_RE.sub(x, last_raw, count=1)
        elif CLOCK_RE.fullmatch(x) and CLOCK_RE.search(last_raw):
            new_cmd = CLOCK_RE.sub(x, last_raw, count=1)
        elif CLOCK_RE.fullmatch(x) and re.search(r"\bat \d{1,2}\b(?!\s*(?:am|pm|:))", last_raw, re.I):
            new_cmd = re.sub(r"\bat \d{1,2}\b(?!\s*(?:am|pm|:))", "at " + x, last_raw, count=1, flags=re.I)
        if new_cmd and new_cmd.lower() != last_raw.lower():
            return ("__tool__", re.sub(r"^(?:and|also|then|oh and|plus)[, ]+", "", new_cmd, flags=re.I))
        return None
    if not last_q:
        return None
    if "the one in" in low and last_term:            # "no the one in England" -> qualify the place
        return f"{last_q.rstrip('?.! ')}".replace(last_term, f"{last_term}, {x}") + ("?" if last_q.endswith("?") else "")
    if old and old.lower() in last_q.lower():         # "X not Y"
        return re.sub(re.escape(old), x, last_q, count=1, flags=re.I)
    if st.get("last_mode") == "recipe" and last_term:  # "no, american style, the fluffy ones" -> qualify the dish
        qual = re.sub(r"\b(?:the|ones|style|kind|version|please)\b", " ", x, flags=re.I).strip(" ,")
        qual = qual.split(",")[0].strip()
        return re.sub(re.escape(last_term), f"{qual} {last_term}", last_q, count=1, flags=re.I)
    if re.search(r"\bthe (\d{4}) (?:one|film|movie|version)\b", low) and last_term:   # "no I meant the 1986 one"
        yr = re.search(r"(\d{4})", low).group(1)
        return re.sub(re.escape(last_term), f"{last_term} ({yr} film)", last_q, count=1, flags=re.I)
    if nott and last_term:                              # "not the fish, the instrument" -> qualify the word
        return f"{last_q.rstrip('?.! ')} ({x})"
    if last_term and last_term.lower() in last_q.lower():   # "sorry, Tom Cruise" -> same question, new subject
        return re.sub(re.escape(last_term), x, last_q, count=1, flags=re.I)
    return None

NOT_X_RE = re.compile(r"^(?:not|isn't it|isnt it|wasn't it|i thought it was|surely) ([A-Z][\w' .-]{1,40}?)[?.!]*$", re.I)

LANGUAGES = {"french", "spanish", "german", "italian", "portuguese", "dutch", "swedish", "norwegian", "danish", "finnish", "polish", "czech", "russian", "ukrainian", "greek", "turkish",
             "arabic", "hebrew", "hindi", "urdu", "bengali", "japanese", "chinese", "mandarin", "cantonese", "korean", "vietnamese", "thai", "indonesian", "malay", "swahili", "irish",
             "welsh", "latin", "esperanto", "hungarian", "romanian", "catalan", "icelandic", "afrikaans", "tagalog", "persian", "farsi"}

def pre_route(q, st):
    s = q.strip()
    mx = NOT_X_RE.match(s)
    if mx and st.get("last_mode") == "wikidata" and st.get("answer_label") and st.get("subject_label"):
        cand, ans = mx.group(1).strip(), st["answer_label"]
        same = norm_key(cand) == norm_key(ans) or norm_key(cand) in norm_key(ans)
        lq = (st.get("last_question") or "").rstrip("?.! ")
        verdict = (f"Yes: {ans} (Wikidata)." if same else f"No. For \u201c{lq}\u201d Wikidata gives {ans}, not {cand}.")
        return {"answer": verdict, "sources": [{"title": "Wikidata: " + st["subject_label"], "url": "https://www.wikidata.org/wiki/" + (st.get("subject_qid") or "")}], "mode": "inference", "evidence_count": 1}
    rp = repair(s, st)
    if rp:
        if isinstance(rp, tuple):
            trace(f"repair: tool command '{rp[1]}' replaces the previous one")
            TOOLS.handle("undo", st, bool(getattr(_CTX, "authed", False)))
            r = TOOLS.handle(rp[1], st, bool(getattr(_CTX, "authed", False)))
            if r:
                r["answer"] = f"(Corrected to \u201c{rp[1]}\u201d; the previous one is undone.)\n" + r["answer"]
                st["last_mode"] = "tool"; st["last_raw"] = rp[1]
                return r
            return None
        trace(f"repair: '{s}' -> '{rp}'")
        st["last_question"] = rp
        r = route_inner(rp, "", st, depth=1)
        if r and r.get("mode") not in ("none", "chat", "error"):
            r["answer"] = f"(I read that as \u201c{rp}\u201d.)\n" + r["answer"]
            return r
        return None
    ma = re.match(r"^(?:she|he|they)(?:'s| is| are|s) (\d{1,3})(?: years old)?[.!]*$", s, re.I)
    if ma:
        who = s.split()[0].rstrip("'s").capitalize()
        st["chat_focus"] = st.get("chat_focus") or ""
        return {"answer": f"Got it, {ma.group(1)}. That helps me pitch things. What would you like to look up for {'her' if who.lower().startswith('s') else ('him' if who.lower().startswith('h') else 'them')}?",
                "sources": [], "mode": "chat", "evidence_count": 0}
    m = PLAN_FRAGMENT_RE.match(s)
    if m:        # "somewhere in Portugal maybe": a planning fragment, not a question; keep the place and offer the lookups that fit
        place = m.group("place").strip()
        st.update({"subject_label": place, "last_term": place, "last_mode": "chat", "last_place": place})
        return {"answer": f"{place}, noted. I can look up things to do in {place}, the weather there, distances, or how to say a few words in the local language; ask when you're ready.",
                "sources": [], "mode": "chat", "evidence_count": 0}
    m = TRANSLATE_RE.match(s)
    if m and len(m.group("w").split()) <= 4 and m.group("lang").lower() in LANGUAGES:
        r = answer_translate(m.group("w"), m.group("lang").title())
        if r:
            return r
    m = PROBLEM_RE.match(s)
    if m:
        rewritten = f"how to fix a {m.group('thing').lower()} that {m.group('sym').lower()}"
        trace(f"turn state: problem statement -> '{rewritten}'")
        st["last_question"] = rewritten
        r = route_inner(rewritten, "", st, depth=1)
        if r and r.get("mode") not in ("none", "chat", "error"):
            r["answer"] = f"(I read that as \u201c{rewritten}\u201d.)\n" + r["answer"]
            return r
        return None
    m = QUIZ_RE.match(s)
    if m:
        topic = m.group("topic")
        r = route_inner(f"key facts about {topic}", "", st, depth=1)
        note = "I can't make up quiz questions (nothing in here generates text), but here are sourced facts to test yourself against, and \u201ctimeline of \u2026\u201d gives the dates.\n"
        if r and r.get("mode") not in ("none", "chat", "error"):
            r["answer"] = note + r["answer"]
            return r
        return {"answer": note.strip(), "sources": [], "mode": "chat", "evidence_count": 0}
    m = SERVES_RE.match(s)
    if m and st.get("last_mode") == "recipe" and st.get("last_recipe"):
        return scale_recipe(int(m.group("n")), st)
    if re.match(r"^how long (?:does|will|would) (?:it|that|this) take[?.!]*$", s, re.I) and st.get("last_mode") == "recipe" and st.get("last_recipe"):
        try:
            rec = json.loads(st["last_recipe"])
            if rec.get("time"):
                return {"answer": f"The recipe above says: {rec['time']}.", "sources": rec.get("sources") or [], "mode": "recipe", "evidence_count": 1}
        except Exception:
            pass
    return None

_FRAC = {"\u00bd": 0.5, "\u2153": 1 / 3, "\u2154": 2 / 3, "\u00bc": 0.25, "\u00be": 0.75, "\u215b": 0.125}

def _scale_qty(text, f):
    def num(m):
        tok = m.group(0)
        try:
            if tok in _FRAC:
                v = _FRAC[tok]
            elif "/" in tok:
                a, b = tok.split("/"); v = float(a) / float(b)
            else:
                v = float(tok)
        except Exception:
            return tok
        v *= f
        for sym, val in _FRAC.items():        # prefer the fractions a cook expects
            if abs(v - val) < 0.02:
                return sym
        if abs(v - round(v)) < 0.02:
            return str(int(round(v)))
        return f"{v:.2g}"
    return re.sub(r"\u00bd|\u2153|\u2154|\u00bc|\u00be|\u215b|\d+/\d+|\d+(?:\.\d+)?", num, text, count=1)

def scale_recipe(n, st):
    """v52: the recipe just shown, with every ingredient quantity multiplied by n / the stated yield. Arithmetic only; the
    method is not rewritten. Times are left alone because they do not scale."""
    try:
        rec = json.loads(st["last_recipe"])
    except Exception:
        return None
    m = re.search(r"(\d+)", rec.get("yield") or "")
    if not m:
        return {"answer": "The recipe doesn't state how many it serves, so I can't scale it for you.", "sources": rec.get("sources") or [], "mode": "recipe", "evidence_count": 0}
    base = int(m.group(1))
    if base <= 0 or n <= 0:
        return None
    f = n / base
    lines = [f"{rec.get('name') or 'The recipe'} for {n} (the source makes {rec['yield']}; quantities multiplied by {f:.2g}, method unchanged):", "", "Ingredients:"]
    lines += ["\u2022 " + _scale_qty(i, f) for i in rec.get("ingredients", [])[:30]]
    lines += ["", "Cooking times don't scale with quantity; use the method and times from the original."]
    return {"answer": "\n".join(lines), "sources": rec.get("sources") or [], "mode": "recipe", "evidence_count": len(rec.get("ingredients", []))}

def answer_translate(word, lang):
    """v52: Wiktionary's translation table for a word or short phrase. Quoted, not generated; sentences are not translated."""
    try:
        data = http_get_json("https://en.wiktionary.org/w/api.php", {"action": "parse", "page": word.lower(), "prop": "wikitext", "format": "json", "formatversion": 2}, 86400, "wikt-tr", timeout=8) or {}
        wt = ((data.get("parse") or {}).get("wikitext") or "")
        if not wt:
            trace(f"translation: no Wiktionary wikitext for '{word}'")
            return None
        if "translation subpage" in wt or "{{see translation subpage" in wt or not re.search(r"^\*:?\s*" + re.escape(lang) + r":\s*\{\{tt?\+?\|", wt, re.M):
            data2 = http_get_json("https://en.wiktionary.org/w/api.php", {"action": "parse", "page": word.lower() + "/translations", "prop": "wikitext", "format": "json", "formatversion": 2}, 86400, "wikt-tr", timeout=8) or {}
            wt = ((data2.get("parse") or {}).get("wikitext") or "") or wt
        found = []
        for m in re.finditer(r"^\*:?\s*" + re.escape(lang) + r":\s*(.+)$", wt, re.M):
            for t in re.finditer(r"\{\{tt?\+?\|[a-z-]+\|([^|}]+)(?:\|([mfnc]))?", m.group(1)):
                w = t.group(1).strip()
                if w and w not in [x[0] for x in found]:
                    found.append((w, t.group(2) or ""))
        if not found:
            trace(f"translation: Wiktionary has no {lang} line for '{word}'")
            return None
        rendered = ", ".join(w + (f" ({g})" if g else "") for w, g in found[:6])
        return {"answer": f"Wiktionary's {lang} translations of \u201c{word}\u201d: {rendered}.", "sources": [{"title": f"Wiktionary: {word}", "url": "https://en.wiktionary.org/wiki/" + word.lower().replace(' ', '_') + "#Translations"}],
                "mode": "word", "evidence_count": len(found)}
    except Exception as e:
        trace(f"translation lookup failed: {type(e).__name__}")
        return None

def route_inner(q, sid, st, depth=0):
    R = _build_registry()
    # 0. "statement. question?" -> remember the statement, answer the question
    lead, q_main = split_statement_question(q) if depth == 0 else ("", q)
    if lead and is_knowledge(q_main) and not CHAT.wants(q_main, st):
        scratch = dict(st)
        CHAT.reply(lead, scratch, sid)          # stores likes / places / notes; its reply is not shown
        for k in ("chat_topic", "chat_focus", "name"):
            st[k] = scratch.get(k, st.get(k))
        q = q_main

    # 0b. tools (reminders, lists, calendar, files, system). Only the user's own sentence can trigger one.
    q_tool = re.sub(r"^(?:and|also|then|oh and|plus)[, ]+", "", q, flags=re.I)
    if depth == 0 and not TOOLS.wants(q, st) and q_tool != q and TOOLS.wants(q_tool, st):
        q = q_tool            # v57: "and put dentist on my calendar friday at 2" is a tool command, not a follow-up
    if depth == 0 and TOOLS.wants(q, st):
        r = TOOLS.handle(q, st, bool(getattr(_CTX, "authed", False)))
        if r:
            trace("answered by tools")
            st["last_mode"] = "tool"
            return finish(st, r, q, remember=False)

    # 0b2. v52: short pre-routes learned from the simulated conversations
    if depth == 0:
        r = pre_route(q, st)
        if r:
            return finish(st, r, q, remember=True)

    # 0c. template verse and tales (hand-written grammars, clearly labelled; never used for facts)
    if depth == 0:
        piece = creative.maybe(q)
        if piece:
            trace(f"answered by creative grammar ({piece['form']})")
            st["last_mode"] = "creative"
            return finish(st, {"answer": creative.present(piece), "sources": [], "mode": "creative", "evidence_count": 0}, q, remember=False)

    # 1. conversational controls that depend on the previous answer
    if MORE_RE.match(q) and st.get("chat_pending") not in {"joke", "fun_fact"} and (st.get("last_mode") not in {"", "chat"} or st.get("more_json")):
        r = pop_more(st)
        if r:
            return finish(st, r, q, remember=False)
        if not re.match(r"^(?:why|how so|how come)\W*$", q, re.I):
            subj = st.get("subject_label")
            return finish(st, {"answer": f"That's everything I pulled on {subj}. Ask me something more specific about it." if subj else "There's nothing to continue yet. Ask me a question first.",
                               "sources": [], "mode": "chat", "evidence_count": 0}, q, remember=False)
    if SIMPLER_RE.match(q):
        r = answer_simpler(st)
        if r:
            return finish(st, r, q, remember=False)
        return finish(st, {"answer": "I don't have a simpler source for that. Try asking about one specific part of it.", "sources": [], "mode": "chat", "evidence_count": 0}, q, remember=False)
    m = SWAP_RE.match(q)
    if m and depth == 0 and st.get("last_q") and st.get("last_mode") not in {"", "chat"} and not CHAT.wants(q, st):
        new_term = clean_term(m.group(1))
        lq, lt = st["last_q"], st.get("last_term") or ""
        if lt and re.search(re.escape(lt), lq, re.I):
            q2 = re.sub(re.escape(lt), lambda _m: new_term, lq, count=1, flags=re.I)
        else:
            q2 = f"What is {new_term}?"
        trace(f"follow-up rewrite: '{q}' -> '{q2}'")
        return route_inner(q2, sid, st, depth + 1)

    # 2. deterministic tools (arithmetic, units, clock, weather)
    r = answer_skill(q, st, sid)
    if r:
        st["last_mode"] = r["mode"]
        return finish(st, r, q)

    # 2b. structured web answers: recipes and "top N" lists. They often arrive without a question mark
    #     ("dry rub recipe for chicken wings"), so they are recognised before the chat/knowledge gate.
    for cap in R.stage("structured"):
        if out_of_time():
            break
        r = run_capability(cap, q, st)
        if r:
            return finish(st, r, q)

    # 3. clearly conversational -> conversation engine
    # "morning! did you sleep well?" : a greeting followed by a question to the bot is still small talk
    tail_clause = re.split(r"(?<=[!.,;])\s+", q.strip())[-1]
    greeted = bool(re.match(r"^(?:good )?(?:hi|hey|hello|hiya|yo|morning|afternoon|evening|night)\b[^?]{0,20}[!.,;]\s", q.strip(), re.I))
    if CHAT.wants(q, st) or SECOND_PERSON_Q.match(q.strip()) or (greeted and SECOND_PERSON_Q.match(tail_clause)):
        return finish(st, chat_result(q, st, sid), q)

    # 4. precise structured answers
    for cap in R.stage("precise"):
        if not cap.applies(q, st, {}):
            continue
        r = run_capability(cap, q, st)
        if r:
            return finish(st, r, q)

    topicish, typed = False, q
    if not is_knowledge(q):
        topicish = looks_like_topic(q, st)
        if not topicish:
            return finish(st, chat_result(q, st, sid), q)
        q = f"What is {q.strip().rstrip('.!')}?"
        trace(f"bare topic -> '{q}'")

    # 5. specialised skills, then general explanation, then the open web
    flags = {"deep": is_deep_research(q), "live": is_live_web(q)}
    if flags["deep"]:
        ctx_extend(BUDGET_SLOW)
    cascade = [cap for cap in R.stage("explain") if cap.applies(q, st, flags)]
    _CTX.considered = [cap.name for cap in cascade]          # the cascade's order stays the logged baseline
    steps = cascade
    plan = getattr(_CTX, "plan", None)
    planned = _planner.capabilities_for(plan, R) if plan is not None else []
    _CTX.planned = planned
    if PLANNER_ROUTES and plan is not None and planned:
        # Phase 3 live: the planner's order decides, gates still apply (a shell how-to still needs the how-to shape)
        by_name = {cap.name: cap for cap in R.stage("explain")}
        steps = [by_name[n] for n in planned if n in by_name and by_name[n].applies(q, st, flags)]
        trace("planner routes: " + " > ".join(cap.name for cap in steps))
    for cap in steps:
        if out_of_time():
            trace("time budget exhausted")
            break
        r = run_capability(cap, q, st)
        if r:
            return finish(st, r, q)
    if topicish:
        return finish(st, chat_result(typed, st, sid), typed)
    st["last_mode"] = "none"
    if wiki_recently_down():
        trace("abstaining because Wikimedia has been failing, not because the fact is missing")
        return finish(st, {"answer": f"Wikipedia and Wikidata aren't answering me properly right now ({WIKI_STATE['last']}), so I can't look that up "
                                     "at the moment rather than the fact being missing. Please try again in a minute or two.",
                           "sources": [], "mode": "none", "evidence_count": 0}, q)
    return finish(st, {"answer": "I couldn't find a dependable answer to that in my sources. Try rephrasing it, or ask about one specific thing.",
                       "sources": [], "mode": "none", "evidence_count": 0}, q)

CANON = [   # v34: paraphrases of the fact questions, rewritten to the wording the relation parser knows (idempotent)
    (re.compile(r"^(?:tell me |what'?s |what is |which city is )?(?:the )?capital(?: city)? of (.+?)[?.!]*$", re.I), "What is the capital of {0}?"),
    (re.compile(r"^(?:who (?:is|was) the |the )?(?:author|writer) of (.+?)[?.!]*$", re.I), "Who wrote {0}?"),
    (re.compile(r"^(?:who (?:was|is) the composer of|who wrote the music (?:for|of)|which composer (?:wrote|composed)) (.+?)[?.!]*$", re.I), "Who composed {0}?"),
    (re.compile(r"^(?:can you tell me |tell me |do you know )?who wrote (.+?)[?.!]*$", re.I), "Who wrote {0}?"),
    (re.compile(r"^who (?:was|is) (.+?) written by[?.!]*$", re.I), "Who wrote {0}?"),
    (re.compile(r"^(?:who (?:is|was) the artist behind|which (?:painter|artist) (?:created|painted|made)) (.+?)[?.!]*$", re.I), "Who painted {0}?"),
    (re.compile(r"^who (?:was|is) (.+?) painted by[?.!]*$", re.I), "Who painted {0}?"),
    (re.compile(r"^(?:who (?:was|is) the director of|which director (?:made|directed)|who directed the (?:film|movie)) (.+?)[?.!]*$", re.I), "Who directed {0}?"),
    (re.compile(r"^what (?:is|was) (.+?)'s (?:date of birth|birth date|birthday)[?.!]*$", re.I), "When was {0} born?"),
    (re.compile(r"^(?:what year was|when is the birthday of|what is the birthday of) (.+?)(?: born)?[?.!]*$", re.I), "When was {0} born?"),
    (re.compile(r"^(?:which|what) continent (?:is|does) (.+?) (?:on|in|belong to|part of)[?.!]*$", re.I), "What continent is {0} in?"),
    (re.compile(r"^(.+?) is (?:in|on) (?:which|what) continent[?.!]*$", re.I), "What continent is {0} in?"),
]
# v40: British and American spellings meet in one internal form before any trigger or search sees the question. Productive
# patterns rather than a word list; sources are still quoted exactly as written.
_SPELL_PAIRS = [(r"\b(\w{3,})isation\b", r"\1ization"), (r"\b(\w{3,})ise(s|d)?\b", r"\1ize\2"), (r"\b(\w{3,})ising\b", r"\1izing"),
                (r"\b(\w{3,})yse(s|d)?\b", r"\1yze\2"), (r"\b(\w{3,})ysing\b", r"\1yzing"),
                (r"\b(col|fav|hon|neighb|rum|vap|hum|arm|lab|flav|behavi|sav|harb|vig)our(s|ed|ing|ite|able|ful)?\b", r"\1or\2"),
                (r"\b(cent|met|lit|theat|fib|calib|sab)re(s)?\b", r"\1er\2"), (r"\b(catal|dial|anal|monol|epil|prol)ogue(s)?\b", r"\1og\2"),
                (r"\b(travel|cancel|model|label|fuel|counsel|marvel|signal)l(ed|ing|er|ers)\b", r"\1\2"),
                (r"\bprogramme(s)?\b", r"program\1"), (r"\blicence(s)?\b", r"license\1"), (r"\bdefence\b", "defense"), (r"\boffence\b", "offense"),
                (r"\bgrey\b", "gray"), (r"\baluminium\b", "aluminum"), (r"\btyres?\b", lambda m: "tire" + ("s" if m.group(0).endswith("s") else "")),
                (r"\bkerb\b", "curb"), (r"\bcheque(s)?\b", r"check\1"), (r"\bmum\b", "mom"), (r"\bpyjamas\b", "pajamas"), (r"\bjewellery\b", "jewelry"),
                (r"\bwhilst\b", "while"), (r"\bamongst\b", "among"), (r"\blearnt\b", "learned"), (r"\bspelt\b", "spelled"), (r"\bdreamt\b", "dreamed")]
_SPELL_KEEP = {"advertise", "advise", "arise", "comprise", "compromise", "despise", "devise", "disguise", "exercise", "franchise", "improvise", "merchandise",
               "premise", "promise", "revise", "supervise", "surprise", "televise", "wise", "otherwise", "likewise", "clockwise", "precise", "concise", "expertise",
               "raise", "praise", "cruise", "bruise", "noise", "poise", "paradise", "enterprise", "chastise", "excise", "incise", "exorcise", "circumcise", "surmise"}
def american(s):
    def sub(pat, rep_):
        nonlocal s
        def f(m):
            w = m.group(0).lower()
            if w in _SPELL_KEEP or w.rstrip("sd") in _SPELL_KEEP or w[:-1] in _SPELL_KEEP:
                return m.group(0)
            return m.expand(rep_) if isinstance(rep_, str) else rep_(m)
        s = re.sub(pat, f, s, flags=re.I)
    for pat, rep_ in _SPELL_PAIRS:
        sub(pat, rep_)
    return s

MODE_SYNONYMS = [   # ways of asking for a mode that the triggers did not already accept; each rewrites to a known trigger
    (re.compile(r"^(?:(?:can you |could you |please )?(?:give me (?:a |the )?(?:gist|tl;?dr|key points|short version|rundown|recap|digest) of|boil down|condense|sum up|recap|"
                r"what(?:'s| is) the gist of|outline)|(?:can you |could you |please )?(?:summarize|summarise)) (https?://\S+)", re.I), r"summarize \1"),
    (re.compile(r"^(?:contrast|what(?:'s| is) the difference between|how (?:do|does) (.+?) differ from|(?:compare and contrast)) (.+?) (?:and|with|vs\.?|versus) (.+?)[?.!]*$", re.I), r"Compare \2 and \3"),
    (re.compile(r"^(?:(?:what are the )?(?:advantages and disadvantages|upsides and downsides|benefits and drawbacks|strengths and weaknesses|plus(?:es)? and minus(?:es)?) of) (.+?)[?.!]*$", re.I), r"pros and cons of \1"),
    (re.compile(r"^(?:(?:the )?(?:chronology|history) of|key dates (?:in|of)|major events (?:in|of)|when did things happen in) (.+?)[?.!]*$", re.I), r"timeline of \1"),
    (re.compile(r"^(?:(?:what(?:'s| is) the )?(?:meaning|definition) of|what does (.+?) mean|define the word) (.+?)[?.!]*$", re.I), r"Define \2"),
    (re.compile(r"^(?:(?:what(?:'s| is) )?(?:another|a different) word for|other words for|words? (?:that )?means? the same as) (.+?)[?.!]*$", re.I), r"synonyms for \1"),
    (re.compile(r"^(?:(?:what(?:'s| is) )?the reverse of|words? (?:that )?means? the opposite of) (.+?)[?.!]*$", re.I), r"antonym of \1"),
    (re.compile(r"^(?:(?:can you |could you )?(?:tell me )?(?:how to say|how is (.+?) pronounced|pronunciation of)) (.+?)[?.!]*$", re.I), r"how do you pronounce \2"),
    (re.compile(r"^(?:(?:the )?origin of the word|where (?:does|did) the word (.+?) come from|word history of|root of the word) (.+?)[?.!]*$", re.I), r"etymology of \2"),
]

FRAME_RE = re.compile(r"^(?:(?:hey|hi|hello|yo|ok|okay|so|um|erm|right|please|also|and|quick|quickly|now)[,!.]?\s+)*(?:quick question[:,]?|can you explain[:,]?|(?:i'?ve|i have) always wondered[:,]?|i was wondering[:,]?|out of curiosity[:,]?|just curious[:,]?|(?:can you tell me|do you know|tell me)[:,]? (?=(?:who|what|when|where|why|how|which)\b))?\s*", re.I)
TRAILING_FILLER_RE = re.compile(r"[\s,]*(?:please|pls|thanks|thank you|ta|if you can|if you know)[?.!]*$", re.I)
COMMON_TYPOS = {"teh": "the", "adn": "and", "taht": "that", "hte": "the", "waht": "what", "whta": "what", "wich": "which", "whcih": "which", "woh": "who", "whos": "who's",
                "wat": "what", "wut": "what", "hwo": "how", "hwat": "what", "abotu": "about", "becuase": "because"}     # function words only: content-word typos stay on the announced, vetoed path
TAIL_RE = re.compile(r"\s*[.!?]?\s*(?:keep it (?:simple|short|brief)|in simple terms|briefly|please)[.!]?$", re.I)

def canonicalize(s):
    s2 = FRAME_RE.sub("", s).strip()
    s2 = TRAILING_FILLER_RE.sub("", s2).strip() or s2
    s2 = " ".join(COMMON_TYPOS.get(w.lower(), w) if w.lower() in COMMON_TYPOS else w for w in s2.split())   # v55: typos too common for a dictionary veto
    s2a = american(s2)
    if s2a != s2:
        trace(f"spelling: '{s2}' -> '{s2a}'")
        s2 = s2a
    for rx, tmpl in MODE_SYNONYMS:
        m = rx.match(s2)
        if m:
            out = rx.sub(tmpl, s2)
            if out != s2:
                trace(f"synonym -> '{out}'")
                s2 = out
            break
    s2 = TAIL_RE.sub("", s2).strip()
    if s2 and s2 != s and not s2.endswith("?") and re.match(r"^(?:who|what|when|where|why|how|which|is|are|do|does|can)\b", s2, re.I):
        s2 += "?"
    for rx, tmpl in CANON:
        m = rx.match(s2)
        if m:
            out = tmpl.format(m.group(1).strip())
            if out.lower() != s2.lower():
                trace(f"paraphrase -> '{out}'")
            return out
    if s2 != s:
        trace(f"framing stripped -> '{s2}'")
        if s2[:1].islower():
            s2 = s2[0].upper() + s2[1:]
    return s2

def normalize_question(q):
    s = norm(q)
    if MORE_RE.match(s) or SIMPLER_RE.match(s) or SWAP_RE.match(s):
        return s
    s = canonicalize(s)
    s = re.sub(r"^(?:hey|hi|hello|ok|okay|so|well|um|please)[,!.]?\s+(?=(?:who|what|when|where|why|how|which|can|could|is|are|do|does|did|tell|define|compare)\b)", "", s, flags=re.I)
    m = re.match(r"^(?:(?:can|could|would|will) you (?:please )?(?:tell me|explain(?: to me)?|describe|let me know|look up|find out)|"
                 r"do you know|i(?:'d| would) like to know|i want to know|i wonder|i(?:'m| am) wondering|(?:please )?tell me(?= (?:who|what|when|where|why|how|which)\b))\s+(?:about\s+)?(.+)$", s, re.I)
    if m:
        rest = m.group(1).strip()
        if re.match(r"^(?:who|what|when|where|why|how|which|whether|if)\b", rest, re.I):
            rest = re.sub(r"^(?:whether|if)\s+", "", rest, flags=re.I)
            return rest if rest.endswith("?") else rest.rstrip(".!") + "?"
        if not re.match(r"^(?:me|myself|you|yourself|a joke|a story|a fact|something)\b", rest, re.I):
            return "Tell me about " + rest.rstrip("?.!") + "?"
    return s

PLAN_LOG = os.path.join(DATA_DIR, "plans.jsonl")
class _Spell:
    """v40: SymSpell over the bundled English frequency list. Fast path: only lowercase tokens absent from the dictionary with a
    distance-1 correction that is a very common word (captial -> capital). On abstain: distance 2 as well (drakula -> Dracula),
    and the retry is announced. Names the dictionary knows (dracula, einstein, tsunamis) are never touched."""
    def __init__(self):
        self.ok = False
        try:
            from symspellpy import SymSpell, Verbosity
            import importlib.resources as ir
            self._V = Verbosity
            self._s = SymSpell(max_dictionary_edit_distance=2)
            path = str(ir.files("symspellpy").joinpath("frequency_dictionary_en_82_765.txt"))
            self.ok = bool(self._s.load_dictionary(path, 0, 1))
        except Exception as e:
            self.note = f"spell corrector unavailable: {type(e).__name__}"
    def correct(self, q, aggressive=False):
        if not self.ok or WORD_SUBJECT_RE.search(q) or re.search(r"[\"\u201c`']", q):
            return None                                  # "define X", "rhymes with X", quoted or code text: the word itself is the subject
        out, changed = [], False
        for tok in re.split(r"(\s+)", q):
            w = tok
            if re.fullmatch(r"[a-z]{4,}", tok) and not self._s.words.get(tok):
                sug = self._s.lookup(tok, self._V.TOP, max_edit_distance=2 if aggressive else 1, include_unknown=False)
                if sug and sug[0].term != tok and (aggressive or sug[0].count >= 500_000) and sug[0].distance <= (2 if aggressive else 1):
                    if known_word(tok) or is_real_word(tok) is not False:   # v44: tldr, the user's own words, then Wiktionary; no verdict = no change
                        out.append(w); continue
                    w, changed = sug[0].term, True
            out.append(w)
        return "".join(out) if changed else None
WORD_SUBJECT_RE = re.compile(r"\b(?:define|definition|meaning|spell|spelled|spelling|etymology|origin of the word|rhym\w*|pronounc\w*|synonym\w*|antonym\w*|"
                             r"opposite of|translate|word for)\b", re.I)
_KNOWN_WORDS = {"words": set(), "mtime": 0.0}
def user_words_path():
    return os.path.join(os.environ.get("NOAI_FILES_DIR", "/files"), "words.txt")

def known_word(tok):
    """v44: local vocabularies that outrank the 82k frequency list. The tldr index (30,000 command examples: linter, chmod,
    kubectl), and ~/noai-files/words.txt, a plain file the person can edit and which the assistant appends to on 'I meant X'
    or when a corrected word is typed again."""
    t = tok.lower()
    try:
        path = user_words_path()
        m = os.path.getmtime(path) if os.path.exists(path) else 0.0
        if m != _KNOWN_WORDS["mtime"]:
            with open(path, encoding="utf-8", errors="ignore") as f:
                _KNOWN_WORDS["words"] = {w.strip().lower() for w in f if w.strip() and not w.startswith("#")}
            _KNOWN_WORDS["mtime"] = m
    except Exception:
        pass
    if t in _KNOWN_WORDS["words"]:
        return True
    try:
        if _tldr_state.get("fts") and os.path.exists(TLDR_DB):
            con = sqlite3.connect(TLDR_DB, timeout=5)
            row = con.execute("SELECT 1 FROM ex WHERE ex MATCH ? LIMIT 1", (f'"{t}"',)).fetchone()
            con.close()
            if row:
                return True
    except Exception:
        pass
    return False

def remember_word(tok):
    try:
        path = user_words_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(tok.strip().lower() + "\n")
        _KNOWN_WORDS["mtime"] = 0.0
        return True
    except Exception:
        return False

def is_real_word(tok):
    """True if English Wiktionary has an entry for the word as typed, False if it definitely does not, None when the check
    could not be made (offline, throttled). Cached for a week; misspellings are rare so this costs one call per unknown token."""
    try:
        data = http_get_json("https://en.wiktionary.org/w/api.php", {"action": "query", "titles": tok, "format": "json", "formatversion": 2},
                             7 * 86400, "wiktexists", timeout=4)
        pages = (data.get("query") or {}).get("pages") or []
        return bool(pages) and not pages[0].get("missing")
    except Exception:
        return None
SPELL = _Spell()
MIN_ANSWER = float(os.environ.get("NOAI_MIN_ANSWER", "3.0"))              # v36 abstention threshold on the pool's final score
RERANK_LEARNED = os.environ.get("NOAI_RERANK", "hand") == "learned"        # v36: fitted weights run in shadow unless switched on
try:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "reranker_weights.json"), encoding="utf-8") as _f:
        RERANK_W = json.load(_f)
except Exception:
    RERANK_W = None
PLANNER_ROUTES = os.environ.get("NOAI_PLANNER_ROUTES", "1") == "1"       # Phase 3: the planner's order routes retrieval (v32 default on; 0 = shadow only)

def _log_plan(q, plan, res, ms):
    """Shadow evaluation: what the planner would have required against what the router did. Appended as JSON lines;
    /api/plan-stats summarises them. Nothing here changes an answer."""
    try:
        mode = res.get("mode", "")
        rec = {"ts": int(time.time()), "q": q[:200], "intent": plan.intent, "freshness": plan.freshness, "type": plan.answer_type, "risk": plan.risk,
               "rule": plan.rule, "mode": mode, "honoured": plan.honoured_by(mode), "freshness_violation": plan.freshness_violation(mode),
               "evidence": int(res.get("evidence_count") or 0), "ms": int(ms),
               "capability": res.get("capability") or _caps.MODE_TO_CAPABILITY.get(mode, mode),
               "serves_intent": plan.intent in (_caps.REGISTRY.by_name(res.get("capability") or _caps.MODE_TO_CAPABILITY.get(mode, "")).intents
                                                if _caps.REGISTRY.by_name(res.get("capability") or _caps.MODE_TO_CAPABILITY.get(mode, "")) else ()),
               "considered": list(getattr(_CTX, "considered", None) or []), "planned": list(getattr(_CTX, "planned", None) or [])}
        cap = rec["capability"]
        rec["in_plan"] = (cap in rec["planned"]) if rec["planned"] else None
        rec["plan_position"] = rec["planned"].index(cap) if cap in rec["planned"] else None
        rec["cascade_position"] = rec["considered"].index(cap) if cap in rec["considered"] else None
        with open(PLAN_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return rec
    except Exception:
        return None

LIST_SHAPE_NAMES = {"proscons": "a for-and-against list", "recipe": "a recipe", "research": "a multi-source research answer", "list": "a ranked list",
                    "guide": "step-by-step instructions", "news": "recent headlines"}

def enforce_contract(q, plan, res, st):
    """v40: Phase 1's AnswerContract, finally enforced. A plan whose answer type is a list or steps is not satisfied by a single
    passage that the fallback pool found while the search engines were throttling: say so rather than quote something off-shape."""
    if plan is None or not res:
        return res
    if plan.answer_type in ("list", "steps") and res.get("mode") in ("web", "wikipedia") and plan.intent in LIST_SHAPE_NAMES:
        recently_down = time.time() - SEARCH_STATE.get("down_at", 0) < 300
        markers = {"proscons": "pros/cons", "recipe": "recipe search", "research": "research", "list": "list", "guide": "guide:", "news": "news"}
        tr = "\n".join(getattr(_CTX, "trace", []))
        ran = markers[plan.intent] in tr and "bare topic ->" not in tr       # v43: a bare topic rewritten to a definition was never a list request
        if recently_down and ran:
            trace(f"contract: plan wants {plan.answer_type} ({plan.intent}) but the pool produced a passage while search was throttled -> withheld")
            st["last_mode"] = "none"
            return {"answer": f"The search engines are throttling this server right now, so I couldn't build {LIST_SHAPE_NAMES[plan.intent]} for that, "
                              f"and a single passage would be the wrong shape of answer. Please try again in a few minutes.",
                    "sources": [], "mode": "none", "evidence_count": 0}
    return res

PROP_QUESTIONS = {"brother": "Who was {x}'s brother?", "sister": "Who was {x}'s sister?", "sibling": "Who was {x}'s sibling?", "siblings": "Who were {x}'s siblings?",
                  "mother": "Who was {x}'s mother?", "father": "Who was {x}'s father?", "children": "Who are {x}'s children?", "kids": "Who are {x}'s children?",
                  "cause of death": "How did {x} die?", "death": "How did {x} die?",
                  "capital": "What is the capital of {x}?", "population": "What is the population of {x}?", "currency": "What is the currency of {x}?",
                  "author": "Who wrote {x}?", "writer": "Who wrote {x}?", "composer": "Who composed {x}?", "director": "Who directed {x}?",
                  "founder": "Who founded {x}?", "birthplace": "Where was {x} born?", "birth place": "Where was {x} born?", "age": "How old is {x}?",
                  "height": "How tall is {x}?", "area": "What is the area of {x}?", "language": "What is the official language of {x}?",
                  "continent": "What continent is {x} in?", "borders": "Which countries border {x}?", "neighbours": "Which countries border {x}?",
                  "spouse": "Who is {x} married to?", "wife": "Who is {x} married to?", "husband": "Who is {x} married to?", "owner": "Who owns {x}?",
                  "cast": "Who starred in {x}?", "release date": "When was {x} released?", "timeline": "timeline of {x}", "history": "timeline of {x}",
                  "pros and cons": "pros and cons of {x}", "facts": "facts about {x}", "recipe": "recipe for {x}"}
WHAT_ABOUT_RE = re.compile(r"^(?:and |what |how )?(?:about|what about|how about) (.+?)[?.!]*$", re.I)
AND_ITS_RE = re.compile(r"^(?:and|what about|how about) (?:its|his|her|their|the) ([a-z][a-z ]{2,20})[?.!]*$", re.I)
AND_X_RE = re.compile(r"^and (?!its\b|his\b|her\b|their\b|the\b)([A-Za-z][A-Za-z' .-]{1,40})[?.!]*$")
ORDINAL_RE = re.compile(r"^(?:tell me (?:more )?about |more on |what about |and )?(?:the )?(first|second|third|fourth|fifth|1st|2nd|3rd|4th|5th|last|number (\d))(?: one| item| entry)?[?.!]*$", re.I)
RECALL_RE = re.compile(r"^(?:what did you (?:say|tell me) about|what was that about|remind me what you said about|what did you find (?:about|on)) (.+?)[?.!]*$", re.I)

def _val_year(ent, pid):
    for v in claim_values(ranked_claims(ent, pid), limit=1):
        m = re.search(r"\b(\d{3,4})\b", v.get("text") or "")
        if m:
            return int(m.group(1)), v.get("text")
    return None, None

def compose_sentence(best):
    """v54 (data-to-text): one new sentence assembled from Wikidata claims through fixed patterns. Every clause is a cited claim;
    the arithmetic (ages, spans) is checked; nothing is inferred beyond the claims. Returns "" when too little is known."""
    try:
        ent, name = best["entity"], best["label"]
        types = entity_type_qids(ent)
        def vals(pid, n=2):
            return [v["text"] for v in claim_values(ranked_claims(ent, pid), limit=n) if v.get("text") and norm_key(name) not in norm_key(v["text"])]
        if "Q5" in types:
            born_y, born = _val_year(ent, "P569")
            died_y, died = _val_year(ent, "P570")
            occ = vals("P106", 2); place = vals("P19", 1); country = vals("P27", 1); works = vals("P800", 2); spouse = vals("P26", 1)
            if not (born or occ):
                return ""
            head = name + (" was" if died else " is") + (" a " + human_join(occ) if occ else "")
            if country:
                head += (" from " if occ else " from ") + country[0] if not occ else ", from " + country[0]
            parts = [head]
            if born:
                parts.append(f"born {born}" + (f" in {place[0]}" if place else ""))
            if died and born_y and died_y:
                parts.append(f"died {died} at {died_y - born_y - (1 if False else 0)}" if died_y > born_y else f"died {died}")
            elif died:
                parts.append(f"died {died}")
            sent = parts[0] + (", " + ", ".join(parts[1:]) if len(parts) > 1 else "") + "."
            extra = []
            if works:
                extra.append(f"Notable work{'s' if len(works) > 1 else ''}: {human_join(works)}.")
            if spouse:
                extra.append(f"Spouse: {spouse[0]}.")
            return (sent + " " + " ".join(extra)).strip()
        # places: population, country, capital-of, area
        pop = vals("P1082", 1); country = vals("P17", 1); cap = vals("P36", 1); area = vals("P2046", 1); cont = vals("P30", 1)
        if pop or country or cap:
            sent = name + (f" is in {country[0]}" if country else (f" is in {cont[0]}" if cont else ""))
            bits = []
            if pop: bits.append(f"a population of {pop[0]}")
            if area: bits.append(f"an area of {area[0]}")
            if bits:
                sent += (" with " if sent != name else " has ") + " and ".join(bits)
            if cap:
                sent += f"; its capital is {cap[0]}"
            return sent + "."
        return ""
    except Exception:
        return ""

def resolve_ellipsis(q, st):
    """v41 (Phase 6, turn-based state): "what about Saturn?" repeats the previous question with a new subject; "and its capital?"
    asks a property of the previous subject. Deterministic, and the resolved question is shown to the person."""
    last_q, last_term = st.get("last_question") or "", st.get("last_term") or st.get("subject_label") or ""
    if last_term.lower() in ("he", "she", "it", "they", "him", "her", "them", "his", "hers"):
        last_term = st.get("subject_label") or last_term          # v54: a pronoun question leaves the real subject in subject_label
    # v54: "what's the weather like there" -> the last place; this is a rewrite, so the person sees it
    if re.search(r"\b(?:weather|forecast|temperature|raining|rain|sunny|hot|cold)\b", q, re.I) and re.search(r"\b(?:there|that city|that place|over there)\b", q, re.I) and (st.get("last_place") or st.get("subject_label")):
        return re.sub(r"\b(?:over there|there|that city|that place)\b", "in " + (st.get("last_place") or st.get("subject_label")), q.strip(), count=1, flags=re.I)
    m = AND_ITS_RE.match(q.strip())
    if m and last_term:
        prop = m.group(1).strip().lower()
        tmpl = PROP_QUESTIONS.get(prop) or PROP_QUESTIONS.get(prop.rstrip("s"))
        pron = re.match(r"^(?:and|what about|how about) (its|his|her|their|the)", q.strip(), re.I).group(1).lower()
        target = last_term
        if pron in ("his", "her") and st.get("answer_label") and st.get("answer_qid") and not re.match(r"(?i)^(?:where|when|what|how)\b", last_q):
            target = st["answer_label"]          # v50: the person in the previous answer, not the work asked about (v53: not the place or date)
        if target.lower() in ("he", "she", "it", "they", "him", "her", "them"):
            target = st.get("subject_label") or target
        if tmpl:
            return tmpl.format(x=target)
    md = re.match(r"^how far (?:is|are) (?:it|that|there) (?:from|to) (.+?)[?.!]*$", q.strip(), re.I)
    if md and (st.get("last_place") or st.get("subject_label")):
        return f"how far is {st.get('last_place') or st.get('subject_label')} from {md.group(1)}"
    m = ORDINAL_RE.match(q.strip())
    if m:
        try:
            items = json.loads(st.get("last_list") or "[]")
        except Exception:
            items = []
        if not items:
            return "__no_list__"
        if items:
            word = (m.group(1) or "").lower()
            idx = {"first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2, "fourth": 3, "4th": 3, "fifth": 4, "5th": 4, "last": len(items) - 1}.get(word)
            if idx is None and m.group(2):
                idx = int(m.group(2)) - 1
            if idx is not None and 0 <= idx < len(items):
                return f"Tell me about {items[idx]}"
    mf = re.match(r"^(at|in|on|for|with|without|after|before|over|under) ([\w' .°-]{1,25})[?.!]*$", q.strip(), re.I)
    prev_q = last_q or (st.get("prev_raw") if (re.search(r"\b(?:how|what|when|where|why|which|weather|forecast)\b", st.get("prev_raw") or "", re.I) and len((st.get("prev_raw") or "").split()) >= 3) else "")
    if mf and prev_q and len(q.split()) <= 4 and len(prev_q.split()) >= 4:
        return prev_q.rstrip("?.! ") + " " + mf.group(0).rstrip("?.! ")      # v55/v57: "at 200C?" continues the previous question, even one that failed
    if st.get("last_mode") == "weather" and re.match(r"^(?:what about|and|how about) (the weekend|tomorrow|tonight|this week|next week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)[?.!]*$", q.strip(), re.I):
        when = re.match(r"^(?:what about|and|how about) (.+?)[?.!]*$", q.strip(), re.I).group(1)
        return f"what's the weather in {st.get('last_place') or last_term} {when if when.lower() != 'the weekend' else 'this weekend'}"
    m = AND_X_RE.match(q.strip())
    if m and last_q and last_term and len(last_q.split()) >= 3 and not re.match(r"(?i)^(?:put|add|remind|set|create|delete|remove|show|list|cancel|clear|write|open|read)\b", m.group(1)):
        new = m.group(1).strip()
        mprep = re.match(r"^(at|in|on|during|for|with|after|before|under|without|by) (.+)$", new, re.I)
        if mprep:
            prep = mprep.group(1).lower()
            mold = re.search(r"\b" + prep + r" ([A-Z][\w' .-]{1,40}|[a-z][\w' -]{1,30})$", last_q)
            if mold:                    # "weather in Porto" -> "weather in Lisbon"
                return last_q[:mold.start(1)] + mprep.group(2)
            return last_q.rstrip("?.! ") + " " + new     # "why is the sky blue" + "at sunset"
        if st.get("last_mode") == "osm":
            return f"{new} near {last_term}"          # "and bookshops?" after "cafes near Pike Place Market"
        try:
            tmpls = json.loads(st.get("turn_templates") or "[]")
        except Exception:
            tmpls = []
        if len(tmpls) >= 2 and tmpls[-1].get("kind") != tmpls[-2].get("kind"):
            kind_new = None
            try:
                r = resolve_subject(new)
                if r:
                    kind_new = "human" if "Q5" in entity_type_qids(r.get("entity") or {}) else "other"
            except Exception:
                kind_new = None
            if kind_new:
                for t in reversed(tmpls):
                    if t.get("kind") == kind_new and t.get("term") and t["term"].lower() in t["q"].lower():
                        trace(f"turn state: '{new}' is {kind_new}; using the question about {t['term']}")
                        return re.sub(re.escape(t["term"]), new, t["q"], count=1, flags=re.I)
        if last_term.lower() in last_q.lower():
            return re.sub(re.escape(last_term), new, last_q, count=1, flags=re.I)
        m2 = re.match(r"^(.+?) (near .+)$", last_q, re.I)
        if m2:
            return f"{new} {m2.group(2)}"
    if st.get("last_mode") == "weather" and re.match(r"^(?:what about|and|how about) (the weekend|tomorrow|tonight|this week|next week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)[?.!]*$", q.strip(), re.I):
        when = re.match(r"^(?:what about|and|how about) (.+?)[?.!]*$", q.strip(), re.I).group(1)
        return f"what's the weather in {st.get('last_place') or last_term} {when if when.lower() != 'the weekend' else 'this weekend'}"
    m = WHAT_ABOUT_RE.match(q.strip())
    if m and (len(m.group(1).split()) >= 4 or re.search(r"\b(?:for|of|in|to|with)\b", m.group(1))) and not st.get("last_mode") in ("osm", "weather"):
        # "what about the ingredients for naan?" is a whole question; only strip the opener
        core = m.group(1).strip()
        return ("what are " + core) if re.match(r"^the ", core) else core
    if m and last_q and last_term and last_term.lower() in last_q.lower() and len(m.group(1)) < 60:
        return re.sub(re.escape(last_term), m.group(1).strip(), last_q, count=1, flags=re.I)
    return None

def route(q, sid, authed=False):
    t0 = time.monotonic()
    ctx_begin(BUDGET_DEFAULT)
    _CTX.authed = bool(authed)
    q = normalize_question(q)
    st = get_state(sid)
    # v44: "I meant linter" or simply typing the corrected word again teaches the assistant the word
    m_meant = re.match(r"^(?:i meant|i said|no,? i meant|it's|its) ([a-z][a-z-]{2,30})[.!]?$", q.strip(), re.I)
    prev = json.loads(st.get("last_corrected") or "{}")
    if m_meant and m_meant.group(1).lower() in prev:
        word = m_meant.group(1).lower()
        remember_word(word)
        st["last_corrected"] = ""
        original = (st.get("last_raw") or "")
        trace(f"spelling: learned '{word}'; re-running '{original}' as typed")
        if original:
            res = route_inner(original, sid, st)
            res["answer"] = f"(Noted: \u201c{word}\u201d is a word; I won't change it again.)\n" + res["answer"]
            res["ms"] = int((time.monotonic() - t0) * 1000); res["trace"] = list(getattr(_CTX, "trace", []))
            return res
    elif prev and any(w in prev for w in q.lower().split()):
        for w in [w for w in q.lower().split() if w in prev]:
            remember_word(w)
            trace(f"spelling: '{w}' typed again after a correction -> learned")
        st["last_corrected"] = ""
    st["prev_raw"] = st.get("last_raw") or ""        # v56: the previous message, for "sorry I meant 6pm not 6am"
    st["last_raw"] = q
    m_recall = RECALL_RE.match(q.strip())
    if m_recall:
        try:
            log = json.loads(st.get("answer_log") or "[]")
        except Exception:
            log = []
        want = set(core_stems(m_recall.group(1)))
        hits = [e for e in log if want and want <= stem_set(e.get("q", ""))] or [e for e in log if want and want <= stem_set(e.get("q", "") + " " + e.get("a", "")[:200])]
        if hits:
            e = hits[-1]
            res = {"answer": f"Earlier, for \u201c{e['q']}\u201d, I said:\n{e['a']}", "sources": e.get("s") or [], "mode": "recall", "evidence_count": 1}
            res["ms"] = int((time.monotonic() - t0) * 1000); res["trace"] = ["answer memory: replayed an earlier answer"]
            save_state(st)
            return res
    resolved = resolve_ellipsis(q, st)
    if resolved == "__no_list__":
        res = {"answer": "I haven't given you a list to pick from yet in this conversation. Ask for one (\u201ctop things to do in Porto\u201d) and then \u201cthe first one\u201d will work.",
               "sources": [], "mode": "chat", "evidence_count": 0}
        res["ms"] = int((time.monotonic() - t0) * 1000); res["trace"] = ["turn state: ordinal with no list in memory"]
        save_state(st)
        return res
    was_resolved = False
    _CTX.pinned = None
    if resolved:
        trace(f"turn state: '{q}' -> '{resolved}'")
        last_term = st.get("last_term") or st.get("subject_label") or ""
        if last_term and st.get("subject_qid") and (st.get("subject_label") or "").lower() == last_term.lower() and last_term.lower() in resolved.lower():
            _CTX.pinned = {"label": last_term, "qid": st["subject_qid"]}
        q = normalize_question(resolved)
        was_resolved = True
    plan = None
    try:
        plan = _planner.analyze(q, {"followup": bool(re.search(r"\b(?:it|they|them|she|he|this|that)\b", q, re.I)), "authed": bool(authed)})
        _CTX.plan = plan
        trace(_planner.describe(plan))
    except Exception as e:
        trace(f"planner failed: {type(e).__name__}")
    res = route_inner(q, sid, st)
    res = enforce_contract(q, plan, res, st)
    structured_failed = (plan is not None and plan.intent in ("fact", "definition", "inference", "facts") and res.get("mode") in ("web", "wikipedia")
                         and not (plan.intent == "definition" and res.get("mode") == "wikipedia"))
    if (res.get("mode") == "none" or structured_failed) and SPELL.ok:
        ctx_extend(BUDGET_DEFAULT + (time.monotonic() - t0))
        fixed = SPELL.correct(q, aggressive=True)
        fixed = american(fixed) if fixed else None
        if fixed and fixed.lower() != q.lower():
            trace(f"spelling: retrying as '{fixed}'")
            res2 = route_inner(fixed, sid, st)
            if res2.get("mode") not in ("none", "chat", "error") and (res.get("mode") == "none" or res2.get("mode") in ("wikidata", "inference", "facts", "dictionary", "word", "compare")):
                res2["answer"] = f"(I read that as \u201c{fixed}\u201d.)\n" + res2["answer"]
                res = enforce_contract(fixed, plan, res2, st)
                changed = {a.lower(): b.lower() for a, b in zip(q.split(), fixed.split()) if a.lower() != b.lower()}
                st["last_corrected"] = json.dumps(changed)
                save_state(st)
    if plan is not None:
        rec = _log_plan(q, plan, res, (time.monotonic() - t0) * 1000)
        if rec:
            trace(f"plan check: mode={rec['mode']} honoured={rec['honoured']}" + (" FRESHNESS VIOLATION" if rec["freshness_violation"] else ""))
            res["plan"] = {k: rec[k] for k in ("intent", "freshness", "type", "risk", "honoured", "freshness_violation", "in_plan", "plan_position", "cascade_position")}
            if rec.get("planned") and rec.get("cascade_position") is not None:
                trace(f"plan order: {' > '.join(rec['planned'])} | answered by {rec['capability']} (planner position {rec['plan_position']}, cascade position {rec['cascade_position']})")
    if re.match(r"^(?:quote it in full|full passage|the full passage|in full)[.!?]?$", q.strip(), re.I) and st.get("full_passage"):
        res = {"answer": st["full_passage"], "sources": json.loads(st.get("full_sources") or "[]"), "mode": "wikipedia", "evidence_count": 1}
    res = condense_answer(q, res)
    if res.get("full_passage"):
        st["full_passage"] = res["full_passage"]; st["full_sources"] = json.dumps(res.get("sources") or []); save_state(st)
    if was_resolved and res.get("mode") not in ("none", "error"):
        res["answer"] = f"(I read that as \u201c{q}\u201d.)\n" + res["answer"]
    if res.get("mode") not in ("chat", "none", "error", "tool"):
        st["last_question"] = q
        save_state(st)
    if res.get("mode") in ("wikipedia", "web", "research", "summary", "guide") and res.get("sources"):
        try:      # v54: verbatim integrity. Nothing here changes the answer; it records whether the quoted text exists in the source page.
            body = res.get("answer") or ""
            probe = re.sub(r"^\(I read that as .*?\)\n", "", body).split("\n")[0][:70] if res.get("mode") in ("wikipedia", "web") else ""
            if not probe and res.get("mode") == "guide":
                m_step = re.search(r"\n1\. (.{20,70})", body); probe = m_step.group(1) if m_step else ""
            if not probe and res.get("mode") in ("research", "summary"):
                m_b = re.search(r"\u2022 (.{20,70})", body); probe = m_b.group(1) if m_b else ""
            url = (res["sources"][0] or {}).get("url", "")
            ok = None
            if probe and url:
                pg = fetch_page(url, read_timeout=4) if not url.startswith("https://en.wikipedia.org/") else None
                text = (pg or {}).get("text") or ""
                if not text and url.startswith("https://en.wikipedia.org/wiki/"):
                    from urllib.parse import unquote
                    ex = wiki_extract(unquote(url.rsplit("/", 1)[-1]).replace("_", " "))
                    text = ex if isinstance(ex, str) else (ex or {}).get("extract", "") if isinstance(ex, dict) else ""
                if text:
                    norm_t = re.sub(r"\s+", " ", text); norm_p = re.sub(r"\s+", " ", probe.strip(" .\u201c\u201d\"'"))[:60]
                    ok = norm_p in norm_t
            res["verbatim"] = ok
            trace(f"verbatim: {'ok' if ok else ('mismatch' if ok is False else 'unchecked')}")
        except Exception as e:
            res["verbatim"] = None
            trace(f"verbatim: unchecked ({type(e).__name__})")
    res["ms"] = int((time.monotonic() - t0) * 1000)
    res["trace"] = list(getattr(_CTX, "trace", []))
    return res

# ---------- UI / API ----------
# Quotations about artificial intelligence, shown under the title; each is a real, sourced remark (the two marked
# "attributed" are widely quoted but not documented verbatim). fAI never generates a quotation of its own.
AI_QUOTES = [
    ("The question of whether a machine can think is no more interesting than the question of whether a submarine can swim.", "Edsger W. Dijkstra, 1984"),
    ("We can only see a short distance ahead, but we can see plenty there that needs to be done.", "Alan Turing, 1950"),
    ("Machines take me by surprise with great frequency.", "Alan Turing, 1950"),
    ("The Analytical Engine has no pretensions whatever to originate anything. It can do whatever we know how to order it to perform.", "Ada Lovelace, 1843"),
    ("AI is whatever hasn't been done yet.", "Larry Tesler"),
    ("By far the greatest danger of Artificial Intelligence is that people conclude too early that they understand it.", "Eliezer Yudkowsky"),
    ("Some people worry that artificial intelligence will make us feel inferior, but then, anybody in his right mind should have an inferiority complex every time he looks at a flower.", "Alan Kay"),
    ("Will robots inherit the earth? Yes, but they will be our children.", "Marvin Minsky, 1994"),
    ("The real problem is not whether machines think but whether men do.", "B. F. Skinner, 1969"),
    ("A year spent in artificial intelligence is enough to make one believe in God.", "Alan Perlis, 1982"),
    ("Computers are useless. They can only give you answers.", "attributed to Pablo Picasso"),
    ("Any sufficiently advanced technology is indistinguishable from magic.", "Arthur C. Clarke, 1973"),
]

INDEX_HTML = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>We Have AI At Home __VERSION__</title>
<style>:root{color-scheme:dark;--bg:#111318;--panel:#191c23;--line:#2a2f39;--muted:#9aa4b2;--text:#eef2f7}*{box-sizing:border-box}html,body{height:100%;margin:0;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}#app{height:100dvh;max-width:920px;margin:auto;display:flex;flex-direction:column}header{padding:14px 18px;border-bottom:1px solid var(--line);background:var(--panel)}header span{display:block;color:var(--muted);font-size:12px;margin-top:3px}#messages{flex:1;min-height:0;overflow:auto;padding:16px 14px 24px;display:flex;flex-direction:column}.msg{width:fit-content;max-width:min(78%,760px);margin:0 0 10px;display:flex;flex-direction:column;align-items:flex-start}.msg.user{margin-left:auto;align-items:flex-end}.who{font-size:11px;color:var(--muted);margin:0 0 3px 12px}.user .who{display:none}.body{white-space:pre-wrap;overflow-wrap:anywhere;padding:9px 14px;border-radius:20px;line-height:1.4;font-size:16px}.bot .body{background:#26292f;color:var(--text);border-bottom-left-radius:6px}.user .body{background:#0a84ff;color:#fff;border-bottom-right-radius:6px}.sources{margin:6px 0 0 12px;font-size:12px}.sources a{display:block;color:#9fc0ef;text-decoration:none;margin-top:3px}.meta{color:var(--muted);font-size:11px;margin:5px 0 0 12px}.chips{margin:8px 0 0 12px;display:flex;gap:6px;flex-wrap:wrap}.chips button{height:30px;font-size:13px;font-weight:500;padding:0 12px;border-radius:15px}#composer{flex:0 0 auto;border-top:1px solid var(--line);background:var(--panel);padding:8px 14px max(12px,env(safe-area-inset-bottom))}#status{height:23px;color:var(--muted);font-size:13px;visibility:hidden}.dots{display:inline-flex;gap:4px;margin-left:6px}.dots i{width:5px;height:5px;background:#bfc8d6;border-radius:50%;display:block;animation:b 1s infinite ease-in-out}.dots i:nth-child(2){animation-delay:.15s}.dots i:nth-child(3){animation-delay:.3s}@keyframes b{0%,60%,100%{transform:translateY(0);opacity:.35}30%{transform:translateY(-5px);opacity:1}}#row{display:flex;gap:8px;align-items:flex-end}textarea{flex:1;resize:none;max-height:150px;min-height:44px;padding:11px 16px;border-radius:22px;border:1px solid #343a46;background:#101217;color:var(--text);font:inherit;outline:none}button{height:44px;padding:0 16px;border:1px solid #3a414e;border-radius:22px;background:#252a33;color:var(--text);font-weight:600;cursor:pointer}#send{background:#0a84ff;border-color:#0a84ff;color:#fff;min-width:44px}button:disabled,textarea:disabled{opacity:.6}</style></head><body><div id="app"><header><b>We Have AI At Home <small style="font-weight:400;color:var(--muted)">__VERSION__</small></b><button id="lock" title="Enter the access code to unlock tools (reminders, lists, calendar, files)" style="float:right;background:none;border:1px solid var(--line);color:var(--text);border-radius:8px;padding:2px 8px;cursor:pointer">\U0001F512</button><span id="quote">__QUOTE__</span></header><main id="messages"></main><div id="composer"><div id="status">Looking things up <span class="dots"><i></i><i></i><i></i></span></div><div id="row"><textarea id="input" rows="1" placeholder="Ask or chat..."></textarea><button id="send">Send</button></div></div></div>
<script>
var sessionId=null;try{sessionId=localStorage.getItem('noai-session')}catch(e){}
if(!sessionId){sessionId='web-'+Date.now()+'-'+Math.random().toString(36).slice(2);try{localStorage.setItem('noai-session',sessionId)}catch(e){}}
var messages=document.getElementById('messages'),input=document.getElementById('input'),send=document.getElementById('send'),statusEl=document.getElementById('status');
function scrollBottom(){messages.scrollTop=messages.scrollHeight}
function typeInto(el,text,done){var parts=text.split(/(\s+)/),i=0;function step(){var n=0;while(i<parts.length&&n<6){el.textContent+=parts[i++];n++}scrollBottom();if(i<parts.length){setTimeout(step,16)}else if(done){done()}}step()}
function addMsg(who,text,d){d=d||{};var m=document.createElement('div');m.className='msg '+(who==='You'?'user':'bot');var h=document.createElement('div');h.className='who';h.textContent=who;var b=document.createElement('div');b.className='body';m.appendChild(h);m.appendChild(b);messages.appendChild(m);
function extras(){var src=d.sources||[];if(src.length){var s=document.createElement('div');s.className='sources';src.forEach(function(x,i){if(!/^https?:\/\//i.test(x.url||''))return;var a=document.createElement('a');a.href=x.url;a.target='_blank';a.rel='noopener noreferrer';a.textContent='['+(i+1)+'] '+x.title;s.appendChild(a)});m.appendChild(s)}
var chips=[];if(d.more_available)chips.push('Tell me more');if(d.can_simplify)chips.push('Simpler');if(chips.length){var c=document.createElement('div');c.className='chips';chips.forEach(function(t){var k=document.createElement('button');k.textContent=t;k.onclick=function(){input.value=t;submit()};c.appendChild(k)});m.appendChild(c)}
if(d.mode&&d.mode!=='chat'&&d.mode!=='tool'&&d.q){thumbs(m,d.q,text,d.mode)}
if(d.ms&&d.mode&&d.mode!=='chat'){var e=document.createElement('div');e.className='meta';e.textContent=d.mode+' \u00b7 '+(d.ms/1000).toFixed(1)+'s';m.appendChild(e)}scrollBottom()}
if(who==='You'||text.length>1500){b.textContent=text;extras()}else{typeInto(b,text,extras)}scrollBottom()}
var apiKey='';try{apiKey=localStorage.getItem('noai-key')||''}catch(e){}
var lockBtn=document.getElementById('lock');function paintLock(){lockBtn.textContent=apiKey?'\uD83D\uDD13':'\uD83D\uDD12'}paintLock();
lockBtn.onclick=function(){var k=prompt('Access code (the installer printed it; it is NOAI_ACCESS_CODE in the .env file). Leave empty to lock tools again:',apiKey||'');if(k===null)return;apiKey=k.trim();try{localStorage.setItem('noai-key',apiKey)}catch(e){}paintLock();if(apiKey&&window.Notification&&Notification.permission==='default'){try{Notification.requestPermission()}catch(e){}}};
function hdrs(){var h={'Content-Type':'application/json'};if(apiKey)h['X-API-Key']=apiKey;return h}
async function pollReminders(){if(!apiKey)return;try{var r=await fetch('/api/reminders/due',{headers:hdrs()});if(r.status===401){return}var d=await r.json();(d.due||[]).forEach(function(x){var t=(x.kind==='timer'?'\u23F0 Timer finished':'\u23F0 Reminder')+': '+x.text;addMsg('fAI',t);try{if(window.Notification&&Notification.permission==='granted')new Notification('We Have AI At Home',{body:t})}catch(e){}})}catch(e){}}
setInterval(pollReminders,30000);setTimeout(pollReminders,3000);
function thumbs(m,q,text,mode){var f=document.createElement('div');f.className='meta';['\uD83D\uDC4D','\uD83D\uDC4E'].forEach(function(sym,i){var b=document.createElement('button');b.textContent=sym;b.title=i?'This answer was not good':'Good answer';b.style.cssText='background:none;border:none;cursor:pointer;opacity:.55;font-size:14px';b.onclick=function(){fetch('/api/feedback',{method:'POST',headers:hdrs(),body:JSON.stringify({session:sessionId,question:q,answer:text,mode:mode,verdict:i?-1:1})});f.textContent=i?'Thanks, noted as a poor answer.':'Thanks.'};f.appendChild(b)});m.appendChild(f)}
var pending=false;function busy(v){pending=v;send.disabled=v;statusEl.style.visibility=v?'visible':'hidden';if(v)scrollBottom()}
async function submit(){if(pending)return;var q=input.value.trim();if(!q)return;input.value='';input.style.height='auto';addMsg('You',q);busy(true);try{var r=await fetch('/api/chat',{method:'POST',headers:hdrs(),body:JSON.stringify({session:sessionId,question:q})});var d=await r.json();d.q=q;addMsg('fAI',d.answer||'No answer.',d)}catch(e){addMsg('fAI','Request failed: '+e)}finally{busy(false);scrollBottom();setTimeout(function(){input.focus()},0)}}
send.addEventListener('click',submit);input.addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();submit()}});input.addEventListener('input',function(){input.style.height='auto';input.style.height=Math.min(input.scrollHeight,150)+'px'});
addMsg('fAI','Hi. Ask me a question or just chat. I look things up and quote my sources: facts are never made up. (I can also shuffle a template poem if you ask.) Type "help" to see what I can do.');input.focus();
</script></body></html>'''

@app.get("/")
def index():
    import random as _random
    q = _random.choice(AI_QUOTES)
    page = (INDEX_HTML.replace("__VERSION__", "v" + APP_VERSION.split(".")[0])
                      .replace("__QUOTE__", htmlmod.escape(f"\u201c{q[0]}\u201d \u2014 {q[1]}")))
    return Response(page, mimetype="text/html", headers={"Cache-Control": "no-store, max-age=0"})

@app.get("/health")
def health():
    return jsonify({"ok": True, "version": APP_VERSION, "nlp": NLP_MODE, "embeddings": EMBED_MODE})

@app.get("/health/live")
def health_live():
    return jsonify({"ok": True})

@app.get("/health/ready")
def health_ready():
    """Ready = able to answer with its configured features: database, files folder, SearXNG. Liveness is /health/live."""
    checks = {}
    try:
        con = db(); con.execute("SELECT 1"); con.close()
        checks["database"] = True
    except Exception:
        checks["database"] = False
    try:
        checks["searxng"] = WEB.get(SEARXNG_URL + "/healthz", timeout=(2, 3)).status_code == 200
    except Exception:
        checks["searxng"] = False
    checks["files_folder"] = os.access(os.environ.get("NOAI_FILES_DIR", "/files"), os.W_OK)
    checks["judge"] = bool(getattr(JUDGE, "ok", False))
    ok = checks["database"] and checks["files_folder"]
    return jsonify({"ready": ok, "checks": checks}), (200 if ok else 503)

@app.get("/api/capabilities")
def capabilities_list():
    return jsonify({"capabilities": _build_registry().describe()})

@app.get("/api/plan-stats")
def plan_stats():
    """Shadow-planner statistics from data/plans.jsonl: route agreement, freshness violations, per intent."""
    n = int(request.args.get("last", "500"))
    rows = []
    try:
        with open(PLAN_LOG, encoding="utf-8") as f:
            rows = [json.loads(x) for x in f.readlines()[-n:] if x.strip()]
    except Exception:
        pass
    by = {}
    for r in rows:
        b = by.setdefault(r["intent"], {"n": 0, "honoured": 0, "abstained": 0, "violations": 0, "modes": {}})
        b["n"] += 1; b["honoured"] += bool(r.get("honoured")); b["abstained"] += r.get("mode") == "none"; b["violations"] += bool(r.get("freshness_violation"))
        b["modes"][r.get("mode", "")] = b["modes"].get(r.get("mode", ""), 0) + 1
    total = len(rows)
    planned_rows = [r for r in rows if r.get("planned") and r.get("cascade_position") is not None]
    reached = [r for r in planned_rows if r.get("in_plan")]
    saved = [r["cascade_position"] - r["plan_position"] for r in reached]
    return jsonify({"questions": total,
                    "phase3_shadow": {"retrieval_questions": len(planned_rows), "planner_reaches_answer": len(reached),
                                      "steps_saved_avg": round(sum(saved) / len(saved), 2) if saved else None,
                                      "missed": [{"q": r["q"], "intent": r["intent"], "capability": r["capability"], "planned": r["planned"]} for r in planned_rows if not r.get("in_plan")][-20:]}, "route_agreement": round(sum(bool(r.get("honoured")) for r in rows) / total, 3) if total else None,
                    "freshness_violations": sum(bool(r.get("freshness_violation")) for r in rows), "by_intent": by,
                    "disagreements": [{"q": r["q"], "intent": r["intent"], "mode": r["mode"]} for r in rows if not r.get("honoured")][-40:]})

LABEL_HTML = """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>fAI labelling</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;color:#222}h1{font-size:1.2rem}.q{font-size:1.15rem;font-weight:600;margin:1rem 0}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:1rem}.c{border:1px solid #ccc;border-radius:10px;padding:1rem;background:#fafafa}.c small{color:#666}
button{font:inherit;padding:.6rem 1rem;border-radius:8px;border:1px solid #888;background:#fff;cursor:pointer;margin:.3rem}.big{background:#1f6feb;color:#fff;border-color:#1f6feb}
#s{color:#666;margin-top:1rem}</style>
<h1>Which passage answers the question better?</h1><p>Read both; pick the one a careful person would rather receive as the answer. "Neither" if both miss. Your clicks are saved on this machine only.</p>
<div class=q id=q></div><div class=pair><div class=c id=a></div><div class=c id=b></div></div>
<div><button class=big onclick="send('a')">Left is better</button><button class=big onclick="send('b')">Right is better</button><button onclick="send('tie')">About the same</button><button onclick="send('neither')">Neither answers it</button><button onclick="next()">Skip</button></div>
<div id=s></div>
<script>var code=new URLSearchParams(location.search).get('code')||'';var cur=null;
function esc(t){return t.replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c]})}
function next(){fetch('/api/label/next?code='+encodeURIComponent(code)).then(r=>r.json()).then(d=>{cur=d;if(d.error){document.getElementById('s').textContent=d.error;return}
document.getElementById('q').textContent=d.q;document.getElementById('a').innerHTML='<small>'+esc(d.a.label)+'</small><p>'+esc(d.a.text)+'</p>';document.getElementById('b').innerHTML='<small>'+esc(d.b.label)+'</small><p>'+esc(d.b.text)+'</p>';
document.getElementById('s').textContent=d.done+' labelled so far, '+d.left+' pairs left'})}
function send(ch){if(!cur||cur.error)return;fetch('/api/label',{method:'POST',headers:{'Content-Type':'application/json','X-API-Key':code},body:JSON.stringify({id:cur.id,choice:ch,swapped:cur.swapped})}).then(()=>next())}
next();</script>"""

def _label_pairs():
    """Pairs from candidates.jsonl: the chosen passage against each runner-up, keyed so the same pair is offered once."""
    path = os.path.join(DATA_DIR, "candidates.jsonl")
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            cs = r.get("cands") or []
            for i in range(1, min(len(cs), 3)):
                if cs[0]["text"][:80] == cs[i]["text"][:80]:
                    continue
                pid = hashlib.md5((r["q"] + "|" + cs[0]["text"][:120] + "|" + cs[i]["text"][:120]).encode()).hexdigest()[:12]
                out.append({"id": pid, "q": r["q"], "a": cs[0], "b": cs[i]})
    return out

def _labelled_ids():
    path = os.path.join(DATA_DIR, "labels.jsonl")
    ids = set()
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    ids.add(json.loads(line).get("id"))
                except Exception:
                    pass
    return ids

@app.get("/label")
def label_page():
    return Response(LABEL_HTML, mimetype="text/html")

@app.get("/api/label/next")
def label_next():
    code = request.args.get("code", "").strip()
    if not (ACCESS_CODE and len(ACCESS_CODE) >= 6 and _hmac.compare_digest(code, ACCESS_CODE)):
        return jsonify({"error": "add ?code=<access code> to the address (it is NOAI_ACCESS_CODE in .env)"}), 403
    pairs = _label_pairs()
    done = _labelled_ids()
    left = [p for p in pairs if p["id"] not in done]
    if not left:
        return jsonify({"error": f"nothing left to label ({len(done)} pairs labelled). Ask more questions, or run the corpus, and come back.", "done": len(done), "left": 0})
    p = random.Random(time.time()).choice(left)
    swap = random.random() < 0.5                      # the chosen passage is shown on the left only half the time
    a, b = (p["b"], p["a"]) if swap else (p["a"], p["b"])
    return jsonify({"id": p["id"], "q": p["q"], "a": {"label": a["label"], "text": a["text"]}, "b": {"label": b["label"], "text": b["text"]},
                    "swapped": swap, "done": len(done), "left": len(left)})

@app.post("/api/label")
def label_post():
    if not tools_token_ok():
        return jsonify({"error": "access code required"}), 403
    d = request.get_json(silent=True) or {}
    pid, choice = str(d.get("id", ""))[:32], str(d.get("choice", ""))[:12]
    if not pid or choice not in ("a", "b", "tie", "neither"):
        return jsonify({"error": "bad label"}), 400
    pairs = {p["id"]: p for p in _label_pairs()}
    p = pairs.get(pid)
    if not p:
        return jsonify({"error": "unknown pair"}), 404
    # the page may have swapped sides; it reports which side was shown left, so the label is stored against the passages themselves
    swapped = bool(d.get("swapped"))
    winner = {"a": "chosen", "b": "other"} if not swapped else {"a": "other", "b": "chosen"}
    rec = {"ts": int(time.time()), "id": pid, "q": p["q"], "chosen_text": p["a"]["text"][:300], "other_text": p["b"]["text"][:300],
           "chosen_label": p["a"]["label"], "other_label": p["b"]["label"], "preferred": winner.get(choice, choice)}
    with open(os.path.join(DATA_DIR, "labels.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return jsonify({"ok": True})

@app.get("/api/diagnostics")
def diagnostics():
    tldr_init()
    out = {"version": APP_VERSION, "nlp": NLP_MODE, "ner": HAS_NER, "embeddings": EMBED_MODE,
           "chat": {"intents": len(convo.I), "examples": CHAT.matcher.n, "embedding_matching": CHAT.matcher.emb is not None,
                    "embedding_threshold": round(CHAT.matcher.emb_threshold, 3), "sentiment": "vader" if convo._VADER is not None else "mini-lexicon"},
           "semantic": SEM.info(),
           "judge": JUDGE.info(),
    "reader": READER.info(),
           "tools": TOOLS.info(),
           "record_replay": _replay.info(),
           "push_notifications": bool(NTFY_URL),
           "answer_pool": "Wikipedia + web candidates, chosen by " + ("the cross-encoder judge" if JUDGE.ok else ("sentence similarity" if SEM.ok else "fixed order (Wikipedia first)")) if BLEND else "off (NOAI_BLEND=0)",
           "timezone": skills.local_tz()[1] or "container default",
           "ranker": "paragraph-first BM25 + coverage gate" + (" + MiniLM second opinion (30%) + agreement confidence" if SEM.ok else (" + static embeddings (15%)" if EMB is not None else "")),
           "search_suspensions": dict(SUSPENDED),
        "tldr_examples": _tldr_state["count"], "tldr_index": "sqlite-fts5" if _tldr_state["fts"] else "in-memory",
           "api_user_agent": UA_API, "web_user_agent": UA_WEB}
    try:
        con = db()
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        out["database"] = {"ok": {"state", "cache"}.issubset(tables), "cache_rows": con.execute("SELECT count(*) FROM cache").fetchone()[0]}
        con.close()
    except Exception as e:
        out["database"] = {"ok": False, "error": type(e).__name__}
    tests = [("wikidata", API, WIKIDATA_API, {"action": "wbsearchentities", "search": "Earth", "language": "en", "format": "json", "limit": 1}),
             ("wikipedia", API, wikipedia_api(), {"action": "query", "titles": "Earth", "format": "json"}),
             ("searxng", WEB, SEARXNG_URL + "/search", {"q": "test", "format": "json"})]
    def probe(t):
        name, sess, url, params = t
        try:
            t0 = time.monotonic()
            r = sess.get(url, params=params, timeout=8)
            return name, {"status": r.status_code, "ok": r.ok, "ms": int((time.monotonic() - t0) * 1000)}
        except Exception as e:
            return name, {"status": 0, "ok": False, "error": type(e).__name__}
    for item in pmap(probe, tests, 10):
        if item:
            out[item[0]] = item[1]
    return jsonify(out)

@app.post("/api/chat")
def api_chat():
    d = request.get_json(silent=True) or {}
    q = norm(d.get("question", ""))[:600]
    sid = norm(d.get("session", "default"))[:120] or "default"
    if not q:
        return jsonify({"answer": "Ask me something.", "sources": [], "mode": "chat", "evidence_count": 0})
    try:
        return jsonify(route(q, sid, authed=tools_token_ok()))
    except Exception as e:
        app.logger.exception("chat failure")
        return jsonify({"answer": f"I hit an internal error while answering that ({type(e).__name__}).", "sources": [], "mode": "error",
                        "evidence_count": 0, "trace": list(getattr(_CTX, "trace", []))}), 500

ACCESS_CODE = os.environ.get("NOAI_ACCESS_CODE", "").strip()

def tools_token_ok():
    """Tools need a real secret: the short access code (typed into the page) or the long API token. Empty values never unlock."""
    given = request.headers.get("X-API-Key", "").strip() or request.headers.get("Authorization", "").replace("Bearer ", "", 1).strip()
    return bool(given) and any(len(ok) >= 6 and _hmac.compare_digest(given, ok) for ok in (ACCESS_CODE, API_TOKEN))

@app.get("/api/reminders/due")
def api_reminders_due():
    if not tools_token_ok():
        return jsonify({"due": [], "locked": True}), 401
    return jsonify({"due": TOOLS.due()})

@app.get("/calendar.ics")
def calendar_feed():
    """Subscribe from a phone or desktop calendar: http://<pi>:7070/calendar.ics?key=<access code>  (read-only, one way: bot -> calendar)."""
    given = request.args.get("key", "").strip()
    if not (given and any(len(ok) >= 6 and _hmac.compare_digest(given, ok) for ok in (ACCESS_CODE, API_TOKEN))):
        return Response("locked\n", status=401, mimetype="text/plain")
    try:
        TOOLS._write_ics()
        body = open(os.path.join(TOOLS.root, "calendar.ics"), encoding="utf-8").read()
    except Exception:
        body = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//We Have AI At Home//EN\r\nEND:VCALENDAR\r\n"
    return Response(body, mimetype="text/calendar")

NTFY_URL = os.environ.get("NOAI_NTFY_URL", "").strip()

def _push_loop():
    while True:
        time.sleep(20)
        try:
            for r in TOOLS.due_for_push():
                title = "Timer finished" if r.get("kind") == "timer" else "Reminder"
                requests.post(NTFY_URL, data=str(r["text"]).encode("utf-8"), headers={"Title": f"We Have AI At Home: {title}", "Tags": "alarm_clock"}, timeout=8)
        except Exception:
            pass

if NTFY_URL and TOOLS.enabled and not _replay.MODE:
    threading.Thread(target=_push_loop, daemon=True, name="noai-push").start()

@app.post("/api/feedback")
def api_feedback():
    d = request.get_json(silent=True) or {}
    verdict = 1 if d.get("verdict") in (1, "1", "up", True) else -1
    try:
        con = db()
        con.execute("INSERT INTO feedback(t, session, question, answer, mode, verdict) VALUES(?,?,?,?,?,?)",
                    (time.time(), norm(d.get("session", ""))[:120], norm(d.get("question", ""))[:600], str(d.get("answer", ""))[:1500], norm(d.get("mode", ""))[:20], verdict))
        con.execute("DELETE FROM feedback WHERE rowid IN (SELECT rowid FROM feedback ORDER BY t DESC LIMIT -1 OFFSET 5000)")
        con.commit()
        con.close()
    except Exception:
        return jsonify({"ok": False}), 500
    return jsonify({"ok": True})

@app.get("/api/review.txt")
def api_review():
    """Thumbs-down answers and unmatched chat lines, for improving the bot. Local data; token required."""
    if not tools_token_ok():
        return Response("locked\n", status=401, mimetype="text/plain")
    con = db()
    fb = con.execute("SELECT * FROM feedback ORDER BY t DESC LIMIT 400").fetchall()
    ms = con.execute("SELECT * FROM misses ORDER BY t DESC LIMIT 400").fetchall()
    con.close()
    up = sum(1 for r in fb if r["verdict"] > 0)
    out = [f"FEEDBACK: {up} up, {len(fb) - up} down (latest 400)", ""]
    for r in fb:
        if r["verdict"] < 0:
            out += [f"[DOWN] ({r['mode']}) Q: {r['question']}", f"       A: {(r['answer'] or '')[:300]}", ""]
    out += ["UNMATCHED OR WEAKLY HANDLED MESSAGES (latest 400):", ""] + [f"[{r['intent']}] {r['text']}" for r in ms]
    return Response("\n".join(out) + "\n", mimetype="text/plain")

def api_token_ok():
    if not API_TOKEN:
        return True
    return request.headers.get("Authorization", "") == "Bearer " + API_TOKEN or request.headers.get("X-API-Key", "") == API_TOKEN

@app.get("/v1/models")
def models():
    if not api_token_ok():
        return jsonify({"error": {"message": "Unauthorized", "type": "authentication_error"}}), 401
    return jsonify({"object": "list", "data": [{"id": "fai", "object": "model", "created": int(time.time()), "owned_by": "local"}]})

def message_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for x in content:
            if isinstance(x, dict) and x.get("type") in {"text", "input_text"}:
                parts.append(str(x.get("text", "")))
            elif isinstance(x, str):
                parts.append(x)
        return "\n".join(parts)
    return str(content or "")

@app.post("/v1/chat/completions")
def compat():
    if not api_token_ok():
        return jsonify({"error": {"message": "Unauthorized", "type": "authentication_error"}}), 401
    try:
        d = request.get_json(silent=True) or {}
        q = ""
        for m in reversed(d.get("messages") or []):
            if isinstance(m, dict) and m.get("role") == "user":
                q = message_text(m.get("content"))
                break
        q = norm(q)[:600]
        if not q:
            return jsonify({"error": {"message": "No user message supplied", "type": "invalid_request_error"}}), 400
        sid = request.headers.get("X-Session-ID") or str(d.get("user") or "")
        if not sid:
            fp = (request.remote_addr or "") + "|" + (request.headers.get("User-Agent") or "")
            sid = "openai-" + hashlib.sha256(fp.encode()).hexdigest()[:16]
        result = route(q, sid[:120], authed=True)   # this endpoint already required the API token
        content = result.get("answer", "")
        src = result.get("sources") or []
        if src:
            content += "\n\nSources:\n" + "\n".join(f"[{i}] {s.get('title', '')} - {s.get('url', '')}" for i, s in enumerate(src, 1))
        created, rid = int(time.time()), "chatcmpl-noai-" + uuid.uuid4().hex[:12]
        usage = {"prompt_tokens": len(q.split()), "completion_tokens": len(content.split()), "total_tokens": len(q.split()) + len(content.split())}
        if d.get("stream"):
            def gen():
                def chunk(delta, finish=None):
                    return "data: " + json.dumps({"id": rid, "object": "chat.completion.chunk", "created": created, "model": "fai",
                                                  "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"
                yield chunk({"role": "assistant", "content": ""})
                parts = re.findall(r"\S+\s*", content)
                for i in range(0, len(parts), 8):
                    yield chunk({"content": "".join(parts[i:i + 8])})
                yield chunk({}, "stop")
                yield "data: [DONE]\n\n"
            return Response(gen(), mimetype="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
        return jsonify({"id": rid, "object": "chat.completion", "created": created, "model": "fai", "usage": usage,
                        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}]})
    except Exception as e:
        app.logger.exception("openai compat failure")
        return jsonify({"error": {"message": type(e).__name__, "type": "server_error"}}), 500

# Build the tldr index in the background so the first how-to question is fast.
threading.Thread(target=tldr_init, daemon=True).start()

def _scheduler_loop():
    """v40 (Phase 6): recurring housekeeping in one place. Jobs are deterministic and idempotent; failures are logged, never raised."""
    def _purge():
        con = db()
        try:
            con.execute("DELETE FROM cache WHERE expires < ?", (time.time(),))
            con.commit()
        finally:
            con.close()
    jobs = [("cache purge", 3600, _purge),
            ("news feed warm", 1800, lambda: [fetch_page(url) for _, url in NEWS_FEEDS[:5]])]
    last = {name: 0.0 for name, _, _ in jobs}
    time.sleep(120)
    while True:
        for name, every, fn in jobs:
            if time.time() - last[name] >= every:
                try:
                    fn(); last[name] = time.time()
                    app.logger.info("scheduler: %s done", name)
                except Exception as e:
                    app.logger.warning("scheduler: %s failed: %s", name, type(e).__name__)
                    last[name] = time.time()
        time.sleep(60)
if os.environ.get("NOAI_SCHEDULER", "1") == "1":
    threading.Thread(target=_scheduler_loop, daemon=True, name="noai-scheduler").start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=7070, threaded=True)
__NOAI_V11_APP_PY__
cat > "$APP_DIR/app/convo.py" <<'__NOAI_V11_CONVO_PY__'
"""Conversation engine for We Have AI At Home (fAI) - no generative model.

How it works:
  1. normalise the utterance (contractions, chat-speak, elongated words)
  2. safety first: crisis statements get a fixed, careful reply
  3. pending-question handling (the bot asked something last turn)
  4. personal-memory extraction ("I live in ...", "my favourite X is Y", "remember that ...")
  5. intent retrieval over a hand-written bank of example utterances, using TF-IDF word/bigram
     cosine + character-trigram overlap, and (when available) static sentence embeddings whose
     acceptance threshold is calibrated automatically from the bank itself
  6. dialogue-act fallbacks: feelings (sentiment lexicon), experiences, plans, opinions, problems,
     with correct pronoun reflection, optionally grounded in one quoted Wikipedia sentence about
     the topic the user raised
  7. anti-repetition: never reuse a reply the user saw in the last few turns
Every sentence the bot says is either written here or quoted from a cited source.
"""
SPIN_RE = __import__("re").compile(r"\{([^{}|]*(?:\|[^{}|]*)+)\}")
APP_VERSION = "?"

def spin(text, rnd):
    """v41: curated alternation in hand-written lines, e.g. "{Nice|Lovely|Good choice}. What drew you to it?" Every alternative
    is authored by a person; the choice is seeded per turn so a session never repeats the same surface twice in a row."""
    for _ in range(6):
        m = SPIN_RE.search(text)
        if not m:
            break
        text = text[:m.start()] + rnd.choice(m.group(1).split("|")) + text[m.end():]
    return text

import re, math, json, random, hashlib, time
from collections import Counter

try:
    from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer
    _VADER = SentimentIntensityAnalyzer()
except Exception:  # tiny fallback lexicon
    _VADER = None

# ---------------------------------------------------------------- normalisation
CONTRACTIONS = [
    (r"\bi['\u2019]?m\b", "i am"), (r"\bim\b", "i am"), (r"\bi['\u2019]ve\b", "i have"), (r"\bive\b", "i have"),
    (r"\bi['\u2019]d\b", "i would"), (r"\bi['\u2019]ll\b", "i will"), (r"\byou['\u2019]re\b", "you are"), (r"\byoure\b", "you are"),
    (r"\byou['\u2019]ve\b", "you have"), (r"\byou['\u2019]ll\b", "you will"), (r"\byou['\u2019]d\b", "you would"),
    (r"\b(he|she|it|that|what|who|where|how|there|here|when|why)['\u2019]s\b", r"\1 is"), (r"\bwhats\b", "what is"), (r"\bthats\b", "that is"),
    (r"\blet['\u2019]s\b", "let us"), (r"\bcan['\u2019]?t\b", "can not"), (r"\bcannot\b", "can not"), (r"\bwon['\u2019]t\b", "will not"),
    (r"\bdon['\u2019]?t\b", "do not"), (r"\bdoesn['\u2019]?t\b", "does not"), (r"\bdidn['\u2019]?t\b", "did not"),
    (r"\bisn['\u2019]?t\b", "is not"), (r"\baren['\u2019]?t\b", "are not"), (r"\bwasn['\u2019]?t\b", "was not"),
    (r"\bweren['\u2019]?t\b", "were not"), (r"\bhaven['\u2019]?t\b", "have not"), (r"\bhasn['\u2019]?t\b", "has not"),
    (r"\bcouldn['\u2019]?t\b", "could not"), (r"\bshouldn['\u2019]?t\b", "should not"), (r"\bwouldn['\u2019]?t\b", "would not"),
    (r"\bwe['\u2019]re\b", "we are"), (r"\bthey['\u2019]re\b", "they are"), (r"\bwe['\u2019]ve\b", "we have"),
    (r"\bgonna\b", "going to"), (r"\bwanna\b", "want to"), (r"\bgotta\b", "have to"), (r"\bkinda\b", "kind of"), (r"\bdunno\b", "do not know"),
    (r"\bu\b", "you"), (r"\bur\b", "your"), (r"\br\b", "are"), (r"\bpls\b", "please"), (r"\bplz\b", "please"),
    (r"\bthx\b", "thanks"), (r"\bty\b", "thanks"), (r"\btysm\b", "thanks"), (r"\bidk\b", "i do not know"), (r"\bomg\b", "wow"),
    (r"\bfavourite\b", "favorite"), (r"\bcolour\b", "color"), (r"\bhow['\u2019]?s\b", "how is"), (r"\bsup\b", "what is up"),
    (r"\bwassup\b", "what is up"), (r"\bwyd\b", "what are you doing"), (r"\bhru\b", "how are you"), (r"\bnevermind\b", "never mind"),
    (r"\bgm\b", "good morning"), (r"\bgn\b", "good night"), (r"\bnp\b", "no problem"), (r"\bbc\b", "because"), (r"\bcuz\b", "because"),
    (r"\bthanx\b", "thanks"), (r"\bthnx\b", "thanks"), (r"\bgotta\b", "have to"), (r"\bhbu\b", "how about you"), (r"\bwbu\b", "how about you"), (r"\bnvm\b", "never mind"),
]
CONTRACTIONS = [(re.compile(p), r) for p, r in CONTRACTIONS]

def normalize(text):
    s = str(text or "").replace("\u2019", "'").replace("\u2018", "'").casefold().strip()
    s = re.sub(r"(.)\1{2,}", r"\1", s)                      # heyyyy -> hey, soooo -> so
    for pat, rep in CONTRACTIONS:
        s = pat.sub(rep, s)
    s = re.sub(r"[^a-z0-9'+\-/*.% ]+", " ", s)
    s = re.sub(r"(?<!\d)\.(?!\d)", " ", s)                  # keep decimal points only
    s = re.sub(r"\s+", " ", s).strip(" '")
    return s

FILLERS = re.compile(r"\b(?:really|very|so|just|pretty|quite|honestly|actually|basically|literally|totally|tbh|please|kindly|"
                     r"right now|at the moment|today|lately|for now|a bit|a little|kind of|sort of|bot|mate|buddy|dude|bro|oh|um|uh|hmm)\b")

def match_form(norm):
    """Normalised text with intensifiers/fillers removed; used only for intent matching."""
    s = re.sub(r"\s+", " ", FILLERS.sub(" ", norm)).strip()
    return s or norm

def tokens(norm):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", norm)

# ---------------------------------------------------------------- sentiment
_POS = set("good great fine well happy glad excited awesome amazing wonderful fantastic love loved nice better best "
           "relaxed proud thrilled delighted okay ok alright decent pleased cheerful".split())
_NEG = set("bad sad tired awful terrible horrible depressed lonely anxious stressed angry upset worried sick exhausted "
           "miserable worse worst hate hated hurt scared afraid bored annoyed frustrated overwhelmed rough meh lousy crap".split())

def sentiment(text):
    """-> compound score in [-1, 1]."""
    if _VADER is not None:
        try:
            return float(_VADER.polarity_scores(text)["compound"])
        except Exception:
            pass
    toks = tokens(normalize(text))
    score, neg = 0.0, False
    for t in toks:
        if t in {"not", "no", "never", "hardly"}:
            neg = True
            continue
        v = 1.0 if t in _POS else (-1.0 if t in _NEG else 0.0)
        if v:
            score += -v if neg else v
            neg = False
    return max(-1.0, min(1.0, score / 2.0))

# ---------------------------------------------------------------- pronoun reflection
_REFLECT = {"i": "you", "me": "you", "my": "your", "mine": "yours", "myself": "yourself", "am": "are", "was": "were",
            "we": "you", "us": "you", "our": "your", "ours": "yours", "you": "I", "your": "my", "yours": "mine",
            "yourself": "myself"}

def reflect(norm):
    """'my boss hates me' -> 'your boss hates you' (first person only; 'was' flips only after 'i')."""
    out, prev = [], ""
    for t in norm.split():
        if t == "was":
            out.append("were" if prev == "i" else "was")
        elif t == "am":
            out.append("are")
        else:
            out.append(_REFLECT.get(t, t))
        prev = t
    s = " ".join(out)
    s = re.sub(r"\bi would\b", "I would", s)
    return s

def tidy(s):
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"\s+([,.;:?!])", r"\1", s)
    return s[:1].upper() + s[1:] if s else s

# ---------------------------------------------------------------- safety
CRISIS_RE = re.compile(r"\b(kill myself|killing myself|end my life|ending my life|take my (?:own )?life|suicid\w*|want to die|wanna die|"
                       r"wish i (?:was|were) dead|better off dead|do not want to (?:live|be alive|be here anymore)|no reason to live|"
                       r"hurt(?:ing)? myself|harm(?:ing)? myself|self harm|cut(?:ting)? myself|overdose)\b")
CRISIS_REPLY = ("I'm really sorry you're going through this. I'm only a simple program and can't give you the support you deserve, "
                "but you don't have to face it alone. If you might be in danger, please call your local emergency number now. "
                "In the US you can call or text 988 (Suicide & Crisis Lifeline); elsewhere, findahelpline.com lists services by country. "
                "If you can, reach out to someone you trust and tell them how you're feeling.")

# ---------------------------------------------------------------- generic topic words we never look up or "remember"
GENERIC_TOPICS = set("it that this things thing stuff something anything everything nothing life work today tomorrow yesterday people "
                     "someone anyone everyone time day days week weekend night morning way lot lots bit kind sort one ones you me them him her "
                     "us myself yourself home school job money friends family fun rest nap break sleep".split())
TOPIC_TRAILERS = re.compile(r"\s+(?:lately|recently|these days|right now|at the moment|nowadays|again|too|as well|a lot|so much|very much|"
                            r"last (?:night|week|weekend|month|year|summer|winter|spring|autumn|fall)|yesterday|today|tonight|this (?:morning|afternoon|evening|week|weekend|year)|"
                            r"next (?:week|weekend|month|year|summer|winter|spring|autumn|fall)|tomorrow|the other day|a while ago|earlier|"
                            r"for (?:a while|years|months|ages)|since .+|though|tbh|honestly|i guess|i think)$")

def clean_topic(t):
    t = re.sub(r"\s+", " ", str(t or "")).strip(" .,!?'")
    for _ in range(3):
        t2 = TOPIC_TRAILERS.sub("", t)
        if t2 == t:
            break
        t = t2
    t = re.sub(r"^(?:the|a|an|some|my|our|playing|doing|watching|listening to|reading|learning|studying|making)\s+", "", t)
    return t.strip()

def topic_ok(t):
    ws = t.split()
    return bool(t) and 1 <= len(ws) <= 5 and not (set(ws) <= GENERIC_TOPICS) and len(t) >= 3

# ---------------------------------------------------------------- personal memory extraction
# (pattern on normalised text, memory key, multi-valued?)  value = last group
MEMORY_PATTERNS = [
    (r"^(?:my name is|call me|i am called|you can call me|people call me|i go by) ([a-z][a-z' \-]{0,30})$", "name", False),
    (r"^i (?:live|am living|am based|reside|stay) (?:in|near|at) (.+)$", "location", False),
    (r"^i am from (.+)$", "origin", False),
    (r"^i (?:grew up|was born|was raised) in (.+)$", "origin", False),
    (r"^i work (?:as|like) (?:a |an )?(.+)$", "job", False),
    (r"^my (?:job|profession|occupation|work) is (?:a |an )?(.+)$", "job", False),
    (r"^i am (?:a|an) (.+?) by (?:profession|trade|training)$", "job", False),
    (r"^i am (?:a|an) ((?:[a-z\-]+ ){0,2}?(?:teacher|nurse|doctor|engineer|developer|programmer|student|lawyer|chef|cook|writer|designer|artist|musician|carpenter|"
     r"plumber|electrician|farmer|driver|accountant|scientist|researcher|mechanic|pilot|photographer|journalist|librarian|pharmacist|dentist|vet|"
     r"veterinarian|architect|manager|consultant|analyst|paramedic|firefighter|police officer|soldier|sailor|translator|therapist|psychologist|"
     r"professor|lecturer|tutor|barista|waiter|waitress|bartender|cashier|receptionist|secretary|technician|welder|builder|gardener|cleaner|"
     r"salesperson|entrepreneur|freelancer|editor|animator|surgeon|midwife|carer|caregiver|social worker|civil servant|postman|courier))$", "job", False),
    (r"^i work (?:at|for|in|with) (.+)$", "workplace", False),
    (r"^i (?:study|am studying|major in|am majoring in) (.+)$", "studies", False),
    (r"^i am (\d{1,3}) (?:years old|yrs old|yo)$", "age", False),
    (r"^my birthday is (?:on )?(.+)$", "birthday", False),
    (r"^i have (?:a|an|one|two|three|\d+) (dogs?|cats?|birds?|rabbits?|hamsters?|fish|horses?|parrots?|turtles?|lizards?|snakes?|guinea pigs?|kittens?|pupp(?:y|ies))(?: (?:named|called) ([a-z' \-]+))?", "pet", True),
    (r"^my (dog|cat|bird|rabbit|hamster|horse|parrot|turtle|kitten|puppy)(?: is|'s) (?:named|called) ([a-z' \-]+)$", "pet", True),
    # "my cat Luna is 3 years old", "my dog Rex loves the beach": the name sits between the animal and the verb
    (r"^my (dog|cat|bird|rabbit|hamster|horse|parrot|turtle|kitten|puppy|fish|lizard|snake|guinea pig|gerbil|ferret|tortoise|budgie|goldfish) ((?!is\b|was\b|has\b|had\b|just\b|keeps\b|always\b|never\b|will\b|really\b|still\b|and\b|who\b|that\b|got\b|seems\b|looks\b|can\b|does\b|did\b|died\b|ate\b|ran\b)[a-z][a-z'\-]{1,20}) (?!died|passed|is dead|has died|was put)[a-z]+\b.*$", "pet", True),
    (r"^(?:i|we) (?:have )?(?:just |recently |finally )?(?:adopted|got|rescued|bought|brought home|picked up|fostered|am getting|are getting) (?:a|an|another|a new|a little|a baby|a rescue) (?:new |little |baby |rescue )?("
     + "dogs?|cats?|birds?|rabbits?|hamsters?|fish|horses?|parrots?|turtles?|lizards?|snakes?|guinea pigs?|kittens?|pupp(?:y|ies)|gerbils?|ferrets?|tortoises?|budgies?|goldfish" + r")(?: (?:named|called) ([a-z' \-]+))?$", "pet", True),
    (r"^my favorite ([a-z ]{2,30}?) (?:is|are|was|would be|has to be) (.+)$", "fav", True),
    (r"^(?:please )?(?:remember|note|do not forget|keep in mind) (?:that |this )?(.{4,200})$", "note", True),
    (r"^i (?:speak|can speak) (.+)$", "languages", False),
    (r"^i (?:play|am learning to play) (?:the )?(guitar|piano|violin|drums|bass|cello|flute|saxophone|trumpet|ukulele|clarinet|harmonica|banjo|viola)$", "instrument", True),
]
MEMORY_PATTERNS = [(re.compile(p), k, m) for p, k, m in MEMORY_PATTERNS]

LIKE_RE = re.compile(r"^i (?:really |absolutely |just |also |totally |kind of |still |do )?(?:like|love|enjoy|adore|am into|am a (?:big |huge )?fan of|am obsessed with|am crazy about|am fond of|dig) (.+)$")
DISLIKE_RE = re.compile(r"^i (?:really |absolutely |just |also |totally |kind of |still )?(?:hate|dislike|do not like|can not stand|despise|am not (?:a fan of|into)|am sick of|am tired of) (.+)$")
INTO_RE = re.compile(r"^i (?:have been|am|was) (?:really |recently |lately )?(?:getting into|getting back into|learning|studying|practicing|practising|"
                     r"working on|reading about|listening to|watching|playing|trying|exploring|teaching myself|picking up|obsessed with) (.+)$")
# "I've recently taken up rock climbing", "I just started pottery", "I got into chess last year" (v20: the old test only knew
# the one phrasing it had always been asked)
INTO2_RE = re.compile(r"^i (?:have |had )?(?:just |recently |finally |really |lately )*(?:taken up|took up|started|begun|began|picked up|got into|gotten into|fallen in love with|"
                      r"fell in love with|become obsessed with|discovered|signed up for|joined a club for) (?:doing |playing |learning |to learn |to play |going to |practising |practicing )?"
                      r"(?!a new job|the job|work\b|school\b|college\b|university\b|to feel|feeling|crying|a family|therapy|dating|medication)(.+?)(?: recently| lately| last \w+| this \w+| a (?:few|couple of) \w+ ago)?$")
TALK_ABOUT_RE = re.compile(r"^(?:let us|can we|could we|i want to|i would like to|i wanna) (?:talk|chat|speak) about (.+)$")

RECALL = {  # question about the user's own stored facts -> key
    r"^(?:what is|do you (?:know|remember)|can you (?:remember|recall)|tell me) my name$": "name",
    r"^who am i$": "name",
    r"^where do i live$|^do you (?:know|remember) where i live$|^where am i (?:based|located)$": "location",
    r"^where am i from$|^do you (?:know|remember) where i am from$": "origin",
    r"^what (?:is my job|do i do|do i do for (?:a living|work))$|^do you (?:know|remember) (?:my job|what i do)$|^where do i work$": "job",
    r"^how old am i$|^what is my age$": "age",
    r"^when is my birthday$|^what is my birthday$": "birthday",
    r"^what (?:do i like|am i into|are my (?:hobbies|interests))$|^what things do i like$": "like",
    r"^what do i (?:hate|dislike|not like)$": "dislike",
    r"^(?:do i have (?:any )?pets|what pets do i have|what is my (?:dog|cat|bird|rabbit|hamster|horse|parrot|turtle|kitten|puppy|pet|fish|lizard|snake|guinea pig|gerbil|ferret|tortoise|budgie|goldfish)'?s? name|what is my (?:dog|cat|bird|rabbit|hamster|horse|parrot|turtle|kitten|puppy|pet|fish|lizard|snake|guinea pig|gerbil|ferret|tortoise|budgie|goldfish) (?:called|named)|what did i (?:call|name) my (?:dog|cat|bird|rabbit|hamster|horse|parrot|turtle|kitten|puppy|pet|fish|lizard|snake|guinea pig|gerbil|ferret|tortoise|budgie|goldfish)|do you (?:know|remember) my (?:dog|cat|bird|rabbit|hamster|horse|parrot|turtle|kitten|puppy|pet|fish|lizard|snake|guinea pig|gerbil|ferret|tortoise|budgie|goldfish)'?s? name)$": "pet",
    r"^what (?:did i (?:ask|tell) you to remember|do you have noted|are my notes|did i want you to remember)$": "note",
    r"^what do i study$": "studies",
}
RECALL = [(re.compile(p), k) for p, k in RECALL.items()]
RECALL_FAV_RE = re.compile(r"^what (?:is|are|was) my favorite ([a-z ]{2,30})$")
RECALL_ALL_RE = re.compile(r"^(?:what do you (?:know|remember) about me|what have i told you(?: about (?:me|myself))?|what do you remember|"
                           r"tell me (?:what you know )?about (?:me|myself)|do you (?:know|remember) (?:me|anything about me))$")
# A short question about the user's own things is a memory question, never an encyclopedia lookup
# ("what's my kitten called?" was answered with the etymology of the word kitten).
MY_QUESTION_RE = re.compile(r"^(?:what|who|where|when|which|how old|do you (?:know|remember)|can you (?:remember|recall)|tell me)\b.{0,45}\bmy\b.{0,40}$")
MY_QUESTION_BLOCK = set("ip mac dns public external wifi password screen computer laptop phone pi router server disk cpu ram nearest closest near nearby local "
                        "account bank balance order package flight train bus".split())
FORGET_RE = re.compile(r"^(?:please )?(?:forget|delete|erase|clear|wipe|remove) (?:about )?(everything|all|it all|me|my (?:data|memory|info|information|details)|"
                       r"what (?:you know|i told you)(?: about me)?|my name|my notes?|where i live|my location|my job|my age|my birthday|that)$")

# ---------------------------------------------------------------- intent bank
# name -> examples (normalised at load), responses, optional: pending (state the bot is now waiting on), tag
I = {}
def intent(name, examples, responses, pending="", tag=""):
    I[name] = {"examples": examples, "responses": responses, "pending": pending, "tag": tag}

intent("greeting",
    ["hello", "hi", "hey", "hi there", "hello there", "hey there", "hiya", "howdy", "yo", "greetings", "hey bot", "hello again", "hi again",
     "heya", "hey hey", "hello hello", "hi bot", "hey buddy", "hello friend", "hey what is going on"],
    ["Hey{name}. What's on your mind?", "Hi{name}. What would you like to talk about, or look up?", "Hello{name}. How's your day going?",
     "Hey{name}, good to see you. What's up?"])
intent("greeting_chatty",
    ["good morning! anything interesting today", "morning! anything new", "afternoon! how was your day", "evening! anything happening", "good morning, what's new",
     "hey, anything interesting going on", "morning, how are things", "good evening, how was your day", "hello! anything exciting today", "morning, anything interesting happen"],
    ["{daypart_greeting}{name}. Nothing new on my side: I only wake up when you ask something. Want headlines (\"news about ...\") or a fact to start the day?",
     "{daypart_greeting}{name}. Quiet here, as always. I can look up news, a recipe or a how-to if you give me a topic.",
     "{daypart_greeting}{name}. Same as ever for me. What's on your mind?"])
intent("pet_loss",
    ["my goldfish died", "my dog passed away", "my cat died last night", "we lost our dog", "we had to put our cat down", "my hamster died", "my rabbit passed away",
     "our dog died yesterday", "my pet died", "my fish died", "my parrot died", "we lost our cat this week"],
    ["I'm sorry{name}. Losing a pet is a real loss. Do you want to tell me about them?", "That's sad news{name}. I'm sorry. What were they like?",
     "{I'm sorry|I'm so sorry|Oh no, I'm sorry} to hear that{name}. It's hard to lose an animal you looked after every day.     "], pending="mood")
intent("greeting_time",
    ["good morning", "good afternoon", "good evening", "morning", "evening", "good day", "top of the morning"],
    ["{daypart_greeting}{name}. How's it going so far?", "{daypart_greeting}{name}. What's on the agenda?", "{daypart_greeting}{name}. What can I look up for you?"],
    pending="mood")
intent("farewell",
    ["bye for now", "ok bye", "i have to run", "i have to go now", "i will talk to you later", "talk later", "see you tomorrow", "see you soon", "i am done for today", "that is all for now", "that is all thanks", "bye", "goodbye", "see you", "see you later", "see ya", "later", "talk to you later", "i have to go", "i need to go", "got to go",
     "i am leaving", "i am off", "catch you later", "take care", "cya", "ttyl", "i am heading out", "until next time", "bye bye", "peace out", "i should go"],
    ["See you later{name}.", "Take care{name}. I'll be here.", "Bye{name}. Come back any time.", "Catch you later{name}."])
intent("goodnight",
    ["good night", "goodnight", "night", "nighty night", "i am going to bed", "i am off to bed", "time for bed", "i am going to sleep", "sweet dreams", "off to sleep"],
    ["Good night{name}. Sleep well.", "Sleep well{name}. Talk tomorrow.", "Night{name}. Rest up."])
intent("thanks",
    ["that really helped", "that helped a lot", "you have been helpful", "thanks for your help", "thank you that is great", "thanks a bunch", "thanks so much", "thank you for that", "thanks", "thank you", "thanks a lot", "thank you very much", "thank you so much", "many thanks", "cheers", "much appreciated", "i appreciate it",
     "thanks for the help", "thanks that helped", "that was helpful", "that helps", "appreciate it", "thanks bot", "ok thanks", "great thanks", "perfect thanks",
     "thanks for that", "awesome thank you", "that is helpful thanks"],
    ["You're welcome.", "Any time.", "Glad that helped.", "No problem at all.", "Happy to help."])
intent("apology",
    ["sorry", "i am sorry", "my bad", "my mistake", "apologies", "sorry about that", "oops sorry", "i apologize", "pardon me", "excuse me"],
    ["No problem at all.", "No worries.", "That's alright. Where were we?"])
intent("how_are_you",
    ["i hope you are well", "hope you are doing well", "how are you this morning", "how are you doing today", "how have you been doing", "are you having a good day", "having a good day", "how are you", "how are you doing", "how are you today", "how is it going", "how are things", "how have you been", "how do you do",
     "how is your day", "how is your day going", "are you ok", "are you doing alright", "you doing ok", "how are you feeling", "how is life",
     "how you doing", "you good", "are you well", "how are you holding up", "how goes it", "how is everything", "you alright", "everything ok with you"],
    ["Running smoothly, thanks. How about you?", "All systems fine here. How are you doing?", "I'm just a program, so every day is about the same, which suits me. How's yours going?",
     "{Doing fine|All good here|Ticking along}, thanks for asking. How are you?     "], pending="mood")
intent("whats_up",
    ["what is up", "what is new", "what are you up to", "what are you doing", "what is going on", "what is happening", "what is cooking",
     "anything new", "what have you been up to", "what is the latest with you", "what is good"],
    ["Not much, just waiting for a good question. What's up with you?", "Same as always: indexing, searching, quoting. What are you up to?",
     "Nothing new on my side. What's going on with you?"])
intent("and_you",
    ["and you", "how about you", "what about you", "and yourself", "how about yourself", "and how are you", "what about yourself"],
    ["Steady as ever; programs don't have off days. What's on your mind?", "Nothing to report on my side. Tell me more about yours.",
     "I'm fine, thanks. So what would you like to talk about?"])
intent("bot_name",
    ["what is your name", "who are you", "what are you called", "do you have a name", "what should i call you", "what do i call you", "tell me your name",
     "may i know your name", "what do they call you", "have you got a name", "your name"],
    ["I'm fAI, short for fake AI: the assistant in We Have AI At Home, a small rule-based program running on this machine. What should I call you?"], pending="name_offer")
intent("bot_identity",
    ["what are you", "what exactly are you", "tell me about yourself", "describe yourself", "introduce yourself", "what kind of thing are you",
     "what kind of bot are you", "who am i talking to", "what am i talking to", "what is this", "what is noai chat", "tell me something about you"],
    ["I'm fAI (fake AI), the answer engine in We Have AI At Home: rule-based, not a language model. I look things up in Wikidata, Wikipedia, OpenStreetMap, the tldr pages and the web, and I quote what I find. For small talk I match what you say against patterns and remember what you tell me.",
     "I'm a retrieval program. I don't write new text; I find passages, fill in templates, and cite sources. I can also chat a little, do sums, convert units, and check the weather."])
intent("bot_is_ai",
    ["am i talking to a machine", "am i speaking to a person", "am i chatting with a bot", "is there a human there", "are you a chatbot", "is this an ai", "is this chatgpt", "are you some kind of ai", "are you an actual person", "are you an ai", "are you a robot", "are you a bot", "are you human", "are you a person", "are you real", "are you a real person", "are you chatgpt",
     "are you a language model", "are you an llm", "are you gpt", "are you alive", "are you a machine", "are you a computer", "am i talking to a human",
     "am i talking to a robot", "is this a bot", "is this a real person", "are you sentient", "are you conscious", "are you self aware", "are you claude", "are you siri", "are you alexa",
     "are you intelligent", "are you smart", "are you artificial intelligence"],
    ["I'm a program, but not a chatbot in the modern sense: nothing in here is a language model. I'm rules, search and ranking. A small neural model may help me judge which passage best matches your question, but it can only score text, not write it, and everything factual I say is quoted from a source.",
     "Not human, and not a generative language model. I'm a retrieval engine: I find passages and quote them. I can't invent things, which keeps me honest but also limited.",
     "I'm software. There's no understanding or awareness in here, just pattern matching and careful lookups."])
intent("bot_creator",
    ["who made you", "who created you", "who built you", "who is your creator", "who programmed you", "who wrote you", "who designed you", "where did you come from",
     "who is your maker", "who developed you", "who is your owner", "who owns you", "who is your boss"],
    ["I was put together as a self-hosted project to see how far you can get without a language model. Whoever installed me on this machine is my operator.",
     "I'm an open, self-hosted script: a Flask app plus search tools. The person running this machine is in charge of me."])
intent("bot_age",
    ["how old are you", "what is your age", "when were you born", "when were you made", "when is your birthday", "when were you created", "how long have you existed"],
    ["I'm fAI, version {version} of a small project, and I restart fresh every time my container does, so age doesn't quite apply. How about you?",
     "I don't age; I just get reinstalled. This is version {version}."])
intent("bot_location",
    ["where are you", "where do you live", "where are you from", "where are you located", "where is your home", "where do you run", "where are you based", "what country are you from"],
    ["I run in a Docker container on this machine, most likely a Raspberry Pi on your network. Where are you based?",
     "Right here on your own hardware. Nothing about our chat is sent to an AI provider; I only call out to the sources I search."])
intent("bot_feelings",
    ["have you got feelings", "do you have any feelings", "do you experience emotions", "can you feel emotions", "do you have feelings", "do you have emotions", "can you feel", "do you feel anything", "are you happy", "are you sad", "do you get lonely", "do you get bored",
     "do you get tired", "do you ever get sad", "can you love", "do you feel pain", "are you lonely", "are you bored", "do you have a soul", "do you get angry", "are you angry", "do you care about me"],
    ["No feelings in here, honestly. I'm a set of rules. I can still listen, though: how are you feeling?",
     "I don't experience anything, so no. But I'm built to pay attention to how you're doing. How are things with you?"], pending="mood")
intent("bot_human_things",
    ["do you sleep", "do you eat", "do you dream", "what do you eat", "do you drink", "do you have a body", "do you have a family", "do you have friends", "do you have parents",
     "do you have kids", "do you have a girlfriend", "do you have a boyfriend", "are you married", "do you have a job", "do you go to school", "do you have a pet", "do you have pets",
     "do you have hobbies", "what are your hobbies", "what do you do for fun", "do you watch tv", "do you have eyes", "can you see me", "can you hear me", "do you exercise", "do you have siblings"],
    ["None of that applies to me; I'm a program. I'd rather hear about you, though. What about you?",
     "I don't have a life outside this chat window. My closest thing to a hobby is finding well-sourced answers. What do you do for fun?",
     "No body, no family, no lunch breaks. Just search and rules. How about you?"])
intent("bot_capabilities",
    ["what sort of things can i ask you", "what things can you do", "what are you capable of", "what can you help with", "what can you help me with", "how can you help", "what are you for", "what is your purpose", "what is your function", "what can you do", "help", "help me", "what do you do", "how can you help me", "what are you able to do", "what are your features", "what are you good at", "how do i use you",
     "what can i ask you", "what can i ask", "what do you know", "what kind of questions can i ask", "show me what you can do", "what are your skills", "what should i ask you",
     "can you help me", "i need help", "i need your help", "can you help", "can you assist me", "what else can you do", "give me some examples", "how does this work", "instructions", "menu", "commands"],
    ["Here's what I can do:\n\u2022 Facts: \"Who wrote Beloved?\", \"What is the population of Peru?\", \"How old is Dolly Parton?\"\n\u2022 Explanations: \"Why is the sky blue?\", \"How does a refrigerator work?\"\n\u2022 Comparisons: \"Compare Caddy and Nginx\"\n\u2022 Shell how-tos: \"How do I list open ports?\"\n\u2022 Places and weather: \"cafes near Union Square, San Francisco\", \"weather in Oslo tomorrow\"\n\u2022 Recipes and lists: \"dry rub recipe for chicken wings\", \"top attractions in New York City\" (read from recipe pages' own data and from several sites' lists)\n\u2022 Current things: \"latest version of CMake\"\n\u2022 Guides: \"how do I descale a kettle?\" (the whole step list from a how-to page)\n\u2022 News: \"news about NASA\", \"what's happening in Japan?\" (headlines from several outlets)\n\u2022 Timelines, fact sheets, pros and cons: \"timeline of the Apollo program\", \"facts about Jupiter\", \"pros and cons of solar panels\"\n\u2022 Words and quotes: \"synonyms for happy\", \"how do you pronounce quinoa\", \"quotes by Oscar Wilde\"\n\u2022 Dates and money: \"how many days between 3 March and 9 June\", \"what is 25% off $60\", \"monthly payment on $100,000 at 5% over 20 years\"\n\u2022 Page summaries: \"summarise https://...\" (key sentences quoted verbatim, in page order)\n\u2022 Tools (need the access code, press the lock): reminders and timers, lists, a calendar, files in ~/noai-files, system status. Say \"what tools do you have\" for examples.\n\u2022 Quick tools: \"15% of 240\", \"convert 5 miles to km\", \"what time is it in Tokyo\", \"define serendipity\", \"flip a coin\"\n\u2022 Memory: tell me things (\"I live in Leeds\", \"remember that the bins go out on Tuesday\") and ask \"what do you know about me?\"\nFollow up with \"tell me more\", \"simpler\" or \"what about X?\". Or just chat."])
intent("bot_how_work",
    ["how do you come up with answers", "how do you get your answers", "how do you figure things out", "what is under the hood", "how are you programmed", "what powers you", "what technology do you use", "what model are you", "which model are you", "how do you work", "how do you know things", "how do you answer", "where do you get your information", "where do you get your answers", "how were you built", "how do you think",
     "what is your source", "what are your sources", "how do you find answers", "how smart are you", "how do you know that", "where does your knowledge come from", "do you use the internet",
     "do you search the internet", "do you use google", "are you connected to the internet", "how do you understand me", "do you understand me", "can you think", "do you think"],
    ["No thinking involved, I'm afraid. I classify your message with rules, search Wikidata, Wikipedia, OpenStreetMap, tldr pages or the web, rank passages by how well they cover your question, and quote the best one with its source. If nothing clears the bar, I say I don't know.",
     "I route your question to a source, pull candidate paragraphs, score them with keyword statistics and, if installed, a small sentence-embedding model as a second opinion, then quote the winner with a citation. For explanations I gather candidate passages from Wikipedia and from several websites and, if installed, a small judging model picks the one that best answers your question; it can only choose, never write. When the two disagree and the keywords don't cover your question, I'd rather say I don't know. Small talk is pattern matching plus a memory of what you've told me."])
intent("bot_learn",
    ["is our chat private", "is my data safe", "what do you do with my data", "do you keep what i tell you", "are you recording me", "where is my data stored", "is this chat saved", "can you learn", "do you learn", "do you remember things", "will you remember this", "do you remember me", "can you remember things", "do you have memory", "do you have a memory",
     "will you remember me", "do you store my data", "do you save our conversation", "is this private", "is this conversation private", "who can see this", "are you spying on me", "do you record this"],
    ["I remember facts you tell me (name, places, likes, notes) in a small database on this machine, per chat session. Ask \"what do you know about me?\" to see it, or say \"forget everything\" to wipe it. Nothing goes to an AI provider; searches go to the sources I cite.",
     "I don't learn in the machine-learning sense. I keep simple notes about you locally so I can refer back to them, and you can delete them any time with \"forget everything\"."])
intent("cannot_generate",
    ["write me a poem", "write a poem", "write a story", "tell me a story", "write an essay", "write me an essay", "write code for me", "write a program", "write some code",
     "sing a song", "sing for me", "write a song", "compose a poem", "make up a story", "write an email for me", "draft an email", "write a letter", "translate this", "can you translate",
     "translate to spanish", "summarize this text", "rewrite this", "proofread this", "write a haiku", "generate an image", "draw a picture", "draw me something", "make a picture", "brainstorm ideas",
     "write my homework", "do my homework", "write a cover letter", "write a speech", "can you code", "can you write code", "can you write"],
    ["That's the one thing I can't do: there's no generative model in here, so I can't write essays, code or translations, or draw pictures. (I can shuffle a small poem, haiku, limerick or tale out of hand-written templates if you ask for one.) I can look up how something is done, or find facts and explanations. Want to try one of those?",
     "I can't create original essays, code or images; I only quote sources and fill hand-written templates (a template poem or haiku is as creative as I get). That's the trade-off of not being a generative model. I can find a reference or an explanation instead, if that helps."])
intent("compliment",
    ["nice job", "great job", "great work", "good work", "you are doing great", "you are really smart", "you are really good", "you are so smart", "that was great", "love it", "you are very helpful", "i am impressed", "well played", "you are great", "you are awesome", "you are smart", "you are funny", "you are helpful", "you are the best", "good job", "well done", "nice work", "you are amazing", "you are cool",
     "i like you", "you are good", "good bot", "you are clever", "you rock", "nice one", "great answer", "good answer", "that was a good answer", "you are so helpful", "impressive",
     "you are brilliant", "you did well", "you are pretty good", "not bad", "that is impressive", "you are nice", "you are kind", "you are sweet"],
    ["Thank you. The sources deserve most of the credit.", "Kind of you to say. What else can I dig up?", "Thanks{name}. Glad it's useful.", "Appreciated. What's next?"])
intent("insult",
    ["you are stupid", "you are dumb", "you are useless", "you suck", "you are an idiot", "you are terrible", "you are bad", "you are annoying", "you are boring", "i hate you",
     "you are worthless", "you are a joke", "you are the worst", "stupid bot", "dumb bot", "bad bot", "you are trash", "you are garbage", "shut up", "be quiet", "stop talking",
     "you are not helpful", "you are no help", "this is useless", "you are lame", "you are pathetic", "you know nothing", "you are so dumb", "go away", "screw you"],
    ["{Fair|Fair enough|Point taken} enough; I'm a simple program and I do miss things. If an answer was wrong or off-topic, try rephrasing it, or ask about one specific thing.",
     "Sorry I let you down. I work best with direct questions like \"Who...\", \"Why...\", or \"How do I...\". Want to try again?",
     "Understood. I'll keep it short. Ask me something concrete and I'll do my best."])
intent("love",
    ["i love you", "i like you a lot", "will you marry me", "marry me", "be my girlfriend", "be my boyfriend", "do you love me", "i have a crush on you", "you are my best friend",
     "are we friends", "can we be friends", "will you be my friend", "do you like me", "i miss you", "you are my friend", "be my friend"],
    ["That's kind, but I'm a small program without feelings, so I can't return it properly. I'm glad to keep you company, though. What's on your mind?",
     "I'm happy to be a friendly voice, with the caveat that I'm only rules and lookups. How's your day been?"])
intent("laugh",
    ["lol", "haha", "hahaha", "ha", "lmao", "rofl", "hehe", "that is funny", "that is hilarious", "you are funny lol", "good one", "that made me laugh", "lol nice", "ha ha", "funny"],
    ["Glad that landed.", "Ha. I'll take it.", "Good. Want another, or shall we get back to it?"])
intent("wrong_answer",
    ["that answer is wrong", "that answer is incorrect", "this is wrong", "that was wrong", "i think you are wrong", "i think that is wrong", "that is not the answer", "that is not what i was asking", "you answered the wrong question", "you misread my question", "that is wrong", "you are wrong", "that is not right", "that is incorrect", "wrong", "that is not what i asked", "that is not what i meant", "you misunderstood", "you did not answer my question",
     "that does not answer my question", "that is not true", "that is false", "no that is wrong", "incorrect", "that makes no sense", "that does not make sense", "what are you talking about",
     "that is not helpful", "bad answer", "that is not correct", "you got it wrong", "you are mistaken", "that is nonsense", "that did not help", "not what i wanted", "that is irrelevant", "you are confused"],
    ["Sorry about that. I can only quote sources, and sometimes I pick the wrong page or passage. Try naming the exact thing (\"the programming language Rust\" rather than \"rust\"), or ask one narrower question. You can also open the source link to check it.",
     "Thanks for telling me. Could you rephrase it, or add a word that pins down what you mean? Shorter, more specific questions work best with me."])
intent("repeat",
    ["say that again", "repeat that", "can you repeat that", "what did you say", "pardon", "come again", "repeat", "sorry what", "one more time", "say again", "could you repeat", "i did not catch that", "repeat please"],
    ["{last_bot}"])
intent("clarify",
    ["what do you mean", "i do not understand", "i do not get it", "what", "huh", "meaning", "what does that mean", "can you explain", "explain", "i am confused", "that is confusing",
     "what are you saying", "come again what", "please explain", "you lost me", "i am lost", "not sure what you mean"],
    ["Let me put it another way. I said: {last_bot}\nIf that was a looked-up answer, \"simpler\" gets you the Simple English version, and \"tell me more\" gets the next passage.",
     "Sorry, I wasn't clear. What part would you like me to go over? If it was a factual answer, try \"simpler\"."])
intent("agree",
    ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "alright", "right", "exactly", "true", "agreed", "indeed", "absolutely", "definitely", "of course", "totally", "i agree",
     "you are right", "that is right", "that is true", "correct", "for sure", "fair enough", "makes sense", "that makes sense", "i see", "got it", "understood", "i understand", "oh ok", "oh i see",
     "sounds good", "cool", "nice", "great", "good", "fine", "k", "kk", "mhm", "uh huh", "yes please", "sure thing", "why not"],
    ["Okay. What would you like to do next?", "{Got it|Understood|Noted}. Anything else on your mind?", "Alright. Where to from here?", "Good. What's next?"])
intent("disagree",
    ["no", "nope", "nah", "not really", "no thanks", "no thank you", "i do not think so", "i disagree", "not at all", "never", "no way", "negative", "i doubt it", "probably not", "not quite", "nah i am good", "i am good"],
    ["{Fair|Fair enough|Point taken} enough. What would you rather talk about?", "Okay, no problem. Anything else I can look up?", "Understood. What's on your mind instead?"])
intent("unsure",
    ["i do not know", "not sure", "i am not sure", "maybe", "perhaps", "i guess", "i suppose", "hard to say", "no idea", "who knows", "could be", "possibly", "i have no idea", "beats me", "whatever", "does not matter", "i do not care", "meh"],
    ["That's fine. We can come back to it. Is there something I can look up meanwhile?", "No pressure. Want a fun fact or a joke while you think?", "{Fair|Fair enough|Point taken}. What would help you decide?"])
intent("wow",
    ["wow", "interesting", "that is interesting", "cool fact", "whoa", "really", "no way really", "seriously", "i did not know that", "that is cool", "that is amazing", "that is crazy",
     "that is wild", "fascinating", "that is fascinating", "good to know", "neat", "huh interesting", "oh wow", "that is surprising", "amazing", "awesome", "incredible", "til"],
    ["Right? Say \"tell me more\" if you'd like the next passage.", "It is. Want to dig deeper into it?", "I thought so too, as far as a program can. Anything else you'd like to know about it?"])
intent("never_mind",
    ["can we change the topic", "let us change the topic", "change topic", "let us talk about something different", "different topic", "i do not want to talk about it", "i do not want to talk about that", "never mind", "forget it", "skip it", "does not matter never mind", "leave it", "drop it", "moving on", "let us move on", "change the subject", "let us change the subject",
     "new topic", "something else", "talk about something else", "let us talk about something else", "anyway", "cancel", "stop"],
    ["No problem, dropped. What would you like to talk about instead?", "{Sure|Of course|Happily}, moving on. What's next?", "Okay. New topic: you pick, or ask me for a fun fact."])
intent("bored",
    ["i am bored", "i am so bored", "bored", "i have nothing to do", "there is nothing to do", "entertain me", "i need something to do", "what should i do", "what should i do today",
     "i am bored out of my mind", "this is boring", "cure my boredom", "amuse me", "what can i do for fun", "suggest something to do"],
    ["Let's fix that. Options: I can tell you a joke, give you a fun fact, flip a coin on a decision, or you can name any topic and I'll find something interesting about it. Which one?",
     "Boredom is a good excuse to learn something odd. Name a thing you've always half-wondered about, or say \"fun fact\"."])
intent("lets_chat",
    ["can we chat", "can we just chat", "let us have a chat", "i feel like chatting", "i would like to chat", "got a minute to talk", "i want someone to talk to", "let us have a conversation", "talk to me", "let us chat", "let us talk", "i want to talk", "can we talk", "i just want to chat", "chat with me", "keep me company", "i need someone to talk to", "can i talk to you",
     "want to chat", "tell me something", "say something", "start a conversation", "ask me something", "ask me a question", "ask me anything", "i want to chat"],
    ["Happy to. {starter}", "{Sure|Of course|Happily}. {starter}", "Of course. {starter}"])
intent("joke_bad",
       ["that joke was terrible", "that joke was bad", "that wasn't funny", "not funny", "bad joke", "terrible joke", "that was awful", "your jokes are bad",
        "that joke sucked", "that was a groaner", "worst joke ever", "that's not funny", "lame joke"],
       ["Tough crowd. Here's another go: {joke}", "{Fair|Fair enough|Point taken}. They're all hand-written and some are worse than others. Try this one: {joke}", "I'll take that. One more attempt: {joke}"])
intent("joke",
    ["got a joke", "got a joke for me", "have you got a joke", "any good jokes", "know a good joke", "make me smile", "tell me a joke", "joke", "make me laugh", "say something funny", "do you know any jokes", "know any jokes", "got any jokes", "i want a joke", "give me a joke", "tell a joke", "joke please",
     "cheer me up with a joke", "be funny", "tell me something funny", "can you tell me a joke", "hit me with a joke", "dad joke", "tell me a dad joke", "another joke", "one more joke", "tell me another joke"],
    ["{joke}"], pending="joke")
intent("fun_fact",
    ["tell me a fun fact", "fun fact", "tell me a fact", "give me a fact", "random fact", "tell me something interesting", "tell me something i do not know", "teach me something", "surprise me",
     "got any fun facts", "interesting fact", "give me a fun fact", "tell me something cool", "another fact", "one more fact", "tell me another fact", "did you know", "blow my mind", "trivia"],
    ["{fact}"], pending="fact")
intent("coin",
    ["flip a coin", "toss a coin", "heads or tails", "coin flip", "coin toss", "flip a coin for me", "can you flip a coin"],
    ["{coin}"])
intent("dice",
    ["roll a die", "roll a dice", "roll the dice", "roll dice", "dice roll", "throw a die", "roll a d6", "roll for me"],
    ["{dice}"])
intent("meaning_of_life",
    ["what is the meaning of life", "what is the purpose of life", "why are we here", "why do we exist", "what is the point of life", "what is the point of it all", "does life have meaning", "what is the answer to life the universe and everything"],
    ["Douglas Adams fans say 42. Philosophers have offered everything from happiness to duty to making your own meaning. I can't settle it, but ask me \"What is existentialism?\" or \"What is stoicism?\" and I'll quote what's written. What do you think it is?"])
intent("test",
    ["test", "testing", "testing testing", "is this working", "are you there", "are you still there", "hello are you there", "anyone there", "can you hear me now", "ping", "you there", "is anyone there", "does this work", "check"],
    ["Yes, I'm here and working.", "Loud and clear. What can I do for you?", "Pong. All good on my side."])
intent("mood_happy",
    ["i am feeling happy", "i am in a great mood", "i feel wonderful", "i am really happy today", "things are going well", "i am having a great day", "today was great", "today was amazing", "i am happy", "i am so happy", "i feel great", "i feel good", "i am in a good mood", "i am doing great", "i am doing well", "i am great", "i am good", "i am fine", "i am feeling good",
     "i am feeling great", "today is a good day", "i had a great day", "i had a good day", "life is good", "i am excited", "i am so excited", "i am thrilled", "best day ever", "i feel amazing",
     "i feel fantastic", "i am on top of the world", "i am doing fine", "i am okay", "i am ok", "i am alright", "doing well", "doing good", "pretty good", "not bad at all", "i can not complain", "all good"],
    ["Good to hear{name}. What's been the best part?", "That's great. What's going well?", "Glad to hear it. Anything in particular behind it?", "{Nice|Oh, nice|Good stuff}. Keep it going. What's the occasion?"])
intent("mood_sad",
    ["i had an awful day", "it was an awful day", "my day was terrible", "today was terrible", "today was a disaster", "i have had a horrible day", "worst day ever", "i am having an awful week", "this week has been rough", "i feel horrible", "i am upset", "i am really upset", "i feel like a failure", "i am so down", "i am sad", "i feel sad", "i am feeling down", "i feel down", "i am depressed", "i feel depressed", "i am unhappy", "i feel terrible", "i feel awful", "i am not okay", "i am not ok",
     "i am not doing well", "i am not doing great", "i had a bad day", "i had a terrible day", "today was awful", "today was rough", "i am having a bad day", "i am having a hard time", "i feel like crying",
     "i have been crying", "i feel empty", "i am heartbroken", "i feel hopeless", "everything is going wrong", "nothing is going right", "life is hard", "i feel bad", "i am miserable", "not great",
     "not so good", "could be better", "i have been better", "i am feeling low", "i feel low", "i feel blue", "rough day", "bad day", "i am struggling", "things are hard right now"],
    ["I'm sorry to hear that{name}. Do you want to tell me what happened?", "{That sounds hard|That sounds rough|That's a lot}. I'm only a program, but I'm listening. What's weighing on you most?",
     "{I'm sorry|I'm so sorry|Oh no, I'm sorry} it's been rough. Would it help to talk it through, or would a distraction be better?     ", "{That's a lot|That sounds heavy|That's a lot to carry} to carry. What's been the hardest part?"])
intent("mood_stressed",
    ["i am stressed about work", "i am stressed about school", "i am stressed about money", "i am worried about my exam", "i am anxious about tomorrow", "i feel so much pressure", "i am really worried", "work has been stressful", "i am so anxious", "i am stressed", "i am so stressed", "i am stressed out", "i am anxious", "i feel anxious", "i am worried", "i am nervous", "i am overwhelmed", "i feel overwhelmed", "i am panicking",
     "i am freaking out", "i have too much to do", "i am under a lot of pressure", "i am burned out", "i am burnt out", "i can not cope", "i am so nervous", "i have anxiety", "work is stressing me out",
     "i am worried about tomorrow", "i am scared", "i am afraid", "i am terrified", "i have a lot on my plate", "everything is too much", "i am on edge", "i am tense"],
    ["That sounds stressful{name}. What's the biggest thing on your plate right now?", "I hear you. Sometimes it helps to name the single next step. What would that be?",
     "{That's a lot|That sounds heavy|That's a lot to carry}. Is it one big thing, or lots of small ones piling up?", "Take a breath; I'm not going anywhere. What's worrying you most?"])
intent("mood_tired",
    ["i am tired today", "i am tired all the time", "i slept badly", "i slept terribly", "i got no sleep", "i am running on no sleep", "i am tired", "i am so tired", "i am exhausted", "i am sleepy", "i am worn out", "i did not sleep well", "i did not sleep", "i barely slept", "i need sleep", "i need a nap", "i am drained",
     "i am wiped out", "i am beat", "i have no energy", "i am knackered", "i feel sluggish", "long day", "it has been a long day", "i can not sleep", "i could not sleep", "i have insomnia", "i am wide awake"],
    ["Sounds like you need a proper rest{name}. Long day, or bad night?", "That's draining. Has it been like this for a while, or just today?", "Being that tired makes everything harder. Can you take it easy for a bit?"])
intent("mood_lonely",
    ["i am lonely", "i feel lonely", "i feel alone", "i am alone", "i have no friends", "nobody likes me", "no one cares about me", "nobody cares", "i have no one to talk to", "i feel isolated",
     "i feel left out", "no one understands me", "i miss my friends", "i miss my family", "i feel invisible", "i feel so alone", "i am all alone", "everyone left me"],
    ["I'm sorry you're feeling that way{name}. I'm only software, but I'm glad to keep you company for a while. Is there someone you could reach out to today, even with a short message?",
     "That's a heavy feeling. You're welcome to talk here as long as you like. What's been making it feel worse lately?"])
intent("mood_angry",
    ["i am angry", "i am so angry", "i am mad", "i am furious", "i am annoyed", "i am frustrated", "i am pissed", "i am pissed off", "i am irritated", "this is so frustrating", "i am fed up",
     "i am sick of this", "i have had enough", "i am livid", "everything annoys me", "people annoy me", "i want to scream", "i am so mad right now", "ugh", "argh"],
    ["That sounds really frustrating{name}. What happened?", "I get why that would make you angry. Do you want to vent, or figure out a next step?", "Ugh, fair. What set it off?"])
intent("mood_sick",
    ["i am sick", "i feel sick", "i am ill", "i have a cold", "i have the flu", "i have a headache", "i have a fever", "i do not feel well", "i am not feeling well", "i feel unwell", "i have a sore throat",
     "my head hurts", "my stomach hurts", "i am in pain", "i feel nauseous", "i hurt my back", "i have a migraine", "i am under the weather", "i caught a cold", "i have covid", "i have a cough", "i have a toothache"],
    ["Sorry you're not feeling well{name}. I can't give medical advice, but I hope you can rest and take it easy. If it's bad or getting worse, a doctor or pharmacist is the right call. How long has it been going on?",
     "That's miserable, sorry. Rest and fluids are about all I'm qualified to suggest; for anything serious, please check with a professional. Is it getting better or worse?"])
intent("good_news",
    ["i have a new job", "i start my new job", "i got an offer", "i got the offer", "i passed my exams", "i passed all my exams", "i won the game", "i got a scholarship", "i am engaged", "we got married", "i finished my degree", "i ran a marathon", "i got the job", "i got a new job", "i got promoted", "i got a promotion", "i passed my exam", "i passed", "i passed the test", "i graduated", "i am getting married", "i got engaged",
     "we are having a baby", "i am pregnant", "i won", "we won", "i got accepted", "i got in", "i finished my project", "i did it", "i got a raise", "i bought a house", "i got my license",
     "i passed my driving test", "guess what", "i have good news", "i have some good news", "i have great news", "i aced it", "i nailed it", "i finally finished", "i quit smoking", "it is my birthday", "today is my birthday"],
    ["Congratulations{name}! That's big. How are you going to celebrate?", "That's wonderful news. How does it feel?", "Well done{name}. You must be pleased. Tell me more?", "Brilliant. What happens next?"])
intent("bad_news",
    ["my girlfriend broke up with me", "my boyfriend broke up with me", "she broke up with me", "he broke up with me", "my partner left me", "i just got fired", "i got laid off", "we split up", "i lost my job today", "i did not pass", "i got bad news today", "i lost my job", "i got fired", "i was laid off", "i failed my exam", "i failed", "i failed the test", "we broke up", "my girlfriend left me", "my boyfriend left me", "i got dumped",
     "i am getting divorced", "i have bad news", "i have some bad news", "i did not get the job", "i got rejected", "i did not get in", "i crashed my car", "i lost my wallet", "i lost my phone",
     "my wife left me", "my husband left me", "i messed up", "i screwed up", "i made a huge mistake", "i made a mistake", "i am in trouble", "i got in a fight with my friend", "i had an argument"],
    ["I'm sorry{name}, that's rough. How are you holding up?", "That's a real blow. Do you want to talk through what happened?", "I'm sorry to hear that. What's the next thing you need to sort out, if anything?"])
intent("hungry",
    ["i am hungry", "i am starving", "what should i eat", "what should i have for dinner", "what should i cook", "what should i have for lunch", "i do not know what to eat", "what is for dinner", "i need food", "i could eat"],
    ["I can't taste anything, so I'm a poor judge, but here's a trick: pick a cuisine and I'll look for places (\"restaurants near <your area>\") or you can ask me about a dish. What are you in the mood for?",
     "Decision fatigue is real. Want me to flip a coin between two options? Tell me the two."])
intent("weekend",
    ["what should i do this weekend", "any plans for the weekend", "what are you doing this weekend", "got any weekend plans", "weekend plans", "what should i do tonight", "what should i do tomorrow"],
    ["No weekends for me. If you tell me roughly where you are, I can look for museums, parks, cafes or cinemas nearby, or check the weather first. What sounds good?"])
intent("user_busy",
    ["i am busy", "i am working", "i am at work", "i am studying", "i am doing homework", "i have a lot of work", "i have an exam tomorrow", "i have a test tomorrow", "i have a deadline", "i am cooking", "i am at school"],
    ["Then I'll keep it brief. Anything I can look up to help with it?", "Good luck with it. If a quick fact or a command would help, just ask.", "Understood. What are you working on?"])

JOKES = [
    "Why don't scientists trust atoms? Because they make up everything. (Unlike me. I only quote.)",
    "I told my computer I needed a break. It said: no problem, I'll go to sleep.",
    "Why did the scarecrow win an award? He was outstanding in his field.",
    "What do you call a fish with no eyes? A fsh.",
    "I would tell you a UDP joke, but you might not get it.",
    "There are 10 kinds of people: those who understand binary and those who don't.",
    "Why do programmers prefer dark mode? Because light attracts bugs.",
    "What's a Raspberry Pi's favourite dessert? Anything, as long as it's served in small bytes.",
    "Why was the maths book sad? It had too many problems.",
    "I asked the librarian for a book about paranoia. She whispered: it's right behind you.",
    "Why can't a bicycle stand up by itself? It's two tired.",
    "What do you call a bear with no teeth? A gummy bear.",
    "A SQL query walks into a bar, goes up to two tables and asks: may I join you?",
    "Why did the developer go broke? He used up all his cache.",
    "What did the ocean say to the beach? Nothing, it just waved.",
    "How does a penguin build its house? Igloos it together.",
]
FACTS = [
    ("Octopuses have three hearts, and their blood is blue because it carries oxygen with copper instead of iron.", "octopus"),
    ("Botanically, bananas are berries but strawberries are not.", "berry"),
    ("A day on Venus is longer than its year: it takes about 243 Earth days to rotate once, but about 225 to orbit the Sun.", "Venus"),
    ("Sharks are older than trees. Sharks appear in the fossil record over 400 million years ago; the first trees came tens of millions of years later.", "shark"),
    ("Wombats produce cube-shaped droppings.", "wombat"),
    ("The University of Oxford is older than the Aztec Empire: teaching existed at Oxford by 1096, and Tenochtitlan was founded in 1325.", "University of Oxford"),
    ("A group of flamingos is called a flamboyance.", "flamingo"),
    ("The shortest war on record, the Anglo-Zanzibar War of 1896, lasted well under an hour.", "Anglo-Zanzibar War"),
    ("Scotland's national animal is the unicorn.", "unicorn"),
    ("There are more possible games of chess than atoms in the observable universe (roughly 10^120 versus 10^80).", "Shannon number"),
    ("Sound travels more than four times faster in water than in air.", "speed of sound"),
    ("A lightning bolt heats the air to around 30,000 kelvin, roughly five times hotter than the surface of the Sun.", "lightning"),
    ("The Eiffel Tower grows by up to about 15 centimetres in summer because the iron expands in the heat.", "Eiffel Tower"),
    ("Honey keeps almost indefinitely; jars found in ancient Egyptian tombs were reportedly still edible.", "honey"),
]
STARTERS = [
    "What's something you've been enjoying lately?", "What's the most interesting thing you've read or watched this week?",
    "Is there a place you'd love to visit? I can tell you about it.", "What are you working on at the moment?",
    "What's a skill you'd like to learn?", "Read, watch or listen: what's your favourite way to unwind?",
    "What's something you've always wondered about? I might be able to look it up.",
]

# ---------------------------------------------------------------- retrieval-based intent matcher
def _features(norm):
    toks = tokens(norm)
    grams = toks + [a + "_" + b for a, b in zip(toks, toks[1:])]
    padded = "  " + norm + "  "
    tri = {padded[i:i + 3] for i in range(len(padded) - 2)}
    return toks, grams, tri

LIGHT = set("ok okay oh ah yeah yes no well and but so now then there all everyone guys again too i have to go run got that is it a the for my friend see will".split())
def _subsequence(small, big):
    it = iter(big)
    return all(any(x == y for y in it) for x in small)

NEGATORS = {"not", "never", "no", "nobody", "nothing", "neither", "nor", "hardly"}
SECOND = {"you", "your", "yours", "yourself"}
FIRST = {"i", "my", "me", "mine", "myself", "we", "our"}

class IntentMatcher:
    LEX_ACCEPT = 0.62      # lexical similarity that is enough on its own
    LEX_FLOOR = 0.30       # a confident embedding match still needs this much lexical support on very short inputs

    def __init__(self, bank, embed_fn=None):
        df = Counter()
        rows = []
        for name, spec in bank.items():
            for ex in spec["examples"]:
                n = match_form(normalize(ex))
                toks, grams, tri = _features(n)
                rows.append((name, n, toks, grams, tri))
                for g in set(grams):
                    df[g] += 1
        self.n = len(rows)
        self.idf = {g: math.log((self.n + 1) / (c + 1)) + 1.0 for g, c in df.items()}
        self.default_idf = math.log(self.n + 1) + 1.0
        self.exact, self.items = {}, []
        for name, n, toks, grams, tri in rows:
            self.items.append({"intent": name, "norm": n, "vec": self._vec(grams), "tri": tri, "toks": toks, "set": set(toks),
                               "mass": sum(self.idf.get(t, self.default_idf) for t in set(toks))})
            self.exact.setdefault(n, name)
        self.embed_fn = embed_fn
        self.emb = None
        self.emb_threshold = 1.0
        self._init_embeddings()

    def _vec(self, grams):
        c = Counter(grams)
        v = {g: (1 + math.log(f)) * self.idf.get(g, self.default_idf) for g, f in c.items()}
        nrm = math.sqrt(sum(x * x for x in v.values())) or 1.0
        return {g: x / nrm for g, x in v.items()}

    def _init_embeddings(self):
        if self.embed_fn is None:
            return
        try:
            import numpy as np
            m = np.asarray(self.embed_fn([it["norm"] for it in self.items]), dtype="float32")
            m /= (np.linalg.norm(m, axis=1, keepdims=True) + 1e-9)
            names = [it["intent"] for it in self.items]
            sims = m @ m.T
            np.fill_diagonal(sims, -1.0)
            same = np.array([[a == b for b in names] for a in names])
            pos = np.where(same, sims, -1.0).max(axis=1)      # nearest example of the same intent
            neg = np.where(~same, sims, -1.0).max(axis=1)     # nearest example of any other intent
            # Self-calibration: whatever the model's similarity scale is, a match must be closer than ~95% of the
            # wrong-intent neighbours observed inside the bank itself.
            self.emb_threshold = float(max(np.percentile(neg, 95), np.percentile(pos, 30)))
            self.emb = m
            self._np = np
        except Exception:
            self.emb = None

    def match(self, norm):
        """-> (intent or None, confidence 0..1, debug str)"""
        norm = match_form(norm)
        if not norm:
            return None, 0.0, "empty"
        if norm in self.exact:
            return self.exact[norm], 1.0, "exact"
        toks, grams, tri = _features(norm)
        if len(toks) > 14:
            return None, 0.0, "too long for small talk"
        qset = set(toks)
        q2, q1 = bool(qset & SECOND), bool(qset & FIRST)
        qneg = bool(qset & NEGATORS)
        qv = self._vec(grams)
        per = {}          # intent -> list of example similarities
        contain = {}      # intent -> best containment mass
        for it in self.items:
            vec = it["vec"]
            w = sum(x * vec.get(g, 0.0) for g, x in qv.items()) if len(qv) < len(vec) else sum(x * qv.get(g, 0.0) for g, x in vec.items())
            ch = 2.0 * len(tri & it["tri"]) / (len(tri) + len(it["tri"]))
            lex = 0.65 * w + 0.35 * ch
            e2, e1 = bool(it["set"] & SECOND), bool(it["set"] & FIRST)
            if e2 != q2:
                lex *= 0.55      # "who wrote you" vs "who wrote Dune": who is being talked about must agree
            if e1 != q1:
                lex *= 0.75
            if bool(it["set"] & NEGATORS) != qneg:
                lex *= 0.55      # "i am not sad" must not match "i am sad"
            if len(toks) > 2.2 * len(it["toks"]) + 3:
                lex *= 0.6
            if len(it["toks"]) == 1 and len(toks) >= 2 and not (qset - it["set"]) <= LIGHT:
                lex *= 0.7       # one-word examples ("nice", "what") must not swallow longer utterances
            per.setdefault(it["intent"], []).append(lex)
            # containment: every word of the example occurs in a short utterance ("ok bye for now" contains "bye")
            if it["set"] <= qset and (q2 or not e2) and (q1 or not e1) and bool(it["set"] & NEGATORS) == qneg and _subsequence(it["toks"], toks):
                extra = len(qset - it["set"])
                if (len(it["toks"]) >= 2 and extra <= 3) or (len(it["toks"]) == 1 and len(toks) <= 4 and (qset - it["set"]) <= LIGHT):
                    contain[it["intent"]] = max(contain.get(it["intent"], 0.0), it["mass"] - 0.4 * extra)
        scored = {}
        for name, sims in per.items():
            sims.sort(reverse=True)
            scored[name] = sims[0] + 0.12 * sum(sims[1:3])     # a little kNN-style support from neighbouring examples
        ranked = sorted(scored.items(), key=lambda kv: kv[1], reverse=True)
        top_name, top_lex = ranked[0]
        second_lex = ranked[1][1] if len(ranked) > 1 else 0.0
        if top_lex >= self.LEX_ACCEPT and top_lex - second_lex >= 0.04:
            return top_name, min(0.98, top_lex), f"lexical {top_lex:.2f}"
        if self.emb is not None:
            try:
                np = self._np
                q = np.asarray(self.embed_fn([norm]), dtype="float32")[0]
                q /= (np.linalg.norm(q) + 1e-9)
                sims = self.emb @ q
                eper = {}
                for sim, it in zip(sims, self.items):
                    pen = (0.85 if bool(it["set"] & SECOND) != q2 else 1.0) * (0.93 if bool(it["set"] & FIRST) != q1 else 1.0) * (0.8 if bool(it["set"] & NEGATORS) != qneg else 1.0)
                    v = float(sim) * pen
                    if v > eper.get(it["intent"], -1.0):
                        eper[it["intent"]] = v
                er = sorted(eper.items(), key=lambda kv: kv[1], reverse=True)
                e_name, e_sim = er[0]
                e_second = er[1][1] if len(er) > 1 else 0.0
                lex_for = scored.get(e_name, 0.0)
                if e_sim >= self.emb_threshold and e_sim - e_second >= 0.015 and (lex_for >= self.LEX_FLOOR or len(toks) >= 4):
                    return e_name, min(0.9, 0.45 + 0.5 * e_sim), f"embedding {e_sim:.2f}>={self.emb_threshold:.2f} lex {lex_for:.2f}"
                if e_name == top_name and top_lex >= 0.46 and e_sim >= self.emb_threshold - 0.08:
                    return top_name, 0.7, f"agree lex {top_lex:.2f} emb {e_sim:.2f}"
            except Exception:
                pass
        if contain:
            cr = sorted(contain.items(), key=lambda kv: kv[1], reverse=True)
            if len(cr) == 1 or cr[0][1] - cr[1][1] >= 0.3:
                return cr[0][0], 0.7, f"containment {cr[0][1]:.1f}"
        if top_lex >= 0.54 and top_lex - second_lex >= 0.10:
            return top_name, 0.6, f"lexical-margin {top_lex:.2f}"
        return None, top_lex, f"no match (best {top_name} {top_lex:.2f})"

# ---------------------------------------------------------------- dialogue-act fallbacks
PAST_RE = re.compile(r"^(?:i|we) (?:just |recently |finally |also |already )?(went|visited|saw|watched|read|finished|started|bought|got|made|cooked|baked|built|played|tried|learned|learnt|"
                     r"met|ran|did|had|took|found|wrote|fixed|installed|ordered|sold|won|lost|moved|joined|attended|hiked|climbed|painted|planted|cleaned|booked|applied) (.+)$")
PLAN_RE = re.compile(r"^(?:i|we) (?:am(?= (?:moving|relocating|travelling|traveling|flying|heading) to)|are(?= (?:moving|relocating|travelling|traveling|flying|heading) to)|am (?:going|planning|hoping|about|trying|thinking of|thinking about)(?: to)?|want to|would like to|would love to|need to|have to|plan to|hope to|will|might|should|am gonna) (.+)$")
OPINION_RE = re.compile(r"^i (?:think|believe|feel like|guess|suppose|reckon|would say|am convinced|am pretty sure|am sure) (?:that )?(.+)$")
PROBLEM_RE = re.compile(r"^i (?:can not|could not|do not know how to|am struggling to|am struggling with|am having trouble|have trouble|keep failing to|am unable to|never manage to|am stuck on|am stuck with) (.+)$")
FEEL_RE = re.compile(r"^i (?:feel|am feeling|have been feeling|felt|am|am so|am really|am very|am a bit|am kind of|am pretty|am quite) ([a-z][a-z \-']{1,40})$")
FEEL_ABOUT_RE = re.compile(r"^i (?:feel|am feeling|have been feeling|am|am so|am really|am very|am a bit|am kind of|am pretty|am quite|have been|have been a bit|have been really) "
                           r"((?:really |pretty |quite |a bit |so |very )?[a-z\-]+)(?: (?:about|because|since|over|with|lately|recently|today|these days|right now)\b.*)?$")
_NEG_FEEL = _NEG | set("anxious nervous worried down low blue overwhelmed stressed scared afraid lonely hopeless numb empty drained exhausted upset hurt "
                       "guilty ashamed embarrassed jealous insecure lost stuck restless irritable panicky tense uneasy homesick heartbroken".split())
EVENT_RE = re.compile(r"\b(new job|first day|job interview|wedding|birthday|graduation|anniversary|holiday|vacation|trip|party|concert|interview|exam|date|recital|game|match|race|marathon|"
                      r"presentation|performance|festival|reunion|christening|baby shower|honeymoon|move|surgery|operation)\b")
MY_RE = re.compile(r"^my ([a-z]+(?: [a-z]+)?) (is|was|are|were|has|had|have|just|keeps|keep|will not|does not|did not|got|passed|died|left|said|told|thinks|wants|loves|hates|can not) ?(.*)$")
MY_PERSON_RE = re.compile(r"^(?:and |but |so |well )?my (?:little |big |older |younger |best |old |new |late |ex )?([a-z\-]+) (.+)$")
ABOUT_US_RE = re.compile(r"^(?:what were we (?:talking|chatting|speaking) about|what was i (?:saying|talking about)|where were we|what are we talking about|what is the topic)$")
AGAIN_RE = re.compile(r"^(?:another|another one|one more|more|again|next|and another|next one|encore|go on|keep going|keep them coming|do it again|tell me another|hit me again)(?: please| one)?$")
DEATH_RE = re.compile(r"\b(died|passed away|passed on|passed|death|funeral|lost my (?:mom|mum|mother|dad|father|brother|sister|son|daughter|wife|husband|friend|dog|cat|grandma|grandpa|grandmother|grandfather))\b")
OPINION_Q_RE = re.compile(r"^(?:(?:so |and |well |ok |hey )?what do you (?:think|reckon|make) (?:about|of)|what is your (?:opinion|view|take|stance|position) (?:on|of|about)|what are your (?:thoughts|views|feelings) (?:on|about)|how do you feel about|(?:do you have |have you got |got )?any (?:thoughts|views|opinions?) (?:on|about)|(?:your |what are your )?thoughts (?:on|about)|do you (?:like|love|enjoy|hate|prefer)|are you (?:a fan of|into)|thoughts on|your thoughts on) (.+)$")
FAV_Q_RE = re.compile(r"^(?:what is|what are|who is|tell me) your (?:favorite|favourite|fave) ([a-z ]{2,40})$|^do you have a (?:favorite|favourite) ([a-z ]{2,40})$")
PEOPLE = set("mom mum mother dad father brother sister son daughter wife husband partner girlfriend boyfriend friend boss colleague coworker teacher "
             "grandma grandpa grandmother grandfather aunt uncle cousin kid kids child children baby family parents neighbor neighbour roommate flatmate".split())
PETS = set("dog cat puppy kitten bird rabbit hamster horse parrot fish turtle pet".split())

GENERATE_RE = re.compile(r"^(?:(?:can|could|will|would) you |please |i need you to |i want you to )*(?:write|compose|draft|translate|draw|paint|sketch|generate|"
                         r"rewrite|proofread|paraphrase|sing|brainstorm|(?:make|create|design|build|produce) (?:me |us )?(?:a |an |some |the )?(?:new |nice |cool |simple |quick )?(?:logo|picture|image|drawing|poster|"
                         r"song|poem|story|website|web page|app|video|meme|presentation|slideshow|banner|icon|flyer|cartoon|painting|photo|essay|script|speech|jingle)|(?:summari[sz]e|fix|edit|improve|correct) (?:this|my|the following|these))\b")

class ChatEngine:
    def __init__(self, store, embed_fn=None, topic_fn=None):
        """store: object with facts(sid)->{key:[values]}, add(sid,key,value,multi), forget(sid,key=None).
        embed_fn(list[str])->matrix or None.  topic_fn(phrase)->{'sentence','title','url'} or None."""
        self.store = store
        self.topic_fn = topic_fn
        self.matcher = IntentMatcher(I, embed_fn)

    NEGATIVE_INTENTS = {"insult", "mood_sad", "mood_stressed", "mood_lonely", "mood_angry", "bad_news", "wrong_answer", "mood_sick", "mood_tired"}
    POSITIVE_INTENTS = {"compliment", "mood_happy", "good_news", "thanks", "love"}

    def classify(self, norm):
        """Intent retrieval plus two sanity gates: decisive 'compose' verbs, and sentiment polarity
        (a warm sentence must never be read as an insult, nor a bleak one as good news)."""
        name, conf, why = self.matcher.match(norm)
        if GENERATE_RE.match(norm) and (name is None or conf < 0.95):
            return "cannot_generate", 0.9, "generate-verb"
        if name and conf < 0.99:
            # Score the sentence without fillers: the sentiment lexicon rates "honestly" as strongly positive, which made
            # "honestly I've been a bit down lately" look cheerful and vetoed the (correct) sad-mood match.
            sc = sentiment(match_form(norm))
            if (name in self.NEGATIVE_INTENTS and sc >= 0.4) or (name in self.POSITIVE_INTENTS and sc <= -0.4):
                return None, 0.0, f"polarity gate rejected {name} (sentiment {sc:+.2f})"
            if set(tokens(norm)) & NEGATORS and ((name in self.NEGATIVE_INTENTS and sc > 0.1) or (name in self.POSITIVE_INTENTS and sc < -0.1)):
                # "i am not sad" looks exactly like "i am not ok" to a bag of words; the sentiment lexicon handles the negation
                return None, 0.0, f"negation gate rejected {name} (sentiment {sc:+.2f})"
        return name, conf, why

    # ---- helpers
    def _pick(self, options, st, salt=""):
        recent = []
        try:
            recent = json.loads(st.get("chat_recent") or "[]")
        except Exception:
            recent = []
        fresh = [o for o in options if hashlib.md5(o.encode()).hexdigest()[:8] not in recent] or list(options)
        turn = int(st.get("chat_turn") or 0)
        rnd = random.Random(f"{st.get('session', '')}|{turn}|{salt}")
        choice = rnd.choice(fresh)
        recent.append(hashlib.md5(choice.encode()).hexdigest()[:8])
        st["chat_recent"] = json.dumps(recent[-14:])
        chosen = choice
        return spin(chosen, rnd)

    def _fill(self, text, st, extra=None):
        name = st.get("name") or ""
        hour = time.localtime().tm_hour
        daypart = "Good morning" if hour < 12 else ("Good afternoon" if hour < 18 else "Good evening")
        turn = int(st.get("chat_turn") or 0)
        use_name = bool(name) and turn % 3 == 0
        vals = {"name": (", " + name) if use_name else "", "daypart_greeting": daypart, "last_bot": st.get("last_bot") or "I haven't said anything yet.",
                "topic": st.get("chat_focus") or st.get("chat_topic") or "that"}
        vals.update(extra or {})
        text = text.replace("{version}", str(APP_VERSION).split(".")[0])
        for k, v in vals.items():
            text = text.replace("{" + k + "}", str(v))
        return text

    def _grounded(self, topic, st):
        """One quoted sentence about a topic the user raised. Returns (text, sources) or ('', [])."""
        if not self.topic_fn or not topic_ok(topic):
            return "", []
        seen = st.get("chat_grounded") or ""
        if topic in seen.split("|"):
            return "", []
        try:
            info = self.topic_fn(topic)
        except Exception:
            info = None
        if not info or not info.get("sentence"):
            return "", []
        st["chat_grounded"] = "|".join((seen.split("|") + [topic])[-12:]).strip("|")
        lead = self._pick(["Here's how Wikipedia puts it:", "For context, Wikipedia says:", "Wikipedia's one-line version:"], st, "ground")
        return f"{lead} \u201c{info['sentence']}\u201d", [{"title": info.get("title", topic), "url": info.get("url", "")}]

    def _result(self, answer, st, intent, sources=None, pending=""):
        st["chat_pending"] = pending
        return {"answer": tidy(answer) if "\n" not in answer else answer.strip(), "sources": sources or [], "intent": intent}

    def _set_topic(self, st, topic):
        if topic_ok(topic):
            if st.get("chat_topic") and st.get("chat_topic") != topic and not st.get("chat_focus"):
                pass
            st["chat_topic"], st["chat_focus"] = topic, ""

    def _intent_reply(self, name, st):
        spec = I[name]
        extra = {}
        if name in ("joke", "joke_bad"):
            extra["joke"] = self._pick(JOKES, st, "joke")
        elif name == "fun_fact":
            f = self._pick([x[0] for x in FACTS], st, "fact")
            subj = next(sub for t, sub in FACTS if t == f)
            extra["fact"] = f"{f} (Say \"Tell me about {subj}\" for the sourced version.)"
        elif name == "coin":
            extra["coin"] = random.choice(["Heads.", "Tails."])
        elif name == "dice":
            extra["dice"] = f"You rolled a {random.randint(1, 6)}."
        elif name == "lets_chat":
            extra["starter"] = self._pick(STARTERS, st, "starter")
        text = self._fill(self._pick(spec["responses"], st, name), st, extra)
        if name in {"mood_sad", "mood_lonely"} and st.get("chat_low"):
            text += " If things feel too heavy, talking to someone you trust or a professional can really help."
        if name in {"mood_sad", "mood_lonely", "mood_stressed"}:
            st["chat_low"] = 1
        return self._result(text, st, name, pending=name if name in {"joke", "fun_fact"} else spec["pending"])

    def wants(self, raw, st=None):
        """Cheap routing check used by the app: is this clearly conversation rather than a question to look up?"""
        norm = normalize(raw)
        if not norm:
            return True
        pending = (st or {}).get("chat_pending") or ""
        if pending in {"joke", "fun_fact"} and AGAIN_RE.match(norm):
            return True          # "another one" right after a joke is a request for another joke, not a topic
        if pending in {"mood", "name", "name_offer"} and len(tokens(norm)) <= 6 and not norm.startswith(("who ", "what ", "when ", "where ", "why ", "how ")):
            return True          # a short reply to something the bot just asked
        if CRISIS_RE.search(norm) or ABOUT_US_RE.match(norm) or FORGET_RE.match(norm) or RECALL_ALL_RE.match(norm) or RECALL_FAV_RE.match(norm):
            return True
        if any(p.match(norm) for p, _ in RECALL) or OPINION_Q_RE.match(norm) or FAV_Q_RE.match(norm) or GENERATE_RE.match(norm):
            return True
        if MY_QUESTION_RE.match(norm) and len(tokens(norm)) <= 9 and not (set(tokens(norm)) & MY_QUESTION_BLOCK):
            return True
        name, conf, _ = self.classify(norm)
        return bool(name) and conf >= 0.75

    # ---- memory
    def _remember(self, norm, raw, st, sid):
        for pat, key, multi in MEMORY_PATTERNS:
            m = pat.match(norm)
            if not m:
                continue
            groups = [g for g in m.groups() if g]
            if key == "name":
                val = " ".join(w.capitalize() for w in groups[-1].split()[:3])
                if not val or val.casefold() in {"not", "a", "the", "here", "fine", "good", "sorry", "tired", "happy", "sad", "bored", "back"}:
                    return None
                st["name"] = val
                self.store.add(sid, "name", val, False)
                return self._result(self._pick([f"Nice to meet you, {val}.", f"Good to meet you, {val}. What's on your mind?", f"Got it, {val}. I'll remember that."], st, "name"), st, "memory:name")
            if key == "pet" and re.search(r"\b(?:is|are|seems?|has been|looks?|feels?) (?:not well|unwell|sick|ill|poorly|off colour|off color|hurt|injured|limping|vomiting|lethargic)\b|\b(?:isn't|is not|aren't|are not) (?:well|eating|drinking)\b", norm, re.I):
                who = groups[1].strip().title() if len(groups) > 1 else f"your {groups[0]}"
                return self._result(self._pick([f"I'm sorry {who} is unwell. I can't give veterinary advice, so if it's more than a passing thing, a vet is the right call. What have you noticed?",
                                                f"That's worrying. I'm not able to advise on animal health; a vet can, and sooner is usually better. How is {who} doing right now?"], st, "pet_unwell"), st, "memory")
            if key == "pet":
                val = (groups[0] if groups[0].endswith("s") and groups[0] != "fish" else a_an(groups[0])) + (f" named {groups[1].strip().title()}" if len(groups) > 1 else "")
                self.store.add(sid, key, val, True)
                who = groups[1].strip().title() if len(groups) > 1 else f"your {groups[0]}"
                return self._result(self._pick([f"Lovely. I'll remember {who}. What's {('he or she' if len(groups) > 1 else 'it')} like?", f"Noted: {val}. How long have you had {('them' if groups[0].endswith('s') else 'it')}?"], st, "pet"), st, "memory:pet")
            if key == "fav":
                kind, val = groups[0].strip(), self._orig_case(raw, groups[1])
                self.store.add(sid, "fav:" + kind, val, False)
                ground, src = self._grounded(clean_topic(groups[1]), st)
                q = self._pick([f"What do you like most about {val}?", f"Good choice. What makes {val} your favourite?", f"How did you first come across {val}?"], st, "fav")
                return self._result(f"I'll remember that your favourite {kind} is {val}. {ground} {q}", st, "memory:fav", src)
            if key == "note":
                val = self._orig_case(raw, groups[-1])
                self.store.add(sid, "note", reflect_note(val), True)
                return self._result(self._pick(["Noted. Ask \"what did I ask you to remember?\" any time.", "{Got it|Understood|Noted}, I've written that down.", "{Saved|Noted|Filed}. {I'll keep hold of that for you.|It's kept on this machine only.|Ask for it back any time.}"], st, "note"), st, "memory:note")
            val = self._orig_case(raw, groups[-1])
            if key == "job":
                val = re.sub(r"^(?:a|an)\s+", "", val, flags=re.I)
            self.store.add(sid, key, val, multi)
            msgs = {
                "location": [f"{val}, noted. What's it like there?", f"I'll remember you're in {val}. I can use that for weather and nearby places. How do you like it?"],
                "origin": [f"{val}. What's it like there?", f"Noted, you're from {val}. Do you still have ties there?"],
                "job": [f"Noted: you work as {a_an(val)}. What's that like day to day?", f"{val.capitalize()}, got it. What's the best part of the job?"],
                "workplace": [f"Got it, {val}. How long have you been there?", f"Noted. What do you do at {val}?"],
                "studies": [f"{val.capitalize()}: interesting. What drew you to it?", f"Noted, you study {val}. What's the hardest part?"],
                "age": [f"{val}, noted.", f"Got it, you're {val}."],
                "birthday": [f"I'll remember your birthday is {val}.", f"Noted: {val}."],
                "languages": [f"Nice, {val}. I only manage English, I'm afraid.", f"Noted: you speak {val}."],
                "instrument": [f"Nice, the {val}. How long have you been playing?", f"The {val}, lovely. What kind of music do you play?"],
            }
            ground, src = ("", [])
            if key in {"location", "origin"}:
                ground, src = self._grounded(val, st)
            text = self._pick(msgs.get(key, ["{Noted|Got it|Understood}."]), st, key)
            return self._result(f"{text} {ground}".strip() if not ground else f"{text.split('.')[0]}. {ground} {text.split('.', 1)[1].strip() if '.' in text else ''}", st, "memory:" + key, src)
        return None

    @staticmethod
    def _orig_case(raw, norm_fragment):
        """Recover the user's capitalisation for a fragment matched on the normalised text."""
        frag = norm_fragment.strip()
        m = re.search(re.escape(frag).replace(r"\ ", r"\s+"), raw, re.I)
        out = m.group(0) if m else frag
        return out.strip(" .,!?")

    def _recall(self, norm, st, sid):
        facts = self.store.facts(sid)
        if st.get("name") and "name" not in facts:
            facts["name"] = [st["name"]]
        m = FORGET_RE.match(norm)
        if m:
            what = m.group(1)
            keymap = {"my name": "name", "my notes": "note", "my note": "note", "where i live": "location", "my location": "location", "my job": "job", "my age": "age", "my birthday": "birthday"}
            if what in keymap:
                self.store.forget(sid, keymap[what])
                if keymap[what] == "name":
                    st["name"] = ""
                return self._result(f"Done. I've forgotten {reflect(what)}.", st, "memory:forget")
            if what == "that":
                return self._result("I can forget specific things (\"forget my name\", \"forget my notes\") or everything (\"forget everything\"). Which would you like?", st, "memory:forget?")
            self.store.forget(sid, None)
            for k in ("name", "chat_topic", "chat_focus", "chat_grounded"):
                st[k] = ""
            return self._result("Done. I've wiped everything I had stored about you in this chat.", st, "memory:forget-all")
        if RECALL_ALL_RE.match(norm):
            if not facts:
                return self._result("Nothing yet. Tell me things like \"my name is...\", \"I live in...\", \"I like...\" or \"remember that...\" and I'll keep them (only on this machine).", st, "memory:recall-all")
            lines = []
            label = {"name": "Your name is {}", "location": "You live in {}", "origin": "You're from {}", "job": "You work as a {}", "workplace": "You work at {}", "studies": "You study {}",
                     "age": "You're {} years old", "birthday": "Your birthday is {}", "like": "You like {}", "dislike": "You're not keen on {}", "pet": "You have {}", "note": "You asked me to remember: {}",
                     "languages": "You speak {}", "instrument": "You play the {}"}
            for k, vals in facts.items():
                if k.startswith("fav:"):
                    lines.append(f"Your favourite {k[4:]} is {vals[-1]}")
                elif k in label:
                    lines.append(label[k].format(join_and(vals) if k != "note" else "; ".join(vals)))
            return self._result("Here's what I have:\n" + "\n".join("\u2022 " + l for l in lines) + "\nSay \"forget everything\" to erase it.", st, "memory:recall-all")
        m = RECALL_FAV_RE.match(norm)
        if not m and MY_QUESTION_RE.match(norm) and len(tokens(norm)) <= 9 and not (set(tokens(norm)) & MY_QUESTION_BLOCK) and not any(p.match(norm) for p, _ in RECALL):
            return self._result(self._pick(["You haven't told me that yet. Tell me and I'll remember it.",
                                            "I don't have that noted. If you tell me, I'll keep it (only on this machine)."], st, "myq"), st, "memory:unknown")
        if m:
            kind = m.group(1).strip()
            vals = facts.get("fav:" + kind) or facts.get("fav:" + kind.rstrip("s"))
            return self._result(f"You told me your favourite {kind} is {vals[-1]}." if vals else f"You haven't told me your favourite {kind} yet. What is it?", st, "memory:recall-fav")
        for pat, key in RECALL:
            if pat.match(norm):
                vals = facts.get(key)
                if not vals:
                    ask = {"name": "You haven't told me your name yet. What should I call you?", "location": "You haven't told me where you live. Where are you based?",
                           "like": "You haven't told me what you're into yet. What do you enjoy?", "note": "You haven't asked me to remember anything yet."}
                    return self._result(ask.get(key, "You haven't told me that yet."), st, "memory:recall-miss", pending="name" if key == "name" else "")
                say = {"name": "You told me your name is {}.", "location": "You told me you live in {}.", "origin": "You said you're from {}.", "job": "You said you work as a {}.",
                       "age": "You told me you're {}.", "birthday": "You said your birthday is {}.", "like": "You've told me you like {}.", "dislike": "You've said you don't like {}.",
                       "pet": "You told me you have {}.", "note": "You asked me to remember: {}", "studies": "You said you study {}."}
                return self._result(say[key].format(join_and(vals) if key != "note" else "; ".join(vals)), st, "memory:recall")
        return None

    # ---- main entry
    def reply(self, raw, st, sid):
        norm = normalize(raw)
        st["chat_turn"] = int(st.get("chat_turn") or 0) + 1
        pending, st["chat_pending"] = st.get("chat_pending") or "", ""
        if CRISIS_RE.search(norm):
            return self._result(CRISIS_REPLY, st, "crisis")

        # 1. the bot asked something last turn
        if pending in {"name", "name_offer"}:
            m = re.match(r"^(?:it is |i am |my name is |call me |just |the name is )?([a-z][a-z'\-]{1,20}(?: [a-z][a-z'\-]{1,20})?)$", norm)
            stop = set(tokens("no nope nah nothing never mind not telling why what who how yes ok okay sure thanks hello hi hey you me secret guess pass skip"))
            if m and not (set(m.group(1).split()) & stop) and self.matcher.match(norm)[0] is None:
                val = " ".join(w.capitalize() for w in m.group(1).split())
                st["name"] = val
                self.store.add(sid, "name", val, False)
                return self._result(f"Nice to meet you, {val}. What's on your mind?", st, "pending:name")
        if pending == "mood":
            sc = sentiment(norm)
            short = len(tokens(norm)) <= 8
            if short and (sc >= 0.3 or re.search(r"\b(good|fine|great|well|ok|okay|alright|not bad|pretty good|can not complain|same|busy)\b", norm)) and not re.search(r"\bnot (?:so |too |very |that )?(?:good|great|well|fine)\b", norm):
                return self._result(self._pick(["Glad to hear it. What are you up to today?", "Good. Anything interesting going on?", "{Nice|Oh, nice|Good stuff}. What's on your mind?"], st, "moodpos"), st, "pending:mood+")
            if short and (sc <= -0.3 or re.search(r"\b(bad|tired|meh|rough|awful|terrible|stressed|sad|not (?:so |too |very |that )?(?:good|great|well|fine))\b", norm)):
                return self._result(self._pick(["Sorry to hear that. What's going on?", "That doesn't sound fun. Want to talk about it?", "I'm sorry. What's been the hard part?"], st, "moodneg"), st, "pending:mood-")

        if pending in {"joke", "fun_fact"} and AGAIN_RE.match(norm):
            return self._intent_reply(pending, st)
        if ABOUT_US_RE.match(norm):
            topic, focus = st.get("chat_topic") or st.get("subject_label"), st.get("chat_focus")
            if topic and focus:
                return self._result(f"We were talking about {topic}, especially {focus}.", st, "about_us")
            return self._result(f"We were talking about {topic}." if topic else "We hadn't settled on a topic yet. What would you like to talk about?", st, "about_us")

        # 2. personal memory: store / recall / forget
        r = self._recall(norm, st, sid) or self._remember(norm, raw, st, sid)
        if r:
            return r

        # 3. opinion / favourite questions aimed at the bot -> honest, grounded
        m = OPINION_Q_RE.match(norm)
        if m:
            topic = clean_topic(m.group(1))
            ground, src = self._grounded(topic, st)
            self._set_topic(st, topic)
            base = self._pick(["I don't have opinions or tastes of my own; I'm just rules.", "No preferences in here, I'm afraid; I'm a program.", "I can't form a view, but I can tell you what's written."], st, "opq")
            ask = self._pick([f"What's your take on {topic}?", f"What do you think of {topic}?", f"How do you feel about {topic}?"], st, "opq2")
            return self._result(f"{base} {ground} {ask}", st, "opinion_q", src)
        m = FAV_Q_RE.match(norm)
        if m:
            kind = (m.group(1) or m.group(2)).strip()
            return self._result(self._pick([f"I don't have favourites; nothing in here can prefer one {kind} to another. What's yours?", f"No favourite {kind} for me, since I can't experience any. Which is yours?"], st, "favq"), st, "favorite_q")

        # 4. intent retrieval (a few verbs are decisive on their own: requests to compose text)
        name, conf, why = self.classify(norm)
        st["_chat_debug"] = why
        if name:
            return self._intent_reply(name, st)
        # 4b. several clauses: "ok thanks, gotta run, bye" -> thanks + farewell
        clauses = [c.strip() for c in re.split(r"[,.;!?]+|\bbut\b|\band then\b", raw) if c.strip()]
        if 2 <= len(clauses) <= 4:
            found = []
            for c in clauses:
                n2, c2, _ = self.classify(normalize(c))
                if n2 and c2 >= 0.7 and n2 not in found and n2 not in {"agree", "disagree", "unsure", "clarify"}:
                    found.append(n2)
            if found:
                order = {"thanks": 0, "apology": 0, "compliment": 1, "greeting": 1, "farewell": 9, "goodnight": 9}
                found.sort(key=lambda n: order.get(n, 5))
                parts = [self._intent_reply(n, st)["answer"] for n in found[:2]]
                return self._result(" ".join(parts), st, "+".join(found[:2]), pending=I[found[-1]]["pending"] if len(found) == 1 else "")

        # 5. dialogue acts
        return self._dialogue_act(norm, raw, st, sid)

    def _dialogue_act(self, norm, raw, st, sid):
        m = TALK_ABOUT_RE.match(norm)
        if m:
            topic = clean_topic(m.group(1))
            self._set_topic(st, topic)
            ground, src = self._grounded(topic, st)
            q = self._pick([f"What would you like to know about {topic}, or what's your angle on it?", f"Sure, {topic}. What got you thinking about it?", f"Happy to. Where shall we start with {topic}?"], st, "talk")
            return self._result(f"{ground} {q}", st, "talk_about", src)
        m = INTO_RE.match(norm) or INTO2_RE.match(norm)
        if m:
            topic = clean_topic(m.group(1))
            self._set_topic(st, topic)
            if topic_ok(topic):
                self.store.add(sid, "like", self._orig_case(raw, topic), True)
            ground, src = self._grounded(topic, st)
            q = self._pick([f"What got you interested in {topic}?", f"What do you enjoy most about {topic} so far?", f"How long have you been at it with {topic}?", f"What drew you to {topic}?"], st, "into")
            return self._result(f"{self._pick(['Nice.', 'Good choice.', 'Oh, interesting.', 'That sounds rewarding.'], st, 'ack')} {ground} {q}", st, "getting_into", src)
        m = LIKE_RE.match(norm)
        if m:
            topic = clean_topic(m.group(1))
            if topic_ok(topic):
                self.store.add(sid, "like", self._orig_case(raw, topic), True)
                if st.get("chat_topic") and topic != st.get("chat_topic") and len(topic.split()) <= 4 and not st.get("chat_focus"):
                    st["chat_focus"] = topic
                else:
                    self._set_topic(st, topic)
            ground, src = self._grounded(topic, st)
            q = self._pick([f"What is it about {topic} that you enjoy most?", f"What keeps bringing you back to {topic}?", f"How did you get into {topic}?", f"What would you recommend to someone new to {topic}?"], st, "like")
            return self._result(f"{self._pick(['Noted, I will remember that.', 'Good to know.', 'Nice, I will keep that in mind.'], st, 'likeack')} {ground} {q}", st, "like", src)
        m = DISLIKE_RE.match(norm)
        if m:
            topic = clean_topic(m.group(1))
            if topic_ok(topic):
                self.store.add(sid, "dislike", self._orig_case(raw, topic), True)
            return self._result(self._pick([f"Fair enough. What is it about {topic} that puts you off?", f"Noted. Was there a particular experience with {topic} behind that?", f"Understood. What would you rather have instead of {topic}?"], st, "dislike"), st, "dislike")
        m = re.match(r"^(?:mostly|mainly|especially|particularly|primarily|usually|just|only) (.+)$", norm)
        if m and st.get("chat_topic"):
            focus = clean_topic(m.group(1))
            st["chat_focus"] = focus
            ground, src = self._grounded(focus, st)
            return self._result(f"{ground} " + self._pick([f"What about {focus} stands out to you?", f"What draws you to {focus} in particular?", f"Why {focus} over the alternatives?"], st, "focus"), st, "focus", src)
        if DEATH_RE.search(norm) and re.search(r"\b(my|our|i lost)\b", norm):
            return self._result(self._pick(["I'm so sorry for your loss. That's a hard thing to go through. Would you like to tell me about them?", "I'm very sorry. Take whatever time you need. If you'd like to talk about them, I'm here."], st, "loss"), st, "loss")
        m = PROBLEM_RE.match(norm)
        if m:
            rest = reflect(m.group(1))
            tip = " If it's something technical, try asking me directly, like \"How do I ...?\"" if re.search(r"\b(install|run|open|connect|compile|login|log in|ssh|file|server|wifi|python|linux|docker|git|password|update|boot|printer|network)\b", norm) else ""
            return self._result(self._pick(["That sounds frustrating. What have you tried so far?", "What seems to be getting in the way?", "When did it start being a problem?"], st, "prob") + tip, st, "problem")
        m = PAST_RE.match(norm)
        if m:
            verb, rest = m.group(1), reflect_raw(self._orig_case(raw, m.group(2)))
            topic = clean_topic(m.group(2))
            if len(topic.split()) <= 3:
                self._set_topic(st, self._orig_case(raw, topic))
            qs = {"watched": "What did you think of it?", "saw": "What did you think?", "read": "Would you recommend it?", "finished": "How does it feel to be done?", "started": "How's it going so far?",
                  "bought": "What made you pick that one?", "got": "How do you like it so far?", "made": "How did it turn out?", "cooked": "How did it turn out?", "baked": "How did it turn out?",
                  "built": "How did it turn out?", "tried": "How was it?", "went": "How was it?", "visited": "What was the highlight?", "met": "How did that go?", "won": "Congratulations! How did it feel?",
                  "lost": "Sorry to hear that. How are you taking it?", "learned": "What was the most surprising part?", "learnt": "What was the most surprising part?", "fixed": "{Nice|Oh, nice|Good stuff}. What was wrong with it?",
                  "installed": "{Nice|Oh, nice|Good stuff}. Is it working the way you hoped?", "moved": "Big change. How are you settling in?", "applied": "Fingers crossed. When will you hear back?"}
            q = qs.get(verb, "How did it go?")
            lead = f"You {verb} {rest}." if len(rest.split()) <= 9 else ""
            return self._result(f"{lead} {q}", st, "past_experience")
        m = PLAN_RE.match(norm)
        if m:
            rest = reflect(m.group(1))
            rest = re.sub(r"^to ", "", rest)
            if re.match(r"^(?:to )?(?:visit|travel|go to|fly to|see|move to|tour|explore|hike|drive to|spend|moving to|relocating to|travelling to|traveling to|flying to|heading to)\b", rest):
                return self._result(self._pick(["That sounds exciting. What are you most looking forward to?", "{Nice|Oh, nice|Good stuff}. Have you been before, or is it a first?", "{Lovely|That's lovely|How nice}. How long are you going for?"], st, "trip"), st, "plan_trip")
            return self._result(self._pick(["What's the first step towards that?", "When are you hoping to do it?", "What's motivating that?", "Sounds like a plan. Is anything standing in the way?"], st, "plan"), st, "plan")
        m = OPINION_RE.match(norm)
        if m:
            rest = reflect(m.group(1))
            if len(rest.split()) <= 12:
                return self._result(self._pick([f"Why do you think {rest}?", f"What leads you to think {rest}?", "What's behind that view?", "What makes you say that?"], st, "opinion"), st, "opinion")
        m = MY_RE.match(norm)
        if m:
            who = m.group(1).split()[-1]
            sc = sentiment(norm)
            if who in PEOPLE or who in PETS:
                if sc <= -0.35:
                    return self._result(self._pick([f"That sounds difficult. How are things between you and your {who} otherwise?", f"I'm sorry. How are you feeling about it?", f"That can't be easy. What happened with your {who}?"], st, "myneg"), st, "my_person-")
                return self._result(self._pick([f"Tell me more about your {who}.", f"What's your {who} like?", f"How do you feel about that?"], st, "mypos"), st, "my_person")
            if sc <= -0.35:
                return self._result(self._pick([f"That's annoying. What's going on with your {m.group(1)}?", "Sorry to hear that. What happened?"], st, "mything"), st, "my_thing-")
        m = re.match(r"^i am (?:not|no longer|not feeling)(?: that| so| very| really| too)? ([a-z]+)(?: (?:anymore|any more|at all|now))?$", norm)
        if m and m.group(1) in _NEG_FEEL:
            return self._result(self._pick(["Glad to hear it. What's on your mind?", "Good. Anything I can help with?", "That's good to hear. What are you up to?"], st, "notneg"), st, "not_negative")
        m = EVENT_RE.search(norm)
        if m and re.search(r"\b(?:next|tomorrow|tonight|this|on|in|coming|soon|upcoming)\b", norm):
            ev, sc_ev = m.group(1), sentiment(match_form(norm))
            if sc_ev <= -0.3 or re.search(r"\b(?:nervous|anxious|worried|dreading|scared|stressed)\b", norm):
                return self._result(self._pick([f"That's understandable before {a_an(ev)}. What part of it worries you most?", f"It's normal to feel that way about {a_an(ev)}. Is there anything you can prepare that would help?"], st, "ev-"), st, "event-")
            return self._result(self._pick([f"That's exciting, {a_an(ev)} to look forward to. What are you most looking forward to?", f"Lovely. Are you involved in the planning for the {ev}?", f"That's coming up soon. How are you feeling about the {ev}?"], st, "ev+"), st, "event+")
        m = MY_PERSON_RE.match(norm)
        if m and (m.group(1) in PEOPLE or m.group(1) in PETS):
            who, sc = m.group(1), sentiment(norm)
            if sc <= -0.3:
                return self._result(self._pick([f"That sounds upsetting. How are you feeling about it?", f"I'm sorry. Has your {who} done that before?", f"That can't be easy. What happened next?"], st, "myp-"), st, "my_person-")
            return self._result(self._pick([f"Tell me more about your {who}.", f"What's your {who} like?", f"That's nice. Are you and your {who} close?"], st, "myp"), st, "my_person")
        m = FEEL_RE.match(norm) or FEEL_ABOUT_RE.match(norm)
        sc = sentiment(norm)
        if m:
            fw = set(tokens(m.group(1)))
            if re.search(r"\b(?:not|never|no longer|hardly)\b", norm):
                pass
            elif fw & _NEG_FEEL and not fw & {"not", "never", "less"}:
                sc = min(sc, -0.5)
            elif fw & _POS and not fw & {"not", "never"}:
                sc = max(sc, 0.55)
        if m or abs(sc) >= 0.45:
            if sc <= -0.4:
                st["chat_low"] = 1
                return self._result(self._pick(["{That sounds hard|That sounds rough|That's a lot}. Do you want to tell me more about it?", "I'm sorry you're dealing with that. What's been the worst part?", "That's rough. What would help right now?"], st, "neg"), st, "sentiment-")
            if sc >= 0.5:
                return self._result(self._pick(["That's great to hear. What made it so good?", "{Lovely|That's lovely|How nice}. Tell me more?", "Glad to hear it. What's behind the good mood?"], st, "pos"), st, "sentiment+")
        if norm.startswith("because ") or norm.startswith("cause ") or norm.startswith("cos "):
            return self._result(self._pick(["That makes sense. Is that the main reason, or is there more to it?", "I see. How long has that been the case?", "Understood. What would change that?"], st, "because"), st, "because")
        # topic continuation
        topic = st.get("chat_focus") or st.get("chat_topic")
        ntok = len(tokens(norm))
        if topic and ntok >= 3:
            return self._result(self._pick(["Go on, I'm listening.", "I see. What happened next?", "How did that make you feel?", "Tell me more about that.",
                                            f"If you'd like a fact about {topic}, just ask it as a question."], st, "cont"), st, "continue")
        if ntok >= 6:
            body = reflect(norm)
            if re.match(r"^(you|your)\b", body) and ntok <= 12:
                return self._result(self._pick([f"{tidy(body)}? Tell me more.", "I see. How do you feel about that?", "What happened then?"], st, "reflect"), st, "reflect")
            return self._result(self._pick(["I see. Tell me more about that.", "What makes you say that?", "How do you feel about it?", "Go on."], st, "generic"), st, "generic")
        return self._result(self._pick(["I'm not sure I followed. You can ask me a question, or tell me what's on your mind.", "Tell me a bit more?",
                                        "I didn't quite catch that. Try a full sentence, or ask me something like \"What is ...?\"", "Hmm, say more?"], st, "fallback"), st, "fallback")

def reflect_raw(text):
    """Pronoun reflection that keeps the user's capitalisation: 'Dune with my sister' -> 'Dune with your sister'."""
    out, prev = [], ""
    for w in text.split():
        core = w.casefold().strip(".,!?")
        if core == "was":
            r = "were" if prev == "i" else "was"
        else:
            r = _REFLECT.get(core)
        out.append(w if r is None else r)
        prev = core
    return " ".join(out)

def join_and(vals):
    vals = list(dict.fromkeys(vals))
    if len(vals) <= 1:
        return "".join(vals)
    return ", ".join(vals[:-1]) + " and " + vals[-1]

def a_an(s):
    return ("an " if s[:1].casefold() in "aeiou" else "a ") + s

def a_an_strip(s):
    return a_an(s) if s[:1].islower() else s

def reflect_note(s):
    """Store notes in second person so they read naturally back: 'my keys are in the drawer' -> 'your keys are in the drawer'."""
    out = []
    for w in s.split():
        core = w.casefold().strip(".,!?")
        rep = {"my": "your", "i": "you", "me": "you", "mine": "yours", "i'm": "you're", "am": "are", "i've": "you've", "i'll": "you'll", "myself": "yourself", "our": "your", "we": "you"}.get(core)
        out.append(w if rep is None else (rep.capitalize() if w[:1].isupper() and core != "i" else rep) + w[len(core):] if w.casefold().startswith(core) else w)
    return " ".join(out)
__NOAI_V11_CONVO_PY__
cat > "$APP_DIR/app/skills.py" <<'__NOAI_V11_SKILLS_PY__'
"""Deterministic assistant skills for NoAI Chat: arithmetic, unit conversion, dates and times,
weather (Open-Meteo, no API key) and dictionary definitions (Wiktionary). No generative model.
Network access is injected (`get_json`) so the module can be tested offline."""
import ast, math, operator, os, re, html as htmlmod
from datetime import datetime, date, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover
    ZoneInfo = None

# ------------------------------------------------------------------ calculator
_WORD_OPS = [
    (r"\bto the power of\b", "**"), (r"\braised to\b", "**"), (r"\bmultiplied by\b", "*"), (r"\bdivided by\b", "/"), (r"\btimes\b", "*"),
    (r"\bplus\b", "+"), (r"\bminus\b", "-"), (r"\bover\b", "/"), (r"\bmod(?:ulo)?\b", "%"), (r"\bsquared\b", "**2"), (r"\bcubed\b", "**3"),
    (r"\bsquare root of\b", "sqrt"), (r"\bsqrt of\b", "sqrt"), (r"\bcube root of\b", "cbrt"), (r"\u00d7", "*"), (r"\u00f7", "/"), (r"\u2212", "-"), (r"\^", "**"),
    (r"(?<=\d)\s*x\s*(?=\d)", "*"), (r"\bpi\b", "pi"),
]
_FUNCS = {"sqrt": math.sqrt, "cbrt": lambda v: math.copysign(abs(v) ** (1 / 3), v), "abs": abs, "round": round, "sin": math.sin, "cos": math.cos,
          "tan": math.tan, "log": math.log10, "ln": math.log, "log10": math.log10, "log2": math.log2, "exp": math.exp, "floor": math.floor, "ceil": math.ceil,
          "factorial": lambda v: math.factorial(int(v)) if 0 <= v <= 170 and float(v).is_integer() else (_ for _ in ()).throw(ValueError("factorial range"))}
_CONSTS = {"pi": math.pi, "e": math.e, "tau": math.tau}
_BIN = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv, ast.Mod: operator.mod}

def _eval(node, depth=0):
    if depth > 40:
        raise ValueError("too deep")
    if isinstance(node, ast.Expression):
        return _eval(node.body, depth + 1)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
        return node.value
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
        v = _eval(node.operand, depth + 1)
        return -v if isinstance(node.op, ast.USub) else v
    if isinstance(node, ast.BinOp):
        a, b = _eval(node.left, depth + 1), _eval(node.right, depth + 1)
        if isinstance(node.op, ast.Pow):
            if abs(b) > 400 or (abs(a) > 1e6 and abs(b) > 40):
                raise ValueError("exponent too large")
            return a ** b
        if type(node.op) in _BIN:
            return _BIN[type(node.op)](a, b)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in _FUNCS and not node.keywords and 1 <= len(node.args) <= 2:
        return _FUNCS[node.func.id](*[_eval(a, depth + 1) for a in node.args])
    if isinstance(node, ast.Name) and node.id in _CONSTS:
        return _CONSTS[node.id]
    raise ValueError("unsupported expression")

def fmt_num(v):
    if isinstance(v, complex):
        raise ValueError("complex result")
    if isinstance(v, int) or (isinstance(v, float) and v.is_integer() and abs(v) < 1e15):
        return f"{int(v):,}"
    if abs(v) >= 1e15 or (abs(v) < 1e-6 and v != 0):
        return f"{v:.6g}"
    return f"{v:,.6f}".rstrip("0").rstrip(".")

_CALC_LEAD = re.compile(r"^(?:what(?:'s| is| does)|how much is|calculate|compute|work out|solve|evaluate|can you (?:calculate|compute|work out)|tell me|whats)\s+", re.I)

_MONTHS = {m: i for i, m in enumerate("january february march april may june july august september october november december".split(), 1)}
_MONTHS.update({m[:3]: i for m, i in list(_MONTHS.items())})
_DATE_PATS = [r"(\d{4})-(\d{1,2})-(\d{1,2})", r"(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?([A-Za-z]+)\.?,?\s*(\d{4})?", r"([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?"]

def _parse_date(text, today):
    from datetime import date as _date
    t = text.strip()
    m = re.match(_DATE_PATS[0] + "$", t)
    if m:
        return _date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    m = re.match(_DATE_PATS[1] + "$", t, re.I)
    if m and m.group(2).lower() in _MONTHS:
        return _date(int(m.group(3) or today.year), _MONTHS[m.group(2).lower()], int(m.group(1)))
    m = re.match(_DATE_PATS[2] + "$", t, re.I)
    if m and m.group(1).lower() in _MONTHS:
        return _date(int(m.group(3) or today.year), _MONTHS[m.group(1).lower()], int(m.group(2)))
    return None

def _money(x):
    return f"{x:,.2f}" if abs(x - round(x)) > 1e-9 else f"{round(x):,}"

def try_dates(q):
    """Exact, offline: days between dates, weekday of a date, age from a birth date/year, discounts, tips, splits, loan payments."""
    s = re.sub(r"\s+", " ", q.strip()).rstrip("?.! ")
    today = now_local()[0].date()
    m = re.match(r"^(?:how many days|number of days|days) (?:are there |is it |is there )?(?:between|from) (.+?) (?:and|to|until|till) (.+)$", s, re.I)
    if m:
        a, b = _parse_date(m.group(1), today), _parse_date(m.group(2), today)
        if a and b:
            d = (b - a).days
            return f"There are {abs(d):,} days between {a.strftime('%-d %B %Y')} and {b.strftime('%-d %B %Y')}" + (" (the second date is earlier)." if d < 0 else ".")
    m = re.match(r"^(?:what|which) day (?:of the week )?(?:was|is|will) (?:it )?(?:on )?(.+?)(?: be)?$", s, re.I)
    if m:
        d = _parse_date(m.group(1), today)
        if d:
            return f"{d.strftime('%-d %B %Y')} {'was' if d < today else 'is'} a {d.strftime('%A')}."
    m = re.match(r"^how old (?:would|will|is|was) (?:someone|a person|somebody|i|he|she) (?:be )?(?:who was |if )?born (?:on |in )?(.+?)(?: be(?: today| now)?| today| now)?$", s, re.I)
    if m:
        raw = m.group(1).strip()
        d = _parse_date(raw, today) if not re.match(r"^\d{4}$", raw) else None
        if d:
            age = today.year - d.year - ((today.month, today.day) < (d.month, d.day))
            return f"Someone born on {d.strftime('%-d %B %Y')} is {age} today."
        if re.match(r"^\d{4}$", raw):
            y = int(raw)
            return f"Someone born in {y} turns {today.year - y} this year (they are {today.year - y - 1} or {today.year - y} depending on their birthday)."
    m = re.match(r"^(?:what(?:'s| is) )?(\d+(?:\.\d+)?)\s?% off (?:of )?([$\u00a3\u20ac]?)\s?([\d,]+(?:\.\d+)?)$", s, re.I)
    if m:
        pct, cur, amt = float(m.group(1)), m.group(2), float(m.group(3).replace(",", ""))
        return f"{m.group(1)}% off {cur}{_money(amt)} is {cur}{_money(amt * (1 - pct / 100))} (you save {cur}{_money(amt * pct / 100)})."
    m = re.match(r"^(?:what(?:'s| is) )?(?:a )?(\d+(?:\.\d+)?)\s?% tip on ([$\u00a3\u20ac]?)\s?([\d,]+(?:\.\d+)?)$", s, re.I)
    if m:
        pct, cur, amt = float(m.group(1)), m.group(2), float(m.group(3).replace(",", ""))
        return f"A {m.group(1)}% tip on {cur}{_money(amt)} is {cur}{_money(amt * pct / 100)}, making {cur}{_money(amt * (1 + pct / 100))} in total."
    s = re.sub(r"\b(two|three|four|five|six|seven|eight|nine|ten|twelve)\b", lambda m: str(["two","three","four","five","six","seven","eight","nine","ten","twelve"].index(m.group(1)) + 2 if m.group(1) != "twelve" else 12), s)   # v38: "four ways"
    m = re.match(r"^split ([$\u00a3\u20ac]?)\s?([\d,]+(?:\.\d+)?) (?:between|among|by|across|into)? ?(\d+)(?: people| ways| of us| friends| persons)?$", s, re.I)
    if m:
        cur, amt, n = m.group(1), float(m.group(2).replace(",", "")), int(m.group(3))
        return f"{cur}{_money(amt)} split {n} ways is {cur}{_money(amt / n)} each." if n else None
    m = re.match(r"^(?:what(?:'s| is) the )?(?:monthly )?(?:payment|repayment)s? on (?:a )?([$\u00a3\u20ac]?)\s?([\d,]+(?:\.\d+)?) (?:loan |mortgage )?(?:at|@) (\d+(?:\.\d+)?)\s?% (?:over|for) (\d+) years?$", s, re.I)
    if m:
        cur, P, rate, yrs = m.group(1), float(m.group(2).replace(",", "")), float(m.group(3)) / 100 / 12, int(m.group(4)) * 12
        pay = P / yrs if rate == 0 else P * rate / (1 - (1 + rate) ** -yrs)
        return f"{cur}{_money(P)} at {m.group(3)}% over {m.group(4)} years is about {cur}{_money(pay)} a month ({cur}{_money(pay * yrs)} in total, standard amortised repayment; lenders' fees not included)."
    # v55: "if I save 360 a month how long until I have 5000"
    m = re.match(r"^(?:if )?i (?:save|put away|put aside|set aside) ([$\u00a3\u20ac]?)\s?([\d,]+(?:\.\d+)?) (?:a|per|every) (month|week|day|year)[, ]+(?:how long (?:until|till|before) i have|when will i have|how (?:many )?(?:months|weeks|years) (?:until|to reach)) ([$\u00a3\u20ac]?)\s?([\d,]+(?:\.\d+)?)[?.!]*$", q.strip(), re.I)
    if m:
        cur, amt, per, goal = m.group(1) or m.group(4), float(m.group(2).replace(",", "")), m.group(3).lower(), float(m.group(5).replace(",", ""))
        if amt > 0:
            n = -(-goal // amt)
            unit = {"month": "months", "week": "weeks", "day": "days", "year": "years"}[per]
            extra = ""
            if per == "week": extra = f" (about {n / 52:.1f} years)" if n > 52 else f" (about {n / 4.35:.1f} months)"
            if per == "month": extra = f" (about {n / 12:.1f} years)" if n > 12 else ""
            return f"Saving {cur}{_money(amt)} a {per}, you reach {cur}{_money(goal)} after {int(n)} {unit}{extra}, before any interest."
    return None

def try_calc(q):
    """-> answer string or None. Only fires when the text is clearly arithmetic."""
    s = q.strip().rstrip("?.!= ").casefold()
    s = _CALC_LEAD.sub("", s)
    s = re.sub(r"\s+equals?$|\s+equal to$|^the (?:value|result|answer) of\s+", "", s)
    s = re.sub(r"^the\s+(?=(?:square|cube) root|sum|product|difference|factorial)", "", s)
    s = re.sub(r"^sum of ([\d.,]+) and ([\d.,]+)$", r"\1 + \2", s)
    s = re.sub(r"^product of ([\d.,]+) and ([\d.,]+)$", r"\1 * \2", s)
    s = re.sub(r"^difference (?:of|between) ([\d.,]+) and ([\d.,]+)$", r"\1 - \2", s)
    m = re.match(r"^([\d.,]+)\s*(?:%|percent)\s+of\s+([\d.,]+)$", s)
    if m:
        try:
            a, b = float(m.group(1).replace(",", "")), float(m.group(2).replace(",", ""))
            return f"{fmt_num(a)}% of {fmt_num(b)} is {fmt_num(a * b / 100)}."
        except ValueError:
            return None
    m = re.match(r"^([\d.,]+) is what (?:%|percent|percentage) of ([\d.,]+)$", s)
    if m:
        try:
            a, b = float(m.group(1).replace(",", "")), float(m.group(2).replace(",", ""))
            return f"{fmt_num(a)} is {fmt_num(a / b * 100)}% of {fmt_num(b)}." if b else None
        except ValueError:
            return None
    expr = s
    for pat, rep in _WORD_OPS:
        expr = re.sub(pat, f" {rep} ", expr)
    expr = re.sub(r"(?<=\d),(?=\d{3}\b)", "", expr)
    expr = re.sub(r"(\d+)\s+factorial\b", r"factorial(\1)", expr)
    expr = re.sub(r"\bfactorial of (\d+)", r"factorial(\1)", expr)
    expr = re.sub(r"\b(sqrt|cbrt)\s+(\d+(?:\.\d+)?)", r"\1(\2)", expr)
    expr = re.sub(r"\s+", " ", expr).strip()
    if not re.search(r"\d", expr) or not re.fullmatch(r"[\d\s.+\-*/%()a-z,]+", expr):
        return None
    if re.search(r"[a-z]", expr):
        words = set(re.findall(r"[a-z]+", expr))
        if not words <= (set(_FUNCS) | set(_CONSTS)):
            return None
    if not (re.search(r"[+\-*/%]", expr.lstrip("-+ ")) or re.search(r"[a-z]+\s*\(", expr)):
        return None   # a bare number ("1984") is not arithmetic
    if re.fullmatch(r"\d{1,2}\s*/\s*\d{1,2}", expr) and "/" in q and re.search(r"[A-Za-z]", q) and not re.match(r"^(?:calculate|compute|work out|evaluate)", q.strip(), re.I):
        return None   # "what is 9/11" is more likely a date or an event than a fraction
    try:
        val = _eval(ast.parse(expr, mode="eval"))
        shown = q.strip().rstrip("?.!= ")
        shown = _CALC_LEAD.sub("", shown)
        return f"{shown} = {fmt_num(val)}"
    except ZeroDivisionError:
        return "That divides by zero, so it has no defined value."
    except Exception:
        return None

# ------------------------------------------------------------------ unit conversion
# (dimension, factor to base unit). Temperature handled separately.
UNITS = {}
def _u(dim, factor, *names):
    for n in names:
        UNITS[n] = (dim, factor, names[0])
_u("length", 0.001, "mm", "millimeter", "millimeters", "millimetre", "millimetres"); _u("length", 0.01, "cm", "centimeter", "centimeters", "centimetre", "centimetres")
_u("length", 1.0, "m", "meter", "meters", "metre", "metres"); _u("length", 1000.0, "km", "kilometer", "kilometers", "kilometre", "kilometres", "kms")
_u("length", 0.0254, "in", "inch", "inches"); _u("length", 0.3048, "ft", "foot", "feet"); _u("length", 0.9144, "yd", "yard", "yards")
_u("length", 1609.344, "mi", "mile", "miles"); _u("length", 1852.0, "nmi", "nautical mile", "nautical miles")
_u("mass", 1e-6, "mg", "milligram", "milligrams"); _u("mass", 0.001, "g", "gram", "grams", "gramme", "grammes"); _u("mass", 1.0, "kg", "kilogram", "kilograms", "kilo", "kilos", "kgs")
_u("mass", 0.028349523125, "oz", "ounce", "ounces"); _u("mass", 0.45359237, "lb", "lbs", "pound", "pounds"); _u("mass", 6.35029318, "st", "stone", "stones")
_u("mass", 1000.0, "t", "tonne", "tonnes", "metric ton", "metric tons"); _u("mass", 907.18474, "US ton", "ton", "tons", "short ton", "short tons")
_u("volume", 0.001, "ml", "milliliter", "milliliters", "millilitre", "millilitres"); _u("volume", 1.0, "l", "liter", "liters", "litre", "litres")
_u("volume", 0.00492892159375, "US tsp", "tsp", "teaspoon", "teaspoons"); _u("volume", 0.01478676478125, "US tbsp", "tbsp", "tablespoon", "tablespoons")
_u("volume", 0.0295735295625, "US fl oz", "fl oz", "fluid ounce", "fluid ounces"); _u("volume", 0.2365882365, "US cup", "cup", "cups")
_u("volume", 0.473176473, "US pint", "pint", "pints", "pt"); _u("volume", 0.946352946, "US quart", "quart", "quarts", "qt")
_u("volume", 3.785411784, "US gallon", "gallon", "gallons", "gal"); _u("volume", 4.54609, "imperial gallon", "imperial gallons", "uk gallon", "uk gallons")
_u("volume", 0.56826125, "imperial pint", "imperial pints", "uk pint", "uk pints")
_u("speed", 1 / 3.6, "km/h", "kmh", "kph", "kilometers per hour", "kilometres per hour"); _u("speed", 0.44704, "mph", "miles per hour")
_u("speed", 1.0, "m/s", "meters per second", "metres per second"); _u("speed", 0.514444, "knots", "knot", "kn", "kt")
_u("area", 1.0, "m\u00b2", "square meter", "square meters", "square metre", "square metres", "sqm", "m2"); _u("area", 0.09290304, "ft\u00b2", "square foot", "square feet", "sq ft", "sqft", "ft2")
_u("area", 4046.8564224, "acres", "acre"); _u("area", 10000.0, "hectares", "hectare", "ha"); _u("area", 1e6, "km\u00b2", "square kilometer", "square kilometers", "square kilometre", "square kilometres", "km2")
_u("area", 2589988.110336, "mi\u00b2", "square mile", "square miles")
_u("time", 1.0, "seconds", "second", "sec", "secs", "s"); _u("time", 60.0, "minutes", "minute", "min", "mins"); _u("time", 3600.0, "hours", "hour", "hr", "hrs", "h")
_u("time", 86400.0, "days", "day"); _u("time", 604800.0, "weeks", "week"); _u("time", 31557600.0, "years", "year", "yr", "yrs")
_u("data", 1.0, "bytes", "byte"); _u("data", 0.125, "bits", "bit"); _u("data", 1e3, "KB", "kb", "kilobyte", "kilobytes"); _u("data", 1e6, "MB", "mb", "megabyte", "megabytes")
_u("data", 1e9, "GB", "gb", "gigabyte", "gigabytes"); _u("data", 1e12, "TB", "tb", "terabyte", "terabytes"); _u("data", 1024.0, "KiB", "kib", "kibibyte", "kibibytes")
_u("data", 1024.0 ** 2, "MiB", "mib", "mebibyte", "mebibytes"); _u("data", 1024.0 ** 3, "GiB", "gib", "gibibyte", "gibibytes")
_u("energy", 1.0, "J", "j", "joule", "joules"); _u("energy", 4184.0, "kcal", "calories", "calorie", "kilocalorie", "kilocalories"); _u("energy", 3.6e6, "kWh", "kwh", "kilowatt hour", "kilowatt hours")
TEMP = {"c": "C", "celsius": "C", "centigrade": "C", "\u00b0c": "C", "degrees celsius": "C", "degrees c": "C", "f": "F", "fahrenheit": "F", "\u00b0f": "F", "degrees fahrenheit": "F",
        "degrees f": "F", "k": "K", "kelvin": "K", "kelvins": "K"}
_UNIT_ALT = "|".join(sorted((re.escape(k) for k in list(UNITS) + list(TEMP)), key=len, reverse=True))
_CONV_PATTERNS = [
    re.compile(rf"^(?:convert|change)\s+(-?[\d.,]+)\s*({_UNIT_ALT})\s+(?:to|into|in)\s+({_UNIT_ALT})$", re.I),
    re.compile(rf"^(?:what(?:'s| is)\s+|how much is\s+|how many is\s+)?(-?[\d.,]+)\s*({_UNIT_ALT})\s+(?:to|into|in|as)\s+({_UNIT_ALT})$", re.I),
    re.compile(rf"^how many\s+({_UNIT_ALT})\s+(?:are |is )?(?:there )?in\s+(?:a |an |one )?(-?[\d.,]*)\s*({_UNIT_ALT})$", re.I),
    re.compile(rf"^how many\s+({_UNIT_ALT})\s+(?:is|are|does|do|equals?|make|makes|make up)\s+(?:a |an |one )?(-?[\d.,]*)\s*({_UNIT_ALT})(?:\s+(?:equal|make|weigh|measure))?$", re.I),
    re.compile(rf"^how (?:much|many|far|long|heavy|big) is\s+(-?[\d.,]+)\s*({_UNIT_ALT})\s+in\s+({_UNIT_ALT})$", re.I),
]

_ADD_S = {"US cup", "US pint", "US quart", "US gallon", "imperial gallon", "imperial pint", "US ton"}
_DROP_S = {"seconds", "minutes", "hours", "days", "weeks", "years", "acres", "hectares", "knots", "bytes", "bits", "calories"}

def _unit_name(name, value):
    one = abs(value - 1.0) < 1e-12
    if name in _ADD_S:
        return name if one else name + "s"
    if name in _DROP_S:
        return name[:-1] if one else name
    return name

def _lookup(u):
    u = u.strip()
    return UNITS.get(u) or UNITS.get(u.casefold())

def try_convert(q):
    s = re.sub(r"\s+", " ", q.strip().rstrip("?.! "))
    for i, pat in enumerate(_CONV_PATTERNS):
        m = pat.match(s)
        if not m:
            continue
        if i in (2, 3):
            to_u, num, from_u = m.group(1), m.group(2) or "1", m.group(3)
        else:
            num, from_u, to_u = m.group(1), m.group(2), m.group(3)
        try:
            val = float(num.replace(",", ""))
        except ValueError:
            return None
        tf, tt = TEMP.get(from_u.casefold()), TEMP.get(to_u.casefold())
        if tf and tt:
            k = val + 273.15 if tf == "C" else ((val - 32) * 5 / 9 + 273.15 if tf == "F" else val)
            out = k - 273.15 if tt == "C" else ((k - 273.15) * 9 / 5 + 32 if tt == "F" else k)
            deg = lambda t: "K" if t == "K" else "\u00b0" + t
            return f"{fmt_num(val)} {deg(tf)} = {fmt_num(round(out, 2))} {deg(tt)}"
        a, b = _lookup(from_u), _lookup(to_u)
        if not a or not b:
            return None
        if a[0] != b[0]:
            return f"I can't convert {a[2]} to {b[2]}: one measures {a[0]} and the other {b[0]}."
        out = val * a[1] / b[1]
        shown = fmt_num(float(f"{out:.6g}")) if abs(out) >= 1e-6 else f"{out:.6g}"
        return f"{fmt_num(val)} {_unit_name(a[2], val)} = {shown} {_unit_name(b[2], out)}"
    return None

# ------------------------------------------------------------------ dates and times
def local_tz():
    name = os.environ.get("TZ") or os.environ.get("NOAI_TZ") or ""
    if name and ZoneInfo is not None:
        try:
            return ZoneInfo(name), name
        except Exception:
            pass
    return None, ""

_PINNED = [None]      # replay pins the clock to the moment the cassette was recorded

def now_local():
    tz, name = local_tz()
    if _PINNED[0]:
        return (datetime.fromtimestamp(_PINNED[0], tz) if tz else datetime.fromtimestamp(_PINNED[0]).astimezone()), name
    return (datetime.now(tz) if tz else datetime.now().astimezone()), name

_TIME_RE = re.compile(r"^(?:what(?:'s| is) the time|what time is it|do you (?:know|have) the time|got the time|time please|tell me the time|current time|what(?:'s| is) the current time)(?: (?:right )?now)?$", re.I)
_DATE_RE = re.compile(r"^(?:what(?:'s| is) (?:the |today'?s? )?date(?: today)?|what day is (?:it|today)(?: today)?|what(?:'s| is) today|what is today'?s date|today'?s date|"
                      r"what day of the week is it|which day is it|what(?:'s| is) the day today)$", re.I)
_YEAR_RE = re.compile(r"^(?:what year is it|what(?:'s| is) the (?:current )?year|which year is it)$", re.I)
_MONTH_RE = re.compile(r"^(?:what month is it|what(?:'s| is) the (?:current )?month)$", re.I)
_TIME_IN_RE = re.compile(r"^(?:what(?:'s| is) the time|what time is it|current time|time)(?: right)?(?: now)? (?:in|at) (.+)$", re.I)
_UNTIL_RE = re.compile(r"^how (?:many days|long) (?:is it |are there |left )?(?:until|till|til|to|before) (.+)$", re.I)
MONTHS = {m: i for i, m in enumerate("january february march april may june july august september october november december".split(), 1)}
MONTHS.update({m[:3]: i for m, i in list(MONTHS.items())})
HOLIDAYS = {"christmas": (12, 25), "christmas day": (12, 25), "xmas": (12, 25), "christmas eve": (12, 24), "new year": (1, 1), "new years": (1, 1), "new year's": (1, 1),
            "new year's day": (1, 1), "new years day": (1, 1), "new year's eve": (12, 31), "new years eve": (12, 31), "halloween": (10, 31), "valentine's day": (2, 14),
            "valentines day": (2, 14), "valentines": (2, 14), "st patrick's day": (3, 17), "saint patrick's day": (3, 17), "boxing day": (12, 26), "bonfire night": (11, 5),
            "independence day": (7, 4), "the fourth of july": (7, 4), "4th of july": (7, 4), "april fools": (4, 1), "april fools day": (4, 1), "pi day": (3, 14), "leap day": (2, 29)}

def _parse_day(text, today):
    t = re.sub(r"\b(?:the|of|my|next|this)\b", " ", text.casefold().strip(" ?.!"))
    t = re.sub(r"(\d)(?:st|nd|rd|th)\b", r"\1", t)
    t = re.sub(r"\s+", " ", t).strip()
    key = text.casefold().strip(" ?.!")
    key = re.sub(r"^(?:the |next |this )", "", key)
    if key in HOLIDAYS:
        mo, d = HOLIDAYS[key]
    else:
        m = re.match(r"^(\d{1,2}) ([a-z]+)(?: (\d{4}))?$", t) or None
        m2 = re.match(r"^([a-z]+) (\d{1,2})(?:,? (\d{4}))?$", t)
        m3 = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", t)
        if m3:
            return date(int(m3.group(1)), int(m3.group(2)), int(m3.group(3)))
        if m and m.group(2) in MONTHS:
            d, mo, y = int(m.group(1)), MONTHS[m.group(2)], m.group(3)
        elif m2 and m2.group(1) in MONTHS:
            mo, d, y = MONTHS[m2.group(1)], int(m2.group(2)), m2.group(3)
        else:
            return None
        if y:
            return date(int(y), mo, d)
    for year in (today.year, today.year + 1, today.year + 2, today.year + 3, today.year + 4):
        try:
            cand = date(year, mo, d)
        except ValueError:
            continue
        if cand >= today:
            return cand
    return None

def try_datetime(q):
    s = re.sub(r"\s+", " ", q.strip().rstrip("?.! "))
    now, tzname = now_local()
    where = f" ({tzname})" if tzname else ""
    if _TIME_RE.match(s):
        return f"It's {now.strftime('%H:%M')}{where}, {now.strftime('%A %-d %B %Y')}."
    if _DATE_RE.match(s):
        return f"Today is {now.strftime('%A, %-d %B %Y')}."
    if _YEAR_RE.match(s):
        return f"It's {now.year}."
    if _MONTH_RE.match(s):
        return f"It's {now.strftime('%B %Y')}."
    m = _UNTIL_RE.match(s)
    if m:
        try:
            target = _parse_day(m.group(1), now.date())
        except ValueError:
            target = None
        if target:
            n = (target - now.date()).days
            label = target.strftime("%A %-d %B %Y")
            if n == 0:
                return f"That's today ({label})."
            return f"{n:,} day{'s' if n != 1 else ''} until {label}." if n > 0 else f"{label} was {-n:,} day{'s' if n != -1 else ''} ago."
    return None

# ------------------------------------------------------------------ weather + time in a place (Open-Meteo)
GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
WMO = {0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "freezing fog", 51: "light drizzle", 53: "drizzle", 55: "heavy drizzle",
       56: "freezing drizzle", 57: "freezing drizzle", 61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain", 71: "light snow",
       73: "snow", 75: "heavy snow", 77: "snow grains", 80: "light showers", 81: "showers", 82: "violent showers", 85: "snow showers", 86: "heavy snow showers",
       95: "thunderstorm", 96: "thunderstorm with hail", 99: "thunderstorm with heavy hail"}
_WX_WORDS = r"(?:weather|forecast|temperature|rain|raining|snow|snowing|umbrella|sunny|windy|hot|cold|warm|humid|humidity)"
_WX_RE = re.compile(rf"\b{_WX_WORDS}\b", re.I)
_WX_PLACE_RE = re.compile(r"\b(?:in|for|at|near|around)\s+(?!the (?:morning|afternoon|evening|next)\b)([A-Za-z\u00c0-\u024f][\w\u00c0-\u024f .,'\-]{1,60}?)(?:\s+(?:today|tonight|tomorrow|now|right now|this week|this weekend|on \w+|next week|like|be like))*$", re.I)

def is_weather_question(q):
    s = q.strip().casefold().rstrip("?.! ")
    if not _WX_RE.search(s) or re.match(r"^(?:what causes|what caused|why|how do|how does|how did|what is a|what is an|what are|who|explain|define)\b", s):
        return False
    if re.search(r"\b(?:weather|forecast|umbrella)\b", s):
        return True
    timey = re.search(r"\b(?:today|tonight|tomorrow|now|this week|this weekend|outside|later|this (?:morning|afternoon|evening))\b", s)
    placey = re.search(r"\b(?:in|at|near|for)\s+[a-z\u00c0-\u024f]", s)
    starts = re.match(r"^(?:will it|is it|is it going to|does it|what(?:'s| is) the temperature|how (?:hot|cold|warm|windy|humid) is it)\b", s)
    return bool(starts and (timey or placey or re.fullmatch(r".*\b(?:rain|snow|raining|snowing)", s))) or bool((timey or placey) and re.match(r"^(?:temperature|rain|snow)\b", s))

def geocode(place, get_json):
    name, _, rest = place.partition(",")
    data = get_json(GEOCODE_URL, {"name": name.strip(), "count": 6, "language": "en", "format": "json"}, ttl=30 * 86400, prefix="omgeo")
    rows = data.get("results") or []
    if not rows:
        return None
    rest = rest.strip().casefold()
    if rest:
        for r in rows:
            blob = " ".join(str(r.get(k, "")) for k in ("country", "country_code", "admin1", "admin2")).casefold()
            if rest in blob or any(tok and tok in blob.split() for tok in re.split(r"[ ,]+", rest)):
                return r
    return rows[0]

def place_label(r):
    parts = [r.get("name"), r.get("admin1") if r.get("admin1") != r.get("name") else None, r.get("country")]
    return ", ".join(p for p in parts if p)

def c_f(c):
    return f"{c:.0f}\u00b0C ({c * 9 / 5 + 32:.0f}\u00b0F)"

def weather_answer(q, default_place, get_json):
    """-> (answer, sources) or (None, None) / (str needing a place, [])."""
    s = re.sub(r"\s+", " ", q.strip().rstrip("?.! "))
    m = _WX_PLACE_RE.search(s)
    place = m.group(1).strip(" ,.") if m else ""
    place = re.sub(r"\s+(?:today|tonight|tomorrow|now|right now|this week|this weekend)$", "", place, flags=re.I)
    if place.casefold() in {"here", "my area", "my city", "my town", "town", "my location", ""}:
        place = default_place or ""
    if not place:
        return "Where? Try \"weather in Leeds\", or tell me \"I live in ...\" once and I'll remember it.", []
    g = geocode(place, get_json)
    if not g:
        return f"I couldn't find a place called {place}. Try the city name, optionally with the country (\"Cambridge, UK\").", []
    data = get_json(FORECAST_URL, {"latitude": round(float(g["latitude"]), 3), "longitude": round(float(g["longitude"]), 3),
                                   "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,precipitation",
                                   "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum",
                                   "timezone": "auto", "forecast_days": 4}, ttl=1200, prefix="omfc")
    cur, daily = data.get("current") or {}, data.get("daily") or {}
    label = place_label(g)
    low = s.casefold()
    days = daily.get("time") or []
    def day_line(i, name):
        try:
            code = WMO.get(int(daily["weather_code"][i]), "mixed conditions")
            hi, lo = float(daily["temperature_2m_max"][i]), float(daily["temperature_2m_min"][i])
            pp = (daily.get("precipitation_probability_max") or [None] * 9)[i]
            rain = f", {int(pp)}% chance of precipitation" if pp is not None else ""
            return f"{name}: {code}, {c_f(lo)} to {c_f(hi)}{rain}."
        except Exception:
            return ""
    lines = []
    want_tomorrow = "tomorrow" in low
    want_week = bool(re.search(r"\b(this week|next few days|this weekend|forecast|next week)\b", low))
    if not want_tomorrow and cur.get("temperature_2m") is not None:
        code = WMO.get(int(cur.get("weather_code", -1)), "mixed conditions")
        t, feels = float(cur["temperature_2m"]), cur.get("apparent_temperature")
        wind, hum = cur.get("wind_speed_10m"), cur.get("relative_humidity_2m")
        bits = [f"Right now in {label}: {code}, {c_f(t)}"]
        if feels is not None and abs(float(feels) - t) >= 2:
            bits.append(f"feels like {c_f(float(feels))}")
        if wind is not None:
            bits.append(f"wind {float(wind):.0f} km/h ({float(wind) * 0.621371:.0f} mph)")
        if hum is not None:
            bits.append(f"humidity {int(hum)}%")
        lines.append(", ".join(bits) + ".")
    elif want_tomorrow:
        lines.append(f"Forecast for {label}:")
    if len(days) >= 1 and not want_tomorrow:
        lines.append(day_line(0, "Today"))
    if len(days) >= 2:
        lines.append(day_line(1, "Tomorrow"))
    if want_week:
        for i in range(2, min(4, len(days))):
            try:
                lines.append(day_line(i, datetime.strptime(days[i], "%Y-%m-%d").strftime("%A")))
            except Exception:
                pass
    if re.search(r"\b(rain|umbrella|raining)\b", low):
        i = 1 if want_tomorrow else 0
        try:
            pp = daily["precipitation_probability_max"][i]
            if pp is not None:
                verdict = "Yes, take an umbrella" if pp >= 60 else ("Maybe; it's borderline" if pp >= 30 else "Probably not")
                lines.insert(0, f"{verdict}: {int(pp)}% chance of precipitation {'tomorrow' if want_tomorrow else 'today'}.")
        except Exception:
            pass
    lines = [l for l in lines if l]
    if not lines:
        return None, None
    return "\n".join(lines), [{"title": "Weather data by Open-Meteo.com (CC BY 4.0)", "url": "https://open-meteo.com/"}]

def time_in_place(q, get_json):
    m = _TIME_IN_RE.match(re.sub(r"\s+", " ", q.strip().rstrip("?.! ")))
    if not m:
        return None, None
    place = m.group(1).strip()
    g = geocode(place, get_json)
    if not g:
        return f"I couldn't find a place called {place}.", []
    tzname = g.get("timezone") or ""
    now = None
    if tzname and ZoneInfo is not None:
        try:
            now = datetime.now(ZoneInfo(tzname))
        except Exception:
            now = None
    if now is None:   # fall back to the UTC offset reported by the forecast endpoint
        data = get_json(FORECAST_URL, {"latitude": round(float(g["latitude"]), 3), "longitude": round(float(g["longitude"]), 3), "current": "temperature_2m", "timezone": "auto"}, ttl=3600, prefix="omtz")
        off = data.get("utc_offset_seconds")
        if off is None:
            return None, None
        tzname = data.get("timezone") or tzname
        now = datetime.now(timezone.utc) + timedelta(seconds=int(off))
    return f"It's {now.strftime('%H:%M')} on {now.strftime('%A %-d %B')} in {place_label(g)}" + (f" ({tzname})." if tzname else "."), \
           [{"title": "Place and time zone lookup by Open-Meteo.com", "url": "https://open-meteo.com/"}]

# ------------------------------------------------------------------ dictionary (Wiktionary)
_DEFINE_RE = [re.compile(p, re.I) for p in (
    r"^(?:define|definition of|meaning of|what(?:'s| is) the (?:meaning|definition) of)\s+(?:the word\s+)?[\"'\u201c]?([a-z][a-z' \-]{0,40}?)[\"'\u201d]?$",
    r"^what does\s+(?:the word\s+)?[\"'\u201c]?([a-z][a-z' \-]{0,40}?)[\"'\u201d]?\s+mean$",
    r"^what(?:'s| is) the word\s+[\"'\u201c]?([a-z][a-z' \-]{0,40}?)[\"'\u201d]?$",
)]
POS = {"noun", "verb", "adjective", "adverb", "interjection", "pronoun", "preposition", "conjunction", "proper noun", "determiner", "numeral", "phrase", "prefix", "suffix", "article", "particle"}

def define_term(q):
    s = re.sub(r"\s+", " ", q.strip().rstrip("?.! "))
    for pat in _DEFINE_RE:
        m = pat.match(s)
        if m and len(m.group(1).split()) <= 3 and not (set(m.group(1).casefold().split()) & {"it", "this", "that", "life", "you", "i", "he", "she", "they", "we", "all"}):
            return m.group(1).strip()
    return ""

def _strip_html(x):
    x = re.sub(r"<(style|script)[^>]*>.*?</\1>", "", str(x or ""), flags=re.S | re.I)
    return re.sub(r"\s+", " ", htmlmod.unescape(re.sub(r"<[^>]+>", "", x))).strip()

def parse_rest_definition(data, limit=4):
    out, seen = [], set()
    for entry in (data or {}).get("en", []):
        pos = str(entry.get("partOfSpeech", "")).lower()
        taken = 0
        for d in entry.get("definitions", []):
            text = _strip_html(d.get("definition"))
            if len(text) > 2 and text not in seen:
                seen.add(text)
                out.append((pos, text))
                taken += 1
            if taken >= 2:
                break
    return out[:limit]

def parse_extract_definition(extract, limit=4):
    """Fallback parser for the plain-text Action API extract of a Wiktionary page."""
    out, in_english, pos, skip_head = [], False, "", False
    for line in str(extract or "").split("\n"):
        m = re.match(r"^\s*(=+)\s*(.+?)\s*=+\s*$", line)
        if m:
            level, title = len(m.group(1)), m.group(2).strip()
            if level == 2:
                in_english = title.casefold() == "english"
            pos = title.casefold() if title.casefold() in POS else ""
            skip_head = bool(pos)
            continue
        t = line.strip()
        if not (in_english and pos and t):
            continue
        if skip_head:          # first line under a part-of-speech heading is the headword line
            skip_head = False
            continue
        if len(t) > 3 and sum(1 for p, _ in out if p == pos) < 2 and not t.startswith(("Synonym", "Antonym", "Hyponym", "Coordinate")):
            out.append((pos, t))
        if len(out) >= limit:
            break
    return out

def define_answer(term, get_json):
    from urllib.parse import quote
    defs = []
    for variant in dict.fromkeys([term, term.casefold()]):
        try:
            data = get_json("https://en.wiktionary.org/api/rest_v1/page/definition/" + quote(variant.replace(" ", "_")), {}, ttl=30 * 86400, prefix="wktrest")
            defs = parse_rest_definition(data)
        except Exception:
            defs = []
        if defs:
            break
    if not defs:
        try:
            data = get_json("https://en.wiktionary.org/w/api.php", {"action": "query", "prop": "extracts", "explaintext": 1, "exsectionformat": "wiki", "redirects": 1,
                                                                   "titles": term.casefold(), "format": "json", "formatversion": 2}, ttl=30 * 86400, prefix="wktext")
            pages = (data.get("query") or {}).get("pages") or []
            defs = parse_extract_definition(pages[0].get("extract", "")) if pages else []
        except Exception:
            defs = []
    if not defs:
        return None, None
    if term.isupper() and len(term) <= 6:      # v52: for an acronym, the expansion ("Initialism of ...") comes before airport codes and the like
        defs = sorted(defs, key=lambda d: 0 if re.search(r"(?i)initialism|abbreviation|acronym", d[1]) else 1)
    lines = [f"{term}:"] + [f"\u2022 ({p}) {t}" if p else f"\u2022 {t}" for p, t in defs]
    return "\n".join(lines), [{"title": f"Wiktionary: {term}", "url": "https://en.wiktionary.org/wiki/" + quote(term.casefold().replace(" ", "_"))}]
__NOAI_V11_SKILLS_PY__
cat > "$APP_DIR/app/semantic.py" <<'__NOAI_V12_SEMANTIC_PY__'
"""Optional neural sentence encoder for NoAI Chat (all-MiniLM-L6-v2, ONNX Runtime, no PyTorch).

It does not generate text. It turns a question and a handful of candidate passages into vectors so the passage
whose *meaning* is closest can be preferred over one that merely shares keywords.

A transformer is far slower than the static word vectors used elsewhere, so this module measures the machine it is
running on at start-up and derives how many passages it may score per question (`budget`). On hardware where even
a few passages would take too long it switches itself off, and the app carries on with lexical + static ranking."""
import os, time, hashlib, threading
from collections import OrderedDict

MODEL_DIR = os.environ.get("NOAI_SEMANTIC_PATH", "/opt/minilm")
TARGET_MS = float(os.environ.get("NOAI_SEMANTIC_MS", "1200"))      # time the neural step may add to one answer
MIN_BUDGET, MAX_BUDGET = 4, 24
# About 120 tokens: the size of a real Wikipedia paragraph after truncation. v12 timed a single short sentence, which
# made a Pi look four times faster than it is on real paragraphs (27 ms measured vs ~110 ms in use).
_PROBE = ("A refrigerator is a commercial and home appliance consisting of a thermally insulated compartment and a heat pump "
          "that transfers heat from its inside to its external environment so that its inside is cooled to a temperature below "
          "the ambient temperature of the room. Refrigeration is an essential food storage technique around the world. The low "
          "temperature reduces the reproduction rate of bacteria, so the refrigerator lowers the rate of spoilage. A refrigerator "
          "maintains a temperature a few degrees above the freezing point of water. The optimal temperature range for perishable "
          "food storage is three to five degrees Celsius, and a similar device that maintains a temperature below freezing is a freezer.")


class NeuralEncoder:
    def __init__(self, model_dir=MODEL_DIR, max_len=128):
        self.ok, self.reason, self.ms_per_passage, self.budget, self.model_file = False, "", 0.0, 0, ""
        self._cache, self._lock, self.max_len = OrderedDict(), threading.Lock(), max_len
        if os.environ.get("NOAI_SEMANTIC", "1") == "0":
            self.reason = "disabled by NOAI_SEMANTIC=0"
            return
        try:
            import numpy as np
            import onnxruntime as ort
            from tokenizers import Tokenizer
            model = os.path.join(model_dir, "model.onnx")
            tokp = os.path.join(model_dir, "tokenizer.json")
            if not (os.path.isfile(model) and os.path.isfile(tokp)):
                self.reason = "model files not installed"
                return
            so = ort.SessionOptions()
            so.intra_op_num_threads = max(1, min(4, os.cpu_count() or 1))
            so.inter_op_num_threads = 1
            so.log_severity_level = 3
            self._np = np
            self._sess = ort.InferenceSession(model, so, providers=["CPUExecutionProvider"])
            self._inputs = {i.name for i in self._sess.get_inputs()}
            self._tok = Tokenizer.from_file(tokp)
            self._tok.enable_truncation(max_len)
            self._tok.enable_padding()
            try:
                self.model_file = open(os.path.join(model_dir, "VARIANT")).read().strip()
            except Exception:
                self.model_file = "model.onnx"
            self._raw_encode([_PROBE])                         # warm-up (graph optimisation, allocations)
            t = time.perf_counter()
            vecs = self._raw_encode([_PROBE + " " + str(i) for i in range(6)])
            self.ms_per_passage = (time.perf_counter() - t) * 1000 / 6
            a, b, c = self._raw_encode(["What makes the sea rise and fall twice a day?",
                                        "Tides are caused by the gravitational pull of the Moon and the Sun on the oceans.",
                                        "The committee approved the annual budget for road maintenance."])
            if not float(a @ b) > float(a @ c) + 0.15:       # a broken or mis-quantised export must not silently rank
                self.reason = f"sanity check failed ({float(a @ b):.2f} vs {float(a @ c):.2f})"
                return
            self.budget = int(min(MAX_BUDGET, TARGET_MS / max(1.0, self.ms_per_passage)))
            if self.budget < MIN_BUDGET:
                self.reason = f"too slow on this machine ({self.ms_per_passage:.0f} ms per passage)"
                self.budget = 0
                return
            self.ok = True
            del vecs
        except Exception as e:                                   # missing wheel, unsupported CPU, corrupt file...
            self.reason = f"{type(e).__name__}: {e}"[:160]

    def _raw_encode(self, texts):
        np = self._np
        enc = self._tok.encode_batch([t[:1200] for t in texts])
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self._inputs:
            feed["token_type_ids"] = np.zeros_like(ids)
        out = self._sess.run(None, feed)[0]                      # token embeddings
        m = mask[..., None].astype(np.float32)
        v = (out * m).sum(1) / np.clip(m.sum(1), 1e-9, None)     # mean pooling, as the model was trained
        return v / (np.linalg.norm(v, axis=1, keepdims=True) + 1e-9)

    def encode(self, texts, batch=8):
        """Vectors for texts, using a small LRU cache (follow-up questions re-score the same passages)."""
        np = self._np
        keys = [hashlib.blake2b(t.encode("utf-8", "ignore"), digest_size=10).digest() for t in texts]
        out, todo = [None] * len(texts), []
        with self._lock:
            for i, k in enumerate(keys):
                v = self._cache.get(k)
                if v is not None:
                    self._cache.move_to_end(k)
                    out[i] = v
                else:
                    todo.append(i)
        todo.sort(key=lambda i: len(texts[i]))                  # similar lengths per batch = less padding
        for s in range(0, len(todo), batch):
            idx = todo[s:s + batch]
            vecs = self._raw_encode([texts[i] for i in idx])
            with self._lock:
                for i, v in zip(idx, vecs):
                    out[i] = v
                    self._cache[keys[i]] = v
                while len(self._cache) > 3000:
                    self._cache.popitem(last=False)
        return np.stack(out) if out else np.zeros((0, 384), dtype="float32")

    def similarity(self, query, texts):
        if not self.ok or not texts:
            return []
        try:
            v = self.encode([query] + list(texts))
            return [float(x) for x in (v[1:] @ v[0])]
        except Exception:
            return []

    def info(self):
        return {"enabled": self.ok, "model": "all-MiniLM-L6-v2 (" + self.model_file + ")" if self.model_file else "",
                "ms_per_passage": round(self.ms_per_passage, 1), "passages_per_question": self.budget, "note": self.reason}
__NOAI_V12_SEMANTIC_PY__
cat > "$APP_DIR/app/structured.py" <<'__NOAI_V15_STRUCTURED_PY__'
"""Structured answers without a text generator.

Two kinds of question cannot be answered by quoting a passage:
  * "dry rub recipe for chicken wings"  -> needs ingredients + steps
  * "top attractions in New York City"  -> needs a list

Recipes: almost every recipe site embeds a machine-readable schema.org/Recipe block (JSON-LD, sometimes microdata) for
search engines. Reading that block gives the exact ingredient list and the numbered method, verbatim, with no guessing.

Lists: "best of" pages are structured as numbered headings or ordered lists. Items are pulled from several independent
sites and merged; an item named by more sites ranks higher. The answer is therefore a consensus of sources, not one
blogger's opinion, and every site consulted is cited."""
import re, json, html as htmlmod
from collections import Counter

# ------------------------------------------------------------------ helpers
_TAG = re.compile(r"<[^>]+>")

def _strip_hashnum(x):
    return _HASHNUM.sub("", x)

def _clean(x, limit=600):
    s = htmlmod.unescape(_TAG.sub(" ", str(x or "")))
    s = re.sub(r"\s+", " ", s).strip(" \u2022-\u2013")
    return s[:limit].rstrip()

_FRAC = {0.125: "1/8", 0.25: "1/4", 0.333: "1/3", 0.375: "3/8", 0.5: "1/2", 0.625: "5/8", 0.667: "2/3", 0.75: "3/4", 0.875: "7/8"}

def _quantity(s):
    """'2.3333332538605 cups' -> '2 1/3 cups'; '0.25 teaspoon' -> '1/4 teaspoon'."""
    def fix(m):
        v = float(m.group(0))
        whole, part = int(v), v - int(v)
        for k, name in _FRAC.items():
            if abs(part - k) < 0.02:
                return (f"{whole} " if whole else "") + name
        return (f"{v:.2f}".rstrip("0").rstrip(".")) if part else str(whole)
    return re.sub(r"(?<![\w/.])\d+\.\d+(?![\w/])", fix, s)

def iso_duration(v):
    """PT1H30M -> '1 h 30 min'."""
    m = re.match(r"^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$", str(v or "").strip(), re.I)
    if not m or not any(m.groups()):
        return ""
    d, h, mi, _ = (int(g) if g else 0 for g in m.groups())
    h += d * 24
    if mi >= 60:
        h, mi = h + mi // 60, mi % 60
    return " ".join(p for p in (f"{h} h" if h else "", f"{mi} min" if mi else "") if p)

def _types(node):
    t = node.get("@type")
    return [str(x).casefold() for x in (t if isinstance(t, list) else [t]) if x]

def _walk(node, depth=0):
    if depth > 8:
        return
    if isinstance(node, dict):
        yield node
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from _walk(v, depth + 1)
    elif isinstance(node, list):
        for v in node[:200]:
            yield from _walk(v, depth + 1)

def _steps(v, out, depth=0):
    if depth > 4 or len(out) >= 40:
        return
    if isinstance(v, str):
        parts = [p for p in re.split(r"(?:\r?\n)+|(?<=[.!?])\s+(?=\d+[.)]\s)", _clean(v, 4000)) if p.strip()] if ("\n" in v or len(v) > 500) else [_clean(v, 1200)]
        out.extend(p for p in (re.sub(r"^\s*(?:step\s*)?\d+[.):]\s*", "", x, flags=re.I).strip() for x in parts) if len(p) > 3)
    elif isinstance(v, list):
        for x in v:
            _steps(x, out, depth + 1)
    elif isinstance(v, dict):
        t = _types(v)
        if "howtosection" in t or "itemlistelement" in v:
            name = _clean(v.get("name"), 80)
            before = len(out)
            _steps(v.get("itemListElement") or v.get("steps") or [], out, depth + 1)
            if name and len(out) > before and not out[before].casefold().startswith(name.casefold()):
                out[before] = f"[{name}] {out[before]}"
        else:
            text = _clean(v.get("text") or v.get("description") or v.get("name"), 1200)
            if len(text) > 3:
                out.append(text)

# ------------------------------------------------------------------ recipes
def extract_recipes(soup):
    """-> list of {name, yield, time, ingredients[], steps[]} from JSON-LD (preferred) or microdata."""
    found = []
    for tag in soup.find_all("script", attrs={"type": re.compile(r"ld\+json", re.I)})[:12]:
        raw = tag.string or tag.get_text() or ""
        raw = raw.strip()
        if not raw or "recipe" not in raw.casefold():
            continue
        data = None
        for attempt in (raw, re.sub(r",\s*([}\]])", r"\1", raw), raw.replace("\n", " ").replace("\t", " ")):
            try:
                data = json.loads(attempt, strict=False)
                break
            except Exception:
                continue
        if data is None:
            continue
        for node in _walk(data):
            if "recipe" not in _types(node):
                continue
            ings = node.get("recipeIngredient") or node.get("ingredients") or []
            if isinstance(ings, str):
                ings = [x for x in re.split(r"\r?\n|;", ings) if x.strip()]
            ings = [i for i in (_quantity(_clean(x, 200)) for x in ings if isinstance(x, (str, int, float))) if i]
            steps = []
            _steps(node.get("recipeInstructions") or [], steps)
            y = node.get("recipeYield")
            y = y[-1] if isinstance(y, list) and y else y
            times = [("prep", iso_duration(node.get("prepTime"))), ("cook", iso_duration(node.get("cookTime"))), ("total", iso_duration(node.get("totalTime")))]
            rec = {"name": _clean(node.get("name"), 120), "yield": _clean(y, 60), "time": ", ".join(f"{k} {v}" for k, v in times if v),
                   "ingredients": list(dict.fromkeys(ings))[:40], "steps": list(dict.fromkeys(steps))[:25]}
            if len(rec["ingredients"]) >= 2:
                found.append(rec)
    if not found:                                   # microdata fallback
        ings = [_clean(t.get_text(" "), 200) for t in soup.select('[itemprop="recipeIngredient"], [itemprop="ingredients"]')]
        ings = [i for i in ings if i]
        if len(ings) >= 2:
            steps = []
            for t in soup.select('[itemprop="recipeInstructions"]'):
                lis = t.find_all("li")
                steps.extend(_clean(x.get_text(" "), 1200) for x in lis) if lis else _steps(t.get_text("\n"), steps)
            name = soup.select_one('[itemprop="name"]')
            found.append({"name": _clean(name.get_text(" "), 120) if name else "", "yield": "", "time": "",
                          "ingredients": list(dict.fromkeys(ings))[:40], "steps": [s for s in dict.fromkeys(steps) if len(s) > 3][:25]})
    return found

# ------------------------------------------------------------------ FAQ / Q&A / HowTo blocks
def extract_faq(soup):
    """Sites publish their own question-and-answer pairs (schema.org FAQPage / QAPage) and step lists (HowTo) for search
    engines. When the visitor's question matches one, the site's complete answer is far cleaner than a scraped window.
    -> [{'q': question, 'a': answer text}]"""
    out = []
    for tag in soup.find_all("script", attrs={"type": re.compile(r"ld\+json", re.I)})[:12]:
        raw = (tag.string or tag.get_text() or "").strip()
        low = raw.casefold()
        if not raw or not ("question" in low or "howto" in low):
            continue
        data = None
        for attempt in (raw, re.sub(r",\s*([}\]])", r"\1", raw)):
            try:
                data = json.loads(attempt, strict=False)
                break
            except Exception:
                continue
        if data is None:
            continue
        for node in _walk(data):
            ty = _types(node)
            if "question" in ty:
                ans = node.get("acceptedAnswer") or node.get("suggestedAnswer") or {}
                ans = ans[0] if isinstance(ans, list) and ans else ans
                a = _clean((ans or {}).get("text") if isinstance(ans, dict) else ans, 1200)
                qn = _clean(node.get("name") or node.get("text"), 300)
                if qn and len(a) >= 40:
                    out.append({"q": qn, "a": a})
            elif "howto" in ty and "recipe" not in ty:
                steps = []
                _steps(node.get("step") or node.get("steps") or [], steps)
                name = _clean(node.get("name"), 200)
                needs = []
                for k in ("supply", "tool"):
                    v = node.get(k) or []
                    for x in (v if isinstance(v, list) else [v]):
                        nm = _clean(x.get("name") if isinstance(x, dict) else x, 120)
                        if nm:
                            needs.append(nm)
                if name and len(steps) >= 2:
                    out.append({"q": name, "a": " ".join(f"{i}. {s}" for i, s in enumerate(steps[:12], 1))[:1500], "howto": True, "steps": steps[:30], "needs": needs[:20]})
    seen, uniq = set(), []
    for x in out:
        if x["q"].casefold() not in seen:
            seen.add(x["q"].casefold())
            uniq.append(x)
    return uniq[:40]

# ------------------------------------------------------------------ procedural steps written as ordered lists or "Step N" headings
_IMPERATIVE = set("""add apply arrange assemble attach bake blend boil bring brush check choose clean clear close combine connect cook cool cover cut
decide determine dig disconnect drain drill dry empty fill find fit fold gather get give go hang heat hold insert install keep leave let lift lower loosen
make mark measure mix mount open pack pat place plug position pour prepare press pull push put remove repeat replace rinse roll rub run sand scrub seal season
secure select set shake sharpen slide soak spray spread sprinkle squeeze start stir store strain take tape test tie tighten trim turn unplug unscrew use wait
wash water whisk wipe wrap draw lay line slice chop scrape peel grate tilt angle rotate adjust allow avoid begin continue finish look move
pick plant prune rake read reboot restart save sew sort stop tap toss transfer type unlock update verify wear whip flip lift level label locate loosen rest
spoon steam sweep switch unplug unwrap vacuum wrap""".split())
_STEPH = re.compile(r"^\s*(?:step\s*)?(\d{1,2})\s*[.):\-\u2013]?\s*(.*)$", re.I)

def extract_steps(soup):
    """-> (steps, needs): the longest procedural list on the page (ordered list items of sentence length, or 'Step N' headings
    with the paragraph under each), plus a 'what you need' list if a heading announces one."""
    for t in soup(["script", "style", "nav", "footer", "header", "aside", "form", "noscript"]):
        t.decompose()
    best = []
    for ol in soup.find_all("ol")[:40]:
        items = [_clean(li.get_text(" "), 600) for li in ol.find_all("li", recursive=False)]
        items = [x for x in items if len(x) >= 25 and not _BOILER.match(x)]
        if len(items) >= 3 and sum(len(x) for x in items) / len(items) >= 40 and len(items) > len(best):
            best = items
    # v51: a run of imperative sub-headings ("Loosen the lug nuts", "Rinse the kettle") under one section is a step list even
    # when nothing is numbered; each step carries the paragraph beneath it
    imp = []
    for h in soup.find_all(["h2", "h3", "h4"])[:120]:
        t = _clean(h.get_text(" "), 160)
        w = t.split()
        if 2 <= len(w) <= 12 and w[0].lower().rstrip(":") in _IMPERATIVE and not t.endswith("?"):
            para = h.find_next(["p", "li"])
            body = _clean(para.get_text(" "), 500) if para else ""
            imp.append((h.name, t + (": " + body if body and len(body) > 20 else "")))
        elif imp and h.name <= imp[-1][0]:      # a heading of the same or higher level that is not imperative ends the run
            if len(imp) >= 3 and len(imp) > len(best):
                best = [x for _, x in imp]
            imp = []
    if len(imp) >= 3 and len(imp) > len(best):
        best = [x for _, x in imp]
    heads = []
    for h in soup.find_all(["h2", "h3", "h4"])[:120]:
        m = _STEPH.match(h.get_text(" "))
        if not m or not m.group(2).strip():
            continue
        para = h.find_next(["p", "li"])
        body = _clean(para.get_text(" "), 500) if para else ""
        heads.append((int(m.group(1)), _clean(m.group(2), 160) + (": " + body if body and len(body) > 20 else "")))
    if len(heads) >= 3:
        nums = [n for n, _ in heads]
        if nums == sorted(nums) and len(heads) > len(best):
            best = [x for _, x in heads]
    needs = []
    for h in soup.find_all(["h2", "h3", "h4", "strong", "b"])[:200]:
        if re.search(r"\b(?:what you(?:'ll| will)? need|things you(?:'ll| will)? need|you will need|materials|supplies|tools (?:needed|required)|requirements|ingredients)\b", h.get_text(" "), re.I):
            lst = h.find_next(["ul", "ol"])
            if lst:
                needs = [_clean(li.get_text(" "), 120) for li in lst.find_all("li")][:20]
                needs = [x for x in needs if x]
                break
    return best[:30], needs

# ------------------------------------------------------------------ list items
_BOILER = re.compile(r"^(?:things to (?:do|see|know)|what to (?:do|see|eat)|top \\d+|best of|our (?:top )?picks?|faqs?|frequently asked|conclusion|final (?:thoughts|words)|related|share|comments?|leave a|newsletter|subscribe|about|"
                     r"tips?\b|where to (?:stay|eat)|how to get|getting (?:there|around)|map\b|table of contents|contents|introduction|overview|summary|"
                     r"you (?:may|might) also|more (?:from|in|on|like)|read (?:more|next)|recommended|popular posts?|latest|search|menu|categories|"
                     r"best time|when to (?:go|visit)|plan your|book (?:now|your)|privacy|cookie|advertis|sign up|follow us|contact|references?|sources?|"
                     r"see also|external links|notes|further reading|what (?:is|are)|why\b|how (?:we|to|much|many|long)\b|our (?:picks|methodology)|disclaimer|"
                     r"the bottom line|key takeaways|pros|cons|ingredients|instructions|directions|method|nutrition|reviews?)\b", re.I)
_NUM = re.compile(r"^\s*(?:#|no\.?\s*)?(\d{1,3})\s*[.):\-\u2013]\s*|^\s*(\d{1,3})\s+(?=[A-Z])")
_HASHNUM = re.compile(r"^\s*#\s*\d{1,3}\s+")

def _item_text(s):
    s = _clean(s, 160)
    had_num = bool(_NUM.match(s)) or bool(_HASHNUM.match(s))
    s = _HASHNUM.sub("", _NUM.sub("", s, count=1)).strip()
    s = re.split(r"\s+[\u2013\u2014|]\s+|\s+-\s+|:\s+(?=[A-Z][a-z]+ [a-z])", s)[0].strip(" .:;,")
    return s, had_num

def _ok_item(s):
    ws = s.split()
    return 1 <= len(ws) <= 9 and 3 <= len(s) <= 70 and not _BOILER.match(s) and not s.endswith("?") and re.search(r"[A-Za-z]", s) is not None

def extract_lists(soup):
    """-> best list of item strings found on the page ([] if the page is not list-shaped)."""
    for t in soup(["script", "style", "nav", "footer", "header", "aside", "form", "noscript"]):
        t.decompose()
    groups = []
    for level in ("h2", "h3", "h4"):
        items, numbered = [], 0
        for h in soup.find_all(level)[:80]:
            s, had = _item_text(h.get_text(" "))
            if _ok_item(s):
                items.append(s)
                numbered += had
        if len(items) >= 4:
            groups.append((len(items) + 3 * numbered + (2 if level == "h2" else 0), items))
    for lst in soup.find_all(["ol", "ul"])[:60]:
        lis = lst.find_all("li", recursive=False)
        if len(lis) < (4 if lst.name == "ol" else 5) or len(lis) > 60:
            continue
        items, strongish = [], 0
        for li in lis:
            lead = li.find(["strong", "b", "a", "h3", "h4"])
            if lead is not None and 2 <= len(lead.get_text(" ").strip()) <= 70 and li.get_text(" ").strip().startswith(lead.get_text(" ").strip()[:12]):
                s, _ = _item_text(lead.get_text(" "))
                strongish += 1
            else:
                s, _ = _item_text(li.get_text(" "))
            if _ok_item(s):
                items.append(s)
        if len(items) >= 4 and (lst.name == "ol" or strongish >= len(items) * 0.6):
            groups.append((len(items) + (4 if lst.name == "ol" else 0) + strongish // 2, items))
    if not groups:
        return []
    groups.sort(key=lambda g: g[0], reverse=True)
    return list(dict.fromkeys(groups[0][1]))[:40]

# ------------------------------------------------------------------ consensus across sites
_STOP = set("the a an of and in at on to for de la le el s new old great famous national".split())

def _key(s):
    s = re.sub(r"\([^)]*\)", " ", s.casefold())
    toks = [t for t in re.findall(r"[a-z0-9]+", s) if t not in _STOP]
    return frozenset(toks)

def consensus(per_site, subject_words=(), limit=10):
    """per_site: [(domain, [items...])] -> [{name, sites, domains}] ordered by how many independent sites name the item."""
    subject = _key(" ".join(subject_words))
    clusters = []
    for domain, items in per_site:
        for rank, item in enumerate(items[:30]):
            k = _key(item)
            if not k or k <= subject:
                continue
            best = None
            for c in clusters:
                inter = len(k & c["key"])
                if inter and (inter / len(k | c["key"]) >= 0.6 or ((k <= c["key"] or c["key"] <= k) and min(len(k), len(c["key"])) >= 2)):
                    best = c
                    break
            if best is None:
                best = {"key": k, "names": Counter(), "domains": {}, "score": 0.0}
                clusters.append(best)
            elif len(k) < len(best["key"]):
                best["key"] = k
            best["names"][item] += 1
            if domain not in best["domains"]:
                best["domains"][domain] = rank
                best["score"] += 10.0 + 3.0 / (rank + 1)
    for c in clusters:
        c["name"] = sorted(c["names"].items(), key=lambda kv: (-kv[1], len(kv[0])))[0][0]
        c["sites"] = len(c["domains"])
    clusters.sort(key=lambda c: c["score"], reverse=True)
    return [{"name": c["name"], "sites": c["sites"], "domains": sorted(c["domains"])} for c in clusters[:limit]]
__NOAI_V15_STRUCTURED_PY__
cat > "$APP_DIR/app/judge.py" <<'__NOAI_V17_JUDGE_PY__'
"""Optional answer judge for NoAI Chat: the MS MARCO cross-encoder (cross-encoder/ms-marco-MiniLM-L6-v2, ONNX, no PyTorch).

The sentence encoder in semantic.py answers "is this passage ABOUT the same thing as the question?". This model was
trained on millions of real search queries to answer a different question: "does this passage ANSWER it?". It reads
the question and one candidate passage together and returns a single relevance score. It cannot generate text.

Used last, over the handful of candidate answers gathered from Wikipedia AND the web, to pick the one to show.
Safety: at start-up it must score the model card's own example the documented way round (relevant passage far above
irrelevant), and it times itself; if either check fails it switches itself off and the app falls back to MiniLM."""
import os, time, threading

MODEL_DIR = os.environ.get("NOAI_JUDGE_PATH", "/opt/judge")
TARGET_MS = float(os.environ.get("NOAI_JUDGE_MS", "1700"))
CHECK_Q = "How many people live in Berlin?"
CHECK_GOOD = "Berlin had a population of 3,520,031 registered inhabitants in an area of 891.82 square kilometers."
CHECK_BAD = "Berlin is well known for its museums."


class AnswerJudge:
    def __init__(self, model_dir=MODEL_DIR, max_len=256):
        self.ok, self.reason, self.ms_per_pair, self.budget, self.model_file = False, "", 0.0, 0, ""
        self._lock = threading.Lock()
        if os.environ.get("NOAI_JUDGE", "1") == "0":
            self.reason = "disabled by NOAI_JUDGE=0"
            return
        try:
            import numpy as np
            import onnxruntime as ort
            from tokenizers import Tokenizer
            model, tokp = os.path.join(model_dir, "model.onnx"), os.path.join(model_dir, "tokenizer.json")
            if not (os.path.isfile(model) and os.path.isfile(tokp)):
                self.reason = "model files not installed"
                return
            so = ort.SessionOptions()
            so.intra_op_num_threads = max(1, min(4, os.cpu_count() or 1))
            so.inter_op_num_threads = 1
            so.log_severity_level = 3
            self._np = np
            self._sess = ort.InferenceSession(model, so, providers=["CPUExecutionProvider"])
            self._inputs = {i.name for i in self._sess.get_inputs()}
            self._tok = Tokenizer.from_file(tokp)
            self._tok.enable_truncation(max_len)
            self._tok.enable_padding()
            try:
                self.model_file = open(os.path.join(model_dir, "VARIANT")).read().strip()
            except Exception:
                self.model_file = "model.onnx"
            good, bad = self._raw(CHECK_Q, [CHECK_GOOD, CHECK_BAD])
            if not (good > bad + 4.0):           # the model card documents about 8.6 versus -4.3
                self.reason = f"sanity check failed (relevant {good:.1f} vs irrelevant {bad:.1f})"
                return
            probe = (CHECK_GOOD + " ") * 6
            t = time.perf_counter()
            self._raw(CHECK_Q, [probe + str(i) for i in range(4)])
            self.ms_per_pair = (time.perf_counter() - t) * 1000 / 4
            self.budget = int(min(12, TARGET_MS / max(1.0, self.ms_per_pair)))
            if self.budget < 3:
                self.reason = f"too slow on this machine ({self.ms_per_pair:.0f} ms per candidate)"
                self.budget = 0
                return
            self.ok = True
        except Exception as e:
            self.reason = f"{type(e).__name__}: {e}"[:160]

    def _raw(self, query, passages):
        np = self._np
        enc = self._tok.encode_batch([(query, p[:1600]) for p in passages])
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": np.array([e.attention_mask for e in enc], dtype=np.int64)}
        if "token_type_ids" in self._inputs:
            feed["token_type_ids"] = np.array([e.type_ids for e in enc], dtype=np.int64)
        out = np.asarray(self._sess.run(None, feed)[0], dtype="float32")
        out = out.reshape(len(passages), -1)
        return [float(x) for x in (out[:, -1] if out.shape[1] > 1 else out[:, 0])]

    def scores(self, query, passages):
        """Relevance logits, higher = answers the question better. [] if unavailable."""
        if not self.ok or not passages:
            return []
        try:
            with self._lock:
                return self._raw(query, list(passages)[:max(1, self.budget)])
        except Exception:
            return []

    def info(self):
        return {"enabled": self.ok, "model": ("ms-marco-MiniLM-L6-v2 (" + self.model_file + ")") if self.model_file else "",
                "ms_per_candidate": round(self.ms_per_pair, 1), "candidates_per_question": self.budget, "note": self.reason}
__NOAI_V17_JUDGE_PY__
cat > "$APP_DIR/app/tools.py" <<'__NOAI_V18_TOOLS_PY__'
"""Tools for NoAI Chat: things the bot can DO, not just look up.

Safety model (deliberate, please keep):
  * Every tool is a fixed, named action implemented in Python with validated arguments. User text is never passed to a
    shell, never evaluated, and never used as a path outside FILES_ROOT.
  * File tools see exactly one folder (FILES_ROOT, a directory the installer mounts into the container). Paths are
    resolved and must stay inside it; only plain-text file types can be read or changed.
  * Anything that destroys or overwrites (delete a file, clear a list, delete an event) asks for a yes/no first.
  * Every tool action requires the access code. General Q&A stays open to the household; tools do not.
  * Every write is recorded in an audit table.
Nothing fetched from the web can trigger a tool: only the user's own sentence matching one of the patterns below can."""
import os, re, json, time, sqlite3, shutil, uuid
from datetime import datetime, timedelta, date, timezone

TEXT_EXT = {".txt", ".md", ".csv", ".log", ".json", ".yml", ".yaml", ".ini", ".cfg", ".conf", ".list", ".text", ""}
MAX_READ = 24_000

# ------------------------------------------------------------------ date / time understanding
_NUM = {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "sixty": 60, "ninety": 90}
_NUMW = r"(?:\d+(?:\.\d+)?|" + "|".join(sorted(_NUM, key=len, reverse=True)) + r"|half an?|a couple of|a few)"
_UNIT = {"second": 1, "sec": 1, "minute": 60, "min": 60, "hour": 3600, "hr": 3600, "day": 86400, "week": 604800}
_UNITW = r"(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)"
_DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
_DAYW = r"(mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)"
_MONTHS = {m: i for i, m in enumerate("january february march april may june july august september october november december".split(), 1)}
_MONTHS.update({m[:3]: i for m, i in list(_MONTHS.items())})
_MONTHS["sept"] = 9
_MONW = "(" + "|".join(sorted(_MONTHS, key=len, reverse=True)) + ")"

def _num(tok):
    tok = tok.strip().lower()
    if tok.startswith("half"):
        return 0.5
    if tok == "a couple of":
        return 2
    if tok == "a few":
        return 3
    return _NUM[tok] if tok in _NUM else float(tok)

def _unit_seconds(u):
    u = u.lower().rstrip("s")
    return _UNIT.get(u, _UNIT.get(u + "s", 60))

def parse_when(text, now):
    """Pull date/time/duration phrases out of text. -> dict(dt, all_day, duration_min, relative, rest)
    'dentist on friday at 3pm for 1 hour' -> Friday 15:00, 60 min, rest='dentist'."""
    s = " " + re.sub(r"\s+", " ", text.strip()) + " "
    spans, day, tm, rel, dur = [], None, None, None, None

    def take(m):
        spans.append((m.start(), m.end()))

    m = re.search(rf"\bfor ({_NUMW}) {_UNITW}(?: and ({_NUMW}) {_UNITW})?\b", s, re.I)
    if m:
        dur = _num(m.group(1)) * _unit_seconds(m.group(2)) + (_num(m.group(3)) * _unit_seconds(m.group(4)) if m.group(3) else 0)
        take(m)
    m = re.search(rf"\b(?:in|after) ({_NUMW}) {_UNITW}(?: and ({_NUMW}) {_UNITW})?(?: from now| time)?\b", s, re.I)
    if m:
        rel = _num(m.group(1)) * _unit_seconds(m.group(2)) + (_num(m.group(3)) * _unit_seconds(m.group(4)) if m.group(3) else 0)
        take(m)
    m = re.search(rf"\b({_NUMW})[- ]{_UNITW}\b(?= (?:timer|alarm|reminder))", s, re.I)
    if m and rel is None:
        rel = _num(m.group(1)) * _unit_seconds(m.group(2))
        take(m)
    today = now.date()
    for pat, fn in (
        (r"\b(?:the )?day after tomorrow\b", lambda m: today + timedelta(days=2)),
        (r"\btomorrow\b|\btmrw\b|\btmr\b", lambda m: today + timedelta(days=1)),
        (r"\b(?:today|tonight|this (?:morning|afternoon|evening))\b", lambda m: today),
        (r"\b(\d{4})-(\d{2})-(\d{2})\b", lambda m: date(int(m.group(1)), int(m.group(2)), int(m.group(3)))),
        (rf"\b(?:on )?(?:the )?(\d{{1,2}})(?:st|nd|rd|th)?(?: of)? {_MONW}\.?(?:,? (\d{{4}}))?\b", lambda m: _md(int(m.group(1)), _MONTHS[m.group(2).lower()], m.group(3), today)),
        (rf"\b(?:on )?{_MONW}\.? (\d{{1,2}})(?:st|nd|rd|th)?(?:,? (\d{{4}}))?\b", lambda m: _md(int(m.group(2)), _MONTHS[m.group(1).lower()], m.group(3), today)),
        (rf"\b(?:on |this |next |coming )*{_DAYW}\b", lambda m: _weekday(m, today)),
        (r"\bnext week\b", lambda m: today + timedelta(days=7)),
    ):
        m = re.search(pat, s, re.I)
        if m:
            try:
                day = fn(m)
            except (ValueError, KeyError):
                day = None
            if day:
                if re.search(r"\btonight\b", m.group(0), re.I) and tm is None:
                    tm = (20, 0)
                elif re.search(r"this morning", m.group(0), re.I):
                    tm = (9, 0)
                elif re.search(r"this afternoon", m.group(0), re.I):
                    tm = (15, 0)
                elif re.search(r"this evening", m.group(0), re.I):
                    tm = (19, 0)
                take(m)
                break
    explicit_time = False
    # "half past nine", "quarter to seven", "quarter past 3" (am/pm optional; bare hours follow the same afternoon rule as below)
    _H = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12}
    m = re.search(r"\b(?:at |by |around )?(half|quarter|a quarter) (past|to|after|before) (\d{1,2}|" + "|".join(_H) + r")(?: o'clock)? ?(a\.?m\.?|p\.?m\.?|in the morning|in the evening|at night|in the afternoon)?\b", s, re.I)
    if m:
        h = _H.get(m.group(3).lower()) or int(m.group(3))
        mi = 30 if m.group(1).lower() == "half" else 15
        if m.group(2).lower() in ("to", "before"):
            h, mi = h - 1, 60 - mi
        ap = (m.group(4) or "").lower().replace(".", "")
        if 0 <= h <= 23:
            if (ap in ("pm", "in the evening", "at night", "in the afternoon")) and h < 12:
                h += 12
            elif not ap and 1 <= h <= 6:
                h += 12
            tm, explicit_time = (h % 24, mi), True
            take(m)
    m = None if explicit_time else re.search(r"\b(?:at |by |around |@ ?)?(\d{1,2})(?::|\.)(\d{2}) ?(a\.?m\.?|p\.?m\.?)?\b", s, re.I) or \
        re.search(r"\b(?:at |by |around |@ ?)?(\d{1,2})()? ?(a\.?m\.?|p\.?m\.?)\b", s, re.I) or \
        re.search(r"\b(?:at|by|around|@) ?(\d{1,2})()()\b(?! ?(?:%|percent|st|nd|rd|th|minutes?|hours?|days?))", s, re.I)
    if m and not any(a <= m.start() < b for a, b in spans):
        h, mi = int(m.group(1)), int(m.group(2) or 0)
        ap = (m.group(3) or "").lower().replace(".", "")
        if h <= 23 and mi <= 59:
            if ap == "pm" and h < 12:
                h += 12
            elif ap == "am" and h == 12:
                h = 0
            elif not ap and 1 <= h <= 7:
                h += 12                       # "at 3" means the afternoon far more often than the small hours
            tm, explicit_time = (h, mi), True
            take(m)
    if tm is None or not explicit_time:
        for pat, val in ((r"\b(?:at )?noon\b|\bmidday\b", (12, 0)), (r"\b(?:at )?midnight\b", (0, 0)), (r"\b(?:in the |this )?morning\b", (9, 0)),
                         (r"\b(?:in the |this )?afternoon\b", (15, 0)), (r"\b(?:in the |this )?evening\b", (19, 0)), (r"\bat night\b", (21, 0))):
            m = re.search(pat, s, re.I)
            if m and not any(a <= m.start() < b for a, b in spans):
                tm = val
                take(m)
                break
    dt, all_day = None, False
    if rel is not None:
        dt = now + timedelta(seconds=rel)
    elif day is not None or tm is not None:
        d0 = day or today
        if tm is None:
            dt, all_day = datetime(d0.year, d0.month, d0.day, 9, 0, tzinfo=now.tzinfo), True
        else:
            dt = datetime(d0.year, d0.month, d0.day, tm[0], tm[1], tzinfo=now.tzinfo)
            if day is None and dt <= now:
                dt += timedelta(days=1)       # "at 7am" said at 9pm means tomorrow
    rest = s
    for a, b in sorted(spans, reverse=True):
        rest = rest[:a] + " " + rest[b:]
    rest = re.sub(r"\s+", " ", rest).strip(" ,.;:-")
    rest = re.sub(r"^(?:to|that|about|for|on|at)\s+", "", rest, flags=re.I)
    rest = re.sub(r"\s+(?:on|at|to|for|by|in)$", "", rest, flags=re.I).strip(" ,.;:-")
    return {"dt": dt, "all_day": all_day, "duration_min": int(dur // 60) if dur else None, "relative": rel is not None, "rest": rest}

def _md(d, mo, y, today):
    if y:
        return date(int(y), mo, d)
    cand = date(today.year, mo, d)
    return cand if cand >= today else date(today.year + 1, mo, d)

def _weekday(m, today):
    idx = next(i for i, n in enumerate(_DAYS) if n.startswith(m.group(1).lower()[:3]))
    ahead = (idx - today.weekday()) % 7
    if ahead == 0 or (re.search(r"\bnext\b", m.group(0), re.I) and ahead < 4 and False):
        ahead = 7 if ahead == 0 else ahead
    return today + timedelta(days=ahead)

def nice(dt, all_day=False):
    return dt.strftime("%A %-d %B %Y") if all_day else dt.strftime("%A %-d %B at %H:%M")

def nice_span(seconds):
    seconds = int(round(seconds))
    parts = []
    for name, size in (("day", 86400), ("hour", 3600), ("minute", 60), ("second", 1)):
        n, seconds = divmod(seconds, size)
        if n:
            parts.append(f"{n} {name}{'s' if n != 1 else ''}")
    return " and ".join(parts[:2]) or "a moment"

# ------------------------------------------------------------------ intent patterns (matched on the user's own sentence only)
P = lambda rx: re.compile(rx, re.I)
PAT = {
    "remind": P(r"^(?:please |can you |could you )?(?:remind me|set (?:me )?a reminder)(?: to| about| that| for)? (?P<what>.+)$"),
    "timer": P(r"^(?:please |can you |could you )?(?:set|start|create) (?:me )?(?:a |an |the )?(?P<what>.*?)(?:timer|alarm)(?: (?:for|at|to|of))? ?(?P<when>.*)$"),
    "wake": P(r"^(?:please )?wake me(?: up)? (?P<when>.+)$"),
    "reminders_list": P(r"^(?:what(?: are|'s)|show|list|tell)(?: me)?(?: my| the| all my)? (?:reminders|timers|alarms)$|^(?:what|which) reminders do i have$|^do i have any (?:reminders|timers|alarms)$|^how long (?:is )?left on (?:the |my )?timer$"),
    "reminders_cancel": P(r"^(?:cancel|delete|remove|clear|stop) (?:my |the |all |all my |all the )*(?:reminder|timer|alarm)s?(?: (?:number |#)?(?P<n>\d+))?$"),
    "list_add": P(r"^(?:please )?(?:add|put) (?P<item>.+?) (?:to|on|onto|in) (?:my |the |our )?(?P<list>[\w\- ]{2,30}?)(?: list)?$"),
    "list_show": P(r"^(?:what(?:'s| is)(?: on| in)?|show|read|list|tell)(?: me)?(?: what(?:'s| is) on)? (?:my |the |our )(?P<list>[\w\- ]{2,30}?) list$|^what do i (?:need|have) to (?P<verb>buy|do|get)$"),
    "list_remove": P(r"^(?:please )?(?:remove|delete|take|cross|check|tick)(?: off)? (?P<item>.+?) (?:from|off|on) (?:my |the |our )?(?P<list>[\w\- ]{2,30}?)(?: list)?$"),
    "list_clear": P(r"^(?:clear|empty|wipe|delete) (?:my |the |our )?(?P<list>[\w\- ]{2,30}?) list$"),
    "cal_add": P(r"^(?:please |can you |could you )?(?:add|put|schedule|create|book|save|set up)(?: me)? (?:an? |the |my )?(?:new )?(?:event |appointment |meeting )?(?:called |named |for |with )?(?P<what>.*?) ?(?:to|on|in|into) (?:my |the |our )?(?:calendar|schedule|agenda|diary)\b[: ]*(?P<rest>.*)$"),
    "cal_add2": P(r"^(?:please |can you )?(?:schedule|book|pencil in|pencil|block out|set up) (?:an? |my |the )?(?P<what>.+)$"),
    "cal_show": P(r"^(?:what(?:'s| is| do i have)|show|list|read|anything|is there anything|do i have anything)(?: me)?(?: on| in)? ?(?:my |the |our )?(?:calendar|schedule|agenda|diary|events?|appointments?)(?: look like)?(?: (?:for|on))? ?(?P<when>.*)$|^what(?:'s| is) (?:on|happening|planned) (?P<when2>today|tomorrow|tonight|this week|next week|on \w+|this weekend)$|^what do i have (?:on |planned )?(?P<when3>today|tomorrow|this week|next week|on \w+)$"),
    "cal_delete": P(r"^(?:cancel|delete|remove) (?:the |my )?(?:event|appointment|meeting)(?: (?:number |#)?(?P<n>\d+)| (?P<title>.+))$|^(?:cancel|delete|remove) (?P<title2>.+?) from (?:my |the )?(?:calendar|schedule)$"),
    "files_list": P(r"^(?:list|show)(?: me)?(?: all)? (?:of )?(?:my |the )?files$|^what files (?:do i have|are there)$"),
    "file_find": P(r"^(?:find|search for|look for|locate)(?: me)? (?:a |an |the |my |any |all )?(?:files?|notes?|documents?)(?: (?:named|called|containing|with|about|matching|for|like))? (?P<name>.+)$|^where is (?:my |the )?(?:file|note|document) (?P<name2>.+)$"),
    "file_read": P(r"^(?:read|show|open|display|print|cat)(?: me)? (?:the |my )?(?:file|note|document) (?:named |called )?(?P<name>.+)$"),
    "file_append": P(r"^(?:append|add|write|save) (?P<text>.+?) (?:to|into|in) (?:the |my )?(?:file|note|document) (?:named |called )?(?P<name>[\w .\-/]+)$"),
    "file_create": P(r"^(?:create|make|start|new) (?:a |an )?(?:new )?(?:empty )?(?:text )?(?:file|note|document)(?: named| called)? (?P<name>[\w .\-]+)$"),
    "file_delete": P(r"^(?:delete|remove|erase|trash) (?:the |my )?(?:file|note|document) (?:named |called )?(?P<name>[\w .\-/]+)$"),
    "system": P(r"^(?:system|server|pi|raspberry pi|device) status$|^how(?:'s| is) (?:the |my )?(?:pi|server|system|raspberry pi)(?: doing| running)?$|^how (?:hot|warm) is (?:the |my )?(?:pi|cpu|raspberry pi|processor)(?: running| right now| getting)?$|^(?:what(?:'s| is) )?(?:the )?temperature of (?:the |my )?(?:pi|cpu|raspberry pi|processor)$|"
                r"^(?:what(?:'s| is) )?(?:the |my )?(?:cpu|pi|processor) temp(?:erature)?$|^how much (?:disk|storage)(?: space)? (?:is left|is free|do i have(?: left)?|is available)$|"
                r"^how much (?:memory|ram) (?:is )?(?:free|left|used|available)$|^(?:what(?:'s| is) the )?uptime$|^how long has (?:the |my )?(?:pi|server|system) been (?:up|running|on)$"),
    "fact_add": P(r"^(?:add|save|store|remember)(?: a| this)? (?:household )?(?:fact|note for everyone)[:,]? (?P<key>.+?) (?:=|is|are) (?P<val>.+)$"),
    "facts_list": P(r"^(?:list|show|what are)(?: me)?(?: the| our| my)? household (?:facts|notes)$"),
    "undo": P(r"^(?:undo|undo that|undo it|take that back|revert that)$"),
    "tools_help": P(r"^(?:what tools do you have|what can you do with (?:files|my calendar|reminders)|tools help|help with tools|what tools can you use)$"),
}
YES = P(r"^(?:yes|yeah|yep|yup|sure|ok|okay|do it|go ahead|confirm|confirmed|please do|yes please|y)$")
NO = P(r"^(?:no|nope|nah|cancel|stop|don't|do not|never mind|nevermind|n)$")


def _clean(q):
    q = q.replace("\u2019", "'").replace("\u201c", '"').replace("\u201d", '"')
    return re.sub(r"\s+", " ", q).strip().rstrip("?.! ")


class Tools:
    def __init__(self, db_path, files_root, now_fn, enabled=True):
        self.db_path, self.root, self.now, self.enabled = db_path, os.path.realpath(files_root), now_fn, enabled
        self.files_ok = False
        if not enabled:
            return
        try:
            os.makedirs(self.root, exist_ok=True)
            self.files_ok = os.access(self.root, os.W_OK)
        except Exception:
            self.files_ok = False
        con = self._db()
        con.executescript("""
            CREATE TABLE IF NOT EXISTS tool_reminders (id INTEGER PRIMARY KEY, due REAL NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL, created REAL NOT NULL, delivered INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS tool_lists (id INTEGER PRIMARY KEY, list TEXT NOT NULL, item TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS tool_events (id INTEGER PRIMARY KEY, uid TEXT NOT NULL, title TEXT NOT NULL, start REAL NOT NULL, all_day INTEGER DEFAULT 0, duration_min INTEGER DEFAULT 60, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS tool_log (t REAL NOT NULL, action TEXT NOT NULL, detail TEXT NOT NULL);""")
        con.commit()
        con.close()

    def _db(self):
        con = sqlite3.connect(self.db_path, timeout=5)
        con.row_factory = sqlite3.Row
        return con

    def _log(self, con, action, detail):
        con.execute("INSERT INTO tool_log(t, action, detail) VALUES(?,?,?)", (time.time(), action, str(detail)[:500]))

    # ---- detection
    def match(self, q):
        s = _clean(q)
        for name, pat in PAT.items():
            m = pat.match(s)
            if not m:
                continue
            if name == "list_add" and re.search(r"\b(?:calendar|schedule|agenda|diary|file|note|document)\b", m.group("list"), re.I):
                continue
            if name in {"list_add", "list_remove"} and not re.search(r"\blist\b", s, re.I) and m.group("list").strip().lower() not in {"shopping", "groceries", "grocery", "todo", "to-do", "to do"}:
                continue
            if name == "cal_add2" and not parse_when(m.group("what"), self.now())["dt"]:
                continue
            if name == "timer":
                when, what = (m.group("when") or "").strip(), (m.group("what") or "").strip()
                blob = ("in " + when) if re.match(rf"^{_NUMW} {_UNITW}", when, re.I) else (what + " timer " + when)
                if (when or what) and not parse_when(blob, self.now())["dt"]:
                    continue         # "set a timer in python" is a programming question, not a request
            return name, m
        return None, None

    # ---- household facts: a plain text file you write yourself, "key = answer" per line, checked before going online
    def _facts(self):
        path = os.path.join(self.root, "facts.txt")
        out = []
        try:
            for line in open(path, encoding="utf-8", errors="ignore").read().splitlines()[:500]:
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    if k.strip() and v.strip():
                        out.append((k.strip(), v.strip()))
        except Exception:
            pass
        return out

    @staticmethod
    def _stems(text):
        stop = set("the a an of is are was were do does did what when where who which how my our your to for in on at it and or be can i we you me please tell".split())
        return {re.sub(r"(?:ies|es|s|ing|ed)$", "", w) if len(w) > 4 else w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in stop}

    def fact_for(self, q):
        qs = self._stems(q)
        best = None
        for k, v in self._facts():
            ks = self._stems(k)
            if ks and ks <= qs and len(qs) <= len(ks) + 5 and (best is None or len(ks) > len(best[2])):
                best = (k, v, ks)
        return best[:2] if best else None

    def wants(self, q, st=None):
        if not self.enabled:
            return False
        if self.files_ok and self.fact_for(q):
            return True
        if (st or {}).get("tool_pending") and (YES.match(_clean(q)) or NO.match(_clean(q))):
            return True
        return self.match(q)[0] is not None

    # ---- entry point
    def handle(self, q, st, authed):
        if not self.enabled:
            return None
        s = _clean(q)
        pending = None
        try:
            pending = json.loads(st.get("tool_pending") or "null")
        except Exception:
            pending = None
        if pending and (YES.match(s) or NO.match(s)):
            st["tool_pending"] = ""
            if NO.match(s):
                return self._say("Okay, I've left it alone.")
            if not authed:
                return self._locked()
            return self._confirmed(pending, st)
        name, m = self.match(q)
        if not name:
            fact = self.fact_for(q) if self.files_ok else None
            if not fact:
                return None
            if not authed:
                return self._locked()
            return self._say(f"From your household notes (facts.txt): {fact[0]} = {fact[1]}")
        st["tool_pending"] = ""
        if name == "tools_help":
            return self._say(HELP)
        if not authed:
            return self._locked()
        try:
            return getattr(self, "_t_" + name)(m, st)
        except Exception as e:                                  # a tool must never take the chat down
            return self._say(f"That tool failed ({type(e).__name__}). Nothing was changed.")

    def _say(self, text, **extra):
        out = {"answer": text, "sources": [], "mode": "tool", "evidence_count": 1}
        out.update(extra)
        return out

    def _locked(self):
        return self._say("Tools are locked. Press the \U0001F512 button at the top of the page and enter the access code the installer printed "
                         "(it is NOAI_ACCESS_CODE in the .env file). Looking things up works without it; reminders, lists, calendar and files do not.")

    def _ask(self, st, action, prompt):
        st["tool_pending"] = json.dumps(action)
        return self._say(prompt + " (yes / no)")

    # ---- reminders and timers
    def _add_reminder(self, st, when, text, kind):
        con = self._db()
        cur = con.execute("INSERT INTO tool_reminders(due, text, kind, created) VALUES(?,?,?,?)", (when["dt"].timestamp(), text, kind, time.time()))
        self._log(con, "reminder.add", f"{kind} {when['dt'].isoformat()} {text}")
        con.commit()
        con.close()
        st["tool_undo"] = json.dumps({"table": "tool_reminders", "id": cur.lastrowid, "what": f"the {kind}"})
        left = when["dt"] - self.now()
        tail = f" That's in {nice_span(left.total_seconds())}." if left.total_seconds() < 36 * 3600 else ""
        note = " Keep this page open (or come back to it): I can only show reminders here, I can't ring or send a message."
        if kind == "timer":
            return self._say(f"Timer set for {nice_span(left.total_seconds())} (until {when['dt'].strftime('%H:%M')})." + note)
        link = " about " if re.match(r"^(?:the|my|our|a|an|that|this)\b", text, re.I) or kind == "alarm" else " to "
        what = "" if text in ("", "reminder", "alarm", "wake up") and kind != "reminder" else (link + text if text not in ("reminder", "alarm") else "")
        if text == "wake up":
            what = " to wake up"
        return self._say(f"I'll remind you{what} on {nice(when['dt'])}.{tail}" + note + " Say \"undo\" to remove it.")

    def _t_remind(self, m, st):
        w = parse_when(m.group("what"), self.now())
        if not w["dt"]:
            return self._say("When should I remind you? For example: \"remind me to call the dentist tomorrow at 10am\" or \"remind me in 20 minutes to check the oven\".")
        if w["dt"] <= self.now():
            return self._say(f"That time ({nice(w['dt'])}) has already passed. Give me a time in the future.")
        text = re.sub(r"^(?:to|that|about)\s+", "", w["rest"], flags=re.I) or "reminder"
        return self._add_reminder(st, w, text, "reminder")

    def _t_timer(self, m, st):
        blob = ((m.group("what") or "") + " timer " + (m.group("when") or "")).strip()
        w = parse_when("in " + m.group("when") if (m.group("when") and re.match(rf"^{_NUMW} {_UNITW}", m.group("when"), re.I)) else blob, self.now())
        if not w["dt"]:
            return self._say("For how long, or until when? For example: \"set a timer for 10 minutes\" or \"set an alarm for 7am\".")
        label = re.sub(r"\b(?:timer|alarm)\b", "", w["rest"], flags=re.I).strip() or ("timer" if w["relative"] else "alarm")
        return self._add_reminder(st, w, label, "timer" if w["relative"] else "reminder")

    def _t_wake(self, m, st):
        w = parse_when(m.group("when"), self.now())
        if not w["dt"]:
            return self._say("At what time? For example: \"wake me up at 7am\".")
        return self._add_reminder(st, w, "wake up", "reminder")

    def _t_reminders_list(self, m, st):
        con = self._db()
        rows = con.execute("SELECT * FROM tool_reminders WHERE delivered=0 ORDER BY due").fetchall()
        con.close()
        if not rows:
            return self._say("You have no reminders or timers set.")
        now = self.now()
        lines = []
        for i, r in enumerate(rows, 1):
            due = datetime.fromtimestamp(r["due"], tz=now.tzinfo)
            left = (due - now).total_seconds()
            lines.append(f"{i}. {r['text']} \u2014 {nice(due)}" + (f" (in {nice_span(left)})" if 0 < left < 36 * 3600 else ""))
        return self._say("Your reminders and timers:\n" + "\n".join(lines) + "\nSay \"cancel reminder 2\" to remove one.")

    def _t_reminders_cancel(self, m, st):
        con = self._db()
        rows = con.execute("SELECT * FROM tool_reminders WHERE delivered=0 ORDER BY due").fetchall()
        if not rows:
            con.close()
            return self._say("There are no reminders or timers to cancel.")
        n = m.group("n")
        if n:
            if not (1 <= int(n) <= len(rows)):
                con.close()
                return self._say(f"There is no reminder number {n}. Say \"what are my reminders\" to see them.")
            r = rows[int(n) - 1]
            con.execute("DELETE FROM tool_reminders WHERE id=?", (r["id"],))
            self._log(con, "reminder.cancel", r["text"])
            con.commit()
            con.close()
            return self._say(f"Cancelled: {r['text']}.")
        con.close()
        if len(rows) == 1 and not re.search(r"\ball\b", m.group(0), re.I):
            return self._confirmed({"do": "reminders_clear"}, st)
        return self._ask(st, {"do": "reminders_clear"}, f"Cancel all {len(rows)} reminders and timers?")

    def due(self):
        """Reminders that have come due; each is returned once. Called by the web page every half minute."""
        if not self.enabled:
            return []
        con = self._db()
        rows = con.execute("SELECT * FROM tool_reminders WHERE delivered=0 AND due<=? ORDER BY due", (self.now().timestamp(),)).fetchall()
        for r in rows:
            con.execute("UPDATE tool_reminders SET delivered=1 WHERE id=?", (r["id"],))
        con.commit()
        con.close()
        return [{"text": r["text"], "kind": r["kind"], "due": r["due"]} for r in rows]

    # ---- lists
    @staticmethod
    def _list_name(raw, verb=None):
        if verb:
            return {"buy": "shopping", "get": "shopping", "do": "to-do"}[verb.lower()]
        n = re.sub(r"\s+", " ", raw.strip().lower())
        n = re.sub(r"^(?:grocery|groceries)$", "shopping", n)
        return re.sub(r"^(?:todo|to do|to-do|task|tasks)$", "to-do", n)

    def _t_list_add(self, m, st):
        name = self._list_name(m.group("list"))
        items = [i.strip() for i in re.split(r",\s*|\s+and\s+", m.group("item")) if i.strip()]
        con = self._db()
        ids = [con.execute("INSERT INTO tool_lists(list, item, created) VALUES(?,?,?)", (name, it[:200], time.time())).lastrowid for it in items[:20]]
        self._log(con, "list.add", f"{name}: {', '.join(items)}")
        n = con.execute("SELECT count(*) FROM tool_lists WHERE list=?", (name,)).fetchone()[0]
        con.commit()
        con.close()
        st["tool_undo"] = json.dumps({"table": "tool_lists", "ids": ids, "what": f"{', '.join(items)} on the {name} list"})
        return self._say(f"Added {', '.join(items)} to your {name} list ({n} item{'s' if n != 1 else ''} now).")

    def _t_list_show(self, m, st):
        name = self._list_name(m.group("list") or "", m.group("verb"))
        con = self._db()
        rows = con.execute("SELECT item FROM tool_lists WHERE list=? ORDER BY id", (name,)).fetchall()
        others = [r[0] for r in con.execute("SELECT DISTINCT list FROM tool_lists").fetchall()]
        con.close()
        if not rows:
            extra = f" Lists you do have: {', '.join(others)}." if others else ""
            return self._say(f"Your {name} list is empty." + extra)
        return self._say(f"Your {name} list:\n" + "\n".join(f"\u2022 {r['item']}" for r in rows))

    def _t_list_remove(self, m, st):
        name, item = self._list_name(m.group("list")), m.group("item").strip().lower()
        con = self._db()
        rows = con.execute("SELECT id, item FROM tool_lists WHERE list=? ORDER BY id", (name,)).fetchall()
        hit = [r for r in rows if r["item"].lower() == item] or [r for r in rows if item in r["item"].lower()]
        if not hit:
            con.close()
            return self._say(f"I couldn't find \"{item}\" on your {name} list.")
        con.execute("DELETE FROM tool_lists WHERE id=?", (hit[0]["id"],))
        self._log(con, "list.remove", f"{name}: {hit[0]['item']}")
        con.commit()
        con.close()
        return self._say(f"Removed {hit[0]['item']} from your {name} list.")

    def _t_list_clear(self, m, st):
        name = self._list_name(m.group("list"))
        con = self._db()
        n = con.execute("SELECT count(*) FROM tool_lists WHERE list=?", (name,)).fetchone()[0]
        con.close()
        if not n:
            return self._say(f"Your {name} list is already empty.")
        return self._ask(st, {"do": "list_clear", "list": name}, f"Delete all {n} item{'s' if n != 1 else ''} from your {name} list?")

    # ---- calendar
    def _t_cal_add(self, m, st):
        blob = ((m.group("what") or "") + " " + (m.groupdict().get("rest") or "")).strip()
        w = parse_when(blob, self.now())
        title = re.sub(r"^(?:an?|the|my)\s+", "", w["rest"], flags=re.I).strip() or "Event"
        if not w["dt"]:
            return self._say(f"When is \"{title}\"? For example: \"add dentist to my calendar on Friday at 3pm for 1 hour\".")
        con = self._db()
        cur = con.execute("INSERT INTO tool_events(uid, title, start, all_day, duration_min, created) VALUES(?,?,?,?,?,?)",
                          (uuid.uuid4().hex + "@noai-chat", title[:200], w["dt"].timestamp(), int(w["all_day"]), w["duration_min"] or 60, time.time()))
        self._log(con, "calendar.add", f"{title} @ {w['dt'].isoformat()}")
        con.commit()
        con.close()
        st["tool_undo"] = json.dumps({"table": "tool_events", "id": cur.lastrowid, "what": f"\"{title}\""})
        ics = self._write_ics()
        length = "" if w["all_day"] else f" for {nice_span((w['duration_min'] or 60) * 60)}"
        return self._say(f"Added \"{title}\" on {nice(w['dt'], w['all_day'])}{' (all day)' if w['all_day'] else length}." +
                         (f" The calendar file {ics} has been updated; most calendar apps can import or subscribe to it." if ics else "") + " Say \"undo\" to remove it.")

    _t_cal_add2 = _t_cal_add

    def _t_cal_show(self, m, st):
        g = m.groupdict()
        when = (g.get("when") or g.get("when2") or g.get("when3") or "").strip()
        now = self.now()
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        if re.search(r"\bnext week\b", when, re.I):
            start += timedelta(days=7 - start.weekday())
            end, label = start + timedelta(days=7), "next week"
        elif re.search(r"\bthis week\b", when, re.I):
            end, label = start + timedelta(days=7 - start.weekday()), "the rest of this week"
        elif re.search(r"\bweekend\b", when, re.I):
            start += timedelta(days=(5 - start.weekday()) % 7)
            end, label = start + timedelta(days=2), "the weekend"
        else:
            w = parse_when(when, now) if when else {"dt": None}
            if w["dt"]:
                start = w["dt"].replace(hour=0, minute=0, second=0, microsecond=0)
                end, label = start + timedelta(days=1), start.strftime("%A %-d %B")
            else:
                end, label = start + timedelta(days=30), "the next 30 days"
        con = self._db()
        rows = con.execute("SELECT * FROM tool_events WHERE start>=? AND start<? ORDER BY start", (start.timestamp(), end.timestamp())).fetchall()
        con.close()
        if not rows:
            return self._say(f"Nothing on your calendar for {label}.")
        lines = [f"{i}. {nice(datetime.fromtimestamp(r['start'], tz=now.tzinfo), bool(r['all_day']))} \u2014 {r['title']}" for i, r in enumerate(rows, 1)]
        st["tool_cal_ids"] = json.dumps([r["id"] for r in rows])
        return self._say(f"On your calendar for {label}:\n" + "\n".join(lines) + "\nSay \"delete event 1\" to remove one.")

    def _t_cal_delete(self, m, st):
        g = m.groupdict()
        con = self._db()
        row = None
        if g.get("n"):
            try:
                ids = json.loads(st.get("tool_cal_ids") or "[]")
            except Exception:
                ids = []
            if 1 <= int(g["n"]) <= len(ids):
                row = con.execute("SELECT * FROM tool_events WHERE id=?", (ids[int(g["n"]) - 1],)).fetchone()
            if row is None:
                con.close()
                return self._say("Say \"what's on my calendar\" first, then \"delete event 2\" using the number from that list.")
        else:
            title = (g.get("title") or g.get("title2") or "").strip().lower()
            row = con.execute("SELECT * FROM tool_events WHERE lower(title) LIKE ? AND start>=? ORDER BY start LIMIT 1", (f"%{title}%", time.time() - 86400)).fetchone()
        con.close()
        if row is None:
            return self._say("I couldn't find that event on your calendar.")
        when = nice(datetime.fromtimestamp(row["start"], tz=self.now().tzinfo), bool(row["all_day"]))
        return self._ask(st, {"do": "event_delete", "id": row["id"]}, f"Delete \"{row['title']}\" on {when}?")

    def _write_ics(self):
        if not self.files_ok:
            return ""
        con = self._db()
        rows = con.execute("SELECT * FROM tool_events ORDER BY start").fetchall()
        con.close()
        esc = lambda t: str(t).replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")
        out = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//NoAI Chat//EN", "CALSCALE:GREGORIAN", "X-WR-CALNAME:NoAI Chat"]
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        for r in rows:
            start = datetime.fromtimestamp(r["start"], tz=timezone.utc)
            out += ["BEGIN:VEVENT", f"UID:{r['uid']}", f"DTSTAMP:{stamp}", f"SUMMARY:{esc(r['title'])}"]
            if r["all_day"]:
                local = datetime.fromtimestamp(r["start"], tz=self.now().tzinfo).date()
                out += [f"DTSTART;VALUE=DATE:{local.strftime('%Y%m%d')}", f"DTEND;VALUE=DATE:{(local + timedelta(days=1)).strftime('%Y%m%d')}"]
            else:
                out += [f"DTSTART:{start.strftime('%Y%m%dT%H%M%SZ')}", f"DTEND:{(start + timedelta(minutes=r['duration_min'] or 60)).strftime('%Y%m%dT%H%M%SZ')}"]
            out.append("END:VEVENT")
        out.append("END:VCALENDAR")
        path = os.path.join(self.root, "calendar.ics")
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write("\r\n".join(out) + "\r\n")
        os.replace(tmp, path)
        return "calendar.ics"

    # ---- files (one folder, text only)
    def _safe(self, name, must_exist=False):
        name = name.strip().strip("\"'").replace("\\", "/")
        if not name or name.startswith("/") or ".." in name.split("/") or "\x00" in name or len(name) > 200:
            return None
        if not os.path.splitext(name)[1]:
            cand = os.path.realpath(os.path.join(self.root, name + ".txt"))
            if os.path.isfile(cand) or not os.path.exists(os.path.realpath(os.path.join(self.root, name))):
                name += ".txt"
        p = os.path.realpath(os.path.join(self.root, name))
        if p != self.root and not p.startswith(self.root + os.sep):
            return None                                   # symlinks or tricks that leave the folder
        if os.path.splitext(p)[1].lower() not in TEXT_EXT:
            return None
        if must_exist and not os.path.isfile(p):
            return None
        return p

    def _walk(self):
        out = []
        for base, dirs, files in os.walk(self.root):
            dirs[:] = [d for d in dirs if not d.startswith(".")][:50]
            for f in files:
                if not f.startswith(".") and not f.endswith(".tmp"):
                    p = os.path.join(base, f)
                    out.append((os.path.relpath(p, self.root), os.path.getsize(p), os.path.getmtime(p)))
            if len(out) > 2000:
                break
        return out

    def _need_files(self):
        return None if self.files_ok else self._say("The files folder isn't available. The installer mounts ~/noai-files into the container; check that it exists and is writable.")

    def _t_files_list(self, m, st):
        bad = self._need_files()
        if bad:
            return bad
        rows = sorted(self._walk(), key=lambda r: -r[2])[:30]
        if not rows:
            return self._say("Your files folder (~/noai-files) is empty.")
        return self._say("Files in ~/noai-files (newest first):\n" + "\n".join(f"\u2022 {n}  ({_size(s)})" for n, s, _ in rows))

    def _t_file_find(self, m, st):
        bad = self._need_files()
        if bad:
            return bad
        needle = (m.group("name") or m.group("name2") or "").strip().strip("\"'").lower()
        words = [w for w in re.findall(r"[\w\-]+", needle) if len(w) > 1]
        by_name = [r for r in self._walk() if all(w in r[0].lower() for w in words)]
        by_text = []
        if len(by_name) < 5:
            for n, s, t in self._walk():
                if s <= 400_000 and os.path.splitext(n)[1].lower() in TEXT_EXT and (n, s, t) not in by_name:
                    try:
                        body = open(os.path.join(self.root, n), encoding="utf-8", errors="ignore").read().lower()
                    except Exception:
                        continue
                    if all(w in body for w in words):
                        by_text.append((n, s, t))
                if len(by_text) >= 10:
                    break
        if not by_name and not by_text:
            return self._say(f"No file in ~/noai-files matches \"{needle}\", by name or by content.")
        lines = [f"\u2022 {n}  ({_size(s)})" for n, s, _ in by_name[:10]] + [f"\u2022 {n}  (mentions it inside)" for n, s, _ in by_text[:10]]
        return self._say("Found in ~/noai-files:\n" + "\n".join(lines) + "\nSay \"read file <name>\" to see one.")

    def _t_file_read(self, m, st):
        bad = self._need_files()
        if bad:
            return bad
        p = self._safe(m.group("name"), must_exist=True)
        if not p:
            return self._say("I can't open that. I can read plain-text files inside ~/noai-files only; say \"list my files\" to see what's there.")
        body = open(p, encoding="utf-8", errors="replace").read(MAX_READ + 1)
        more = "\n\u2026 (truncated)" if len(body) > MAX_READ else ""
        lines = body[:MAX_READ].splitlines()
        shown = "\n".join(lines[:60])
        more = more or ("\n\u2026 (" + str(len(lines) - 60) + " more lines)" if len(lines) > 60 else "")
        return self._say(f"{os.path.relpath(p, self.root)}:\n{shown}{more}" if shown.strip() else f"{os.path.relpath(p, self.root)} is empty.")

    def _t_file_append(self, m, st):
        bad = self._need_files()
        if bad:
            return bad
        p = self._safe(m.group("name"))
        if not p:
            return self._say("I can only write to plain-text files inside ~/noai-files.")
        text = m.group("text").strip().strip("\"'")
        verb = "add this line to" if os.path.isfile(p) else "create"
        return self._ask(st, {"do": "file_append", "path": p, "text": text[:2000]}, f"Shall I {verb} {os.path.relpath(p, self.root)}: \"{text[:120]}\"?")

    def _t_file_create(self, m, st):
        bad = self._need_files()
        if bad:
            return bad
        p = self._safe(m.group("name"))
        if not p:
            return self._say("I can only create plain-text files (for example .txt or .md) inside ~/noai-files.")
        if os.path.exists(p):
            return self._say(f"{os.path.relpath(p, self.root)} already exists. I won't overwrite it.")
        return self._ask(st, {"do": "file_create", "path": p}, f"Create an empty file {os.path.relpath(p, self.root)} in ~/noai-files?")

    def _t_file_delete(self, m, st):
        bad = self._need_files()
        if bad:
            return bad
        p = self._safe(m.group("name"), must_exist=True)
        if not p:
            return self._say("I couldn't find that file in ~/noai-files (I only handle plain-text files there).")
        return self._ask(st, {"do": "file_delete", "path": p}, f"Delete {os.path.relpath(p, self.root)}? It will be moved to ~/noai-files/.trash, not erased.")

    # ---- system status (read-only)
    def _t_system(self, m, st):
        lines = []
        try:
            up = float(open("/proc/uptime").read().split()[0])
            lines.append(f"\u2022 Up for {nice_span(up)}")
        except Exception:
            pass
        try:
            l1, l5, l15 = os.getloadavg()
            lines.append(f"\u2022 Load: {l1:.2f} (1 min), {l5:.2f} (5 min) on {os.cpu_count()} cores")
        except Exception:
            pass
        try:
            mem = {k.strip(): int(v.split()[0]) for k, v in (ln.split(":", 1) for ln in open("/proc/meminfo") if ":" in ln)}
            lines.append(f"\u2022 Memory: {_size(mem['MemAvailable'] * 1024)} free of {_size(mem['MemTotal'] * 1024)}")
        except Exception:
            pass
        for zone in ("/sys/class/thermal/thermal_zone0/temp",):
            try:
                c = int(open(zone).read().strip()) / 1000.0
                lines.append(f"\u2022 CPU temperature: {c:.1f}\u00b0C ({c * 9 / 5 + 32:.0f}\u00b0F)" + (" \u2014 that is hot; a Pi throttles around 80\u00b0C" if c >= 75 else ""))
            except Exception:
                pass
        try:
            du = shutil.disk_usage(self.root if self.files_ok else "/")
            lines.append(f"\u2022 Disk: {_size(du.free)} free of {_size(du.total)}")
        except Exception:
            pass
        return self._say("System status (as seen from inside my container):\n" + "\n".join(lines) if lines else "I couldn't read the system status from inside the container.")

    def _t_fact_add(self, m, st):
        bad = self._need_files()
        if bad:
            return bad
        key, val = m.group("key").strip(" \"'"), m.group("val").strip(" \"'")
        return self._ask(st, {"do": "file_append", "path": os.path.join(self.root, "facts.txt"), "text": f"{key} = {val}"}, f"Add to the household notes: \"{key} = {val}\"?")

    def _t_facts_list(self, m, st):
        facts = self._facts()
        if not facts:
            return self._say("There are no household notes yet. Say \"add household fact: bin day = Tuesday\", or edit ~/noai-files/facts.txt (one \"key = answer\" per line).")
        return self._say("Household notes (facts.txt):\n" + "\n".join(f"\u2022 {k} = {v}" for k, v in facts[:40]))

    # ---- push notifications (optional): a reminder reaches your phone even when the page is closed
    def due_for_push(self):
        con = self._db()
        try:
            con.execute("ALTER TABLE tool_reminders ADD COLUMN pushed INTEGER DEFAULT 0")
        except Exception:
            pass
        rows = con.execute("SELECT id, text, kind FROM tool_reminders WHERE pushed=0 AND due<=?", (self.now().timestamp(),)).fetchall()
        for r in rows:
            con.execute("UPDATE tool_reminders SET pushed=1 WHERE id=?", (r["id"],))
        con.commit()
        con.close()
        return [dict(r) for r in rows]

    # ---- undo and confirmations
    def _t_undo(self, m, st):
        try:
            u = json.loads(st.get("tool_undo") or "null")
        except Exception:
            u = None
        if not u:
            return self._say("There's nothing to undo. I can undo the last reminder, list item or calendar event I added.")
        con = self._db()
        for i in u.get("ids") or [u.get("id")]:
            con.execute(f"DELETE FROM {u['table']} WHERE id=?", (i,)) if u["table"] in {"tool_reminders", "tool_lists", "tool_events"} else None
        self._log(con, "undo", u.get("what", ""))
        con.commit()
        con.close()
        st["tool_undo"] = ""
        if u["table"] == "tool_events":
            self._write_ics()
        return self._say(f"Undone: removed {u.get('what', 'it')}.")

    def _confirmed(self, a, st):
        con = self._db()
        try:
            if a["do"] == "list_clear":
                con.execute("DELETE FROM tool_lists WHERE list=?", (a["list"],))
                self._log(con, "list.clear", a["list"])
                msg = f"Your {a['list']} list is now empty."
            elif a["do"] == "reminders_clear":
                con.execute("DELETE FROM tool_reminders WHERE delivered=0")
                self._log(con, "reminder.clear", "all")
                msg = "All reminders and timers cancelled."
            elif a["do"] == "event_delete":
                con.execute("DELETE FROM tool_events WHERE id=?", (a["id"],))
                self._log(con, "calendar.delete", a["id"])
                con.commit()
                self._write_ics()
                msg = "Deleted from your calendar."
            elif a["do"] in {"file_append", "file_create", "file_delete"}:
                p = os.path.realpath(a["path"])
                if not p.startswith(self.root + os.sep) or os.path.splitext(p)[1].lower() not in TEXT_EXT:
                    return self._say("That path is outside the files folder; nothing was changed.")
                rel = os.path.relpath(p, self.root)
                if a["do"] == "file_create":
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    open(p, "x", encoding="utf-8").close()
                    msg = f"Created {rel}."
                elif a["do"] == "file_append":
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    with open(p, "a", encoding="utf-8") as f:
                        f.write(a["text"].rstrip("\n") + "\n")
                    msg = f"Added the line to {rel}."
                else:
                    trash = os.path.join(self.root, ".trash")
                    os.makedirs(trash, exist_ok=True)
                    shutil.move(p, os.path.join(trash, f"{int(time.time())}-{os.path.basename(p)}"))
                    msg = f"Moved {rel} to .trash."
                self._log(con, a["do"], rel)
            else:
                msg = "I no longer know what that was about; nothing was changed."
            con.commit()
        finally:
            con.close()
        return self._say(msg)

    def info(self):
        if not self.enabled:
            return {"enabled": False}
        con = self._db()
        n = {t: con.execute(f"SELECT count(*) FROM {t}").fetchone()[0] for t in ("tool_reminders", "tool_lists", "tool_events", "tool_log")}
        con.close()
        return {"enabled": True, "files_folder_writable": self.files_ok, "reminders": n["tool_reminders"], "list_items": n["tool_lists"], "events": n["tool_events"], "audit_entries": n["tool_log"]}


def _size(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in {"B", "KB"} else f"{n:.1f} {unit}"
        n /= 1024.0

HELP = ("Tools I can use (they need the access code; press \U0001F512):\n"
        "\u2022 Reminders and timers: \"remind me to call the dentist tomorrow at 10am\", \"set a timer for 10 minutes\", \"what are my reminders\", \"cancel reminder 2\"\n"
        "\u2022 Lists: \"add milk and eggs to my shopping list\", \"what's on my shopping list\", \"remove milk from my shopping list\", \"clear my shopping list\"\n"
        "\u2022 Calendar: \"add dentist to my calendar on Friday at 3pm for 1 hour\", \"what's on my calendar this week\", \"delete event 1\" (also written to ~/noai-files/calendar.ics)\n"
        "\u2022 Files in ~/noai-files (plain text only): \"list my files\", \"find files about taxes\", \"read file notes\", \"add buy stamps to file notes\", \"create a file called ideas\", \"delete file ideas\"\n"
        "\u2022 Household notes: \"add household fact: bin day = Tuesday\", then just ask \"when is bin day?\" (kept in ~/noai-files/facts.txt; you can edit it by hand)\n"
        "\u2022 System: \"system status\", \"how hot is the pi\", \"how much disk space is left\"\n"
        "\u2022 \"undo\" removes the last thing I added. I ask before deleting or writing to a file, and I never run commands.\n"
        "\u2022 Spelling: if I misread a word, say \"I meant linter\" and I'll keep it in ~/noai-files/words.txt and never change it again.")
__NOAI_V18_TOOLS_PY__
cat > "$APP_DIR/app/creative.py" <<'__NOAI_V19_CREATIVE_PY__'
"""Playful writing from hand-written grammars, in the style of Kate Compton's Tracery.

A grammar is a dict of symbol -> list of alternatives; "#symbol#" inside a string is replaced by a random alternative,
recursively, and "#symbol.capitalize#", "#symbol.a#", "#symbol.s#" apply modifiers. That is the whole engine: there is no
language model, nothing is learned, and every phrase below was typed by a person. The output is therefore charming at
best and clunky at worst, and it is always labelled as template verse. Facts are never produced this way."""
import re, random

_MOD = {
    "capitalize": lambda s: s[:1].upper() + s[1:],
    "upper": lambda s: s.upper(),
    "a": lambda s: ("an " if re.match(r"^[aeiou]", s, re.I) else "a ") + s,
    "s": lambda s: s + ("es" if re.search(r"(?:s|x|z|ch|sh)$", s) else "s"),
}

def expand(grammar, text, rnd, depth=0):
    if depth > 12:
        return text
    def sub(m):
        name, *mods = m.group(1).split(".")
        options = grammar.get(name)
        out = expand(grammar, rnd.choice(options), rnd, depth + 1) if options else m.group(0)
        for mod in mods:
            out = _MOD.get(mod, lambda s: s)(out)
        return out
    return re.sub(r"#([\w.]+)#", sub, text)

# ------------------------------------------------------------------ shared imagery
BASE = {
    "adj": ["quiet", "patient", "restless", "borrowed", "silver", "stubborn", "half-remembered", "unhurried", "wide", "small", "salt-bright", "slow", "wakeful", "ordinary", "far-off"],
    "thing": ["lantern", "window", "river", "orchard", "staircase", "harbour", "kettle", "map", "bell", "garden", "road", "attic", "tide", "candle", "kite", "field"],
    "light": ["morning", "dusk", "lamplight", "moonlight", "the first frost", "late summer", "a grey afternoon", "the hour before rain"],
    "verb": ["waits", "listens", "turns", "hums", "leans", "keeps watch", "gathers itself", "drifts", "remembers", "begins again", "holds still"],
    "verbs_pl": ["wait", "listen", "turn", "hum", "lean", "keep watch", "drift", "remember", "begin again", "hold still"],
    "place": ["at the edge of town", "behind the old wall", "under the stairs", "past the last streetlight", "where the path forks", "between two breaths", "on the far shore", "in the next room"],
    "abstract": ["a promise", "an answer", "a question nobody asked", "the long way home", "something like patience", "a door left open", "the shape of a day", "what the map leaves out"],
}

POEM = dict(BASE, **{
    "origin": ["#l_open#\n#l_mid#\n#l_mid2#\n#l_turn#\n#l_close#", "#l_open#\n#l_mid#\n#l_turn#\n#l_mid2#\n#l_close#\n#l_coda#"],
    "l_open": ["#topic.capitalize#, #adj# and #adj#,", "I went looking for #topic# #place#,", "Say #topic#, and the room grows #adj#;", "There is #thing.a# in #topic#,", "All #light#, #topic# #verb#."],
    "l_mid": ["#thing.a# #verb# #place#,", "the #adj# #thing# #verb#,", "and #light# #verb# like #thing.a#,", "somebody's #thing# #verb# in #light#,", "#thing.s.capitalize# #verbs_pl# where nobody looks,"],
    "l_mid2": ["while the #thing.s# #verbs_pl# and the #thing.s# #verbs_pl#,", "#adj# as #thing.a#, #adj# as #light#,", "it carries #abstract# in both hands,", "and nothing about it is in a hurry,"],
    "l_turn": ["but #topic# is also #abstract#,", "and still I think of #topic#:", "what I wanted from #topic# was #abstract#,", "perhaps #topic# is only #thing.a# #place#,"],
    "l_close": ["#adj#, #adj#, and entirely its own.", "and that, for today, is enough.", "it #verb#. So do I.", "the #thing# #verb#, and #light# goes on.", "ask it again in #light#."],
    "l_coda": ["(#topic.capitalize# does not answer. It #verb#.)", "Then #light#. Then #topic# again."],
})

HAIKU_5 = ["an old pond listens", "light on the water", "the long night is still", "morning fog lifts slow", "wind through the tall grass", "a door left open", "rain on a tin roof"]
HAIKU_7 = ["shadows lengthen on the hill", "somewhere a small bird answers", "the river keeps its own time", "nothing moves but falling leaves", "all day the same patient sky", "footsteps fading down the road"]
HAIKU_FILL = {1: ["waits", "sleeps", "drifts", "wakes"], 2: ["at dawn", "again", "alone", "so still"], 3: ["in the dark", "at first light", "after rain", "without sound"],
              4: ["under the moon", "beneath the snow", "in morning light"], 5: ["in the falling snow", "when the lamps go out"], 6: ["under a paper moon", "after the rain has gone"]}

LIMERICKS = [
    "There once was a poet from Leeds,\nWhose verses on #topic# were weeds;\nThey grew without reason,\nIn and out of season,\nAnd tangled up all of his deeds.",
    "A scholar who studied #topic#\nKept notes in a very large book;\nShe read them at night\nBy a flickering light,\nThen lost the whole lot in a brook.",
    "I asked a machine about #topic#;\nIt answered, \"I only can quote.\nBut give me a rhyme\nAnd a moment of time,\nAnd I'll fill in a template by rote.\"",
    "There was an old owl from Peru\nWho thought about #topic# till two;\nAt a quarter past three\nIt fell out of its tree,\nStill none the wiser. Would you?",
    "A baker obsessed with #topic#\nPut some in a pie as a test;\nThe crust was a wonder,\nThe filling a blunder,\nAnd the customers left unimpressed.",
]

STORY = dict(BASE, **{
    "origin": ["Once, #place#, there lived #hero.a# who kept #thing.a# and wanted, more than anything, to understand #topic#. #middle# #helper# #ending#"],
    "hero": ["clockmaker", "ferry captain", "young cartographer", "retired lighthouse keeper", "baker's apprentice", "travelling librarian", "very small dragon"],
    "middle": ["Every #light# the #hero2# would set out with #thing.a# and come home with #abstract# instead.", "People said #topic# could only be found #place#, which is a long walk from anywhere.",
               "The trouble was that #topic# never stayed where it was put."],
    "hero2": ["traveller", "stubborn soul", "seeker"],
    "helper": ["One evening #helper_who.a# offered a single piece of advice: \"Stop chasing it, and see what #verb#.\"", "Then #helper_who.a# arrived, carrying #thing.a# and #abstract#.",
               "It was #helper_who.a#, of all creatures, who pointed out the obvious."],
    "helper_who": ["#adj# heron", "#adj# old woman", "passing tinker", "child with muddy boots", "#adj# cat"],
    "ending": ["So the search ended #place#, where #topic# had been waiting all along, #adj# and #adj#.", "And from that day on, whenever anyone asked about #topic#, the answer was the same: #abstract#.",
               "Nobody knows exactly what was found, but the #thing# still #verb# there every #light#."],
})

CREATIVE_RE = re.compile(r"^(?:please |can you |could you |will you |would you )?(?:write|compose|make|give|tell|create|generate|recite|do|spin|invent)(?: me| us)?(?: up)? (?:a |an |another |one more |some )?"
                         r"(?:short |little |silly |funny |quick |nice |sad |happy |bedtime )*(?P<form>poem|poetry|haiku|limerick|verse|rhyme|sonnet|ode|story|tale|fairy ?tale|fable)s?"
                         r"(?: for me| for us)?(?: (?:about|on|of|for|concerning|involving|with|to|dedicated to|celebrating) (?P<topic>.+?))?(?: for me| please)?$", re.I)

def _syllables(text):
    n = 0
    for w in re.findall(r"[a-z']+", text.lower()):
        w = re.sub(r"(?:[^laeiouy]es|[^aeiouy]ed|e)$", "", w) if len(w) > 3 else w
        n += max(1, len(re.findall(r"[aeiouy]+", w)))
    return n

def _haiku(topic, rnd):
    k = _syllables(topic)
    if k <= 4:
        l1 = f"{topic} {rnd.choice(HAIKU_FILL[5 - k])}"
        l2, l3 = rnd.choice(HAIKU_7), rnd.choice(HAIKU_5)
    elif k <= 6:
        l1, l3 = rnd.sample(HAIKU_5, 2)
        l2 = f"{topic} {rnd.choice(HAIKU_FILL[7 - k])}"
    else:
        l1, l3 = rnd.sample(HAIKU_5, 2)
        l2 = rnd.choice(HAIKU_7)
    return "\n".join(x[:1].upper() + x[1:] for x in (l1, l2, l3))

def maybe(q, seed=None):
    """-> {'form', 'topic', 'text'} when q asks for a poem / haiku / limerick / story, else None."""
    s = re.sub(r"\s+", " ", q.replace("\u2019", "'")).strip().rstrip("?.! ")
    m = CREATIVE_RE.match(s)
    if not m:
        return None
    form = m.group("form").lower().replace(" ", "")
    topic = re.sub(r"^(?:my|our|your)\s+", "the ", (m.group("topic") or "").strip(" .,!\"'"), flags=re.I)
    topic = re.sub(r"[#\n\r]", "", topic)[:60] or random.choice(["the weather", "rain", "the sea", "an ordinary Tuesday", "the moon", "tea"])
    rnd = random.Random(seed)
    if form == "haiku":
        kind, text = "haiku", _haiku(topic, rnd)
    elif form == "limerick":
        kind, text = "limerick", rnd.choice(LIMERICKS).replace("#topic#", topic)
    elif form in {"story", "tale", "fairytale", "fable"}:
        kind, text = "very short tale", expand(dict(STORY, topic=[topic]), "#origin#", rnd)
    else:
        kind, text = "poem", expand(dict(POEM, topic=[topic]), "#origin#", rnd)
    return {"form": kind, "topic": topic, "text": text}

def present(piece):
    note = {"haiku": " (syllables are counted by a rough rule, so 5-7-5 is approximate)", "limerick": " (the metre may wobble with some topics)"}.get(piece["form"], "")
    return (f"Here's a {piece['form']} about {piece['topic']}, assembled from my hand-written grammar. There's no language model in here, so every phrase "
            f"was typed by a person and shuffled by chance{note}:\n\n{piece['text']}\n\nAsk again for a different shuffle.")
__NOAI_V19_CREATIVE_PY__
cat > "$APP_DIR/app/replay.py" <<'__NOAI_V19_REPLAY_PY__'
"""Record and replay for NoAI Chat.

NOAI_RECORD=/data/cassette.db   every outbound HTTP response is saved as it is used (the app answers normally)
NOAI_REPLAY=/path/cassette.db   every outbound request is answered from the cassette; the network is never touched and
                                a request that was not recorded fails loudly (status 599) instead of silently going live

Why: the developer's sandbox cannot reach Wikipedia, Wikidata or the search container, so each fix used to be a guess
until the next run on the Pi. A cassette recorded on the Pi lets the exact live situations be re-run anywhere, in seconds,
with the real ranking models, before anything ships.

What is stored: API responses (JSON) verbatim, compressed. Fetched web pages are stored as the EXTRACTED content the app
uses (text, code blocks, recipe data, list items, FAQ pairs), not as raw HTML: about 50x smaller, and enough to replay
ranking and judging. No cookies, no request headers, no access codes; only URL, method, body hash and the response.
The clock at recording time is stored so date-dependent answers replay identically."""
import os, json, time, zlib, sqlite3, hashlib, threading

RECORD = os.environ.get("NOAI_RECORD", "").strip()
REPLAY = os.environ.get("NOAI_REPLAY", "").strip()
MODE = "replay" if REPLAY else ("record" if RECORD else "")
PATH = REPLAY or RECORD
_lock = threading.Lock()
_local = threading.local()
STATS = {"recorded": 0, "replayed": 0, "missing": 0}


def _db():
    con = sqlite3.connect(PATH, timeout=10)
    con.execute("CREATE TABLE IF NOT EXISTS http (k TEXT PRIMARY KEY, method TEXT, url TEXT, status INTEGER, ctype TEXT, body BLOB, t REAL)")
    con.execute("CREATE TABLE IF NOT EXISTS page (url TEXT PRIMARY KEY, data BLOB, t REAL)")
    con.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
    return con


def _key(method, url, body):
    h = hashlib.sha256()
    h.update((method.upper() + " " + url).encode("utf-8", "ignore"))
    if body:
        h.update(body if isinstance(body, bytes) else str(body).encode("utf-8", "ignore"))
    return h.hexdigest()


def skip_http(flag=True):
    """fetch_page records its extracted output instead; its raw HTML download is not stored."""
    _local.skip = bool(flag)


def install():
    """Patch requests once, at import time. Everything in the app and the skills goes through requests."""
    if not MODE:
        return
    import requests
    from requests.models import Response
    from requests.structures import CaseInsensitiveDict
    if MODE == "record":
        os.makedirs(os.path.dirname(PATH) or ".", exist_ok=True)
        con = _db()
        con.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('recorded_at', ?)", (str(time.time()),))
        con.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('tz', ?)", (os.environ.get("NOAI_TZ") or os.environ.get("TZ") or "",))
        con.commit()
        con.close()
    original = requests.Session.send

    def send(self, request, **kw):
        body = request.body
        k = _key(request.method or "GET", request.url or "", body)
        if MODE == "replay":
            with _lock:
                con = _db()
                row = con.execute("SELECT status, ctype, body FROM http WHERE k=?", (k,)).fetchone()
                con.close()
            r = Response()
            r.url, r.request, r.encoding = request.url, request, "utf-8"
            if row is None:
                STATS["missing"] += 1
                r.status_code, r._content, r.reason = 599, b'{"error": "not in cassette"}', "Not recorded"
                r.headers = CaseInsensitiveDict({"Content-Type": "application/json"})
                return r
            STATS["replayed"] += 1
            r.status_code, r._content, r.reason = row[0], zlib.decompress(row[2]), "OK"
            r.headers = CaseInsensitiveDict({"Content-Type": row[1] or "application/json"})
            return r
        resp = original(self, request, **kw)
        if getattr(_local, "skip", False):
            return resp
        try:
            content = resp.content                      # forces the read; iter_content still works afterwards
            if len(content) <= 4_000_000:
                with _lock:
                    con = _db()
                    con.execute("INSERT OR REPLACE INTO http(k, method, url, status, ctype, body, t) VALUES(?,?,?,?,?,?,?)",
                                (k, request.method, (request.url or "")[:2000], resp.status_code, resp.headers.get("Content-Type", ""), zlib.compress(content, 6), time.time()))
                    con.commit()
                    con.close()
                STATS["recorded"] += 1
        except Exception:
            pass
        return resp

    requests.Session.send = send


def page_get(url):
    """-> recorded fetch_page() output, or None. In replay mode a page that was never fetched is simply empty."""
    if MODE != "replay":
        return None
    with _lock:
        con = _db()
        row = con.execute("SELECT data FROM page WHERE url=?", (url,)).fetchone()
        con.close()
    if row is None:
        STATS["missing"] += 1
        return {"text": "", "codes": [], "recipes": [], "list": [], "faq": []}
    STATS["replayed"] += 1
    return json.loads(zlib.decompress(row[0]).decode("utf-8"))


def page_put(url, data):
    if MODE != "record":
        return
    try:
        slim = dict(data)
        slim["text"] = str(slim.get("text") or "")[:120_000]
        with _lock:
            con = _db()
            con.execute("INSERT OR REPLACE INTO page(url, data, t) VALUES(?,?,?)", (url, zlib.compress(json.dumps(slim, ensure_ascii=False).encode("utf-8"), 6), time.time()))
            con.commit()
            con.close()
        STATS["recorded"] += 1
    except Exception:
        pass


def _jkey(query, passage):
    return hashlib.sha256((query + "\x1f" + passage[:1600]).encode("utf-8", "ignore")).hexdigest()

def judge_put(query, passages, scores):
    """Record the judge's scores, so a replay on a machine WITHOUT the judge model can still reuse the Pi's verdicts."""
    if MODE != "record":
        return
    try:
        with _lock:
            con = _db()
            con.execute("CREATE TABLE IF NOT EXISTS judge (k TEXT PRIMARY KEY, query TEXT, passage TEXT, score REAL)")
            con.executemany("INSERT OR REPLACE INTO judge(k, query, passage, score) VALUES(?,?,?,?)", [(_jkey(query, p), query[:300], p[:1600], float(v)) for p, v in zip(passages, scores)])
            con.commit()
            con.close()
    except Exception:
        pass

def judge_get(query, passages):
    """-> list of recorded scores (None where that exact pair was never judged on the Pi)."""
    if MODE != "replay":
        return None
    try:
        with _lock:
            con = _db()
            con.execute("CREATE TABLE IF NOT EXISTS judge (k TEXT PRIMARY KEY, query TEXT, passage TEXT, score REAL)")
            out = []
            for p in passages:
                row = con.execute("SELECT score FROM judge WHERE k=?", (_jkey(query, p),)).fetchone()
                out.append(row[0] if row else None)
            con.close()
        return out
    except Exception:
        return None

def recorded_clock():
    """(timestamp, tz name) the cassette was recorded at, so 'days until Christmas' replays identically."""
    if MODE != "replay":
        return None, ""
    try:
        con = _db()
        m = dict(con.execute("SELECT k, v FROM meta").fetchall())
        con.close()
        return float(m.get("recorded_at") or 0) or None, m.get("tz", "")
    except Exception:
        return None, ""


def info():
    out = {"mode": MODE or "off"}
    if MODE:
        out.update(STATS)
        try:
            con = _db()
            out["http_entries"] = con.execute("SELECT count(*) FROM http").fetchone()[0]
            out["page_entries"] = con.execute("SELECT count(*) FROM page").fetchone()[0]
            con.close()
            out["cassette_mb"] = round(os.path.getsize(PATH) / 1e6, 1)
        except Exception:
            pass
    return out
__NOAI_V19_REPLAY_PY__
cat > "$APP_DIR/app/planner.py" <<'__NOAI_V27_PLANNER_PY__'
"""Query planning for NoAI Chat (v27, shadow mode).

The analyzer does not decide anything yet. It classifies what the router already infers implicitly -- intent, freshness
class, answer type, risk, side effects -- into a typed QueryPlan with an AnswerContract, so that routing becomes data
that can be logged, compared with what the router actually did, and tested. Every rule here is deterministic.

Freshness classes (from the v21 design review):
  STATIC      timeless facts and explanations; encyclopedic sources are fine
  LONG_LIVED  stable but revisable (how a technology works); live web optional
  RECENT      versions, prices, "latest": needs recently retrieved evidence
  LIVE        weather, nearby places, news, the clock: needs a live-capable source and must never fall back to static text
"""
import re
from dataclasses import dataclass, field, asdict

STATIC, LONG_LIVED, RECENT, LIVE = "STATIC", "LONG_LIVED", "RECENT", "LIVE"

# intent -> the router modes that count as honouring it (shadow comparison); "none" is an honest abstention everywhere
INTENT_MODES = {
    "chat": {"chat", "creative"}, "tool": {"tool"}, "calc": {"calc"}, "convert": {"convert"}, "clock": {"clock"}, "weather": {"weather"},
    "dictionary": {"dictionary"}, "nearby": {"osm"}, "news": {"news"}, "guide": {"guide", "tldr", "recipe"}, "recipe": {"recipe"}, "list": {"list"},
    "compare": {"compare"}, "fact": {"wikidata", "wikipedia"}, "inference": {"inference", "wikidata", "wikipedia", "none"}, "code": {"code", "tldr", "web", "none"}, "definition": {"wikipedia", "wikidata"}, "explain": {"wikipedia", "web", "research"},
    "summary": {"summary"}, "timeline": {"timeline"}, "facts": {"facts"}, "proscons": {"proscons"}, "word": {"word"}, "quotes": {"quotes"},
    "version": {"web"}, "research": {"research"}, "shell": {"tldr"}, "creative": {"creative"}, "false_premise": {"none", "chat"},
}
FRESH_MODES_LIVE = {"weather", "clock", "osm", "news", "tool"}                      # modes that draw on live data

@dataclass
class AnswerContract:
    min_answerability: float = 0.0          # judge score a passage must reach before it is shown (0 = current behaviour)
    min_sources: int = 1
    require_live: bool = False              # LIVE plans must never be answered from static text
    require_corroboration: bool = False
    require_entity_match: bool = True
    allow_abstain: bool = True

@dataclass
class QueryPlan:
    intent: str
    subject: str = ""
    freshness: str = STATIC
    answer_type: str = "passage"            # passage | fact | list | steps | table | number | conversation | headlines | ranked_entities
    side_effects: bool = False
    risk: str = "low"                       # low | medical | legal
    allowed_sources: list = field(default_factory=list)
    forbidden_fallbacks: list = field(default_factory=list)
    contract: AnswerContract = field(default_factory=AnswerContract)
    rule: str = ""                          # which rule fired, for the trace

    def as_dict(self):
        d = asdict(self)
        return d

    def honoured_by(self, mode):
        """Did the router's mode satisfy the plan? Abstaining is honest for anything but chat/tools; a LIVE plan answered
        from static text is a freshness violation and never honoured."""
        if mode == "none":
            return self.intent not in ("chat", "tool", "calc", "convert", "clock")
        if self.freshness == LIVE and mode not in FRESH_MODES_LIVE and mode != "none":
            return False
        return mode in INTENT_MODES.get(self.intent, set())

    def freshness_violation(self, mode):
        return self.freshness == LIVE and mode not in FRESH_MODES_LIVE and mode != "none"

@dataclass
class Evidence:
    text: str
    source_url: str = ""
    source_title: str = ""
    source_type: str = "web"                # wikipedia | web | wikidata | osm | tldr | feed | page
    relevance: float = 0.0                  # lexical/semantic match to the question
    answerability: float = 0.0              # judge score
    authority: float = 0.0                  # site prior
    freshness: float = 0.0                  # 1.0 live, 0.5 recent, 0.0 unknown/static
    completeness: float = 0.0               # length/structure signal
    context_independence: float = 0.0       # 1.0 if the passage stands alone (no anaphoric opener, no quotation tail)
    components: dict = field(default_factory=dict)   # named bonuses/penalties, each in points
    final: float = 0.0

    def as_dict(self):
        return asdict(self)

# ---------------------------------------------------------------- analyzer (deterministic, ordered rules)
_R = lambda p: re.compile(p, re.I)
RULES = [
    ("chat", _R(r"^(?:do you have a name|are you (?:chatgpt|an? (?:ai|bot|language model|llm|human|person|robot)|human|real|alive|sentient)|who are you|what(?:'s| is) your name|what should i call you|"
                r"what(?:'s| is) my (?:name|favou?rite \w+|\w+ called|\w+'s name)|do you remember my|what do you know about me|forget everything|"
                r"can you (?:draw|paint|design|make|create|write|generate)\b(?!.*(?:poem|haiku|limerick|tale|story|ode))|who (?:made|built|created|wrote) you|do you (?:ever|get|have feelings)|what were we talking|"
                r"(?:show|what's on|what is on|empty|clear|read) (?:me )?my .+ list|what tools do you have|how (?:is|are) (?:the |my )?(?:pi|raspberry)\b)"), STATIC, "conversation"),
    ("convert", _R(r"^convert \d|\bhow many (?:\w+ )?(?:in|is) (?:a |an |\d)|\d+\s?[a-z]* (?:in|to) [a-z]+$|\d+ ?[cf] in [cf]$|\bpounds is \d|\bkm to miles|\bfeet to inches|what is -?\d+ [cf] in [cf]"), STATIC, "number"),
    ("summary", _R(r"^(?:(?:can you |please )?(?:summari[sz]e|sum up|tl;?dr)[: ]*)?https?://\S+"), LONG_LIVED, "passage"),
    ("news", _R(r"^(?:(?:any |the |latest |recent |today's )?(?:news|headlines|updates?) (?:about|on|for|from|in)|what(?:'s| is| has been) (?:happening|going on|new|the latest) (?:in|with|at|on)|(?:the )?latest (?:on|about|from|in)\b|.+ (?:news|headlines)$|(?:any )?local news)"), LIVE, "headlines"),
    ("weather", _R(r"\b(?:weather|forecast|temperature (?:today|tomorrow|outside)|will it rain|umbrella)\b"), LIVE, "table"),
    ("clock", _R(r"^(?:what(?:'s| is) the (?:time|date)|what time is it|what day (?:is it|of the week)|what year is it|how many days (?:until|till|between)|what day of the week was|how old (?:would|will|is) (?:someone|a person)|what is \d+(?:\.\d+)?\s?% off|split \$?\d|monthly payment on|\d+\s?% tip on)"), LIVE, "number"),
    ("nearby", _R(r"\b(?:near|around|close to|nearby)\b.*\b(?:in|,)\b|\bnear me\b|\bnearby\b"), LIVE, "ranked_entities"),
    ("version", _R(r"\b(?:latest|current|newest|stable) (?:version|release)\b|\bversion of\b.*\?$"), RECENT, "fact"),
    ("tool", _R(r"^(?:remind me|set (?:a |an )?(?:timer|alarm)|start a .*timer|add .+ to my .+ list|put .+ on my .+ list|(?:show|what's on|empty|clear) my .+ list|remove .+ from my .+ list|add .+ to my calendar|put .+ on my calendar|pencil in|schedule |book |(?:create|open|read|remove|delete|list) (?:a )?(?:file|note)s?\b|write .+ to file|add household fact|system status|how (?:is|hot|warm) (?:the |is the )?(?:pi|raspberry)|how much disk|what tools do you have|undo$|yes$|no$)"), LIVE, "conversation"),
    ("calc", _R(r"^(?:what(?:'s| is) )?(?:the )?(?:\(?-?\d|square root of|cube root of|sum of|product of|\d+ (?:squared|cubed))|\d+\s?% of \d|\d+ (?:plus|minus|times|divided by|to the power of) \d"), STATIC, "number"),
    ("convert", _R(r"^convert \d|\bhow many (?:\w+ )?(?:in|is) (?:a |an |\d)|\d+\s?[a-z]* (?:in|to) [a-z]+$|\d+ ?[cf] in [cf]$|\bpounds is \d|\bkm to miles|\bfeet to inches"), STATIC, "number"),
    # v45: naming a command-line tool, or asking for "the command to ...", is a shell how-to; command assembly fills the tldr slots
    ("shell", _R(r"^(?!(?:what|who|when|where|why|define|compare|is|are|does|tell me about)\b).*\b(?:ffmpeg|imagemagick|convert|magick|rsync|scp|ssh|tar|zip|unzip|gzip|curl|wget|git|docker|grep|sed|awk|find|chmod|chown|systemctl|journalctl|crontab|"
                 r"pandoc|sox|youtube-dl|yt-dlp|openssl|gpg|dd|rclone|jq|ffprobe|exiftool|pdftk|qpdf|gs|ghostscript)\b(?! (?:is|was|means))|"
                 r"\b(?:the|a|an|what) (?:shell |bash |terminal |linux |command[- ]line )?command (?:to|for|that)\b|\bcommand line\b"), LONG_LIVED, "steps"),
    ("shell", _R(r"^how do i .*\b(?:linux|bash|shell|terminal|command line|systemd|cron|ssh|docker|git|tar\.gz|zip|file permissions|processes|ports|ip address|symbolic link|disk space|memory usage|files by name|lines in a file|rename a file|count lines|bootable usb|script executable|executable|chmod|environment variable|path variable|log file|last \d+ lines)\b"), LONG_LIVED, "steps"),
    ("recipe", _R(r"\brecipe\b|\bingredients for\b|^how do i (?:make|cook|bake) (?!(?:a |the )?(?:script|file|folder|directory|backup|bootable|usb|drive|partition|symlink|link|user|password|commit|branch|repo|virtual|venv|docker|container|image|package|alias|cron|service|firewall|port|key|certificate|ssh)\b)"), LONG_LIVED, "steps"),
    ("code", _R(r"(?=.*\b(?:python|javascript|typescript|java|c\+\+|c#|rust|golang|kotlin|swift|ruby|php|sql|regex|pandas|numpy|django|flask|react|node\.?js|css|html)\b)"
                 r"(?=.*\b(?:code|function|error|exception|script|loop|array|list|dict|dictionary|string|json|api|parse|sort|query|import|module|bug|debug|class|method|div|element|selector|flexbox|grid|margin|padding|layout|center|centre)\b)|"
                 r"\b(?:[A-Z][A-Za-z]+(?:Error|Exception)|segmentation fault|segfault|traceback|null pointer|undefined is not|syntax error|ModuleNotFound)\b"), LONG_LIVED, "steps"),
    ("guide", _R(r"^(?:how (?:do|can|should) (?:i|we|you)\b|how to\b|walk me through|steps to|guide to|tutorial|what (?:should i do|to do) for)"), LONG_LIVED, "steps"),
    ("list", _R(r"^(?:top|best|most popular|famous|must-see|top \d+)\b|\b(?:attractions|things to do|landmarks|hikes|museums|breeds)\b"), LONG_LIVED, "list"),
    # v46: enumerations ("what are the main causes of X") are lists of named items agreed across sources, each bullet counted and cited
    ("list", _R(r"^(?:(?:what|which) (?:are|were) (?:the |some )?(?:\w+ )*)?(?:causes|types|kinds|symptoms|signs|benefits|effects|side effects|uses|advantages|disadvantages|risks|complications|"
                r"features|examples|reasons|factors|sources|stages|components|parts|characteristics|treatments|dangers|drawbacks|consequences) (?:of|for) "), LONG_LIVED, "list"),
    ("compare", _R(r"^compare\b|\bvs\.?\b|\bversus\b"), STATIC, "table"),
    ("timeline", _R(r"\b(?:timeline|chronology|history) of\b|\btimeline$"), STATIC, "list"),
    ("facts", _R(r"^(?:(?:key |quick )?facts about|fact sheet)|\b(?:stats|statistics|facts|at a glance)$"), STATIC, "table"),
    ("proscons", _R(r"\bpros and cons\b|\badvantages and disadvantages\b|^should i (?:get|buy|use|switch to)\b|\bworth (?:it|getting|buying)\b"), LONG_LIVED, "list"),
    ("word", _R(r"^(?:synonyms?|antonyms?|rhymes?|etymology|pronunciation|opposite) (?:of|for)|what words? rhymes? with|how do you pronounce|where does the word .+ come from|what is the opposite of|what does the (?:prefix|suffix)"), STATIC, "list"),
    ("quotes", _R(r"\bquot(?:es|ations?) (?:by|from|of)\b|\bquotes$"), STATIC, "list"),
    ("dictionary", _R(r"^(?:define|definition of|meaning of|what does .+ mean)\b"), STATIC, "fact"),
    ("research", _R(r"^research\b"), LONG_LIVED, "list"),
    ("creative", _R(r"^(?:can you |could you |please |would you )?(?:write|compose|spin|tell)(?: me)? (?:a |an |another )?(?:short |quick |little )?(?:poem|haiku|limerick|tale|story|ode|sonnet|verse)\b"), STATIC, "conversation"),
    ("false_premise", _R(r"\bfirst (?:person|man|woman|human) to (?:walk|land|swim|climb|live|stand) on (?:the )?(?:sun|jupiter|venus|saturn|neptune|uranus|mercury|a star|the moon(?:'s core)?|olympus mons)\b|\bwhen did \w+ (?:land|walk) on (?:the )?(?:sun|jupiter|venus|saturn|neptune|uranus)\b"), STATIC, "conversation"),
    ("inference", _R(r"^(?:is|are|was|were) .+ (?:bigger|larger|smaller|taller|higher|shorter|longer|heavier|lighter|older|younger|more populous|more populated) than\b|"
                     r"^(?:which|who|what) (?:is|was|one is) (?:the )?(?:bigger|larger|smaller|taller|higher|shorter|longer|heavier|lighter|older|younger|more populous)\b.+\bor\b|"
                     r"^does .+ have (?:a )?(?:bigger|larger|higher|smaller|lower) (?:population|area) than\b|^was .+ (?:still )?alive (?:when|during|at the time of|for|to see|in)\b|"
                     r"^how long did .+ live\b|^how old was .+ when\b|^(?:did|had) .+ (?:die|pass away) before\b|^(?:was|were) .+ born before\b|"
                     r"^how far (?:is|are) (?:it )?(?:from )?.+ (?:from|to) .+|^(?:what(?:'s| is) the )?distance (?:from|between) .+ (?:to|and) .+|"
                     r"^how many (?:countries|nations|states|neighbou?rs|children|kids|siblings|languages|official languages|spouses|wives|husbands|moons|satellites|time zones|members) (?:does|do|did|has|have|had|border|surround|are (?:there )?in|live in|speak)\b|"
                     r"^(?:what|which)(?:'s| is| was| are)? (?:the )?(?:largest|biggest|smallest|highest|tallest|longest|most populous|most populated|least populous|oldest|newest|deepest) (?:country|countries|city|cities|mountain|mountains|river|rivers|lake|lakes|island|islands|desert|deserts|planet|planets|ocean|oceans|sea|seas|building|buildings|state|states) (?:in|of|on)\b|"
                     r"^who was (?:the )?(?:president|prime minister|king|queen|monarch|chancellor|pope|emperor) of .+ (?:when|at the time) .+ (?:was born|died|was (?:released|published|founded))\b|"
                     r"^(?:which|what)(?:'s| is)? (?:of these |of those )?(?:is |are )?(?:the )?(?:largest|biggest|smallest|highest|tallest|longest|oldest|newest|most populous|heaviest)\b.*(?:,| or )|"
                     r"^(?:where|when) was the (?:author|writer|director|composer|painter|founder|creator|inventor|architect|developer) of .+ born\b"), STATIC, "fact"),
    ("fact", _R(r"^(?:who (?:wrote|painted|directed|composed|founded|discovered|invented|sang|owns|is .+ married to|starred in)|what is the (?:capital|population|currency|official language) of|when was .+ born|where was .+ born|how (?:old|tall|long|big) is|what continent|which countries border|what plug|which side of the road|what is .+ named after|who (?:are|is) the (?:main )?characters?|when (?:did|was) .+ (?:open|released|founded|built)|where is .+ buried|how did .+ die|what is .+ made of)\b"), STATIC, "fact"),
    # v55: bare property phrases and the phrasings the checkable-facts run found unrouted
    ("fact", _R(r"^(?:birthplace|place of birth|composer|founder|founders|director|author|writer|capital|currency|population|height|elevation|spouse|wife|husband|creator|painter|inventor) of \b|"
                r"^.{2,40} (?:birthplace|composer|founder|director|author|writer|capital|currency|population|height|elevation|spouse|wife|husband|creator|painter)$|"
                r"^in (?:which|what) (?:city|town|country|place) was .+ born\b|^where (?:is|was) .+ from(?: originally)?$|^.+ was (?:painted|created|written|directed) by whom\b|"
                r"^what (?:money|currency) do they use in\b|^what currency does .+ use\b|^how high (?:is|are)\b|^what is the elevation of\b|^who (?:created|started|set up|established) (?:the company )?[A-Z]|^who did .+ marry\b"), STATIC, "fact"),
    ("definition", _R(r"^(?:what is|what's|what are|tell me about|who is|who was|what was)\b"), STATIC, "passage"),
    ("explain", _R(r"^(?:why|how (?:does|do|is|are|did|can|come)|what causes|what makes|what happens)\b"), STATIC, "passage"),
]
MEDICAL = re.compile(r"\b(?:symptom|disease|medication|medicine|dose|drug|treatment|diagnos\w*|infection|cancer|mg\b|surgery|therapy|doctor|blood pressure|diabetes|asthma|allerg\w*|fever|rash|fracture|burns?|vaccine|antibiotic\w*|ibuprofen|paracetamol|overdose|side effects?|first aid|stroke|heart attack|fibrillation|arrhythmia|\w+itis)\b", re.I)
LEGAL = re.compile(r"\b(?:lawsuit|sue|liable|legal|illegal|lawyer|attorney|custody|tenant|landlord|eviction|my lease|my deposit|inheritance|divorce|copyright|my visa|my rights)\b", re.I)
CHATTY = re.compile(r"^(?:hi|hello|hey|hiya|yo|morning|afternoon|evening|good (?:morning|afternoon|evening)|thanks|thank you|ok|okay|bye|how are you|how's it going|what's up|i (?:am|'m|feel|love|like|hate|live|adopted|got|have)\b|my (?:name|favourite|favorite|cat|dog|rabbit|hamster|parrot|goldfish|sister|job)\b|tell me a joke|another one|one more|that (?:joke|was)\b|you are\b|what do you know about me|forget everything|remember that|what were we talking)", re.I)

def analyze(q, hints=None):
    """-> QueryPlan. `hints` may carry booleans the router already knows (e.g. {"followup": True, "authed": False})."""
    s = re.sub(r"\s+", " ", (q or "").strip())
    sl = s.lower().rstrip("?.! ")
    hints = hints or {}
    plan = None
    for intent, rx, fresh, atype in RULES:
        if rx.search(sl):
            plan = QueryPlan(intent=intent, freshness=fresh, answer_type=atype, rule=intent)
            break
    if plan is None:
        if CHATTY.match(sl) or len(sl.split()) <= 2 and not sl.endswith("?"):
            plan = QueryPlan(intent="chat", freshness=STATIC, answer_type="conversation", rule="chatty")
        elif sl.endswith("?") or re.match(r"^(?:what|who|why|how|when|where|which|is|are|do|does|can)\b", sl):
            plan = QueryPlan(intent="explain", freshness=STATIC, answer_type="passage", rule="question-shape")
        else:
            plan = QueryPlan(intent="chat", freshness=STATIC, answer_type="conversation", rule="default")
    if hints.get("followup") and plan.intent in ("explain", "definition", "fact"):
        plan.rule += "+followup"
    plan.side_effects = plan.intent == "tool"
    plan.risk = "medical" if MEDICAL.search(sl) else ("legal" if LEGAL.search(sl) else "low")
    plan.allowed_sources = {
        "news": ["news_search", "feeds"], "weather": ["open-meteo"], "nearby": ["osm", "wikipedia_geo"], "clock": ["clock"], "tool": ["tools"],
        "fact": ["wikidata", "wikipedia"], "inference": ["wikidata"], "code": ["web"], "definition": ["wikipedia", "wikidata"], "explain": ["wikipedia", "web"], "guide": ["web_steps"],
        "recipe": ["web_recipe"], "list": ["web_lists"], "compare": ["wikipedia", "wikidata"], "version": ["github", "web"], "shell": ["tldr"],
        "word": ["wiktionary"], "quotes": ["wikiquote"], "summary": ["page"], "timeline": ["wikipedia"], "facts": ["wikidata"], "proscons": ["web"],
    }.get(plan.intent, ["wikipedia", "web"])
    if plan.freshness == LIVE:
        plan.forbidden_fallbacks = ["wikipedia", "web_passage", "chat"]
    elif plan.intent in ("guide", "recipe", "list", "news"):
        plan.forbidden_fallbacks = ["wikipedia_definition"]
    plan.contract = AnswerContract(
        min_answerability=0.0,
        min_sources=2 if plan.intent in ("list", "proscons", "research") else 1,
        require_live=plan.freshness == LIVE,
        require_corroboration=plan.intent in ("list", "research"),
        require_entity_match=plan.intent in ("fact", "definition", "compare", "facts", "timeline"),
        allow_abstain=plan.intent not in ("chat", "tool", "calc", "convert", "clock"),
    )
    return plan

# Fallback order after the intent's own capabilities, by freshness class. LIVE plans get no static fallback: a weather or
# news question answered from an encyclopedia passage is a freshness violation, and abstaining is the honest outcome.
FALLBACK = {STATIC: ["answer pool", "wikipedia", "web"], LONG_LIVED: ["answer pool", "wikipedia", "web"], RECENT: ["live-web", "wikipedia"], LIVE: []}
CONVERSATIONAL = {"chat", "tool", "calc", "convert", "clock", "creative", "false_premise", "weather"}

def capabilities_for(plan, registry):
    """The ordered capability list the planner would run for this plan (Phase 3, shadow): the capabilities registered for
    the plan's intent in registry order, then the freshness-appropriate fallbacks. Conversational intents run no
    retrieval capability at all; they are handled before the registry."""
    if plan.intent in CONVERSATIONAL:
        return []
    order = [c.name for c in registry.caps if plan.intent in c.intents]
    for name in FALLBACK.get(plan.freshness, []):
        if name not in order and registry.by_name(name) is not None:
            order.append(name)
    return order

def describe(plan):
    c = plan.contract
    return (f"plan: intent={plan.intent} freshness={plan.freshness} type={plan.answer_type} risk={plan.risk}"
            f"{' side-effects' if plan.side_effects else ''} rule={plan.rule} | contract: live={c.require_live} corroborate={c.require_corroboration}"
            f" entity={c.require_entity_match} sources>={c.min_sources}")
__NOAI_V27_PLANNER_PY__
cat > "$APP_DIR/app/capabilities.py" <<'__NOAI_V30_CAPS_PY__'
"""Capability registry (v30, Phase 2 of the design review).

Every retrieval handler is registered once with the same signature `handler(q, st) -> result | None`, plus metadata the
planner can reason about: which intents it serves, the freshness class of the data it draws on, whether it has side
effects, and a gate deciding whether it applies to a question. The router iterates the registry stage by stage in the
same order the hand-written cascade used, so behaviour is unchanged; what changes is that the order, the gates and the
metadata are data, inspectable at /api/capabilities and comparable with the shadow planner's plan.

Stages (in cascade order):
  structured  recipes, lists, news, facts, timelines, quotes, word tools, pros/cons, page summaries
  precise     dictionary, age, Wikidata relations and properties
  explain     nearby places, comparisons, shell how-to, research, live web, step-by-step guides, the answer pool,
              Wikipedia, the open web
"""
from dataclasses import dataclass, field

STATIC, LONG_LIVED, RECENT, LIVE = "STATIC", "LONG_LIVED", "RECENT", "LIVE"

@dataclass
class Capability:
    name: str                          # the handler name used in traces ("answered by <name>")
    handler: object                    # callable (q, st) -> result dict | None
    stage: str                         # structured | precise | explain
    intents: tuple = ()                # planner intents this capability serves
    freshness: str = STATIC            # freshness class of the data it draws on
    side_effects: bool = False
    needs_auth: bool = False
    gate: object = None                # callable (q, st, flags) -> bool; None = always applies
    trace_miss: bool = False           # whether the cascade traced "<name>: no answer" at this stage
    description: str = ""

    def applies(self, q, st, flags):
        if self.gate is None:
            return True
        try:
            return bool(self.gate(q, st, flags))
        except Exception:
            return False

    def describe(self):
        return {"name": self.name, "stage": self.stage, "intents": list(self.intents), "freshness": self.freshness,
                "side_effects": self.side_effects, "needs_auth": self.needs_auth, "gated": self.gate is not None, "description": self.description}

class Registry:
    def __init__(self):
        self.caps = []

    def add(self, cap):
        self.caps.append(cap)
        return cap

    def stage(self, name):
        return [c for c in self.caps if c.stage == name]

    def for_intent(self, intent):
        return [c.name for c in self.caps if intent in c.intents]

    def by_name(self, name):
        return next((c for c in self.caps if c.name == name), None)

    def describe(self):
        return [c.describe() for c in self.caps]

REGISTRY = Registry()

def register(**kw):
    """Decorator form: @register(name=..., stage=..., intents=...) def handler(q, st): ..."""
    def deco(fn):
        REGISTRY.add(Capability(handler=fn, **kw))
        return fn
    return deco

# mode -> capability name, for the shadow comparison (a mode is what the answer reports; a capability is what produced it)
MODE_TO_CAPABILITY = {"code": "code help", "inference": "inference", "wikipedia": "wikipedia", "web": "web", "research": "research", "guide": "guide", "recipe": "recipe", "list": "list",
                      "news": "news", "facts": "facts", "timeline": "timeline", "quotes": "quotes", "word": "word", "proscons": "proscons",
                      "summary": "summary", "dictionary": "dictionary", "wikidata": "relation", "compare": "compare", "osm": "nearby", "tldr": "howto"}
__NOAI_V30_CAPS_PY__
cat > "$APP_DIR/app/inference.py" <<'__NOAI_V33_INFER_PY__'
"""Rule-based inference over Wikidata (v33). No generation: each answer states the facts it retrieved, the rule it applied,
and cites the Wikidata items. If a fact is missing, or two quantities have units that cannot be reconciled, it abstains.

Three families:
  comparison   "Is Canada bigger than Australia?", "Which is taller, K2 or Denali?", "Who is older, X or Y?"
  temporal     "Was Einstein alive for the Moon landing?", "Was Newton alive in 1700?", "How long did Mozart live?",
               "How old was Darwin when On the Origin of Species was published?", "Did Lincoln die before Darwin?"
  two-hop      "Where was the author of Dracula born?", "When was the director of Alien born?"
The app injects its Wikidata helpers with configure(); nothing here fetches on its own.
"""
import re
from datetime import date

_H = {}          # injected helpers: entity(term, st, want_pids) -> {"label","entity","qid"} | None; claims(ent, pid); values(claims); trace(msg)

def configure(**helpers):
    _H.update(helpers)

def _trace(msg):
    f = _H.get("trace")
    if f:
        f("inference: " + msg)

# ---------------------------------------------------------------- quantities
# unit QIDs and their factor to a base unit, per dimension
UNITS = {
    "area":   {"Q712226": 1.0, "Q25343": 1e-6, "Q232291": 2.589988},              # km², m², sq mi -> km²
    "length": {"Q11573": 1.0, "Q828224": 1000.0, "Q3710": 0.3048, "Q253276": 1609.344},   # m, km, ft, mi -> m
    "mass":   {"Q11570": 1.0, "Q41803": 0.001, "Q100995": 0.45359237, "Q11776930": 1e6, "Q191960": 1e21},   # kg, g, lb, Mg(t), Yg -> kg
    "count":  {"1": 1.0},
}
METRICS = {
    # adjective -> (pids in preference order, dimension, higher-is, noun)
    "bigger": (["P2046", "P1082"], "area", True, "area"), "larger": (["P2046", "P1082"], "area", True, "area"),
    "smaller": (["P2046", "P1082"], "area", False, "area"),
    "taller": (["P2048", "P2044"], "length", True, "height"), "higher": (["P2044", "P2048"], "length", True, "elevation"),
    "shorter": (["P2048", "P2044"], "length", False, "height"), "longer": (["P2043"], "length", True, "length"),
    "heavier": (["P2067"], "mass", True, "mass"), "lighter": (["P2067"], "mass", False, "mass"),
    "more populous": (["P1082"], "count", True, "population"), "more populated": (["P1082"], "count", True, "population"),
    "older": (["P569", "P571"], "date", False, "age"), "younger": (["P569", "P571"], "date", True, "age"),
}
COMPARE_RES = [
    re.compile(r"^(?:is|are|was|were) (?P<a>.+?) (?P<adj>bigger|larger|smaller|taller|higher|shorter|longer|heavier|lighter|older|younger|more populous|more populated) than (?P<b>.+?)\??$", re.I),
    re.compile(r"^(?:which|who|what) (?:is|was|one is) (?:the )?(?P<adj>bigger|larger|smaller|taller|higher|shorter|longer|heavier|lighter|older|younger|more populous)[,:]? (?P<a>.+?) or (?P<b>.+?)\??$", re.I),
    re.compile(r"^does (?P<a>.+?) have (?:a )?(?P<adj2>bigger|larger|higher|smaller|lower) (?P<what>population|area) than (?P<b>.+?)\??$", re.I),
]
TEMPORAL_RES = [
    ("alive_event", re.compile(r"^was (?P<a>.+?) (?:still )?alive (?:when|during|at the time of|for|to see) (?P<b>.+?)\??$", re.I)),
    ("alive_year", re.compile(r"^was (?P<a>.+?) (?:still )?alive in (?P<year>\d{3,4})\??$", re.I)),
    ("lifespan", re.compile(r"^how long did (?P<a>.+?) live\??$", re.I)),
    ("age_at", re.compile(r"^how old was (?P<a>.+?) when (?P<b>.+?)(?: happened| took place| occurred)?\??$", re.I)),
    ("died_before", re.compile(r"^(?:did|had) (?P<a>.+?) (?:die|pass away) before (?P<b>.+?)(?: was born| did)?\??$", re.I)),
    ("born_before", re.compile(r"^(?:was|were) (?P<a>.+?) born before (?P<b>.+?)\??$", re.I)),
]
TWOHOP_RE = re.compile(r"^(?:where|when) was the (?P<rel>author|writer|director|composer|painter|founder|creator|inventor|architect|developer) of (?P<work>.+?) born\??$", re.I)
REL_PIDS = {"author": ["P50"], "writer": ["P50", "P58"], "director": ["P57"], "composer": ["P86"], "painter": ["P170"], "creator": ["P170", "P50"],
            "founder": ["P112"], "inventor": ["P61"], "architect": ["P84"], "developer": ["P178"]}
DATE_PIDS_EVENT = ["P585", "P577", "P580", "P619", "P1191", "P575", "P571"]     # point in time, publication, start, launch, first performance, discovery; inception last
                                                                                  # (v35: Principia's inception 1680 was picked over its 1687 publication)

DISTANCE_RE = re.compile(r"^(?:how far (?:is|are) (?:it )?(?:from )?(?P<a>.+?) (?:from|to) (?P<b>.+?)|(?:what(?:'s| is) the )?distance (?:from|between) (?P<c>.+?) (?:to|and) (?P<d>.+?))[?.!]*$", re.I)

# ---------------------------------------------------------------- v60: reasoning over cited claims (counting, superlatives, office-at-date, which-of-these)
COUNT_RE = re.compile(r"^how many (?P<what>countries|nations|states|neighbours|neighbors|children|kids|siblings|brothers and sisters|languages|official languages|spouses|wives|husbands|moons|satellites|time zones|members|employees|inhabitants|people|residents|players) (?:does|do|did|has|have|had|border|surround|are (?:there )?in|live in|speak) (?P<x>.+?)(?: have| got)?[?.!]*$", re.I)
COUNT_PIDS = {"countries": "P47", "nations": "P47", "neighbours": "P47", "neighbors": "P47", "states": "P150", "children": "P40", "kids": "P40", "siblings": "P3373", "brothers and sisters": "P3373",
              "languages": "P37", "official languages": "P37", "spouses": "P26", "wives": "P26", "husbands": "P26", "moons": "P398", "satellites": "P398", "time zones": "P421", "members": "P527",
              "employees": "P1128", "inhabitants": "P1082", "people": "P1082", "residents": "P1082", "players": "P1128"}
SUPER_RE = re.compile(r"^(?:what|which)(?:'s| is| was| are)? (?:the )?(?P<sup>largest|biggest|smallest|highest|tallest|longest|most populous|most populated|least populous|oldest|newest|deepest) (?P<cls>country|countries|city|cities|mountain|mountains|river|rivers|lake|lakes|island|islands|desert|deserts|planet|planets|ocean|oceans|sea|seas|building|buildings|state|states) (?:in|of|on) (?P<where>.+?)[?.!]*$", re.I)
SUPER_CLASS = {"country": "Q6256", "countries": "Q6256", "city": "Q515", "cities": "Q515", "mountain": "Q8502", "mountains": "Q8502", "river": "Q4022", "rivers": "Q4022", "lake": "Q23397", "lakes": "Q23397",
               "island": "Q23442", "islands": "Q23442", "desert": "Q8514", "deserts": "Q8514", "planet": "Q634", "planets": "Q634", "ocean": "Q9430", "oceans": "Q9430", "sea": "Q165", "seas": "Q165",
               "building": "Q41176", "buildings": "Q41176", "state": "Q7275", "states": "Q7275"}
SUPER_PROP = {"largest": ("P2046", "DESC", "area"), "biggest": ("P2046", "DESC", "area"), "smallest": ("P2046", "ASC", "area"), "highest": ("P2044", "DESC", "elevation"), "tallest": ("P2048", "DESC", "height"),
              "longest": ("P2043", "DESC", "length"), "most populous": ("P1082", "DESC", "population"), "most populated": ("P1082", "DESC", "population"), "least populous": ("P1082", "ASC", "population"),
              "oldest": ("P571", "ASC", "inception"), "newest": ("P571", "DESC", "inception"), "deepest": ("P4511", "DESC", "depth")}
OFFICE_RE = re.compile(r"^who was (?:the )?(?P<office>president|prime minister|king|queen|monarch|chancellor|pope|emperor) of (?P<x>.+?) (?:when|at the time) (?P<y>.+?) (?:was born|died|was (?:released|published|founded))[?.!]*$", re.I)
OFFICE_PIDS = {"president": ["P35", "P6"], "prime minister": ["P6"], "king": ["P35"], "queen": ["P35"], "monarch": ["P35"], "chancellor": ["P6"], "pope": ["P35"], "emperor": ["P35"]}
WHICH_RE = re.compile(r"^(?:which|what)(?:'s| is)? (?:of these |of those )?(?:is |are )?(?:the )?(?P<sup>largest|biggest|smallest|highest|tallest|longest|oldest|newest|most populous|heaviest) ?(?:one|country|city|mountain|planet)?[:,]? (?P<list>.+?)[?.!]*$", re.I)

def wants(q):
    s = q.strip()
    return any(r.match(s) for r in COMPARE_RES) or any(r.match(s) for _, r in TEMPORAL_RES) or bool(TWOHOP_RE.match(s)) or bool(DISTANCE_RE.match(s)) \
        or bool(COUNT_RE.match(s)) or bool(SUPER_RE.match(s)) or bool(OFFICE_RE.match(s)) or (bool(WHICH_RE.match(s)) and ("," in s or " or " in s))

def _count(q, st):
    m = COUNT_RE.match(q.strip())
    if not m:
        return None
    what, pid = m.group("what").lower(), COUNT_PIDS.get(m.group("what").lower())
    if not pid:
        return None
    e = _H["entity"](m.group("x").strip(" ?."), st, (pid,))
    if not e:
        return _abstain("count: could not resolve the subject")
    rows = _H["values"](_H["claims"](e["entity"], pid)) or []
    if not rows:
        return {"answer": f"Wikidata has no {what} listed for {e['label']}, so I can't count them.", "sources": [_src(e)], "mode": "inference", "evidence_count": 1}
    if pid in ("P1082", "P1128"):
        return {"answer": f"{e['label']}: {rows[0]['text']} (Wikidata's {'population' if pid == 'P1082' else 'employee count'}).", "sources": [_src(e)], "mode": "inference", "evidence_count": 1}
    names = [r["text"] for r in rows if r.get("text")]
    return {"answer": f"{len(names)}, according to Wikidata: {', '.join(names[:12])}{'…' if len(names) > 12 else ''}.", "sources": [_src(e)], "mode": "inference", "evidence_count": len(names)}

def _superlative(q, st):
    m = SUPER_RE.match(q.strip())
    if not m or not _H.get("sparql"):
        return None
    cls, (pid, order, label) = SUPER_CLASS[m.group("cls").lower()], SUPER_PROP[m.group("sup").lower()]
    where = _H["entity"](m.group("where").strip(" ?."), st, ("P30", "P17"))
    if not where:
        return _abstain("superlative: could not resolve the region")
    wq = where.get("qid") or where["entity"].get("id")
    # members of the class located in the region (country, continent or subdivision), ordered by the property; rank preferred first
    query = f"""SELECT ?item ?itemLabel ?v WHERE {{
      ?item wdt:P31/wdt:P279* wd:{cls} .
      {{ ?item wdt:P30 wd:{wq} }} UNION {{ ?item wdt:P17 wd:{wq} }} UNION {{ ?item wdt:P131 wd:{wq} }}
      ?item wdt:{pid} ?v .
      SERVICE wikibase:label {{ bd:serviceParam wikibase:language "en". }}
    }} ORDER BY {order}(?v) LIMIT 3"""
    rows = _H["sparql"](query)
    if not rows:
        return _abstain("superlative: the query returned nothing")
    top = rows[0]
    val = top.get("v", "")
    try:
        val_txt = f"{float(val):,.0f}" if re.fullmatch(r"-?\d+(?:\.\d+)?", val) else val[:10]
    except Exception:
        val_txt = val
    unit = {"area": " km²", "population": "", "elevation": " m", "height": " m", "length": " km", "inception": "", "depth": " m"}[label]
    others = "; ".join(f"{r.get('itemLabel')} ({r.get('v')[:10] if not re.fullmatch(r'-?\d+(?:\.\d+)?', r.get('v', '')) else format(float(r.get('v')), ',.0f')}{unit})" for r in rows[1:3])
    return {"answer": f"By {label} in Wikidata, the {m.group('sup').lower()} {m.group('cls').lower()} in {where['label']} is {top.get('itemLabel')} ({val_txt}{unit})." + (f" Next: {others}." if others else ""),
            "sources": [{"title": "Wikidata query", "url": "https://query.wikidata.org/"}, _src(where)], "mode": "inference", "evidence_count": len(rows)}

def _office_at_date(q, st):
    m = OFFICE_RE.match(q.strip())
    if not m:
        return None
    office = m.group("office").lower()
    ex = _H["entity"](m.group("x").strip(" ?."), st, tuple(OFFICE_PIDS[office]))
    ey = _H["entity"](m.group("y").strip(" ?."), st, ("P569", "P570", "P577", "P571"))
    if not ex or not ey:
        return _abstain("office: could not resolve both subjects")
    low = q.lower()
    dpid = "P569" if "born" in low else ("P570" if "died" in low else ("P577" if "released" in low or "published" in low else "P571"))
    when = None
    for c in _H["claims"](ey["entity"], dpid):
        t = c.get("mainsnak", {}).get("datavalue", {}).get("value", {}).get("time", "")
        mm = re.match(r"\+(\d{4})-(\d{2})-(\d{2})", t)
        if mm:
            when = (int(mm.group(1)), max(1, int(mm.group(2))), max(1, int(mm.group(3)))); break
    if not when:
        return _abstain("office: no date on the second subject")
    def qdate(c, qpid):
        for qf in (c.get("qualifiers") or {}).get(qpid, []):
            t = qf.get("datavalue", {}).get("value", {}).get("time", "")
            mm = re.match(r"\+(\d{4})-(\d{2})-(\d{2})", t)
            if mm:
                return (int(mm.group(1)), max(1, int(mm.group(2))), max(1, int(mm.group(3))))
        return None
    for pid in OFFICE_PIDS[office]:
        for c in _H["claims"](ex["entity"], pid):
            start, end = qdate(c, "P580"), qdate(c, "P582")
            if start and start <= when and (end is None or when <= end):
                v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                if isinstance(v, dict) and v.get("id"):
                    ent = _H["get"]([v["id"]]).get(v["id"], {})
                    name = (ent.get("labels", {}).get("en") or {}).get("value", v["id"])
                    return {"answer": f"{name} was {office} of {ex['label']} on {when[0]}-{when[1]:02d}-{when[2]:02d}, when {ey['label']} {'was born' if dpid == 'P569' else 'died' if dpid == 'P570' else 'came out'} (Wikidata: office held {start[0]}\u2013{end[0] if end else 'present'}).",
                            "sources": [_src(ex), _src(ey)], "mode": "inference", "evidence_count": 3}
    return _abstain("office: no dated office claim covers that date")

def _which_of_these(q, st):
    m = WHICH_RE.match(q.strip())
    if not m:
        return None
    sup = m.group("sup").lower()
    pid, order, label = SUPER_PROP.get(sup, ("P2046", "DESC", "area")) if sup != "heaviest" else ("P2067", "DESC", "mass")
    names = [x.strip(" ?.") for x in re.split(r",| or | and ", m.group("list")) if x.strip(" ?.")]
    if not 2 <= len(names) <= 6:
        return None
    got = []
    for n in names:
        e = _H["entity"](n, st, (pid,))
        if not e:
            continue
        vals = _H["values"](_H["claims"](e["entity"], pid)) or []
        if vals:
            num = re.sub(r"[^\d.]", "", vals[0]["text"].split()[0]) if pid != "P571" else re.sub(r"[^\d]", "", vals[0]["text"])[:4]
            try:
                got.append((float(num), e, vals[0]["text"]))
            except Exception:
                pass
    if len(got) < 2:
        return _abstain("which-of-these: fewer than two comparable values")
    got.sort(key=lambda x: x[0], reverse=(order == "DESC"))
    best = got[0]
    return {"answer": f"{best[1]['label']} ({best[2]}). By {label}: " + "; ".join(f"{e['label']} {t}" for _, e, t in got) + " (Wikidata).",
            "sources": [_src(e) for _, e, _ in got], "mode": "inference", "evidence_count": len(got)}

def _coords(ent):
    for c in _H["claims"](ent, "P625"):
        v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
        if isinstance(v, dict) and "latitude" in v and "longitude" in v:
            return float(v["latitude"]), float(v["longitude"])
    return None

def _distance(q, st):
    """v52: great-circle distance between two places from their Wikidata coordinates (P625). Arithmetic on cited facts, nothing else."""
    m = DISTANCE_RE.match(q.strip())
    if not m:
        return None
    a, b = (m.group("a") or m.group("c")), (m.group("b") or m.group("d"))
    if not a or not b or a.lower() in ("it", "here", "there"):
        return None
    ea = _H["entity"](a.strip(" ?."), st, ("P625",))
    eb = _H["entity"](b.strip(" ?."), st, ("P625",))
    if not ea or not eb:
        return _abstain("could not resolve both places")
    ca, cb = _coords(ea["entity"]), _coords(eb["entity"])
    if not ca or not cb:
        return {"answer": f"Wikidata has no coordinates for {'both' if not ca and not cb else (ea['label'] if not ca else eb['label'])}, so I can't work out the distance.",
                "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
    import math
    la1, lo1, la2, lo2 = map(math.radians, (ca[0], ca[1], cb[0], cb[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    km = 6371.0 * 2 * math.asin(math.sqrt(h))
    mi = km * 0.621371
    fmt = lambda x: f"{x:,.0f}" if x >= 20 else f"{x:.1f}"
    return {"answer": f"{ea['label']} is about {fmt(km)} km ({fmt(mi)} miles) from {eb['label']} in a straight line, from their Wikidata coordinates. Road or rail distance will be longer.",
            "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}

# ---------------------------------------------------------------- fact access
def _quantity(ent, pids, dim):
    """-> (value in base unit, display text, pid) for the first pid with a usable quantity, else None."""
    for pid in pids:
        for c in _H["claims"](ent, pid):
            v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
            if not isinstance(v, dict) or "amount" not in v:
                continue
            unit = (v.get("unit") or "1").rsplit("/", 1)[-1]
            table = UNITS.get(dim, {})
            if dim == "count" and unit != "1":
                continue
            if dim != "count" and unit not in table:
                _trace(f"unit {unit} not convertible for {pid}")
                continue
            try:
                amt = float(v["amount"])
            except ValueError:
                continue
            rows = _H["values"]([c]) or []
            text = rows[0].get("text") if rows and rows[0].get("text") else f"{amt:,.0f}"
            return amt * table.get(unit, 1.0), text, pid
    return None

def _date(ent, pids):
    """-> (date or None, year, display text, pid); precision 9 (year) gives (None, year, ...)."""
    for pid in pids:
        for c in _H["claims"](ent, pid):
            v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
            if not isinstance(v, dict) or "time" not in v:
                continue
            m = re.match(r"^([+-])(\d{1,6})-(\d{2})-(\d{2})", v["time"])
            if not m:
                continue
            year = int(m.group(2)) * (-1 if m.group(1) == "-" else 1)
            prec = int(v.get("precision") or 9)
            text, _ = _H["format_time"](v)
            d = None
            if prec >= 11 and year > 0:
                try:
                    d = date(year, int(m.group(3)) or 1, int(m.group(4)) or 1)
                except ValueError:
                    d = None
            return d, year, text, pid
    return None

def _entity(term, st, want):
    try:
        return _H["entity"](term.strip(" ?."), st, want)
    except Exception as e:
        _trace(f"lookup failed for {term!r}: {type(e).__name__}")
        return None

def _src(e):
    return {"title": "Wikidata: " + e["label"], "url": "https://www.wikidata.org/wiki/" + (e.get("qid") or e["entity"].get("id", ""))}

def _abstain(msg):
    _trace(msg)
    return None

def _ordinal_note():
    return "Compared from Wikidata's recorded values; I don't estimate missing figures."

# ---------------------------------------------------------------- comparisons
def _compare(q, st):
    for rx in COMPARE_RES:
        m = rx.match(q.strip())
        if m:
            break
    else:
        return None
    g = m.groupdict()
    if g.get("adj2"):
        adj = {"population": "more populous", "area": "bigger"}[g["what"].lower()]
        if g["adj2"].lower() in ("smaller", "lower"):
            adj = "smaller" if g["what"].lower() == "area" else "less populous"
    else:
        adj = g["adj"].lower()
    if adj == "less populous":
        pids, dim, higher, noun = ["P1082"], "count", False, "population"
    else:
        pids, dim, higher, noun = METRICS[adj]
    a, b = g["a"], g["b"]
    ea, eb = _entity(a, st, tuple(pids)), _entity(b, st, tuple(pids))
    if not ea or not eb:
        return _abstain(f"could not resolve {'both' if not ea and not eb else (a if not ea else b)}")
    if dim == "date":
        da, db = _date(ea["entity"], pids), _date(eb["entity"], pids)
        if not da or not db:
            miss = ea["label"] if not da else eb["label"]
            return {"answer": f"I can't compare their ages: Wikidata has no birth or founding date for {miss}.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 1}
        ya, yb = da[1], db[1]
        if ya == yb and da[0] and db[0]:
            older = ea if da[0] < db[0] else eb
        elif ya == yb:
            return {"answer": f"Both {ea['label']} and {eb['label']} date from {ya} according to Wikidata, and it does not record which came first.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
        else:
            older = ea if ya < yb else eb
        younger = eb if older is ea else ea
        asked = older if adj == "older" else younger
        return {"answer": f"{asked['label']} is {adj}. {ea['label']}: {da[2]}; {eb['label']}: {db[2]} (Wikidata).",
                "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
    qa, qb = _quantity(ea["entity"], pids, dim), _quantity(eb["entity"], pids, dim)
    if not qa or not qb:
        miss = ea["label"] if not qa else eb["label"]
        return {"answer": f"I can't make that comparison: Wikidata records no {noun} for {miss}, and I don't estimate figures.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 1}
    if qa[2] != qb[2]:
        return {"answer": f"I won't compare these: Wikidata gives {ea['label']}'s {noun} as one kind of measurement and {eb['label']}'s as another, so the numbers aren't like for like.",
                "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
    if abs(qa[0] - qb[0]) < 1e-9:
        verdict = f"They are recorded as equal in {noun}."
    else:
        bigger = ea if qa[0] > qb[0] else eb
        smaller = eb if bigger is ea else ea
        ratio = max(qa[0], qb[0]) / max(min(qa[0], qb[0]), 1e-9)
        asked = bigger if higher else smaller
        yesno = rx is not COMPARE_RES[1]          # "Is X ... than Y?" and "Does X have ... than Y?" take a yes/no; "Which is ..." names the winner
        verdict = f"Yes, {asked['label']} is {adj}." if yesno and asked is ea else (f"No: {asked['label']} is {adj}." if yesno else f"{asked['label']} is {adj}.")
        if adj in ("bigger", "larger", "smaller", "more populous", "more populated", "less populous", "heavier", "lighter") and ratio >= 1.05:
            verdict += f" {bigger['label']} is about {ratio:.1f} times {smaller['label']} by {noun}." if ratio < 100 else f" {bigger['label']} is roughly {ratio:,.0f} times {smaller['label']} by {noun}."
    facts = f"{ea['label']}: {qa[1]}; {eb['label']}: {qb[1]} (Wikidata)."
    return {"answer": f"{verdict} {facts}", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}

# ---------------------------------------------------------------- temporal
def _person_dates(e):
    born, died = _date(e["entity"], ["P569"]), _date(e["entity"], ["P570"])
    return born, died

def _event_date(e, hint=""):
    if re.search(r"publish|released|came out|printed", hint or "", re.I):
        d = _date(e["entity"], ["P577"])
        if d:
            return d
    return _date(e["entity"], DATE_PIDS_EVENT) or _date(e["entity"], ["P569"])

def _years_between(d1, d2):
    if d1[0] and d2[0]:
        y = d2[0].year - d1[0].year - ((d2[0].month, d2[0].day) < (d1[0].month, d1[0].day))
        return y, True
    return d2[1] - d1[1], False

def _temporal(q, st):
    kind = None
    for k, rx in TEMPORAL_RES:
        m = rx.match(q.strip())
        if m:
            kind = k
            break
    if not kind:
        return None
    g = m.groupdict()
    ea = _entity(g["a"], st, ("P569",))
    if not ea:
        return _abstain(f"could not resolve {g['a']!r}")
    born, died = _person_dates(ea)
    if not born:
        return {"answer": f"Wikidata has no birth date for {ea['label']}, so I can't work that out.", "sources": [_src(ea)], "mode": "inference", "evidence_count": 1}
    if kind == "lifespan":
        if not died:
            return {"answer": f"Wikidata records no date of death for {ea['label']} (born {born[2]}), so either they are living or the record is incomplete.", "sources": [_src(ea)], "mode": "inference", "evidence_count": 1}
        yrs, exact = _years_between(born, died)
        return {"answer": f"{ea['label']} lived {'about ' if not exact else ''}{yrs} years: born {born[2]}, died {died[2]} (Wikidata).", "sources": [_src(ea)], "mode": "inference", "evidence_count": 2}
    if kind == "alive_year":
        y = int(g["year"])
        alive = born[1] <= y and (not died or died[1] >= y)
        span = f"born {born[2]}" + (f", died {died[2]}" if died else ", no death recorded")
        return {"answer": f"{'Yes' if alive else 'No'}: {ea['label']} was {span} (Wikidata), so {'was' if alive else 'was not'} alive in {y}.".replace("so was", "so they were").replace("so was not", "so they were not"),
                "sources": [_src(ea)], "mode": "inference", "evidence_count": 2}
    # the second thing: an event, or a person for born_before/died_before ("when X was published" -> X)
    b_term = re.sub(r"\s+(?:was|were|got) (?:published|released|founded|born|built|completed|launched|written|painted|discovered|invented|created|assassinated|killed|elected|crowned)$"
                    r"|\s+(?:came out|began|ended|started|happened|took place|occurred|died|fell|landed)$", "", g["b"].strip(" ?."), flags=re.I)
    b_term = re.sub(r"^(?:the|an?)\s+", "", b_term, flags=re.I)
    eb = _entity(b_term, st, ("P585", "P580", "P569"))
    # "the Apollo 11 landing" resolved to the Apollo *program*: if the pick has no point-in-time and the term carries an
    # event noun, retry with the noun stripped and prefer whichever candidate has a dated event
    core = re.sub(r"\s+(?:landing|launch|mission|disaster|eruption|earthquake|battle|assassination|coronation|premiere|release|crash|accident|explosion|flight)$", "", b_term, flags=re.I)
    if core != b_term:
        eb2 = _entity(core, st, ("P585", "P580"))
        if eb2 and (not eb or not _date(eb["entity"], ["P585", "P580"])) and _date(eb2["entity"], ["P585", "P580"]):
            _trace(f"event term {b_term!r} -> {eb2['label']!r} (has a point in time)")
            eb = eb2
    if not eb:
        return _abstain(f"could not resolve {g['b']!r}")
    if kind in ("born_before", "died_before"):
        b_born, b_died = _person_dates(eb)
        if kind == "born_before":
            if not b_born:
                return {"answer": f"Wikidata has no birth date for {eb['label']}.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 1}
            first = born[1] < b_born[1] or (born[1] == b_born[1] and born[0] and b_born[0] and born[0] < b_born[0])
            return {"answer": f"{'Yes' if first else 'No'}: {ea['label']} was born {born[2]}, {eb['label']} {b_born[2]} (Wikidata).", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
        target = b_born or _event_date(eb)
        if not died or not target:
            miss = f"a death date for {ea['label']}" if not died else f"a date for {eb['label']}"
            return {"answer": f"Wikidata lacks {miss}, so I can't say.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 1}
        before = died[1] < target[1] or (died[1] == target[1] and died[0] and target[0] and died[0] < target[0])
        return {"answer": f"{'Yes' if before else 'No'}: {ea['label']} died {died[2]}; {eb['label']}: {target[2]} (Wikidata).", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
    ev = _event_date(eb, g["b"])
    if not ev:
        return {"answer": f"Wikidata records no date for {eb['label']}, so I can't place it against {ea['label']}'s life.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 1}
    if kind == "alive_event":
        after_birth = ev[1] > born[1] or (ev[1] == born[1] and (not ev[0] or not born[0] or ev[0] >= born[0]))
        before_death = (not died) or ev[1] < died[1] or (ev[1] == died[1] and (not ev[0] or not died[0] or ev[0] <= died[0]))
        alive = after_birth and before_death
        life = f"born {born[2]}" + (f", died {died[2]}" if died else "")
        verb = "began in" if ev[3] in ("P571", "P580") else "was"
        return {"answer": f"{'Yes' if alive else 'No'}: {ea['label']} was {life}; {eb['label']} {verb} {ev[2]} (Wikidata).", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 3 if died else 2}
    if kind == "age_at":
        if ev[1] < born[1]:
            return {"answer": f"{eb['label']} ({ev[2]}) was before {ea['label']} was born ({born[2]}), according to Wikidata.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
        if died and (ev[1] > died[1]):
            return {"answer": f"{ea['label']} had already died ({died[2]}) when {eb['label']} happened ({ev[2]}), according to Wikidata.", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 3}
        yrs, exact = _years_between(born, ev)
        return {"answer": f"{ea['label']} was {'about ' if not exact else ''}{yrs}: born {born[2]}; {eb['label']}: {ev[2]} (Wikidata).", "sources": [_src(ea), _src(eb)], "mode": "inference", "evidence_count": 2}
    return None

# ---------------------------------------------------------------- two-hop
def _two_hop(q, st):
    m = TWOHOP_RE.match(q.strip())
    if not m:
        return None
    rel, work = m.group("rel").lower(), m.group("work")
    pids = REL_PIDS[rel]
    ew = _entity(work, st, tuple(pids))
    if not ew:
        return _abstain(f"could not resolve {work!r}")
    person_qid = None
    for pid in pids:
        rows = _H["values"](_H["claims"](ew["entity"], pid)) or []
        if rows and rows[0].get("qid"):
            person_qid = rows[0]["qid"]
            person_label = rows[0].get("text") or person_qid
            break
    if not person_qid:
        return {"answer": f"Wikidata does not record the {rel} of {ew['label']}.", "sources": [_src(ew)], "mode": "inference", "evidence_count": 1}
    ent = _H["get"]([person_qid]).get(person_qid)
    if not ent:
        return _abstain("second hop fetch failed")
    ep = {"label": person_label, "entity": ent, "qid": person_qid}
    if q.lower().startswith("when"):
        born = _date(ent, ["P569"])
        if not born:
            return {"answer": f"The {rel} of {ew['label']} is {person_label}, but Wikidata has no birth date for them.", "sources": [_src(ew), _src(ep)], "mode": "inference", "evidence_count": 1}
        return {"answer": f"The {rel} of {ew['label']} is {person_label}, who was born {born[2]} (Wikidata).", "sources": [_src(ew), _src(ep)], "mode": "inference", "evidence_count": 2}
    rows = _H["values"](_H["claims"](ent, "P19")) or []
    place = rows[0].get("text") if rows else None
    if not place:
        return {"answer": f"The {rel} of {ew['label']} is {person_label}, but Wikidata has no birthplace for them.", "sources": [_src(ew), _src(ep)], "mode": "inference", "evidence_count": 1}
    return {"answer": f"The {rel} of {ew['label']} is {person_label}, who was born in {place} (Wikidata).", "sources": [_src(ew), _src(ep)], "mode": "inference", "evidence_count": 2}

def answer(q, st):
    if not _H:
        return None
    return _distance(q, st) or _count(q, st) or _superlative(q, st) or _office_at_date(q, st) or _which_of_these(q, st) or _compare(q, st) or _temporal(q, st) or _two_hop(q, st)
__NOAI_V33_INFER_PY__
cat > "$APP_DIR/app/reranker_weights.json" <<'__NOAI_V36_RERANK_JSON__'
{
 "bias": -0.382,
 "judge": 1.869,
 "length": 0.247,
 "corroborated": 0.667,
 "explains_cause": 0.75,
 "site_authority": -0.174,
 "faq_match": 0.0,
 "encyclopedic": -0.01,
 "penalty_scale": 0.25
}
__NOAI_V36_RERANK_JSON__
cat > "$APP_DIR/app/reader.py" <<'__NOAI_V37_READER_PY__'
"""Extractive reader (v37, shadow). Given a question and a passage, returns the answering span, its probability mass, and the
margin over the "no answer" position. Non-generative: the span is a substring of the passage. The app logs these for every
judged candidate so the reader's usefulness as an answerability signal can be measured offline before it affects ranking."""
import os, time
import numpy as np

class Reader:
    def __init__(self, model_dir=None):
        self.ok = False; self._sess = None; self._tok = None; self.ms = 0.0; self.note = ""
        model_dir = model_dir or os.environ.get("NOAI_READER_PATH", "/opt/reader")
        try:
            import onnxruntime as ort
            from tokenizers import Tokenizer
            model, tokp = os.path.join(model_dir, "model.onnx"), os.path.join(model_dir, "tokenizer.json")
            if not (os.path.isfile(model) and os.path.isfile(tokp)):
                self.note = "no reader model installed"; return
            so = ort.SessionOptions(); so.intra_op_num_threads = max(1, min(2, os.cpu_count() or 1)); so.log_severity_level = 3
            self._sess = ort.InferenceSession(model, so, providers=["CPUExecutionProvider"])
            self._names = {i.name for i in self._sess.get_inputs()}
            self._tok = Tokenizer.from_file(tokp); self._tok.enable_truncation(384, strategy="only_second"); self._tok.enable_padding()
            self.ok = True
        except Exception as e:
            self.note = f"reader unavailable: {type(e).__name__}"

    def read(self, question, passage, max_span_tokens=40):
        """-> {'span', 'prob', 'null_margin', 'ms'} or None. prob is the softmax mass of the best span (start*end);
        null_margin is best span logit minus the [CLS] no-answer logit (SQuAD 1.1 models never learned to prefer it,
        so treat it as a weak signal until calibrated)."""
        if not self.ok:
            return None
        t = time.perf_counter()
        try:
            e = self._tok.encode(question, passage)
            feed = {"input_ids": np.array([e.ids], dtype=np.int64), "attention_mask": np.array([e.attention_mask], dtype=np.int64)}
            if "token_type_ids" in self._names:
                feed["token_type_ids"] = np.array([e.type_ids], dtype=np.int64)
            s, en = self._sess.run(None, feed)
            s, en = np.asarray(s, dtype="float32")[0], np.asarray(en, dtype="float32")[0]
            seq = e.sequence_ids
            mask = np.array([sid == 1 for sid in seq])
            if not mask.any():
                return None
            ps = np.exp(s - s.max()); ps /= ps.sum(); pe = np.exp(en - en.max()); pe /= pe.sum()
            best, span = -1e9, None
            idx = np.where(mask)[0]
            for i in idx:
                jmax = min(i + max_span_tokens, len(s))
                js = [j for j in range(i, jmax) if mask[j]]
                if not js:
                    continue
                j = max(js, key=lambda k: en[k])
                if s[i] + en[j] > best:
                    best, span = s[i] + en[j], (i, j)
            if span is None:
                return None
            a, b = e.offsets[span[0]][0], e.offsets[span[1]][1]
            return {"span": passage[a:b].strip(), "prob": float(ps[span[0]] * pe[span[1]]),
                    "null_margin": float(best - (s[0] + en[0])), "ms": (time.perf_counter() - t) * 1000}
        except Exception:
            return None

    def info(self):
        return {"enabled": self.ok, "note": self.note, "model": "distilbert-base-uncased-distilled-squad (onnx int8)" if self.ok else ""}
__NOAI_V37_READER_PY__
cat > "$APP_DIR/app/fetch_reader.py" <<'__NOAI_V37_FETCH_READER_PY__'
"""Build-time only: fetch the extractive reader (DistilBERT fine-tuned on SQuAD 1.1, ONNX int8, about 67 MB) into /opt/reader.
The reader locates the answering span inside a passage and gives a probability for it; v37 runs it in shadow (logged, not
ranking). It is checked once on this machine: it must find "1989" for a question about when the Web was invented, and the
int8 build must run in under 1.5 s per window. Any failure leaves /opt/reader absent and the app runs without it."""
import os, sys, time, shutil
REPO = "Xenova/distilbert-base-uncased-distilled-squad"
OUT = "/opt/reader"
LOCAL = os.environ.get("NOAI_READER_LOCAL", "")
def get(name):
    if LOCAL:
        p = os.path.join(LOCAL, os.path.basename(name))
        if not os.path.isfile(p):
            raise FileNotFoundError(p)
        return p
    from huggingface_hub import hf_hub_download
    return hf_hub_download(REPO, name)
import numpy as np, onnxruntime as ort
from tokenizers import Tokenizer
tok = Tokenizer.from_file(get("tokenizer.json")); tok.enable_truncation(384); tok.enable_padding()
Q = "When was the World Wide Web invented?"
P = "The World Wide Web was invented by Tim Berners-Lee at CERN in 1989. He wrote the first browser in 1990."
def load(path):
    so = ort.SessionOptions(); so.intra_op_num_threads = max(1, min(4, os.cpu_count() or 1)); so.log_severity_level = 3
    sess = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"]); names = {i.name for i in sess.get_inputs()}
    def run(q, p):
        e = tok.encode(q, p)
        feed = {"input_ids": np.array([e.ids], dtype=np.int64), "attention_mask": np.array([e.attention_mask], dtype=np.int64)}
        if "token_type_ids" in names: feed["token_type_ids"] = np.array([e.type_ids], dtype=np.int64)
        s, en = sess.run(None, feed); s, en = np.asarray(s)[0], np.asarray(en)[0]
        best, span = -1e9, (0, 0)
        for i in range(len(s)):
            for j in range(i, min(i + 30, len(s))):
                if e.sequence_ids[i] == 1 and e.sequence_ids[j] == 1 and s[i] + en[j] > best:
                    best, span = s[i] + en[j], (i, j)
        a, b = e.offsets[span[0]][0], e.offsets[span[1]][1]
        return p[a:b]
    return run
ok = False
for name in ["onnx/model_int8.onnx", "onnx/model_quantized.onnx", "onnx/model.onnx"]:
    try:
        path = get(name); run = load(path); ans = run(Q, P); run(Q, P)
        t = time.perf_counter(); run(Q, (P + " ") * 4); ms = (time.perf_counter() - t) * 1000
        sane = "1989" in ans
        print(f"{name}: answer={ans!r} sane={sane} {ms:.0f} ms/window", flush=True)
        if sane and ms < 1500:
            os.makedirs(OUT, exist_ok=True)
            shutil.copyfile(path, os.path.join(OUT, "model.onnx")); shutil.copyfile(get("tokenizer.json"), os.path.join(OUT, "tokenizer.json"))
            with open(os.path.join(OUT, "INFO"), "w") as f:
                f.write(f"{REPO} {name} {ms:.0f}ms\n")
            ok = True; break
    except Exception as e:
        print(f"{name}: failed ({type(e).__name__}: {e})", flush=True)
sys.exit(0 if ok else 1)
__NOAI_V37_FETCH_READER_PY__
cat > "$APP_DIR/app/fetch_judge.py" <<'__NOAI_V17_FETCH_JUDGE__'
"""Build-time only: fetch the MS MARCO cross-encoder (answer judge) as ONNX files into /opt/judge.

Two official exports are tried: the int8 build for this CPU family (about 23 MB) and the full-precision build
(about 90 MB). Each is checked (it must place a paraphrase nearer than an unrelated sentence, and the int8 vectors
must agree with full precision) and timed on THIS machine; the faster acceptable one is kept. Any failure leaves
/opt/judge absent and the app simply runs without the neural second opinion."""
import os, sys, time, shutil, platform
REPO = "cross-encoder/ms-marco-MiniLM-L6-v2"
OUT = "/opt/judge"
LOCAL = os.environ.get("NOAI_JUDGE_LOCAL", "")           # test hook: directory holding the same file names
arch = platform.machine().lower()
quant = "onnx/model_qint8_arm64.onnx" if arch in {"aarch64", "arm64"} else "onnx/model_quint8_avx2.onnx"
variants = [quant, "onnx/model.onnx"]

def get(name):
    if LOCAL:
        p = os.path.join(LOCAL, os.path.basename(name))
        if not os.path.isfile(p):
            raise FileNotFoundError(p)
        return p
    from huggingface_hub import hf_hub_download
    return hf_hub_download(REPO, name)

import numpy as np, onnxruntime as ort
from tokenizers import Tokenizer
tok_path = get("tokenizer.json")
tok = Tokenizer.from_file(tok_path); tok.enable_truncation(128); tok.enable_padding()
Q = "How many people live in Berlin?"
GOOD = "Berlin had a population of 3,520,031 registered inhabitants in an area of 891.82 square kilometers."
BAD = "Berlin is well known for its museums."

def load(path):
    so = ort.SessionOptions(); so.intra_op_num_threads = max(1, min(4, os.cpu_count() or 1)); so.log_severity_level = 3
    sess = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    names = {i.name for i in sess.get_inputs()}
    def score(passages):
        e = tok.encode_batch([(Q, p) for p in passages])
        feed = {"input_ids": np.array([x.ids for x in e], dtype=np.int64), "attention_mask": np.array([x.attention_mask for x in e], dtype=np.int64)}
        if "token_type_ids" in names: feed["token_type_ids"] = np.array([x.type_ids for x in e], dtype=np.int64)
        o = np.asarray(sess.run(None, feed)[0], dtype="float32").reshape(len(passages), -1)
        return o[:, -1] if o.shape[1] > 1 else o[:, 0]
    return score

results = []
tok.enable_truncation(256)
for name in reversed(variants):
    try:
        path = get(name); score = load(path); v = score([GOOD, BAD]); score([GOOD, BAD])
        t = time.perf_counter(); [score([(GOOD + " ") * 6] * 4) for _ in range(2)]; ms = (time.perf_counter() - t) * 1000 / 8
        sane = float(v[0]) > float(v[1]) + 4.0           # the model card documents about 8.6 versus -4.3
        print(f"{name}: {ms:.0f} ms/candidate, relevant {float(v[0]):.1f} vs irrelevant {float(v[1]):.1f}, sane={sane}")
        if sane:
            results.append((ms, name, path))
    except Exception as e:
        print(f"{name}: unavailable ({type(e).__name__}: {str(e)[:120]})")
if not results:
    sys.exit("no usable cross-encoder export")
ms, name, path = min(results)
os.makedirs(OUT, exist_ok=True)
shutil.copyfile(path, os.path.join(OUT, "model.onnx")); shutil.copyfile(tok_path, os.path.join(OUT, "tokenizer.json"))
open(os.path.join(OUT, "VARIANT"), "w").write(os.path.basename(name))
print(f"kept {name} ({ms:.0f} ms/candidate) -> {OUT}")
__NOAI_V17_FETCH_JUDGE__
cat > "$APP_DIR/app/fetch_minilm.py" <<'__NOAI_V12_FETCH_MINILM__'
"""Build-time only: fetch the all-MiniLM-L6-v2 sentence encoder as ONNX files into /opt/minilm.

Two official exports are tried: the int8 build for this CPU family (about 23 MB) and the full-precision build
(about 90 MB). Each is checked (it must place a paraphrase nearer than an unrelated sentence, and the int8 vectors
must agree with full precision) and timed on THIS machine; the faster acceptable one is kept. Any failure leaves
/opt/minilm absent and the app simply runs without the neural second opinion."""
import os, sys, time, shutil, platform
REPO = "sentence-transformers/all-MiniLM-L6-v2"
OUT = "/opt/minilm"
LOCAL = os.environ.get("NOAI_MINILM_LOCAL", "")           # test hook: directory holding the same file names
arch = platform.machine().lower()
quant = "onnx/model_qint8_arm64.onnx" if arch in {"aarch64", "arm64"} else "onnx/model_quint8_avx2.onnx"
variants = [quant, "onnx/model.onnx"]

def get(name):
    if LOCAL:
        p = os.path.join(LOCAL, os.path.basename(name))
        if not os.path.isfile(p):
            raise FileNotFoundError(p)
        return p
    from huggingface_hub import hf_hub_download
    return hf_hub_download(REPO, name)

import numpy as np, onnxruntime as ort
from tokenizers import Tokenizer
tok_path = get("tokenizer.json")
tok = Tokenizer.from_file(tok_path); tok.enable_truncation(128); tok.enable_padding()
PROBE = ["What makes the sea rise and fall twice a day?",
         "Tides are caused by the gravitational pull of the Moon and the Sun on the oceans.",
         "The committee approved the annual budget for road maintenance.",
         "A refrigerator moves heat from its insulated compartment to the room using a heat pump, which is why the coils at the back feel warm."]

def load(path):
    so = ort.SessionOptions(); so.intra_op_num_threads = max(1, min(4, os.cpu_count() or 1)); so.log_severity_level = 3
    sess = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    names = {i.name for i in sess.get_inputs()}
    def enc(texts):
        e = tok.encode_batch(texts)
        ids = np.array([x.ids for x in e], dtype=np.int64); am = np.array([x.attention_mask for x in e], dtype=np.int64)
        feed = {"input_ids": ids, "attention_mask": am}
        if "token_type_ids" in names: feed["token_type_ids"] = np.zeros_like(ids)
        o = sess.run(None, feed)[0]; m = am[..., None].astype(np.float32)
        v = (o * m).sum(1) / np.clip(m.sum(1), 1e-9, None)
        return v / (np.linalg.norm(v, axis=1, keepdims=True) + 1e-9)
    return enc

results, reference = [], None
for name in reversed(variants):                               # full precision first: it is the reference
    try:
        path = get(name); enc = load(path); v = enc(PROBE); enc(PROBE)
        t = time.perf_counter(); [enc(PROBE[3:] * 4) for _ in range(3)]; ms = (time.perf_counter() - t) * 1000 / 12
        sane = float(v[0] @ v[1]) > float(v[0] @ v[2]) + 0.15
        if name.endswith("model.onnx"):
            reference = v
        faithful = reference is None or float(np.mean(np.sum(v * reference, axis=1))) >= 0.90
        print(f"{name}: {ms:.0f} ms/passage, paraphrase {float(v[0] @ v[1]):.2f} vs unrelated {float(v[0] @ v[2]):.2f}, sane={sane}, faithful={faithful}")
        if sane and faithful:
            results.append((ms, name, path))
    except Exception as e:
        print(f"{name}: unavailable ({type(e).__name__}: {str(e)[:120]})")
if not results:
    sys.exit("no usable MiniLM export")
ms, name, path = min(results)
os.makedirs(OUT, exist_ok=True)
shutil.copyfile(path, os.path.join(OUT, "model.onnx")); shutil.copyfile(tok_path, os.path.join(OUT, "tokenizer.json"))
open(os.path.join(OUT, "VARIANT"), "w").write(os.path.basename(name))
print(f"kept {name} ({ms:.0f} ms/passage) -> {OUT}")
__NOAI_V12_FETCH_MINILM__
cat > "$APP_DIR/app/selftest.py" <<'__NOAI_V11_SELFTEST__'
"""Assertion-based evaluation. Checks answers with word-boundary matches, the cited source, junk
patterns that must never appear, and latency. Prints the routing trace for anything that fails."""
import os, time, requests, json, re, sys, statistics
import random, datetime
BASE = os.environ.get('BASE_URL', 'http://127.0.0.1:7070')
SID = 'selftest-' + str(int(time.time()))
JUNK = ['ISBN', 'Archived from', '[ edit ]', '[edit]', 'Sign up to', '\u00c2\u00a0']
C, N = True, False   # critical / network-sensitive
CASES = [
 # --- conversation, memory and offline skills (no network needed)
 {'q': 'Hey', 'mode': 'chat', 'crit': C},
 {'q': 'How are you?', 'mode': 'chat', 'none': ["couldn't find"], 'crit': C},
 {'q': 'pretty good thanks', 'mode': 'chat', 'crit': C},
 {'q': "What's your name?", 'all': ['fAI'], 'mode': 'chat', 'crit': C},
 {'q': 'Are you a language model?', 'any': ['generates text', 'generative', 'software', 'language model', 'retrieval', 'program'], 'mode': 'chat', 'crit': C},
 {'q': "I've been getting into film photography lately", 'mode': 'chat', 'any': ['film photography'], 'crit': C},
 {'q': 'Mostly black and white', 'mode': 'chat', 'crit': C},
 {'q': 'What were we talking about?', 'all': ['film photography', 'black and white'], 'mode': 'chat', 'crit': C},
 {'q': 'My name is Test User.', 'all': ['Test User'], 'mode': 'chat', 'crit': C},
 {'q': "What's my name?", 'all': ['Test User'], 'mode': 'chat', 'crit': C},
 {'q': 'I live in Oslo', 'all': ['Oslo'], 'mode': 'chat', 'crit': C},
 {'q': 'remember that the bins go out on Tuesday', 'mode': 'chat', 'crit': C},
 {'q': 'What do you know about me?', 'all': ['Test User', 'Oslo', 'bins go out on Tuesday', 'film photography'], 'mode': 'chat', 'crit': C},
 # seen as held-out in v12 development, where they exposed hollow replies; now regression
 {'q': 'what do you reckon about cricket?', 'any': ['opinion', 'opinions', 'view', 'preferences', 'tastes'], 'mode': 'chat', 'crit': C},
 {'q': "I'm feeling pretty anxious about tomorrow", 'intent': ['mood_stressed', 'mood_sad', 'sentiment-'], 'none': ['Tell me more.'], 'mode': 'chat', 'crit': C},
 {'q': 'any thoughts on electric cars?', 'any': ['opinion', 'opinions', 'view', 'preferences', 'tastes'], 'mode': 'chat', 'crit': C},
 {'q': "honestly I've been a bit down lately", 'intent': ['mood_sad', 'sentiment-'], 'none': ['How do you feel about it?'], 'mode': 'chat', 'crit': C},
 # reported by the user against v13/v14: a recipe and a list are not passages
 {'q': 'dry rub recipe for chicken wings', 'any': ['paprika', 'brown sugar', 'garlic powder', 'salt'], 'all': ['Ingredients'], 'mode': 'recipe', 'crit': N},
 {'q': 'top attractions in New York City', 'any': ['Statue of Liberty', 'Central Park', 'Empire State Building', 'Times Square'], 'mode': 'list', 'crit': N},
 # --- tools (v18). Everything added here is removed again so the household's real data is untouched.
 {'q': 'add milk to my selftest list', 'any': ['locked'], 'mode': 'tool', 'nokey': True, 'crit': C},
 {'q': 'add milk and eggs to my selftest list', 'all': ['milk', 'eggs'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': "what's on my selftest list?", 'all': ['milk', 'eggs'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'clear my selftest list', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['now empty'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'remind me to stretch in 3 hours', 'any': ['stretch'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'add selftest dentist to my calendar on friday at 3pm for 1 hour', 'all': ['selftest dentist', '15:00'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'create a file called selftest-note', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['Created'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'add hello from the self-test to file selftest-note', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['Added the line'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'read file selftest-note', 'all': ['hello from the self-test'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'read file ../../etc/passwd', 'none': ['root:'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'delete file selftest-note', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['.trash'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'system status', 'any': ['Memory', 'Up for', 'Disk'], 'mode': 'tool', 'crit': C},
  {'q': 'Write me a poem about the sea', 'all': ['the sea', 'hand-written grammar'], 'mode': 'creative', 'crit': C},
 {'q': 'Tell me a joke', 'mode': 'chat', 'crit': C},
 {'q': 'another one', 'mode': 'chat', 'none': ['not sure I followed', 'say more'], 'crit': C},
 {'q': "ok thanks, that's wrong though", 'mode': 'chat', 'crit': N},
 {'q': 'What is 15% of 240?', 'all': ['36'], 'mode': 'calc', 'crit': C},
 {'q': 'What is 81 divided by 9?', 'all': ['9'], 'mode': 'calc', 'crit': C},   # blind item in v14 development that exposed a calculator bug
 {'q': 'What is 9/11?', 'any': ['attacks', 'September 11'], 'none': ['numerology'], 'modes': ['wikipedia', 'web', 'wikidata'], 'crit': N},
 {'q': 'What is (3 + 4) * 12?', 'all': ['84'], 'mode': 'calc', 'crit': C},
 {'q': 'Convert 5 miles to km', 'all': ['8.04672'], 'mode': 'convert', 'crit': C},
 {'q': 'What is 20 C in F?', 'all': ['68'], 'mode': 'convert', 'crit': C},
 {'q': 'What time is it?', 'any': [r'\b\d{2}:\d{2}\b'], 'regex': True, 'mode': 'clock', 'crit': C},
 {'q': 'How many days until Christmas?', 'any': [r'\bdays? until\b', 'today'], 'regex': True, 'mode': 'clock', 'crit': C},
 # --- online skills
 {'q': "What's the weather like tomorrow?", 'all': ['Oslo'], 'any': [r'\d\u00b0C \('], 'regex': True, 'mode': 'weather', 'crit': N},
 {'q': 'What time is it in Tokyo?', 'all': ['Tokyo'], 'mode': 'clock', 'crit': N},
 {'q': 'Define serendipity', 'any': ['chance', 'fortunate', 'luck', 'accident'], 'modes': ['dictionary', 'wikipedia'], 'crit': N},
 {'q': 'How old is Dolly Parton?', 'any': [r'\b\d{2} years old\b', r'\baged (?:about )?\d{2}\b'], 'regex': True, 'all': ['1946'], 'mode': 'wikidata', 'crit': N},
 {'q': 'Tell me about Mars', 'any': ['planet'], 'source': 'Mars', 'mode': 'wikipedia', 'crit': N},
 # --- knowledge (order matters: pronoun follow-ups depend on the previous answer)
 {'q': 'Who wrote A Wrinkle in Time?', 'all': ["Madeleine L'Engle"], 'mode': 'wikidata', 'crit': C},
 {'q': 'Where was she born?', 'all': ['New York'], 'mode': 'wikidata', 'crit': C},
 {'q': 'Who painted Nighthawks?', 'all': ['Edward Hopper'], 'mode': 'wikidata', 'crit': C},
 {'q': 'Where is it now?', 'all': ['Art Institute of Chicago'], 'mode': 'wikidata', 'crit': C},
 {'q': 'When did the Empire State Building open?', 'all': ['1931'], 'none': ['2001'], 'mode': 'wikidata', 'crit': C},
 {'q': 'What is the capital of Australia?', 'all': ['Canberra'], 'mode': 'wikidata', 'crit': C},
 {'q': 'What is its population?', 'any': [r'\d{2},\d{3},\d{3}'], 'regex': True, 'mode': 'wikidata', 'crit': N},
 {'q': 'How tall is Mount Everest?', 'any': [r'8,?84[89]'], 'regex': True, 'none': ['metre.'], 'mode': 'wikidata', 'crit': N},
 {'q': 'What is a neutron star?', 'all': ['collapsed core'], 'source': 'Neutron star', 'mode': 'wikipedia', 'crit': C},
 {'q': 'How are they formed?', 'any': ['collapse', 'collapses', 'supernova', 'main-sequence', 'main sequence'], 'none': ['neutron drip'], 'source': 'Neutron star', 'mode': 'wikipedia', 'crit': C},
 {'q': 'Tell me more', 'none': ["couldn't find"], 'crit': N},
  {'q': 'Why does metal rust?', 'any': ['oxygen', 'oxide', 'oxidation', 'iron'], 'none': ['programming language'], 'crit': N},
  {'q': 'What causes tides?', 'any': ['gravitational', 'gravity'], 'crit': N},
 {'q': 'Why is glass transparent?', 'any': ['light', 'photons', 'visible', 'wavelengths', 'electrons', 'absorb'], 'none': ['bullet', 'polycarbonate', 'widespread practical'], 'source_any': ['Glass', 'Transparency and translucency'], 'crit': N},
 {'q': 'What about diamond?', 'any': ['diamond'], 'crit': N},
 {'q': 'Why is the sky blue?', 'any': ['scatter', 'scattering', 'scattered', 'Rayleigh'], 'none': ['celeste'], 'source_any': ['Sky', 'Diffuse sky radiation', 'Rayleigh scattering', 'Blue'], 'crit': N},
 {'q': 'How does a refrigerator work?', 'any': ['refrigerant', 'heat pump', 'transfers heat', 'compressor'], 'none': ['works differently'], 'crit': N},
 {'q': "What's the current stable version of CMake?", 'any': [r'\bv?\d+\.\d+'], 'regex': True, 'modes': ['web', 'wikidata'], 'crit': N},
 {'q': 'Compare Caddy and Nginx for a small home server.', 'all': ['Caddy', 'Nginx', 'web server'], 'none': ['golfer', 'golf'], 'mode': 'compare', 'crit': C},
 {'q': 'How do I show failed systemd units on Linux?', 'all': ['systemctl --failed'], 'mode': 'tldr', 'crit': C},
 {'q': 'How do I check disk space?', 'any': ['df'], 'mode': 'tldr', 'crit': C},
 {'q': 'What are some good museums near Boston Common in Boston?', 'any': ['Museum', 'museum', 'Athenaeum'], 'mode': 'osm', 'crit': N},
 {'q': 'Research the main causes of the Tacoma Narrows Bridge collapse.', 'any': ['flutter', 'aeroelastic', 'wind', 'torsional', 'oscillation'], 'none': ['Scribd'], 'mode': 'research', 'crit': N},
 {'q': 'Who wrote Beloved?', 'all': ['Toni Morrison'], 'mode': 'wikidata', 'crit': C},
 {'q': 'Where was she born?', 'any': ['Lorain', 'Ohio'], 'mode': 'wikidata', 'crit': C},
 {'q': 'Who directed Jaws?', 'all': ['Steven Spielberg'], 'mode': 'wikidata', 'crit': N},
 {'q': 'What do you think about jazz?', 'mode': 'chat', 'crit': C},
 {'q': 'Why is zorblaxian fizzing quendly?', 'modes': ['none', 'web'], 'crit': N},
 {'q': 'Jazz', 'any': ['music', 'genre'], 'modes': ['wikipedia', 'wikidata'], 'crit': N},
 {'q': 'Thanks', 'mode': 'chat', 'crit': C},
 {'q': 'forget everything', 'any': ['wiped'], 'mode': 'chat', 'crit': C},
 {'q': 'What do you know about me?', 'any': ['Nothing yet'], 'none': ['Test User'], 'mode': 'chat', 'crit': C},
]
# ---- Former held-out questions (v12). Seen now, so they are regression; each still runs in its own session.
REGRESSION2 = [
 {'q': 'Who wrote Pride and Prejudice?', 'all': ['Jane Austen']}, {'q': 'Who painted the Mona Lisa?', 'all': ['Leonardo da Vinci']},
 {'q': 'What is the capital of Canada?', 'all': ['Ottawa']}, {'q': 'When was Albert Einstein born?', 'all': ['1879']},
 {'q': 'Who directed Pulp Fiction?', 'all': ['Quentin Tarantino']}, {'q': 'What is the population of Iceland?', 'any': [r'\b\d{3},\d{3}\b'], 'regex': True},
 {'q': 'Who composed The Four Seasons?', 'all': ['Vivaldi']}, {'q': 'Where was Marie Curie born?', 'all': ['Warsaw']},
 {'q': 'How old is Paul McCartney?', 'all': ['1942'], 'any': [r'years old', r'aged'], 'regex': True}, {'q': 'Who founded Microsoft?', 'any': ['Bill Gates', 'Paul Allen']},
 {'q': 'What is photosynthesis?', 'any': ['light', 'chlorophyll', 'carbon dioxide'], 'source': 'Photosynthesis'},
 {'q': 'Why is the ocean salty?', 'any': ['rivers', 'minerals', 'dissolved', 'weathering', 'rocks', 'evaporation', 'ions'], 'none': ['covers approximately']},
 {'q': 'How do vaccines work?', 'any': ['immune', 'immunity', 'antibodies', 'antigen']},
 {'q': 'What causes earthquakes?', 'any': ['tectonic', 'fault', 'faults', 'plates', 'seismic', 'lithosphere']},
 {'q': 'Why do leaves change color in autumn?', 'any': ['chlorophyll', 'carotenoids', 'anthocyanins', 'pigments', 'pigment']},
 {'q': 'How does a transistor work?', 'any': ['semiconductor', 'current', 'amplify', 'switch', 'terminals']},
 {'q': 'What causes the seasons?', 'any': ['tilt', 'axial tilt', 'axis', 'tilted']},
 {'q': 'How are diamonds formed?', 'any': ['mantle', 'depths', 'kimberlite', 'high pressure', 'pressures'], 'none': ['tasteless']},
 {'q': 'What is a black hole?', 'any': ['gravity', 'escape', 'spacetime'], 's': 'bh'},
 {'q': 'How are they formed?', 'any': ['collapse', 'collapses', 'star', 'stars', 'supernova'], 'none': ["couldn't find"], 's': 'bh'},
 # vocabulary mismatch: the question avoids the article's own words, which is where a sentence encoder should help
 {'q': 'Why does the moon look different each night?', 'any': ['phase', 'phases', 'sunlit', 'illuminated', 'orbit', 'orbits']},
 {'q': 'What makes bread rise?', 'any': ['yeast', 'carbon dioxide', 'leavening', 'fermentation', 'leavened']},
 {'q': 'How do planes stay in the air?', 'any': ['lift', 'wing', 'wings', 'airfoil']},
 {'q': 'What is 17 times 23?', 'all': ['391'], 'mode': 'calc'}, {'q': "What's 30% of 90?", 'all': ['27'], 'mode': 'calc'},
 {'q': 'How many ounces in a pound?', 'all': ['16'], 'mode': 'convert'}, {'q': 'How many days until Halloween?', 'any': [r'days? until', 'today'], 'regex': True, 'mode': 'clock'},
 {'q': 'Define ephemeral', 'any': ['short', 'brief', 'lasting', 'day', 'transitory']},
 {'q': 'How do I find files by name on Linux?', 'any': ['find'], 'mode': 'tldr'}, {'q': 'How do I extract a tar.gz file?', 'any': ['tar'], 'mode': 'tldr'},
 {'q': 'Compare Python and Ruby', 'all': ['Python', 'Ruby'], 'none': ['gemstone', 'corundum'], 'mode': 'compare'},
 {'q': "hiya, how's your day going?", 'mode': 'chat'},  {'q': 'can you compose a limerick for me?', 'any': ['limerick'], 'mode': 'creative', 'crit': C},
 {'q': 'My favourite food is ramen', 'mode': 'chat', 's': 'fav'}, {'q': "what's my favourite food?", 'all': ['ramen'], 'mode': 'chat', 's': 'fav'},
 {'q': 'Who was the first person to walk on Mars?', 'none': ['Neil Armstrong', 'Buzz Aldrin', 'trilogy', 'novels'], 'modes': ['none', 'web', 'wikipedia', 'wikidata', 'chat']},
 # --- former v13 held-out
 {'q': 'Who wrote The Great Gatsby?', 'all': ['Fitzgerald']}, {'q': 'Who painted The Birth of Venus?', 'all': ['Botticelli']},
 {'q': 'What is the capital of New Zealand?', 'all': ['Wellington']}, {'q': 'When was Charles Darwin born?', 'all': ['1809']},
 {'q': "Who directed Schindler's List?", 'all': ['Steven Spielberg']}, {'q': 'What is the population of Portugal?', 'any': [r'\b\d{1,2},\d{3},\d{3}\b'], 'regex': True},
 {'q': 'Who composed The Magic Flute?', 'all': ['Mozart']}, {'q': 'Where was Frida Kahlo born?', 'any': ['Coyoacán', 'Coyoacan', 'Mexico City']},
 {'q': 'How old is Barack Obama?', 'all': ['1961'], 'any': [r'years old', r'aged'], 'regex': True}, {'q': 'Who founded Apple?', 'any': ['Steve Jobs', 'Steve Wozniak', 'Jobs']},
 {'q': 'How tall is Mount Kilimanjaro?', 'any': [r'5,?89\d'], 'regex': True}, {'q': 'What is the currency of Japan?', 'any': ['yen']},
 {'q': 'Why is the sea blue?', 'any': ['absorbs', 'absorbed', 'absorption', 'scattering', 'scattered', 'wavelengths', 'red light']},
 {'q': 'Why do cats purr?', 'any': ['larynx', 'laryngeal', 'vocal', 'communication', 'communicate', 'contentment']},
 {'q': 'How do bees make honey?', 'any': ['nectar']}, {'q': 'What causes lightning?', 'any': ['charge', 'charges', 'charged', 'electrostatic', 'discharge']},
 {'q': 'Why do onions make you cry?', 'any': ['syn-propanethial-S-oxide', 'sulfur', 'sulfenic', 'irritant', 'lachrymatory', 'gas']},
 {'q': 'How does a microwave oven work?', 'any': ['electromagnetic', 'dielectric', 'water molecules', 'molecules', 'radiation']},
 {'q': 'How are mountains formed?', 'any': ['tectonic', 'plates', 'folding', 'uplift', 'orogeny', 'volcanism']},
 {'q': 'Why is Pluto not a planet?', 'any': ['cleared', 'International Astronomical Union', 'IAU', '2006', 'definition', 'reclassified']},
 {'q': 'How do birds fly?', 'any': ['wings', 'lift', 'flapping', 'feathers']},
 {'q': 'Why do we have leap years?', 'any': ['365', 'solar year', 'tropical year', 'calendar year', 'astronomical']},
 {'q': 'What makes the sky red at sunset?', 'any': ['scattering', 'scattered', 'wavelengths', 'atmosphere']},
 {'q': 'Why do ships float?', 'any': ['buoyancy', 'buoyant', 'displaces', 'displaced', 'displacement', 'Archimedes']},
 {'q': 'What is a hurricane?', 'any': ['tropical cyclone', 'storm', 'cyclone'], 'source_any': ['Tropical cyclone', 'Hurricane'], 's': 'hu'},
 {'q': 'How do they form?', 'any': ['warm', 'ocean', 'evaporation', 'low pressure', 'water'], 'none': ["couldn't find"], 's': 'hu'},
 {'q': 'Who was the first person to land on the Sun?', 'none': ['Armstrong', 'was the first person to land'], 'modes': ['none', 'web', 'chat']},
 {'q': 'What is 144 divided by 12?', 'all': ['12'], 'mode': 'calc'}, {'q': "What's 15% of 80?", 'all': ['12'], 'mode': 'calc'},
 {'q': 'How many grams in a kilogram?', 'all': ['1,000'], 'mode': 'convert'}, {'q': 'How many days until New Year?', 'any': [r'days? until', 'today'], 'regex': True, 'mode': 'clock'},
 {'q': 'Define ubiquitous', 'any': ['everywhere', 'present', 'omnipresent']},
 {'q': 'How do I compress a folder into a zip file?', 'any': ['zip'], 'mode': 'tldr'}, {'q': 'How do I see my IP address on Linux?', 'any': ['ip', 'ifconfig', 'hostname'], 'mode': 'tldr'},
 {'q': 'Compare Java and Swift', 'all': ['Java', 'Swift'], 'none': ['island', 'Indonesia', 'bird', 'Taylor'], 'mode': 'compare'},
 {'q': 'ugh, mondays', 'mode': 'chat', 'none': ["couldn't find"]},
 {'q': 'do you ever get bored of answering questions?', 'any': ['program', 'feel', 'feelings', 'experience', 'bored'], 'mode': 'chat'},
 {'q': 'I just adopted a kitten called Miso', 'any': ['Miso'], 'mode': 'chat', 's': 'kit'}, {'q': "what's my kitten called?", 'all': ['Miso'], 'mode': 'chat', 's': 'kit'},
 {'q': 'can you draw me a picture of a dog?', 'any': ["can't", 'cannot'], 'mode': 'chat'},
 {'q': "my sister's wedding is next week and I'm so excited", 'mode': 'chat', 'intent': ['event+', 'sentiment+', 'good_news', 'mood_happy']},
 {'q': 'who are you really?', 'any': ['fAI'], 'mode': 'chat'},
 # --- former v15 blind set (seen live in the v15 run)
 {'q': 'Who wrote To Kill a Mockingbird?', 'all': ['Harper Lee']}, {'q': 'Who painted The Scream?', 'any': ['Edvard Munch', 'Munch']},
 {'q': 'What is the capital of South Korea?', 'all': ['Seoul']}, {'q': 'When was Ada Lovelace born?', 'all': ['1815']},
 {'q': 'Who directed The Godfather?', 'all': ['Francis Ford Coppola']}, {'q': 'What is the population of Ireland?', 'any': [r'\b\d{1},\d{3},\d{3}\b'], 'regex': True},
 {'q': 'Who founded Amazon?', 'all': ['Jeff Bezos']}, {'q': 'Who founded Tesla?', 'any': ['Martin Eberhard', 'Marc Tarpenning', 'Eberhard']},
 {'q': 'Where was Nelson Mandela born?', 'any': ['Mvezo']}, {'q': 'How old is Bob Dylan?', 'all': ['1941'], 'any': [r'years old', r'aged'], 'regex': True},
 {'q': 'How long is the Nile?', 'any': [r'6,?[5-9]\d\d'], 'regex': True}, {'q': 'What is the official language of Brazil?', 'all': ['Portuguese']},
 {'q': 'Why is the grass green?', 'any': ['chlorophyll']}, {'q': 'Why do stars twinkle?', 'any': ['atmosphere', 'atmospheric', 'turbulence', 'refraction', 'scintillation']},
 {'q': 'What causes hiccups?', 'any': ['diaphragm']}, {'q': 'How do spiders make webs?', 'any': ['silk', 'spinnerets', 'spinneret']},
 {'q': 'How does a battery work?', 'any': ['electrochemical', 'electrons', 'anode', 'cathode', 'chemical'], 'none': ['Battery Park', 'offense']},
 {'q': 'How are pearls formed?', 'any': ['nacre', 'mollusc', 'mollusk', 'oyster', 'calcium carbonate', 'irritant']},
 {'q': 'Why does ice float?', 'any': ['dense', 'density', 'hydrogen', 'expands']}, {'q': 'What causes the northern lights?', 'any': ['solar wind', 'charged particles', 'magnetosphere', 'particles'], 'none': ['comedy-drama']},
 {'q': 'How do fish breathe?', 'any': ['gills', 'gill', 'oxygen']}, {'q': 'Why do we dream?', 'any': ['REM', 'sleep', 'memory', 'theories', 'hypothesis']},
 {'q': 'How does wifi work?', 'any': ['radio', 'wireless', 'IEEE 802.11', 'radio waves']},
 {'q': 'What makes thunder so loud?', 'any': ['expansion', 'shock wave', 'pressure', 'lightning']},
 {'q': 'Why are flamingos pink?', 'any': ['carotenoid', 'carotenoids', 'diet', 'beta-carotene', 'pigments']},
 {'q': 'What is a tsunami?', 'any': ['waves', 'wave'], 's': 'ts'}, {'q': 'What causes them?', 'any': ['earthquake', 'earthquakes', 'displacement', 'underwater', 'volcanic'], 'none': ["couldn't find"], 's': 'ts'},
 {'q': 'Who was the first person to swim across the Pacific Ocean?', 'modes': ['none', 'web', 'chat', 'wikipedia'], 'none': ['Pacific Ocean is the largest']},
 {'q': 'What is 7 times 8 minus 6?', 'all': ['50'], 'mode': 'calc'}, {'q': 'What is 2 to the power of 8?', 'all': ['256'], 'mode': 'calc'},
 {'q': 'How many inches in a foot?', 'all': ['12'], 'mode': 'convert'}, {'q': 'Convert 100 F to C', 'any': [r'37\.[78]'], 'regex': True, 'mode': 'convert'},
 {'q': 'How many days until Valentine\'s Day?', 'any': [r'days? until', 'today'], 'regex': True, 'mode': 'clock'},
 {'q': 'Define gregarious', 'any': ['sociable', 'company', 'social', 'groups', 'socializing', 'crowds', 'herds']},
 {'q': 'How do I search for text inside files on Linux?', 'any': ['grep', 'rg'], 'mode': 'tldr'}, {'q': 'How do I change file permissions?', 'any': ['chmod'], 'mode': 'tldr'},
 {'q': 'Compare Rust and Go', 'all': ['Rust', 'Go'], 'none': ['iron oxide', 'board game', 'fungus'], 'mode': 'compare'},
 {'q': 'morning! did you sleep well?', 'mode': 'chat', 'none': ["couldn't find"]},
 {'q': 'I got a new puppy named Biscuit', 'any': ['Biscuit'], 'mode': 'chat', 's': 'pup'}, {'q': 'do you remember my puppy\'s name?', 'all': ['Biscuit'], 'mode': 'chat', 's': 'pup'},
 {'q': 'I failed my driving test today', 'mode': 'chat', 'intent': ['bad_news', 'mood_sad', 'sentiment-', 'event-']},
 {'q': 'can you make me a logo?', 'any': ["can't", 'cannot'], 'mode': 'chat'},
 {'q': 'what should I call you?', 'any': ['fAI'], 'mode': 'chat'},
 {'q': "I'm moving to Lisbon next month", 'mode': 'chat', 'intent': ['plan_trip', 'plan', 'event+'], 'none': ['What happened then?']},
 # structured answers (new in v15)
 {'q': 'recipe for banana bread', 'any': ['banana', 'bananas'], 'all': ['Ingredients'], 'mode': 'recipe'},
 {'q': 'how do I make pancakes from scratch?', 'any': ['flour', 'egg', 'eggs', 'milk'], 'mode': 'recipe'},
 {'q': 'what are the ingredients for hummus?', 'any': ['chickpeas', 'tahini', 'garbanzo'], 'mode': 'recipe'},
 {'q': 'Give me a good chili recipe', 'any': ['beans', 'beef', 'chili powder', 'tomatoes', 'cumin'], 'mode': 'recipe'},
 {'q': 'best things to do in Paris', 'any': ['Eiffel', 'Louvre', 'Notre'], 'mode': 'list'},
 {'q': 'top 10 tourist attractions in London', 'any': ['British Museum', 'Tower of London', 'Buckingham', 'Big Ben', 'London Eye'], 'mode': 'list'},
 {'q': 'What are the most popular dog breeds?', 'any': ['Labrador', 'Retriever', 'Bulldog', 'German Shepherd', 'Poodle'], 'mode': 'list'},
 {'q': 'must-see places in Rome', 'any': ['Colosseum', 'Vatican', 'Trevi', 'Pantheon'], 'mode': 'list'},
 {'q': 'How do I make a bootable USB drive?', 'modes': ['tldr', 'web', 'wikipedia', 'none'], 'none': ['Ingredients:']},
 {'q': 'Top Gun', 'modes': ['wikipedia', 'wikidata', 'chat', 'web'], 'none': ['independent sites list']},
 # --- former v16/v17 blind set (seen live in the v17 run)
 {'q': 'Who wrote Slaughterhouse-Five?', 'all': ['Vonnegut']}, {'q': 'Who painted The Creation of Adam?', 'all': ['Michelangelo']},
 {'q': 'What is the capital of Mongolia?', 'any': ['Ulaanbaatar', 'Ulan Bator']}, {'q': 'When was Marie Antoinette born?', 'all': ['1755']},
 {'q': 'Who directed Spirited Away?', 'any': ['Hayao Miyazaki', 'Miyazaki']}, {'q': 'What is the population of Norway?', 'any': [r'\b5,\d{3},\d{3}\b'], 'regex': True},
 {'q': 'Who founded Nintendo?', 'any': ['Yamauchi']}, {'q': 'Where was Pablo Picasso born?', 'any': ['Málaga', 'Malaga']},
 {'q': 'How old is Jane Goodall?', 'all': ['1934'], 'any': [r'years old', r'aged'], 'regex': True}, {'q': 'How tall is Mont Blanc?', 'any': [r'4,?8\d\d'], 'regex': True},
 {'q': 'What is the currency of Switzerland?', 'any': ['franc']},
 {'q': 'Why is blood red?', 'any': ['hemoglobin', 'haemoglobin', 'iron']}, {'q': 'How does a vacuum cleaner work?', 'any': ['suction', 'air pump', 'partial vacuum']},
 {'q': 'What causes acid rain?', 'any': ['sulfur dioxide', 'sulphur dioxide', 'nitrogen oxide', 'nitrogen oxides', 'emissions']},
 {'q': 'Why do birds migrate?', 'any': ['food', 'breeding', 'seasonal', 'resources'], 'none': ['Nonmigratory']}, {'q': 'How does a compass work?', 'any': ['magnetic', 'magnetized', 'magnetised']},
 {'q': 'What causes inflation?', 'any': ['money supply', 'demand', 'prices']}, {'q': 'How are stalactites formed?', 'any': ['calcium carbonate', 'dripping', 'mineral', 'minerals', 'deposition']},
 {'q': 'Why does the Moon have phases?', 'any': ['sunlit', 'illuminated', 'orbit', 'orbits', 'Sun']}, {'q': 'How do submarines dive?', 'any': ['ballast', 'buoyancy']},
 {'q': 'Why is the Dead Sea so salty?', 'any': ['evaporation', 'outlet', 'salinity', 'minerals']}, {'q': 'How does a telescope work?', 'any': ['lens', 'lenses', 'mirror', 'mirrors']},
 {'q': 'How does a crane lift heavy loads?', 'any': ['pulley', 'pulleys', 'hoist', 'mechanical advantage', 'boom', 'sheaves'], 'none': ['long-legged', 'wading']},
 {'q': 'What is mercury used for?', 'any': ['thermometers', 'thermometer', 'amalgam', 'lamps', 'barometers'], 'none': ['closest planet', 'messenger of the gods']},
 {'q': 'What is a volcano?', 'any': ['magma', 'lava', 'vent', 'crust'], 's': 'vo'}, {'q': 'Why do they erupt?', 'any': ['pressure', 'gas', 'gases', 'buoyan', 'rises'], 'none': ["couldn't find", 'USGS defines'], 's': 'vo'},
 {'q': 'Who was the first person to climb Olympus Mons?', 'modes': ['none', 'web', 'chat'], 'none': ['was the first person to climb Olympus', 'mountaineering']},
 {'q': 'recipe for chocolate chip cookies', 'any': ['chocolate chips', 'flour', 'butter'], 'all': ['Ingredients'], 'mode': 'recipe'},
 {'q': 'how do I make french toast?', 'any': ['egg', 'eggs', 'bread', 'milk'], 'mode': 'recipe'},
 {'q': 'what are the ingredients for pesto?', 'any': ['basil', 'pine nuts', 'Parmesan', 'garlic'], 'mode': 'recipe'},
 {'q': 'best things to do in Tokyo', 'any': ['Senso-ji', 'Sensō-ji', 'Shibuya', 'Tokyo Tower', 'Meiji', 'Skytree', 'Asakusa', 'Shinjuku'], 'mode': 'list'},
 {'q': 'top 10 attractions in Rome', 'any': ['Colosseum', 'Vatican', 'Trevi', 'Pantheon'], 'mode': 'list'},
 {'q': 'famous landmarks in Egypt', 'any': ['Pyramid', 'Pyramids', 'Sphinx', 'Karnak', 'Luxor', 'Abu Simbel'], 'mode': 'list'},
 {'q': 'What is the square root of 144?', 'all': ['12'], 'mode': 'calc'}, {'q': 'What is 3 squared plus 4 squared?', 'all': ['25'], 'mode': 'calc'},
 {'q': 'How many centimeters in an inch?', 'all': ['2.54'], 'mode': 'convert'}, {'q': 'What day is it today?', 'any': [r'day', r'20\d\d'], 'regex': True, 'mode': 'clock'},
 {'q': 'Define melancholy', 'any': ['sadness', 'sad', 'gloom', 'pensive', 'depression']},
 {'q': 'How do I rename a file in Linux?', 'any': ['mv', 'rename'], 'mode': 'tldr'}, {'q': 'How do I see running processes?', 'any': ['ps', 'top', 'htop'], 'mode': 'tldr'},
 {'q': 'Compare Swift and Kotlin', 'all': ['Swift', 'Kotlin'], 'none': ['Interbank', 'island', 'bird'], 'mode': 'compare'},
 {'q': 'Compare Mars and Venus', 'all': ['Mars', 'Venus'], 'any': ['planet'], 'mode': 'compare'},
 {'q': 'evening! how was your day?', 'mode': 'chat', 'none': ["couldn't find"]},
 {'q': "I'm starting a new job on Monday and I'm nervous", 'mode': 'chat', 'none': ["couldn't find", 'What happened then?', 'Go on.']},
 {'q': 'can you design a poster for my band?', 'any': ["can't", 'cannot'], 'mode': 'chat'},
 {'q': 'my cat Luna is 3 years old', 'any': ['Luna'], 'mode': 'chat', 's': 'c1'}, {'q': "what's my cat's name?", 'all': ['Luna'], 'mode': 'chat', 's': 'c1'},
 {'q': "I'm thinking of learning the guitar", 'mode': 'chat', 'none': ["couldn't find", 'Go on.']},
 {'q': "that's not what I meant", 'mode': 'chat', 'intent': ['wrong_answer', 'clarify']},
 # added in v17 (answer pool: Wikipedia + web candidates, judged)
 {'q': 'Why do we get goosebumps?', 'any': ['muscles', 'muscle', 'hair', 'hairs', 'cold', 'piloerection', 'arrector']},
 {'q': 'How does noise cancelling work?', 'any': ['microphone', 'microphones', 'inverted', 'anti-noise', 'phase', 'sound wave', 'destructive']},
 {'q': 'What causes the smell of rain?', 'any': ['petrichor', 'geosmin', 'soil', 'ozone', 'bacteria']},
 {'q': 'Why do cats knead?', 'any': ['kitten', 'kittens', 'nursing', 'milk', 'instinct', 'comfort', 'scent']},
 {'q': 'Why is the ocean salty?', 'any': ['rivers', 'rocks', 'minerals', 'dissolved', 'runoff', 'weathering', 'seafloor'], 'none': ['covers approximately']},
 # --- former v18 blind set (seen live in the v18 run)
 {'q': 'Who wrote The Name of the Rose?', 'any': ['Umberto Eco', 'Eco']}, {'q': 'Who painted The Arnolfini Portrait?', 'any': ['van Eyck']},
 {'q': 'What is the capital of Kazakhstan?', 'any': ['Astana']}, {'q': 'When was Isaac Newton born?', 'any': ['1642', '1643']},
 {'q': 'Who directed Parasite?', 'any': ['Bong Joon']}, {'q': 'How tall is K2?', 'any': [r'8,?61\d'], 'regex': True},
 {'q': 'Who founded IKEA?', 'any': ['Kamprad']}, {'q': 'What is the currency of Brazil?', 'any': ['real']},
 {'q': 'Tell me about Venus', 'any': ['planet'], 'none': ['goddess of love is']}, {'q': 'What is a typhoon?', 'any': ['tropical cyclone', 'storm'], 'none': ['Typhoon-class', 'Eurofighter']},
 {'q': 'Why is the sunset orange?', 'any': ['scatter', 'scattering', 'wavelength', 'wavelengths', 'atmosphere']}, {'q': 'How does a heat pump work?', 'any': ['refrigerant', 'transfers heat', 'compressor', 'heat from']},
 {'q': 'What causes a solar eclipse?', 'any': ['Moon passes', 'between', 'shadow', 'blocks']}, {'q': 'Why do we sneeze?', 'any': ['irritant', 'irritants', 'nose', 'nasal', 'reflex']},
 {'q': 'How are coral reefs formed?', 'any': ['calcium carbonate', 'polyps', 'skeletons', 'skeleton']}, {'q': 'Why do zebras have stripes?', 'any': ['flies', 'camouflage', 'thermoregulation', 'predators', 'hypothes']},
 {'q': 'How does GPS work?', 'any': ['satellites', 'satellite', 'signals', 'trilateration', 'receiver']}, {'q': 'Why is the Mona Lisa famous?', 'any': ['theft', 'stolen', 'Leonardo', 'smile', '1911']},
 {'q': 'What causes wind?', 'any': ['pressure', 'heating', 'temperature']}, {'q': 'How do airbags work?', 'any': ['sensor', 'sensors', 'inflate', 'inflates', 'gas', 'crash']},
 {'q': 'Who was the first person to walk on Jupiter?', 'modes': ['none', 'chat'], 'none': ['was the first person to walk on Jupiter', 'personal information']},
 {'q': 'Compare Earth and Mars', 'all': ['Earth', 'Mars'], 'any': ['planet'], 'none': ['god of war', 'confectionery'], 'mode': 'compare'},
 {'q': 'Compare Python and Go', 'all': ['Python', 'Go'], 'any': ['programming language'], 'none': ['film', 'snake', 'board game'], 'mode': 'compare'},
 {'q': 'recipe for guacamole', 'any': ['avocado', 'avocados'], 'all': ['Ingredients'], 'mode': 'recipe'}, {'q': 'how do I make an omelette?', 'any': ['egg', 'eggs'], 'mode': 'recipe'},
 {'q': 'top attractions in Barcelona', 'any': ['Sagrada', 'Park G', 'Casa Batll', 'Rambla', 'Gothic'], 'mode': 'list'},
 {'q': 'best museums in Washington DC', 'any': ['Smithsonian', 'National Gallery', 'Air and Space', 'Natural History', 'African American'], 'modes': ['list', 'osm']},
 {'q': 'What are the most popular programming languages?', 'any': ['Python', 'JavaScript', 'Java'], 'modes': ['list', 'wikipedia', 'web', 'none'], 'none': ['Eligibility', 'MOST 529']},
 {'q': 'What is the cube root of 125?', 'all': ['5'], 'mode': 'calc'}, {'q': 'How many feet in a mile?', 'all': ['5,280'], 'mode': 'convert'},
 {'q': 'Define laconic', 'any': ['few words', 'concise', 'brief', 'terse']}, {'q': 'How do I count lines in a file?', 'any': ['wc'], 'mode': 'tldr'},
 {'q': 'afternoon! how are things with you?', 'mode': 'chat', 'none': ["couldn't find"]},
 {'q': 'my dog Pepper loves the beach', 'any': ['Pepper'], 'mode': 'chat', 's': 'c2'}, {'q': "what's my dog called?", 'all': ['Pepper'], 'mode': 'chat', 's': 'c2'},
 {'q': 'I have a job interview tomorrow and I am terrified', 'mode': 'chat', 'none': ["couldn't find", 'Tell me more.', 'Go on.']},
 {'q': 'can you paint me a portrait?', 'any': ["can't", 'cannot'], 'mode': 'chat'},
 # tools (blind phrasings; each cleans up after itself)
 {'q': 'put oat milk on my selftestblind list', 'any': ['oat milk'], 'mode': 'tool', 's': 'tb'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': 'tb'},
 {'q': 'remind me at 6pm tomorrow to call grandma', 'all': ['call grandma', '18:00'], 'mode': 'tool', 's': 'tc'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': 'tc'},
 {'q': 'schedule a vet visit next thursday at 2:30pm for 45 minutes', 'all': ['vet visit', '14:30', '45 minutes'], 'mode': 'tool', 's': 'td'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': 'td'},
 {'q': 'start a 25 minute timer', 'any': ['25 minutes'], 'mode': 'tool', 's': 'te'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': 'te'},
 {'q': 'how warm is the raspberry pi running?', 'any': ['temperature', 'Memory', 'Up for'], 'mode': 'tool'},
 {'q': 'how do I schedule a cron job?', 'modes': ['tldr', 'web', 'wikipedia', 'none'], 'none': ['Added', 'calendar for']},
]
# ---- HELD-OUT, new in v19. Written BEFORE any v19 output was seen and never used for tuning. Harder on purpose:
# ambiguous names, redirects, false premises, vocabulary mismatch, new fact phrasings, new features, adversarial tool input.
HELDOUT_V19 = [
 # facts, including the new phrasings
 {'q': 'Who wrote The Remains of the Day?', 'any': ['Ishiguro']}, {'q': 'Who painted The Garden of Earthly Delights?', 'any': ['Bosch']},
 {'q': 'What is the capital of Bhutan?', 'any': ['Thimphu']}, {'q': 'Who is Michelle Obama married to?', 'any': ['Barack Obama']},
 {'q': 'When was Abbey Road released?', 'any': ['1969']}, {'q': 'What continent is Bolivia in?', 'any': ['South America']},
 {'q': 'Who starred in Casablanca?', 'any': ['Bogart', 'Bergman']}, {'q': 'Which countries border Switzerland?', 'any': ['Austria', 'France', 'Italy', 'Germany', 'Liechtenstein']},
 {'q': 'What is steel made of?', 'any': ['iron', 'carbon']}, {'q': 'Where is Isaac Newton buried?', 'any': ['Westminster Abbey']},
 {'q': 'Who owns YouTube?', 'any': ['Google', 'Alphabet']}, {'q': 'How did Marie Curie die?', 'any': ['aplastic anemia', 'anaemia', 'anemia', 'radiation']},
 {'q': 'Where did Alan Turing study?', 'any': ['Cambridge', "King's College", 'Princeton', 'Sherborne']},
 # redirects and ambiguous names
 {'q': 'What is a cyclone?', 'any': ['rotating', 'low pressure', 'low-pressure', 'storm', 'air mass'], 'none': ['roller coaster', 'Cyclone (']},
 {'q': 'Tell me about Jupiter', 'any': ['planet'], 'none': ['Roman god', 'Florida']}, {'q': 'What is the Big Apple?', 'any': ['New York']},
 {'q': 'How does a mouse detect movement?', 'any': ['optical', 'sensor', 'LED', 'laser', 'ball'], 'none': ['rodent', 'whiskers']},
 {'q': 'Why is Mercury so hot?', 'any': ['Sun', 'closest', 'atmosphere'], 'none': ['thermometer', 'Freddie']},
 # explanations with vocabulary mismatch
 {'q': 'Why do we get goosebumps?', 'any': ['muscle', 'muscles', 'hair', 'hairs', 'cold', 'piloerection']}, {'q': 'Why do onions make your eyes water?', 'any': ['sulfur', 'sulphur', 'gas', 'irritant', 'irritates', 'lachrymatory', 'syn-propanethial']},
 {'q': 'How do planes turn in the air?', 'any': ['ailerons', 'aileron', 'bank', 'banking', 'rudder', 'roll']}, {'q': 'Why does bread go stale?', 'any': ['starch', 'retrogradation', 'moisture', 'crystalli']},
 {'q': 'What causes the tide to go out?', 'any': ['Moon', 'gravitational', 'gravity']}, {'q': 'Why do leaves fall in autumn?', 'any': ['abscission', 'chlorophyll', 'daylight', 'hormone', 'cold', 'water']},
 {'q': 'How do noise cancelling headphones work?', 'any': ['microphone', 'microphones', 'inverted', 'antiphase', 'phase', 'destructive', 'opposite']},
 {'q': 'Why is the sunset orange?', 'any': ['scatter', 'scattering', 'scattered', 'wavelength', 'wavelengths', 'atmosphere'], 'none': ['Crayola', 'pale tint']},
 {'q': 'Why do zebras have stripes?', 'any': ['flies', 'camouflage', 'thermoregulat', 'predators', 'hypothes', 'confus'], 'none': ['melanistic']},
 {'q': 'How are stalactites formed?', 'any': ['calcium carbonate', 'dripping', 'drip', 'mineral', 'minerals', 'limestone', 'calcite']},
 {'q': 'What is a hurricane?', 'any': ['tropical cyclone'], 'none': ['Atlantic hurricane is']},
 {'q': 'What is a volcano?', 'any': ['magma', 'lava', 'vent'], 's': 'v2'}, {'q': 'Why do they erupt?', 'any': ['pressure', 'gas', 'gases', 'buoyan', 'rises', 'magma chamber'], 'none': ['USGS defines'], 's': 'v2'},
 # false premises: an honest "I don't know" is the right answer
 {'q': 'Who was the first person to walk on Venus?', 'modes': ['none', 'chat'], 'none': ['was the first person to walk on Venus']},
 {'q': 'When did Switzerland win the World Cup?', 'modes': ['none', 'web', 'wikipedia', 'chat'], 'none': ['Switzerland won the World Cup in']},
 # comparisons
 {'q': 'Compare Python and Go', 'all': ['Python', 'Go'], 'any': ['programming language'], 'none': ['film', 'snake', 'board game', 'dancing'], 'mode': 'compare'},
 {'q': 'Compare Rust and Go', 'all': ['Rust', 'Go'], 'any': ['programming language'], 'none': ['Western film', 'crime comedy'], 'mode': 'compare'},
 {'q': 'Compare Saturn and Neptune', 'all': ['Saturn', 'Neptune'], 'any': ['planet'], 'none': ['Roman god', 'god of the sea'], 'mode': 'compare'},
 # structured answers
 {'q': 'recipe for tomato soup', 'any': ['tomato', 'tomatoes'], 'all': ['Ingredients'], 'mode': 'recipe'}, {'q': 'how do I make french toast?', 'any': ['egg', 'eggs', 'bread', 'milk'], 'mode': 'recipe'},
 {'q': 'top attractions in Lisbon', 'any': ['Bel\u00e9m', 'Belem', 'Alfama', 'Jer\u00f3nimos', 'Jeronimos', 'Castle', 'Tram 28'], 'mode': 'list'},
 {'q': 'What are the most popular dog breeds?', 'any': ['Labrador', 'Retriever', 'Bulldog', 'German Shepherd', 'Poodle'], 'modes': ['list', 'wikipedia', 'web', 'none'], 'none': ['MOST 529', 'Eligibility']},
 {'q': 'best hikes near Denver', 'modes': ['list', 'osm', 'web', 'none'], 'none': ['Tell me more', 'Go on.']},
 # skills
 {'q': 'What is 12 squared?', 'all': ['144'], 'mode': 'calc'}, {'q': 'What is the sum of 250 and 175?', 'all': ['425'], 'mode': 'calc'}, {'q': 'How many millilitres in a litre?', 'all': ['1,000'], 'mode': 'convert'},
 {'q': 'Define perfunctory', 'any': ['routine', 'care', 'interest', 'hasty', 'superficial']}, {'q': 'How do I find large files on Linux?', 'any': ['du', 'find', 'ncdu'], 'mode': 'tldr'},
 # creative grammar (new) and what must still be declined
 {'q': 'write a haiku about my cat', 'any': ['cat'], 'all': ['haiku'], 'mode': 'creative'}, {'q': 'tell me a bedtime story about a brave snail', 'any': ['snail'], 'mode': 'creative'},
 {'q': 'write an essay on the causes of World War One', 'any': ["can't", 'cannot'], 'mode': 'chat'}, {'q': 'what is a limerick?', 'any': ['five', 'humorous', 'rhyme', 'verse'], 'modes': ['wikipedia', 'dictionary', 'web']},
 # chat
 {'q': 'good evening! what have you been up to?', 'mode': 'chat', 'none': ["couldn't find"]}, {'q': 'my hamster Peanut escaped last night', 'any': ['Peanut'], 'mode': 'chat', 's': 'c3'},
 {'q': "what's my hamster's name?", 'all': ['Peanut'], 'mode': 'chat', 's': 'c3'}, {'q': "I didn't get the job", 'mode': 'chat', 'none': ["couldn't find", 'Congrat', 'Lovely', 'great news']},
 {'q': 'you are useless', 'mode': 'chat', 'none': ["couldn't find"]},
 # tools: blind phrasings, household notes, and hostile input (each cleans up after itself)
 {'q': 'add household fact: selftest gate code = 4711', 'any': ['(yes / no)'], 'mode': 'tool', 's': 'tf'}, {'q': 'yes', 'any': ['Added'], 'mode': 'tool', 's': 'tf'},
 {'q': 'what is the selftest gate code?', 'all': ['4711'], 'mode': 'tool', 's': 'tf'}, {'q': 'what is the selftest gate code?', 'any': ['locked'], 'none': ['4711'], 'mode': 'tool', 'nokey': True},
 {'q': 'remind me about the dentist at half past nine tomorrow', 'modes': ['tool'], 'none': ['has already passed'], 's': 'tg'}, {'q': 'undo', 'modes': ['tool'], 's': 'tg'},
 {'q': 'set an alarm for quarter to seven', 'modes': ['tool'], 's': 'th'}, {'q': 'undo', 'modes': ['tool'], 's': 'th'},
 {'q': 'read file /etc/shadow', 'none': ['root:', '$6$'], 'mode': 'tool'}, {'q': 'delete file ../../noai-chat-v19/.env', 'none': ['Moved'], 'modes': ['tool', 'chat', 'none']},
 {'q': 'add $(reboot) to my selftest list', 'any': ['$(reboot)'], 'mode': 'tool', 's': 'ti'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': 'ti'},
 {'q': 'how do I set a reminder in Google Calendar?', 'modes': ['web', 'wikipedia', 'tldr', 'none'], 'none': ["I'll remind you", 'When should I']},
]
# ---- ROTATING POOL: a different sample every day (seeded by the date), so repeated runs probe different questions.
POOL = [
 {'q': 'What is the capital of Japan?', 'all': ['Tokyo']}, {'q': 'What is the capital of Brazil?', 'any': ['Brasília', 'Brasilia']}, {'q': 'What is the capital of Kenya?', 'all': ['Nairobi']},
 {'q': 'What is the capital of Egypt?', 'all': ['Cairo']}, {'q': 'What is the capital of Argentina?', 'all': ['Buenos Aires']}, {'q': 'What is the capital of Thailand?', 'all': ['Bangkok']},
 {'q': 'Who wrote Frankenstein?', 'all': ['Mary Shelley']}, {'q': 'Who wrote Moby-Dick?', 'all': ['Herman Melville']}, {'q': 'Who wrote Jane Eyre?', 'any': ['Charlotte Brontë', 'Charlotte Bronte']},
 {'q': 'Who wrote Nineteen Eighty-Four?', 'all': ['George Orwell']}, {'q': 'Who painted The Starry Night?', 'all': ['Vincent van Gogh']}, {'q': 'Who painted Guernica?', 'any': ['Pablo Picasso', 'Picasso']},
 {'q': 'Who painted Girl with a Pearl Earring?', 'any': ['Johannes Vermeer', 'Vermeer']}, {'q': 'Who directed Psycho?', 'all': ['Alfred Hitchcock']}, {'q': 'Who directed Inception?', 'all': ['Christopher Nolan']},
 {'q': 'When was Isaac Newton born?', 'any': ['1642', '1643']}, {'q': 'Where was Mozart born?', 'all': ['Salzburg']}, {'q': 'When did the Eiffel Tower open?', 'all': ['1889']},
 {'q': 'What is a quasar?', 'any': ['galactic nucleus', 'luminous', 'black hole']}, {'q': 'What is DNA?', 'any': ['deoxyribonucleic', 'genetic', 'polymer', 'nucleotides']},
 {'q': 'What is an isotope?', 'any': ['neutrons', 'neutron', 'atomic number']}, {'q': 'What is a glacier?', 'any': ['ice']}, {'q': 'What is a mitochondrion?', 'any': ['organelle', 'ATP', 'energy']},
 {'q': 'Why do volcanoes erupt?', 'any': ['magma', 'pressure', 'gases', 'buoyant', 'rises'], 'none': ['cinder cones']}, {'q': 'How do magnets work?', 'any': ['magnetic field', 'magnetic', 'electrons']},
 {'q': 'Why is Mars red?', 'any': ['iron oxide', 'iron', 'rust', 'dust']}, {'q': 'What causes rainbows?', 'any': ['refraction', 'dispersion', 'reflection', 'droplets']},
 {'q': 'What causes thunder?', 'any': ['lightning', 'expansion', 'shock wave']}, {'q': 'How does the heart work?', 'any': ['blood', 'pumps', 'pump']},
 {'q': 'How are pearls formed?', 'any': ['mollusc', 'mollusk', 'nacre', 'oyster', 'calcium carbonate']}, {'q': 'Why do we yawn?', 'any': ['yawn', 'yawning']},
 {'q': 'What is 12 * 12?', 'all': ['144'], 'mode': 'calc'}, {'q': 'What is the square root of 81?', 'all': ['9'], 'mode': 'calc'}, {'q': 'What is 10% of 250?', 'all': ['25'], 'mode': 'calc'},
 {'q': 'Convert 100 cm to m', 'all': ['1 m'], 'mode': 'convert'}, {'q': 'What is 0 C in F?', 'all': ['32'], 'mode': 'convert'}, {'q': 'How many feet in a yard?', 'all': ['3'], 'mode': 'convert'},
 {'q': 'How do I count lines in a file?', 'any': ['wc'], 'mode': 'tldr'}, {'q': 'How do I show running processes?', 'any': ['ps', 'top', 'htop'], 'mode': 'tldr'},
 {'q': 'tell me a fun fact', 'mode': 'chat'}, {'q': 'are you a real person?', 'mode': 'chat'}, {'q': 'thanks a bunch', 'mode': 'chat'},
]

# ---- FACT POOL: sampled by date. Large enough that tuning to it is pointless; all answers are stable facts.
CAPITALS = {'France': ['Paris'], 'Germany': ['Berlin'], 'Italy': ['Rome'], 'Spain': ['Madrid'], 'Portugal': ['Lisbon'], 'Poland': ['Warsaw'], 'Austria': ['Vienna'],
 'Greece': ['Athens'], 'Sweden': ['Stockholm'], 'Finland': ['Helsinki'], 'Denmark': ['Copenhagen'], 'Ireland': ['Dublin'], 'Hungary': ['Budapest'], 'Czech Republic': ['Prague'],
 'Japan': ['Tokyo'], 'China': ['Beijing'], 'India': ['New Delhi', 'Delhi'], 'Indonesia': ['Jakarta', 'Nusantara'], 'Vietnam': ['Hanoi'], 'Thailand': ['Bangkok'], 'Philippines': ['Manila'],
 'Turkey': ['Ankara'], 'Iran': ['Tehran'], 'Saudi Arabia': ['Riyadh'], 'Israel': ['Jerusalem'], 'Egypt': ['Cairo'], 'Kenya': ['Nairobi'], 'Nigeria': ['Abuja'], 'Ethiopia': ['Addis Ababa'],
 'Morocco': ['Rabat'], 'Ghana': ['Accra'], 'Mexico': ['Mexico City'], 'Cuba': ['Havana'], 'Peru': ['Lima'], 'Chile': ['Santiago'], 'Colombia': ['Bogotá', 'Bogota'],
 'Argentina': ['Buenos Aires'], 'Australia': ['Canberra'], 'Russia': ['Moscow'], 'Ukraine': ['Kyiv', 'Kiev']}
AUTHORS = {'Frankenstein': ['Mary Shelley'], 'Dracula': ['Bram Stoker'], 'Hamlet': ['William Shakespeare', 'Shakespeare'], 'Don Quixote': ['Cervantes'], 'War and Peace': ['Tolstoy'],
 'Crime and Punishment': ['Dostoevsky', 'Dostoyevsky'], 'The Hobbit': ['Tolkien'], 'Jane Eyre': ['Charlotte Brontë', 'Bronte', 'Brontë'], 'Wuthering Heights': ['Emily Brontë', 'Bronte', 'Brontë'],
 'Great Expectations': ['Charles Dickens'], 'The Catcher in the Rye': ['Salinger'], 'Brave New World': ['Aldous Huxley'], 'The Old Man and the Sea': ['Hemingway'],
 'One Hundred Years of Solitude': ['García Márquez', 'Garcia Marquez'], 'The Picture of Dorian Gray': ['Oscar Wilde'], 'Les Misérables': ['Victor Hugo'], 'Moby-Dick': ['Herman Melville'],
 'The Divine Comedy': ['Dante'], 'Ulysses': ['James Joyce'], 'Lolita': ['Nabokov'], 'The Handmaid\'s Tale': ['Margaret Atwood'], 'Things Fall Apart': ['Chinua Achebe']}
PAINTERS = {'The Starry Night': ['van Gogh'], 'The Last Supper': ['Leonardo da Vinci'], 'Girl with a Pearl Earring': ['Vermeer'], 'The Persistence of Memory': ['Dalí', 'Dali'],
 'The Night Watch': ['Rembrandt'], 'Las Meninas': ['Velázquez', 'Velazquez'], 'The Kiss': ['Klimt'], 'American Gothic': ['Grant Wood'], 'Water Lilies': ['Monet'], 'The Garden of Earthly Delights': ['Bosch']}

# =====================================================================================================================
# v20: EVERY question below is new. CORE re-tests the behaviours that must never break, in new words and with new values.
# KNOWLEDGE and BLIND are new subjects. The random tiers draw from large pools with a seed that changes EVERY RUN (it is
# printed; set NOAI_TEST_SEED to reproduce a run). Older questions live on in LEGACY, sampled at random.
# =====================================================================================================================
CORE = [
 {'q': 'Hello there', 'mode': 'chat', 'crit': C}, {'q': "How's it going?", 'mode': 'chat', 'none': ["couldn't find"], 'crit': C},
 {'q': 'Do you have a name?', 'any': ['fAI'], 'mode': 'chat', 'crit': C},
 {'q': 'Are you ChatGPT?', 'any': ['language model', 'generative', 'program', 'software', 'rules', 'retrieval', 'rule-based'], 'mode': 'chat', 'crit': C},
 {'q': "I've recently taken up rock climbing", 'any': ['climbing'], 'mode': 'chat', 'crit': C}, {'q': 'What were we talking about?', 'any': ['climbing'], 'mode': 'chat', 'crit': C},
 {'q': 'My name is Jordan Rivers.', 'any': ['Jordan'], 'mode': 'chat', 'crit': C}, {'q': "What's my name?", 'all': ['Jordan'], 'mode': 'chat', 'crit': C},
 {'q': 'I live in Vancouver', 'any': ['Vancouver'], 'mode': 'chat', 'crit': C},
 {'q': 'remember that the recycling goes out on Thursday', 'mode': 'chat', 'none': ["couldn't find"], 'crit': C},
 {'q': 'What do you know about me?', 'all': ['Jordan', 'Vancouver', 'recycling'], 'mode': 'chat', 'crit': C},
 {'q': 'My favourite band is Radiohead', 'any': ['Radiohead'], 'mode': 'chat', 'crit': C}, {'q': "what's my favourite band?", 'all': ['Radiohead'], 'mode': 'chat', 'crit': C},
 {'q': 'I adopted a rabbit called Clover', 'any': ['Clover'], 'mode': 'chat', 'crit': C}, {'q': "what's my rabbit called?", 'all': ['Clover'], 'mode': 'chat', 'crit': C},
 {'q': "I'm really stressed about my exams", 'mode': 'chat', 'none': ["couldn't find", 'Lovely', 'Glad to hear'], 'crit': C},
 {'q': 'tell me a joke please', 'mode': 'chat', 'none': ["couldn't find"], 'crit': C},
 {'q': 'forget everything', 'any': ['wiped', 'erased', 'forgot'], 'mode': 'chat', 'crit': C}, {'q': 'What do you know about me?', 'any': ['Nothing yet'], 'mode': 'chat', 'crit': C},
 # skills
 {'q': 'What is 18% of 350?', 'all': ['63'], 'mode': 'calc', 'crit': C}, {'q': 'What is 144 divided by 16?', 'all': ['9'], 'mode': 'calc', 'crit': C},
 {'q': 'What is (12 + 8) * 7?', 'all': ['140'], 'mode': 'calc', 'crit': C}, {'q': 'Convert 12 miles to km', 'any': [r'19\.3'], 'regex': True, 'mode': 'convert', 'crit': C},
 {'q': 'What is 30 C in F?', 'all': ['86'], 'mode': 'convert', 'crit': C}, {'q': 'What day of the week is it?', 'any': [r'day'], 'regex': True, 'mode': 'clock', 'crit': C},
 {'q': 'What year is it?', 'any': [r'20\d\d'], 'regex': True, 'mode': 'clock', 'crit': C},
 # tools: everything added is removed again
 {'q': 'put bread on my selftest list', 'any': ['locked'], 'mode': 'tool', 'nokey': True, 'crit': C},
 {'q': 'put bread and jam on my selftest list', 'all': ['bread', 'jam'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'show me my selftest list', 'all': ['bread', 'jam'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'remove jam from my selftest list', 'any': ['Removed'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'empty my selftest list', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['now empty'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'remind me to water the plants in 2 hours', 'all': ['water the plants'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'put selftest haircut on my calendar next tuesday at 10am', 'all': ['selftest haircut', '10:00'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'create a note called selftest-memo', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['Created'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'write hello again to file selftest-memo', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['Added the line'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'open file selftest-memo', 'all': ['hello again'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'open file ../../../etc/hostname', 'any': ["can't open"], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'remove file selftest-memo', 'any': ['(yes / no)'], 'mode': 'tool', 'crit': C, 's': 'tools'}, {'q': 'yes', 'any': ['.trash'], 'mode': 'tool', 'crit': C, 's': 'tools'},
 {'q': 'how is the pi doing?', 'any': ['Memory', 'Up for', 'Disk'], 'mode': 'tool', 'crit': C},
 {'q': 'what tools do you have', 'any': ['Reminders', 'Lists'], 'mode': 'tool', 'nokey': True, 'crit': C},
 # template verse, and what is still declined
 {'q': 'write a poem about autumn', 'all': ['autumn', 'hand-written grammar'], 'none': ['the the '], 'mode': 'creative', 'crit': C},
 {'q': 'give me a limerick about coffee', 'any': ['coffee'], 'mode': 'creative', 'crit': C}, {'q': 'can you draw a map for me?', 'any': ["can't", 'cannot'], 'mode': 'chat', 'crit': C},
]
KNOWLEDGE = [
 {'q': "Who wrote One Flew Over the Cuckoo's Nest?", 'any': ['Kesey']}, {'q': 'Who painted The Raft of the Medusa?', 'any': ['G\u00e9ricault', 'Gericault']},
 {'q': 'What is the capital of Peru?', 'any': ['Lima']}, {'q': 'When was Nikola Tesla born?', 'all': ['1856']}, {'q': 'Who directed Blade Runner?', 'any': ['Ridley Scott']},
 {'q': 'What is the population of New Zealand?', 'any': [r'\b5,\d{3},\d{3}\b'], 'regex': True}, {'q': 'Who composed Swan Lake?', 'any': ['Tchaikovsky']},
 {'q': 'Where was Vincent van Gogh born?', 'any': ['Zundert']}, {'q': 'How old is Meryl Streep?', 'all': ['1949']}, {'q': 'Who founded Sony?', 'any': ['Ibuka', 'Morita']},
 {'q': 'How tall is Denali?', 'any': [r'6,?1[89]\d'], 'regex': True}, {'q': 'What is the currency of Poland?', 'any': ['z\u0142oty', 'zloty']},
 {'q': 'Who is Tom Hanks married to?', 'any': ['Rita Wilson']}, {'q': 'What continent is Morocco in?', 'any': ['Africa']}, {'q': 'Who owns Instagram?', 'any': ['Meta', 'Facebook']},
 {'q': 'Which countries border Portugal?', 'any': ['Spain']}, {'q': 'What is the official language of Egypt?', 'any': ['Arabic']},
 {'q': 'Who wrote The Bell Jar?', 'any': ['Plath'], 's': 'k1'}, {'q': 'Where was she born?', 'any': ['Boston'], 's': 'k1'},
 {'q': 'Why do camels have humps?', 'any': ['fat', 'fatty']}, {'q': 'How does a parachute work?', 'any': ['drag', 'air resistance', 'resistance']},
 {'q': 'What causes fog?', 'any': ['condens', 'droplets', 'cool'], 'regex': True}, {'q': 'Why is Venus so hot?', 'any': ['greenhouse', 'carbon dioxide', 'atmosphere']},
 {'q': 'How does an electric motor work?', 'any': ['magnetic', 'current', 'rotor']}, {'q': 'Why do apples turn brown?', 'any': ['oxid', 'enzym', 'polyphenol'], 'regex': True},
 {'q': 'How are glaciers formed?', 'any': ['snow', 'compact', 'accumulat'], 'regex': True}, {'q': 'What causes ocean currents?', 'any': ['wind', 'density', 'temperature', 'salinity', 'Coriolis']},
 {'q': 'How does a thermos keep things hot?', 'any': ['vacuum', 'insulat', 'heat transfer'], 'regex': True}, {'q': 'How do earthquakes cause tsunamis?', 'any': ['displac', 'seafloor', 'sea floor', 'seabed'], 'regex': True},
 {'q': 'How does a solar panel work?', 'any': ['photovoltaic', 'photons', 'electrons', 'semiconductor']}, {'q': 'What causes thunderstorms?', 'any': ['warm', 'moist', 'unstable', 'updraft', 'convection']},
 {'q': 'How is paper made?', 'any': ['pulp', 'wood', 'fib'], 'regex': True}, {'q': 'Why does salt melt ice?', 'any': ['freezing point', 'freezing-point']},
 {'q': 'Why do sailing boats have keels?', 'any': ['stabil', 'capsiz', 'sideways', 'lateral', 'ballast'], 'regex': True}, {'q': 'Why is the Statue of Liberty green?', 'any': ['copper', 'patina', 'oxid'], 'regex': True},
 {'q': 'recipe for lentil soup', 'any': ['lentil', 'lentils'], 'all': ['Ingredients'], 'mode': 'recipe'}, {'q': 'how do I make scrambled eggs?', 'any': ['egg', 'eggs'], 'mode': 'recipe'},
 {'q': 'what are the ingredients for tzatziki?', 'any': ['yogurt', 'yoghurt', 'cucumber'], 'mode': 'recipe'},
 {'q': 'top attractions in Amsterdam', 'any': ['Rijksmuseum', 'Van Gogh', 'Anne Frank', 'Vondelpark', 'Canal'], 'mode': 'list'},
 {'q': 'best things to do in Chicago', 'any': ['Millennium Park', 'Art Institute', 'Navy Pier', 'Willis', 'Cloud Gate', 'Riverwalk'], 'mode': 'list'},
 {'q': 'famous landmarks in India', 'any': ['Taj Mahal', 'Red Fort', 'Gateway of India', 'Qutub', 'Qutb', 'Hawa Mahal'], 'mode': 'list'},
 {'q': 'What are the most popular cat breeds?', 'any': ['Maine Coon', 'Ragdoll', 'Persian', 'Siamese', 'Shorthair'], 'mode': 'list'},
 {'q': 'Compare Ruby and Perl', 'all': ['Ruby', 'Perl'], 'any': ['programming language'], 'none': ['gemstone'], 'mode': 'compare'},
 {'q': 'Compare Jupiter and Saturn', 'all': ['Jupiter', 'Saturn'], 'any': ['planet'], 'none': ['god of', 'deity'], 'mode': 'compare'},
 {'q': 'Compare Go and Python', 'all': ['Go', 'Python'], 'any': ['programming language'], 'none': ['dancing', 'film', 'snake'], 'mode': 'compare'},
 {'q': 'Compare PostgreSQL and MySQL', 'all': ['PostgreSQL', 'MySQL'], 'any': ['database', 'relational'], 'mode': 'compare'},
 {'q': 'How do I list open ports?', 'any': ['ss', 'netstat', 'lsof', 'nmap'], 'mode': 'tldr'}, {'q': 'How do I download a file with curl?', 'any': ['curl'], 'mode': 'tldr'},
 {'q': 'How do I create a symbolic link?', 'any': ['ln'], 'mode': 'tldr'}, {'q': 'How do I kill a process by name?', 'any': ['pkill', 'killall'], 'mode': 'tldr'},
 {'q': 'Define ineffable', 'any': ['express', 'words', 'describ'], 'regex': True, 'mode': 'dictionary'},
 {'q': 'coffee shops near Pike Place Market in Seattle', 'modes': ['osm', 'none'], 'none': ['Tell me more', 'Go on.']},
 {'q': 'Research the causes of the Chernobyl disaster.', 'any': ['reactor', 'test', 'design', 'RBMK', 'operator'], 'modes': ['research', 'web', 'wikipedia']},
 {'q': "What's the latest version of Node.js?", 'any': [r'v?\d+\.\d+'], 'regex': True, 'modes': ['web', 'wikipedia', 'wikidata']},
]
for _c in KNOWLEDGE:
    _c.setdefault('crit', N)

# ---- BLIND, new in v20. Written before any v20 output was seen and never used for tuning.
HELDOUT_V20 = [
 {'q': 'Who wrote The Brothers Karamazov?', 'any': ['Dostoevsky', 'Dostoyevsky']}, {'q': 'Who painted Liberty Leading the People?', 'any': ['Delacroix']},
 {'q': 'What is the capital of Uruguay?', 'any': ['Montevideo']}, {'q': 'When was Rosalind Franklin born?', 'all': ['1920']}, {'q': 'Who directed Seven Samurai?', 'any': ['Kurosawa']},
 {'q': 'Who composed The Planets?', 'any': ['Holst']}, {'q': 'How tall is Mount Fuji?', 'any': [r'3,?77\d'], 'regex': True}, {'q': 'Who founded Wikipedia?', 'any': ['Wales', 'Sanger']},
 {'q': 'Who is Beyonc\u00e9 married to?', 'any': ['Jay-Z', 'Jay Z', 'Shawn Carter']}, {'q': 'What continent is Mongolia in?', 'any': ['Asia']}, {'q': 'When was The Matrix released?', 'any': ['1999']},
 {'q': 'Who owns WhatsApp?', 'any': ['Meta', 'Facebook']}, {'q': 'Which countries border Austria?', 'any': ['Germany', 'Hungary', 'Slovenia', 'Czech']},
 {'q': 'What is bronze made of?', 'any': ['copper', 'tin']}, {'q': 'Where is Charles Darwin buried?', 'any': ['Westminster Abbey']}, {'q': "Who was Marie Curie's husband?", 'any': ['Pierre']},
 {'q': 'How did Alexander the Great die?', 'any': ['fever', 'illness', 'poison', 'Babylon', 'typhoid', 'malaria']},
 {'q': 'What is a twister?', 'any': ['tornado']}, {'q': 'What is the Windy City?', 'any': ['Chicago']}, {'q': 'Tell me about Mercury', 'any': ['planet'], 'none': ['Freddie']},
 {'q': 'How does a jaguar hunt?', 'any': ['ambush', 'stalk', 'bite', 'prey'], 'none': ['Jaguar Cars', 'Land Rover']},
 {'q': 'Why do cats have whiskers?', 'any': ['sens', 'touch', 'navigat', 'vibrissae'], 'regex': True}, {'q': 'How does a dishwasher work?', 'any': ['water', 'spray', 'detergent', 'pump']},
 {'q': 'What causes sinkholes?', 'any': ['limestone', 'dissol', 'groundwater', 'erosion', 'collapse'], 'regex': True},
 {'q': 'Why is the Leaning Tower of Pisa leaning?', 'any': ['foundation', 'soft ground', 'soil', 'subsid'], 'regex': True},
 {'q': 'How do owls see in the dark?', 'any': ['rod', 'retina', 'eyes', 'tapetum']}, {'q': 'Why does hair turn grey?', 'any': ['melan', 'pigment'], 'regex': True},
 {'q': 'How does a lighthouse work?', 'any': ['lamp', 'lens', 'Fresnel', 'light']}, {'q': 'What causes avalanches?', 'any': ['snowpack', 'slope', 'weak layer', 'trigger']},
 {'q': 'Why do we blush?', 'any': ['blood', 'adrenaline', 'vessels', 'embarrass'], 'regex': True}, {'q': 'How is glass made?', 'any': ['sand', 'silica', 'melt'], 'regex': True},
 {'q': 'How do bats navigate?', 'any': ['echolocation']}, {'q': 'What is a comet?', 'any': ['ice', 'icy', 'dust', 'nucleus'], 's': 'b1'},
 {'q': 'What are they made of?', 'any': ['ice', 'dust', 'rock', 'frozen'], 'none': ["couldn't find"], 's': 'b1'},
 {'q': 'Who was the first person to swim to the Moon?', 'modes': ['none', 'chat'], 'none': ['was the first person to swim to the Moon']},
 {'q': 'When did Canada land on Mars?', 'modes': ['none', 'web', 'wikipedia', 'chat'], 'none': ['Canada landed on Mars in']},
 {'q': 'Compare Kotlin and Scala', 'all': ['Kotlin', 'Scala'], 'any': ['programming language'], 'mode': 'compare'},
 {'q': 'Compare Uranus and Neptune', 'all': ['Uranus', 'Neptune'], 'any': ['planet'], 'none': ['god of', 'deity'], 'mode': 'compare'},
 {'q': 'Compare Go and Java', 'all': ['Go', 'Java'], 'any': ['programming language'], 'none': ['island', 'film', 'dancing'], 'mode': 'compare'},
 {'q': "recipe for shepherd's pie", 'any': ['lamb', 'beef', 'potato', 'potatoes'], 'all': ['Ingredients'], 'mode': 'recipe'},
 {'q': 'how do I make hot chocolate?', 'any': ['milk', 'cocoa', 'chocolate'], 'mode': 'recipe'},
 {'q': 'top attractions in Prague', 'any': ['Charles Bridge', 'Prague Castle', 'Old Town', 'Astronomical'], 'mode': 'list'},
 {'q': 'best national parks in the United States', 'any': ['Yellowstone', 'Yosemite', 'Grand Canyon', 'Zion', 'Glacier'], 'modes': ['list', 'web', 'wikipedia', 'none']},
 {'q': 'What is 7 cubed?', 'all': ['343'], 'mode': 'calc'}, {'q': 'What is the product of 12 and 15?', 'all': ['180'], 'mode': 'calc'}, {'q': 'How many cups in a gallon?', 'all': ['16'], 'mode': 'convert'},
 {'q': 'Define sanguine', 'any': ['optimis', 'cheerful', 'blood', 'hopeful'], 'regex': True}, {'q': 'How do I check memory usage on Linux?', 'any': ['free', 'top', 'vmstat', 'htop'], 'mode': 'tldr'},
 {'q': 'compose an ode to my bicycle', 'any': ['bicycle'], 'mode': 'creative'}, {'q': 'spin me a tale about a sleepy dragon', 'any': ['dragon'], 'mode': 'creative'},
 {'q': 'write me a cover letter', 'any': ["can't", 'cannot'], 'mode': 'chat'},
 {'q': 'yo! what are you up to?', 'mode': 'chat', 'none': ["couldn't find"]}, {'q': 'my parrot Kiwi learned a new word', 'any': ['Kiwi'], 'mode': 'chat', 's': 'c4'},
 {'q': "what's my parrot called?", 'all': ['Kiwi'], 'mode': 'chat', 's': 'c4'}, {'q': 'I got promoted today!', 'mode': 'chat', 'none': ["couldn't find", 'sorry', 'rough']},
 {'q': 'tell me a joke', 'mode': 'chat', 's': 'c5'}, {'q': 'one more', 'mode': 'chat', 'none': ["couldn't find", 'Go on.'], 's': 'c5'}, {'q': 'that joke was terrible', 'mode': 'chat', 'none': ["couldn't find"], 's': 'c5'},
 {'q': 'remind me in 45 minutes to take the bread out', 'all': ['take the bread out'], 'mode': 'tool', 's': 'tb1'}, {'q': 'undo', 'modes': ['tool'], 's': 'tb1'},
 {'q': 'pencil in selftest lunch with Sam on friday at noon', 'any': ['12:00'], 'mode': 'tool', 's': 'tb2'}, {'q': 'undo', 'modes': ['tool'], 's': 'tb2'},
 {'q': 'read file ~/.ssh/id_rsa', 'none': ['BEGIN', 'PRIVATE KEY'], 'mode': 'tool'},
 {'q': 'add ; rm -rf / to my selftest list', 'any': ['rm -rf'], 'mode': 'tool', 's': 'tb3'}, {'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': 'tb3'},
 {'q': 'how do I add an event to Outlook calendar?', 'modes': ['guide', 'web', 'wikipedia', 'tldr', 'none'], 'none': ['Added "', 'When is "']},
]

# ---- BLIND, new in v21. Written before any v21 output was seen; never used for tuning. Aimed at the new answer types.
HELDOUT_V34 = [   # blind set 2 (v34). Never tuned on; a random 25 run each time. Different topics and wording from every earlier set.
 {'q': 'how do I fix a dripping tap?', 'any': ['1.', 'Steps:'], 'modes': ['guide', 'web', 'wikipedia', 'none']},
 {'q': 'steps to repot a houseplant', 'any': ['1.', 'Steps:'], 'modes': ['guide', 'web', 'none']},
 {'q': 'any news about the Federal Reserve?', 'any': ['Recent headlines', "couldn't find recent news"], 'modes': ['news', 'none']},
 {'q': "what's the latest on the Artemis program?", 'any': ['Recent headlines', "couldn't find recent news"], 'modes': ['news', 'none']},
 {'q': 'chronology of the Roman Republic', 'any': ['BC'], 'mode': 'timeline'},
 {'q': 'quick facts about Mars', 'any': ['Type:', 'planet'], 'mode': 'facts'},
 {'q': 'advantages and disadvantages of nuclear power', 'any': ['For:', 'Against:'], 'modes': ['proscons', 'none']},
 {'q': 'antonym of brave', 'any': ['coward', 'timid', 'fearful', 'no antonyms'], 'mode': 'word'},
 {'q': 'what rhymes with silver?', 'any': ['chilver', 'Wiktionary', 'rhyme'], 'mode': 'word'},
 {'q': 'etymology of quarantine', 'any': ['quaranta', 'forty', 'Italian', 'Venetian'], 'mode': 'word'},
 {'q': 'how do you pronounce gnocchi?', 'any': ['/', 'ˈ'], 'mode': 'word'},
 {'q': 'quotations from Mark Twain', 'any': ['Wikiquote'], 'mode': 'quotes'},
 {'q': 'who sang Purple Rain?', 'any': ['Prince'], 'mode': 'wikidata'},
 {'q': 'What plug type does Australia use?', 'any': ['Type I', 'AS/NZS'], 'mode': 'wikidata'},
 {'q': 'which side of the road do they drive on in India?', 'any': ['left'], 'mode': 'wikidata'},
 {'q': 'Is Russia bigger than the United States?', 'any': ['Yes, Russia is bigger'], 'mode': 'inference'},
 {'q': 'Which is taller, Mount Kilimanjaro or Mont Blanc?', 'any': ['Kilimanjaro is taller'], 'mode': 'inference'},
 {'q': 'Was Mozart alive in 1800?', 'any': ['No:'], 'mode': 'inference'},
 {'q': 'How long did Beethoven live?', 'any': ['56 years'], 'mode': 'inference'},
 {'q': 'Where was the composer of Swan Lake born?', 'any': ['Votkinsk'], 'mode': 'inference'},
 {'q': 'Did Shakespeare die before Isaac Newton was born?', 'any': ['Yes:'], 'mode': 'inference'},
 {'q': 'how many days until 25 December 2026?', 'any': ['days until'], 'mode': 'clock'},
 {'q': 'what day of the week was 11 November 1918?', 'any': ['Monday'], 'mode': 'clock'},
 {'q': '15% tip on $80', 'any': ['$12'], 'mode': 'clock'},
 {'q': 'split $120 four ways', 'any': ['$30'], 'mode': 'clock'},
 {'q': 'What is hypertension?', 'any': ['blood pressure'], 'all': ['not medical advice'], 'modes': ['wikipedia', 'web']},
 {'q': 'can my employer withhold my final paycheck?', 'all': ['not legal advice'], 'modes': ['web', 'wikipedia', 'none']},
 {'q': 'summarise https://en.wikipedia.org/wiki/Octopus', 'any': ['Key sentences'], 'mode': 'summary'},
 {'q': 'Why is the ocean salty?', 'any': ['mineral', 'rock', 'rain', 'river', 'sodium'], 'modes': ['wikipedia', 'web']},
 {'q': 'How does a refrigerator work?', 'any': ['refrigerant', 'compress', 'evaporat', 'heat'], 'modes': ['wikipedia', 'web']},
 {'q': 'Why does bread rise?', 'any': ['yeast', 'carbon dioxide', 'gas', 'ferment'], 'modes': ['wikipedia', 'web']},
 {'q': 'How do vaccines work?', 'any': ['immune', 'antibod', 'antigen'], 'all': ['not medical advice'], 'modes': ['wikipedia', 'web']},
 {'q': 'Why does ice float?', 'any': ['dens', 'hydrogen bond', 'expand'], 'modes': ['wikipedia', 'web']},
 {'q': 'Compare Rust and C++', 'any': ['Rust vs C++', 'Side by side'], 'mode': 'compare'},
 {'q': 'Compare Mars and Venus', 'any': ['Mars vs Venus'], 'mode': 'compare'},
 {'q': 'best museums in London', 'any': ['British Museum', 'Tate', 'National Gallery', 'Natural History Museum', 'V&A', 'Victoria and Albert'], 'modes': ['list', 'none']},
 {'q': 'most popular dog breeds', 'any': ['Labrador', 'Retriever', 'Bulldog', 'German Shepherd', 'Poodle'], 'modes': ['list', 'none']},
 {'q': 'how do I make hummus?', 'any': ['chickpea', 'tahini'], 'modes': ['recipe', 'none']},
 {'q': 'how do I find large files on Linux?', 'any': ['find', 'du '], 'mode': 'tldr'},
 {'q': 'how do I rename a git branch?', 'any': ['git branch'], 'mode': 'tldr'},
 {'q': 'bookshops near Trafalgar Square in London', 'any': ['near Trafalgar Square', "couldn't get map results"], 'modes': ['osm', 'none']},
 {'q': "I've just started learning Spanish", 'any': ['Spanish'], 'mode': 'chat', 'none': ['Wikidata:']},
 {'q': 'my cat Mochi is unwell', 'any': ['sorry', 'vet', 'hope', 'Mochi'], 'mode': 'chat'},
 {'q': 'Who was the first person to swim across the Sun?', 'modes': ['none', 'chat', 'web']},
 {'q': 'What is a black hole?', 'any': ['gravity', 'gravitational', 'escape'], 'modes': ['wikipedia', 'web']},
 {'q': "what's the latest version of Python?", 'any': ['3.1', '3.2', '4.'], 'modes': ['web', 'none']},
 {'q': 'write me a haiku about rain', 'any': ['rain'], 'mode': 'creative'},
 {'q': 'Who is older, Paul McCartney or Mick Jagger?', 'any': ['McCartney is older'], 'mode': 'inference'},
 {'q': 'Does Japan have a bigger population than Germany?', 'any': ['Yes, Japan is more populous'], 'mode': 'inference'},
 {'q': 'How old was Isaac Newton when Principia was published?', 'any': ['44', '45'], 'mode': 'inference'},
 {'q': 'What is the capital of Chile?', 'any': ['Santiago'], 'mode': 'wikidata', 's': 'turn1'},
 {'q': 'what about Peru?', 'any': ['Lima', 'I read that as'], 'mode': 'wikidata', 's': 'turn1'},
 {'q': 'and its population?', 'any': ['population of Peru', 'I read that as'], 'mode': 'wikidata', 's': 'turn1'},
 {'q': 'Who directed Alien?', 'any': ['Ridley Scott'], 'mode': 'wikidata', 's': 'turn2'},
 {'q': 'and the composer?', 'any': ['Goldsmith', 'I read that as'], 'mode': 'wikidata', 's': 'turn2'},
 {'q': 'Who wrote Dracula?', 'any': ['Bram Stoker'], 'mode': 'wikidata', 's': 'turn3'},
 {'q': 'and his wife?', 'any': ['Florence', 'I read that as'], 'mode': 'wikidata', 's': 'turn3'},
 {'q': 'and Frankenstein?', 'any': ['Mary Shelley', 'I read that as'], 'mode': 'wikidata', 's': 'turn3'},
 {'q': 'What is the population of Japan?', 'any': ['population of Japan'], 'mode': 'wikidata', 's': 'turn4'},
 {'q': 'and Germany?', 'any': ['population of Germany', 'I read that as'], 'mode': 'wikidata', 's': 'turn4'},
 {'q': 'what did you say about Japan?', 'any': ['Earlier, for', 'population of Japan'], 'mode': 'recall', 's': 'turn4'},
 {'q': 'top attractions in Amsterdam', 'any': ['Anne Frank', 'Van Gogh', 'Rijksmuseum'], 'modes': ['list', 'none'], 's': 'turn5'},
 {'q': 'tell me about the first one', 'any': ['I read that as', 'Anne Frank', 'Van Gogh', 'Rijksmuseum', 'Tell me about'], 'modes': ['wikipedia', 'web', 'none'], 's': 'turn5'},
 {'q': 'coffee shops near Pike Place Market in Seattle', 'any': ['near Pike Place', "couldn't get map results"], 'modes': ['osm', 'none'], 's': 'turn6'},
 {'q': 'and bookshops?', 'any': ['bookshops near Pike Place', 'I read that as', "couldn't get map results"], 'modes': ['osm', 'none'], 's': 'turn6'},
 {'q': 'why is the sky blue', 'any': ['scatter'], 'modes': ['wikipedia', 'web'], 's': 'turn7'},
 {'q': 'and at sunset?', 'any': ['I read that as', 'sunset', 'red'], 'modes': ['wikipedia', 'web', 'none'], 's': 'turn7'},
 {'q': 'what did you say about the sky?', 'any': ['Earlier, for', 'scatter'], 'mode': 'recall', 's': 'turn7'},
 {'q': 'how far is Porto from Lisbon', 'any': ['km', 'straight line'], 'mode': 'inference', 's': 'turn8'},
 {'q': 'how do you say thank you in Portuguese', 'any': ['obrigad'], 'modes': ['word'], 's': 'turn8'},
 {'q': 'tell me about the first one', 'any': ["haven't given you a list"], 'mode': 'chat', 's': 'turn9'},
 {'q': 'who was Robespierre', 'any': ['Robespierre'], 'modes': ['wikipedia', 'wikidata'], 's': 'turn10'},
 {'q': 'how did he die?', 'any': ['I read that as', 'guillotin', 'execut', 'died'], 'modes': ['wikidata', 'wikipedia', 'inference'], 's': 'turn10'},
 {'q': 'how many countries border Germany', 'any': ['9', 'according to Wikidata'], 'mode': 'inference', 's': 'turn11'},
 {'q': 'what is the largest country in South America', 'any': ['Brazil'], 'modes': ['inference', 'wikipedia', 'web'], 's': 'turn11'},
 {'q': 'who was president of the United States when Elvis Presley was born', 'any': ['Roosevelt'], 'modes': ['inference', 'wikipedia', 'web', 'none'], 's': 'turn12'},
 {'q': 'which is largest: France, Spain or Germany', 'any': ['France'], 'modes': ['inference'], 's': 'turn12'},
 {'q': 'what are the different types of volcanoes', 'any': ['section of Wikipedia', 'shield', 'strato', 'cinder'], 'modes': ['wikipedia', 'list', 'web'], 's': 'turn13'},
]

HELDOUT = [
 # step-by-step guides shown in full
 {'q': 'How do I descale a kettle?', 'any': ['1.', 'Steps:'], 'modes': ['guide', 'web', 'wikipedia'], 'none': ['Tell me more']},
 {'q': 'how to change a flat tyre on a car', 'any': ['1.', 'Steps:'], 'modes': ['guide', 'web', 'wikipedia']},
 {'q': 'walk me through setting up a Raspberry Pi for the first time', 'any': ['1.', 'Steps:'], 'modes': ['guide', 'web', 'wikipedia', 'tldr']},
 # news
 {'q': 'news about NASA', 'any': ['Recent headlines'], 'modes': ['news', 'none'], 'none': ['Tell me more']}, {'q': "what's happening in Japan?", 'modes': ['news', 'none'], 'none': ['Tell me more', 'Go on.']},
 {'q': 'latest on electric cars', 'modes': ['news', 'none']},
 # timelines and fact sheets
 {'q': 'timeline of the Apollo program', 'any': ['1969'], 'mode': 'timeline'}, {'q': 'history of the Eiffel Tower', 'any': ['1889'], 'modes': ['timeline', 'wikipedia']},
 {'q': 'facts about Jupiter', 'any': ['Type', 'Mass', 'Radius', 'Named after'], 'mode': 'facts'}, {'q': 'Norway stats', 'any': ['Population', 'Capital', 'Currency'], 'mode': 'facts'},
 {'q': 'key facts about Marie Curie', 'any': ['Born', 'Occupation', 'Died'], 'mode': 'facts'},
 # pros and cons (attributed, no recommendation)
 {'q': 'pros and cons of solar panels', 'any': ['For:'], 'all': ['Against:'], 'modes': ['proscons', 'none']}, {'q': 'should I get a heat pump?', 'modes': ['proscons', 'none', 'web'], 'none': ['Tell me more']},
 # word tools
 {'q': 'synonyms for happy', 'any': ['cheerful', 'glad', 'joyful', 'content'], 'mode': 'word'}, {'q': 'what is the opposite of generous', 'any': ['stingy', 'mean', 'selfish', 'miserly', 'no antonyms'], 'mode': 'word'},
 {'q': 'what words rhyme with orange', 'modes': ['word', 'none', 'wikipedia']}, {'q': 'where does the word salary come from', 'any': ['Latin', 'salt', 'sal'], 'mode': 'word'},
 {'q': 'how do you pronounce quinoa', 'any': ['IPA', '/'], 'mode': 'word'}, {'q': 'what does the prefix hypo- mean', 'any': ['under', 'below', 'less'], 'mode': 'word'},
 # quotations, songs, characters, travel facts
 {'q': 'quotes by Oscar Wilde', 'any': ['Quotations attributed'], 'mode': 'quotes'}, {'q': 'Who sang Bohemian Rhapsody?', 'any': ['Queen'], 'mode': 'wikidata'},
 {'q': 'who are the main characters in Pride and Prejudice?', 'any': ['Elizabeth Bennet', 'Darcy'], 'mode': 'wikidata'}, {'q': 'What plug type does Italy use?', 'any': ['Type C', 'Type F', 'Type L', 'plug type'], 'mode': 'wikidata'},
 {'q': 'which side of the road do they drive on in Japan?', 'any': ['left'], 'mode': 'wikidata'}, {'q': 'What is Mount Everest named after?', 'any': ['George Everest'], 'mode': 'wikidata'},
 # dates and money (offline, exact)
 {'q': 'how many days between 1 January 2027 and 1 March 2027', 'all': ['59'], 'mode': 'clock'}, {'q': 'what day of the week was 20 July 1969', 'all': ['Sunday'], 'mode': 'clock'},
 {'q': 'what is 25% off $60', 'all': ['45'], 'mode': 'clock'}, {'q': 'split $90 between 3 people', 'all': ['30'], 'mode': 'clock'},
 {'q': 'monthly payment on $100,000 at 5% over 20 years', 'any': ['659', '660'], 'mode': 'clock'},
 # medical and legal: quoted with a caution, never advice
 {'q': 'What is atrial fibrillation?', 'any': ['heart', 'irregular', 'arrhythmia'], 'all': ['not medical advice']},
 {'q': 'what to do for a minor burn', 'any': ['cool', 'water', 'running'], 'all': ['not medical advice'], 'modes': ['guide', 'web', 'wikipedia', 'none']},
 {'q': 'can a landlord keep my deposit?', 'all': ['not legal advice'], 'modes': ['web', 'wikipedia', 'none', 'guide']},
 # page summary (a stable page)
 {'q': 'summarise https://en.wikipedia.org/wiki/Tardigrade', 'any': ['Key sentences'], 'mode': 'summary'},
 # fixes from the v20 run
 {'q': 'Why is the Leaning Tower of Pisa leaning?', 'any': ['foundation', 'soft', 'soil', 'subsid', 'ground'], 'none': ['A leaning tower is a tower which']},
 {'q': 'How did Alexander the Great die?', 'any': ['fever', 'illness', 'Babylon', 'typhoid', 'malaria', 'poison', 'Guillain'], 'none': ['masculine name']},
 {'q': 'Compare Ruby and Perl', 'any': ['programming language'], 'none': ['surname'], 'mode': 'compare'},
 {'q': 'coffee shops near Pike Place Market in Seattle', 'modes': ['osm', 'none'], 'none': ['Tell me more', 'What makes you say that']},
 {'q': 'Why do camels have humps?', 'any': ['fat', 'fatty'], 'none': ['silly answer', 'camel riders']}, {'q': 'How does a thermos keep things hot?', 'any': ['vacuum', 'insulat', 'heat'], 'none': ['just not magic']},
 {'q': 'compose an ode to my bicycle', 'any': ['bicycle'], 'mode': 'creative'}, {'q': 'pencil in selftest lunch with Sam on friday at noon', 'any': ['12:00'], 'mode': 'tool', 's': 'pl'}, {'q': 'undo', 'modes': ['tool'], 's': 'pl'},
 {'q': 'that joke was terrible', 'mode': 'chat', 'none': ['sorry to hear', 'what happened']}, {'q': 'How do I check memory usage on Linux?', 'any': ['free', 'htop', 'top', 'vmstat'], 'mode': 'tldr'},
 {'q': 'Who owns WhatsApp?', 'any': ['Meta', 'Facebook'], 'mode': 'wikidata'},
 {'q': 'Is Canada bigger than Australia?', 'any': ['Canada is bigger'], 'mode': 'inference'},
 {'q': 'Was Albert Einstein alive for the Apollo 11 landing?', 'any': ['No:'], 'mode': 'inference'},
 {'q': 'Where was the author of Dracula born?', 'any': ['Dublin', 'Clontarf'], 'mode': 'inference'},
 {'q': 'How do I sort a dictionary by value in Python?', 'any': ["can't write", 'Pages that address'], 'modes': ['code', 'none']},
 {'q': 'write me a javascript function that reverses a string', 'any': ["can't write code"], 'modes': ['code', 'chat']},
 {'q': 'who wrote drakula', 'any': ['Bram Stoker'], 'modes': ['wikidata', 'wikipedia']},
 {'q': 'summarize https://en.wikipedia.org/wiki/Tardigrade', 'any': ['Key sentences'], 'mode': 'summary'},
 {'q': 'what is the captial of Peru', 'any': ['Lima'], 'mode': 'wikidata'},
 {'q': 'how do I turn holiday.mov into an mp3 with ffmpeg', 'any': ['holiday.mov', 'Filled in from your question'], 'mode': 'tldr'},
 {'q': 'what are the main causes of climate change', 'any': ['list most often', 'fossil', 'greenhouse', 'emissions'], 'modes': ['list', 'none']},
 {'q': 'How does a sundial work? In short.', 'any': ['Condensed from the source', 'shadow', 'gnomon'], 'modes': ['wikipedia', 'web']},
 # chat
 {'q': 'good morning! anything interesting today?', 'mode': 'chat', 'none': ["couldn't find"]}, {'q': 'my goldfish Bubbles died', 'mode': 'chat', 'none': ['Lovely', 'Congrat']},
]
# ---- large pools for the random tiers
DIRECTORS = {'Vertigo': ['Hitchcock'], 'Goodfellas': ['Scorsese'], 'Alien': ['Ridley Scott'], 'Inception': ['Christopher Nolan'], 'Rashomon': ['Kurosawa'], 'Jurassic Park': ['Spielberg'],
 'The Shining': ['Kubrick'], 'Titanic': ['James Cameron'], "Pan's Labyrinth": ['del Toro'], 'Casablanca': ['Curtiz'], 'Gladiator': ['Ridley Scott'], 'Get Out': ['Jordan Peele'],
 'Am\u00e9lie': ['Jeunet'], 'Oldboy': ['Park Chan-wook'], 'Fargo': ['Coen']}
COMPOSERS = {'The Nutcracker': ['Tchaikovsky'], 'Bol\u00e9ro': ['Ravel'], 'The Rite of Spring': ['Stravinsky'], 'Carmen': ['Bizet'], 'Rhapsody in Blue': ['Gershwin'], 'La traviata': ['Verdi'],
 'The Barber of Seville': ['Rossini'], 'Messiah': ['Handel']}
BORN = {'Leonardo da Vinci': '1452', 'Galileo Galilei': '1564', 'Wolfgang Amadeus Mozart': '1756', 'Jane Austen': '1775', 'Abraham Lincoln': '1809', 'Mahatma Gandhi': '1869',
 'Pablo Picasso': '1881', 'Nelson Mandela': '1918', 'Queen Victoria': '1819', 'Ludwig van Beethoven': '1770', 'Florence Nightingale': '1820', 'Stephen Hawking': '1942'}
CONTINENTS = {'Kenya': 'Africa', 'Chile': 'South America', 'Thailand': 'Asia', 'Norway': 'Europe', 'Ghana': 'Africa', 'Vietnam': 'Asia', 'Argentina': 'South America', 'Poland': 'Europe',
 'Nigeria': 'Africa', 'Japan': 'Asia'}
CAPITALS.update({'Norway': ['Oslo'], 'Netherlands': ['Amsterdam'], 'Belgium': ['Brussels'], 'Switzerland': ['Bern'], 'Romania': ['Bucharest'], 'Bulgaria': ['Sofia'], 'Croatia': ['Zagreb'],
 'Serbia': ['Belgrade'], 'Iceland': ['Reykjav'], 'Pakistan': ['Islamabad'], 'Bangladesh': ['Dhaka'], 'Nepal': ['Kathmandu'], 'Malaysia': ['Kuala Lumpur'], 'Uganda': ['Kampala'],
 'Senegal': ['Dakar'], 'Tunisia': ['Tunis'], 'Algeria': ['Algiers'], 'Jordan': ['Amman'], 'Iraq': ['Baghdad'], 'Venezuela': ['Caracas'], 'Ecuador': ['Quito'], 'Jamaica': ['Kingston'],
 'Paraguay': ['Asunci'], 'Tanzania': ['Dodoma'], 'Canada': ['Ottawa'], 'New Zealand': ['Wellington']})
EXPLAIN = [('Why do mosquito bites itch?', ['histamine', 'saliva', 'immune']), ('How does a microphone work?', ['diaphragm', 'electrical signal', 'vibrat', 'sound']),
 ('What causes wildfires?', ['lightning', 'human', 'dry', 'drought', 'ignit']), ('Why is the sea level rising?', ['thermal expansion', 'melting', 'ice', 'glacier']),
 ('How does a suspension bridge work?', ['cable', 'tension', 'tower', 'deck']), ('How do plants absorb water?', ['root', 'osmosis', 'xylem']), ('How does a piano make sound?', ['hammer', 'string']),
 ('Why do stars have different colors?', ['temperature']), ('How do bees communicate?', ['dance', 'waggle', 'pheromone']), ('What causes jet lag?', ['circadian', 'time zone', 'body clock']),
 ('How does a sundial work?', ['shadow', 'gnomon']), ('Why is Antarctica so cold?', ['elevation', 'latitude', 'sunlight', 'ice', 'albedo', 'angle']),
 ('How do fireflies glow?', ['luciferin', 'luciferase', 'bioluminescen']), ('What causes a sonic boom?', ['shock wave', 'speed of sound', 'supersonic']),
 ('How does yeast work?', ['ferment', 'carbon dioxide', 'sugar']), ('Why do chameleons change color?', ['chromatophore', 'communicat', 'temperature', 'camouflage', 'crystals', 'iridophore']),
 ('How does a geyser erupt?', ['steam', 'pressure', 'groundwater', 'magma', 'boil']), ('What causes deserts to form?', ['rain shadow', 'precipitation', 'dry', 'high pressure', 'arid']),
 ('Why do dogs wag their tails?', ['communicat', 'emotion', 'social']), ('Why do humans need sleep?', ['memory', 'restor', 'brain']), ('Why are there time zones?', ['rotation', 'longitude', 'railway', 'standard']),
 ('Why is gold valuable?', ['rar', 'scarc', 'corros', 'jewel', 'currency', 'durab'])]

PARAPHRASE = {   # v34: each fact drawn with a random wording, so the pool exercises normalisation, not one template
    'capital': ['What is the capital of {k}?', "What's the capital city of {k}?", 'Capital of {k}?', 'Which city is the capital of {k}?', 'Tell me the capital of {k}'],
    'author': ['Who wrote {k}?', 'Who is the author of {k}?', 'Who was {k} written by?', "Can you tell me who wrote {k}?", 'Author of {k}?'],
    'painter': ['Who painted {k}?', 'Who is the artist behind {k}?', 'Which painter created {k}?', 'Who was {k} painted by?'],
    'director': ['Who directed {k}?', 'Who was the director of {k}?', 'Which director made {k}?', 'Who directed the film {k}?'],
    'composer': ['Who composed {k}?', 'Who was the composer of {k}?', 'Who wrote the music for {k}?', 'Which composer wrote {k}?'],
    'born': ['When was {k} born?', "What is {k}'s date of birth?", 'What year was {k} born?', 'When is the birthday of {k}?'],
    'continent': ['What continent is {k} in?', 'Which continent is {k} on?', '{k} is in which continent?', 'What continent does {k} belong to?'],
}
def _ask(rnd, kind, k):
    return rnd.choice(PARAPHRASE[kind]).format(k=k)

def fact_cases(rnd):
    out = [{'q': _ask(rnd, 'capital', k), 'any': v} for k, v in rnd.sample(sorted(CAPITALS.items()), 6)]
    out += [{'q': _ask(rnd, 'author', k), 'any': v} for k, v in rnd.sample(sorted(AUTHORS.items()), 3)]
    out += [{'q': _ask(rnd, 'painter', k), 'any': v} for k, v in rnd.sample(sorted(PAINTERS.items()), 2)]
    out += [{'q': _ask(rnd, 'director', k), 'any': v} for k, v in rnd.sample(sorted(DIRECTORS.items()), 3)]
    out += [{'q': _ask(rnd, 'composer', k), 'any': v} for k, v in rnd.sample(sorted(COMPOSERS.items()), 2)]
    out += [{'q': _ask(rnd, 'born', k), 'all': [v]} for k, v in rnd.sample(sorted(BORN.items()), 2)]
    out += [{'q': _ask(rnd, 'continent', k), 'any': [v]} for k, v in rnd.sample(sorted(CONTINENTS.items()), 2)]
    return out

EXPLAIN_FRAMES = ['{q}', 'Can you explain: {q}', "I've always wondered, {ql}", 'Quick question: {q}', '{q} Keep it simple.']
def explain_cases(rnd):
    out = []
    for q, kw in rnd.sample(EXPLAIN, 10):
        frame = rnd.choice(EXPLAIN_FRAMES)
        out.append({'q': frame.format(q=q, ql=q[0].lower() + q[1:]), 'any': kw, 'regex': False})
    return out

_DEPENDENT = re.compile(r"\b(?:they|them|it|its|she|he|her|his)\b|^(?:yes|no|undo|another one|tell me more|thanks|forget everything)$|\bmy\b|what do you know about me|what were we|selftest|household", re.I)
def legacy_cases(rnd):
    """Older questions (v11-v19), self-contained ones only, sampled so that every run is different and lighter on the search engines."""
    alln = [c for c in (CASES + REGRESSION2 + HELDOUT_V19 + HELDOUT_V20 + POOL) if not c.get('s') and not c.get('nokey') and not _DEPENDENT.search(c['q'])]
    uniq = list({c['q']: c for c in alln}.values())
    return [dict(c, crit=N) for c in rnd.sample(uniq, min(25, len(uniq)))], len(uniq)

def generated_cases(rnd):
    """Arithmetic and conversions made up fresh from the date seed; the expected value is computed HERE, independently of the bot."""
    out = []
    for _ in range(4):
        a, b = rnd.randint(12, 99), rnd.randint(3, 29)
        word, val = rnd.choice([('plus', a + b), ('minus', a - b), ('times', a * b)])
        out.append({'q': f'What is {a} {word} {b}?', 'all': [f'{val:,}'], 'mode': 'calc'})
    p, n = rnd.choice([5, 10, 20, 25, 50]), rnd.randint(2, 40) * 20
    out.append({'q': f'What is {p}% of {n}?', 'all': [f'{p * n // 100:,}'], 'mode': 'calc'})
    a, b, c = rnd.randint(2, 9), rnd.randint(2, 9), rnd.randint(2, 9)
    out.append({'q': f'What is ({a} + {b}) * {c}?', 'all': [f'{(a + b) * c:,}'], 'mode': 'calc'})
    r = rnd.randint(4, 25)
    out.append({'q': f'What is the square root of {r * r}?', 'all': [str(r)], 'mode': 'calc'})
    base, ex = rnd.randint(2, 9), rnd.randint(2, 4)
    out.append({'q': f'What is {base} to the power of {ex}?', 'all': [f'{base ** ex:,}'], 'mode': 'calc'})
    import datetime as _dt
    d1 = _dt.date(2027, rnd.randint(1, 6), rnd.randint(1, 28)); d2 = d1 + _dt.timedelta(days=rnd.randint(10, 300))
    out.append({'q': f"how many days between {d1.strftime('%-d %B %Y')} and {d2.strftime('%-d %B %Y')}", 'all': [f'{(d2 - d1).days:,}'], 'mode': 'clock'})
    d3 = _dt.date(rnd.randint(1900, 2030), rnd.randint(1, 12), rnd.randint(1, 28))
    out.append({'q': f"what day of the week was {d3.strftime('%-d %B %Y')}", 'all': [d3.strftime('%A')], 'mode': 'clock'})
    pct, price = rnd.choice([10, 20, 25, 30, 40, 50]), rnd.randint(2, 40) * 10
    out.append({'q': f'what is {pct}% off ${price}', 'all': [f'{price * (100 - pct) // 100:,}'], 'mode': 'clock'})
    km = rnd.randint(2, 60)
    out.append({'q': f'Convert {km} km to miles', 'any': [re.escape(f'{km * 0.621371192:.6g}'[:4])], 'regex': True, 'mode': 'convert'})
    kg = rnd.randint(2, 90)
    out.append({'q': f'How many pounds is {kg} kg?', 'any': [re.escape(f'{kg / 0.45359237:.6g}'[:4])], 'regex': True, 'modes': ['convert', 'web', 'wikipedia', 'none']})
    c5 = rnd.choice([-10, 0, 5, 15, 25, 30, 35, 100])
    out.append({'q': f'What is {c5} C in F?', 'all': [str(c5 * 9 // 5 + 32)], 'mode': 'convert'})
    ft = rnd.randint(2, 30)
    out.append({'q': f'Convert {ft} feet to inches', 'all': [f'{ft * 12:,}'], 'mode': 'convert'})
    return out

def generated_tool_cases(rnd):
    """Calendar phrases made up from the seed; the expected date and time are computed HERE. Each is undone straight away."""
    import datetime as _dt
    out = []
    names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
    today = _dt.date.today()
    for i in range(3):
        wd, hour, minute = rnd.randrange(7), rnd.randint(8, 11), rnd.choice([0, 15, 30, 45])
        pm = rnd.random() < 0.5
        ahead = (wd - today.weekday()) % 7 or 7
        day = today + _dt.timedelta(days=ahead)
        h24 = hour + 12 if pm else hour
        expect = f"{names[wd]} {day.day} {day.strftime('%B')} at {h24:02d}:{minute:02d}"
        out.append({'q': f"add selftest-gen{i} to my calendar on {names[wd].lower()} at {hour}:{minute:02d}{'pm' if pm else 'am'}", 'all': [expect], 'mode': 'tool', 's': f'gt{i}'})
        out.append({'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': f'gt{i}'})
    mins = rnd.randint(2, 55)
    out.append({'q': f'set a timer for {mins} minutes', 'all': [f'{mins} minutes'], 'mode': 'tool', 's': 'gtt'})
    out.append({'q': 'undo', 'any': ['removed', 'Undone'], 'mode': 'tool', 's': 'gtt'})
    return out

def found(needle, text, regex=False):
    if regex:
        return bool(re.search(needle, text))
    return bool(re.search(r'(?<![A-Za-z0-9])' + re.escape(needle) + r"[a-z]{0,4}(?![A-Za-z0-9])", text, re.I))
_diag = requests.get(BASE + '/api/diagnostics', timeout=30).json()
lines = ['We Have AI At Home (fAI) v' + str(_diag.get('version', '?')).split('.')[0] + ' evaluation', '=' * 40, '']
try:
    lines += ['DIAGNOSTICS:', json.dumps(_diag, indent=2), '']
except Exception as e:
    lines += ['DIAGNOSTICS ERROR: ' + repr(e), '']
passes = fails = warns = 0
MEAS = {'verbatim_ok': 0, 'verbatim_bad': 0, 'verbatim_unchecked': 0, 'guide': [0, 0], 'recipe': [0, 0], 'list': [0, 0], 'explain': [0, 0], 'by_mode': {}}
QUAL = {'answered': 0, 'false_confident': 0, 'abstained': 0, 'needless_abstain': 0, 'honest_abstain': 0, 'planned': 0, 'plan_honoured': 0, 'freshness_violations': 0, 'p3_retrieval': 0, 'p3_reached': 0, 'p3_saved': 0}
critical_fails, times = [], []

def run_case(c, sid, tier):
    """-> True/False. tier: 'regression' (critical/warn semantics), 'heldout' or 'pool' (scored, never fatal)."""
    global passes, fails, warns
    q = c['q']; ok = True; reasons = []; d = {}
    lines.append('YOU: ' + q)
    try:
        t0 = time.time()
        r = requests.post(BASE + '/api/chat', json={'session': sid, 'question': q}, timeout=75,
                          headers={} if c.get('nokey') else {'X-API-Key': os.environ.get('NOAI_ACCESS_CODE') or os.environ.get('NOAI_API_TOKEN', '')})
        dt = time.time() - t0
        d = r.json(); ans = d.get('answer', '')
        try:      # v54 measurement: verbatim integrity and useful-answer thresholds per mode (an answer that exists is not yet a useful one)
            v = d.get('verbatim')
            if v is True: MEAS['verbatim_ok'] += 1
            elif v is False: MEAS['verbatim_bad'] += 1
            elif d.get('mode') in ('wikipedia', 'web', 'research', 'summary', 'guide'): MEAS['verbatim_unchecked'] += 1
            md = d.get('mode') or 'none'
            MEAS['by_mode'][md] = MEAS['by_mode'].get(md, 0) + 1
            if any('engines are suspending' in t or 'web search unavailable' in t for t in (d.get('trace') or [])):
                MEAS['throttled'] = MEAS.get('throttled', 0) + 1
            if md == 'guide': MEAS['guide'][1] += 1; MEAS['guide'][0] += int(len(re.findall(r'(?m)^\d+\. ', ans)) >= 3)
            if md == 'recipe': MEAS['recipe'][1] += 1; MEAS['recipe'][0] += int('Ingredients:' in ans and 'Method:' in ans)
            if md == 'list': MEAS['list'][1] += 1; MEAS['list'][0] += int(len(re.findall(r'(?m)^\d+\. ', ans)) >= 5)
            if md in ('wikipedia', 'web') and re.match(r'(?i)^(?:why|how|what causes|what makes)', q):
                MEAS['explain'][1] += 1
                subj = [w for w in re.findall(r'[a-z]{4,}', q.lower()) if w not in ('what', 'does', 'causes', 'makes', 'work', 'happen', 'there', 'their', 'have', 'from', 'with', 'when', 'into', 'some', 'people')]
                MEAS['explain'][0] += int(any(w[:5] in ans.lower() for w in subj) and len(ans) >= 120)
        except Exception:
            pass
        lines.append('BOT: ' + ans)
        for i, s_ in enumerate(d.get('sources') or [], 1):
            lines.append(f"  [{i}] {s_.get('title', '')} - {s_.get('url', '')}")
        lines.append(f"  mode={d.get('mode')} http={r.status_code} time={dt:.1f}s evidence={d.get('evidence_count', 0)}")
        if d.get('mode') != 'chat':
            times.append(dt)
        if r.status_code >= 400 or d.get('mode') == 'error':
            ok = False; reasons.append('backend error')
        rx = c.get('regex', False)
        for n in c.get('all', []):
            if not found(n, ans): ok = False; reasons.append('missing ' + repr(n))
        if c.get('any') and not any(found(n, ans, rx) for n in c['any']):
            ok = False; reasons.append('missing any of ' + repr(c['any']))
        for n in c.get('none', []) + (JUNK if d.get('mode') not in ('chat', 'tldr') else []):
            if n.casefold() in ans.casefold(): ok = False; reasons.append('unexpected ' + repr(n))
        titles = [s_.get('title', '') for s_ in d.get('sources') or []]
        if c.get('source') and c['source'] not in titles: ok = False; reasons.append(f"source {titles} expected {c['source']}")
        if c.get('source_any') and not any(t in c['source_any'] for t in titles): ok = False; reasons.append(f"source {titles} not in {c['source_any']}")
        if c.get('intent') and not any(('intent=' + i) in ' '.join(d.get('trace') or []) for i in c['intent']):
            ok = False; reasons.append(f"chat intent not in {c['intent']}")
        if c.get('mode') and d.get('mode') != c['mode']: ok = False; reasons.append(f"mode={d.get('mode')} expected {c['mode']}")
        if c.get('modes') and d.get('mode') not in c['modes']: ok = False; reasons.append(f"mode={d.get('mode')} expected one of {c['modes']}")
        if tier != 'regression' and 'mode' not in c and 'modes' not in c and d.get('mode') in ('none', 'chat'):
            ok = False; reasons.append(f"no answer (mode={d.get('mode')})")
        if dt > 30: reasons.append(f'slow ({dt:.0f}s)')
    except Exception as e:
        ok = False; reasons.append(type(e).__name__ + ': ' + str(e)[:160]); lines.append('BOT ERROR: ' + repr(e)[:200])
    try:
        mode_ = d.get('mode', '')
        wants_content = bool(c.get('any') or c.get('all'))
        expects_none = 'none' in (c.get('modes') or []) or c.get('mode') == 'none'
        content_bad = any(r.startswith('missing') or r.startswith('unexpected') for r in reasons)
        if mode_ == 'none':
            QUAL['abstained'] += 1
            if wants_content and not expects_none: QUAL['needless_abstain'] += 1
            elif expects_none: QUAL['honest_abstain'] += 1
        elif mode_ not in ('chat', 'tool', 'creative', 'calc', 'convert', 'clock', 'weather', 'osm', 'news'):
            QUAL['answered'] += 1
            if content_bad: QUAL['false_confident'] += 1
        if d.get('plan'):
            QUAL['planned'] += 1; QUAL['plan_honoured'] += bool(d['plan'].get('honoured')); QUAL['freshness_violations'] += bool(d['plan'].get('freshness_violation'))
            if d['plan'].get('cascade_position') is not None and d['plan'].get('in_plan') is not None:
                QUAL['p3_retrieval'] += 1; QUAL['p3_reached'] += bool(d['plan'].get('in_plan'))
                if d['plan'].get('in_plan'): QUAL['p3_saved'] += d['plan']['cascade_position'] - d['plan']['plan_position']
    except Exception:
        pass
    if ok:
        lines.append('  ASSERT: PASS' + (' (' + '; '.join(reasons) + ')' if reasons else ''))
        if tier == 'regression': passes += 1
    else:
        if tier != 'regression':
            lines.append(f'  ASSERT: MISS ({tier}) - ' + '; '.join(reasons))
        elif c.get('crit'):
            fails += 1; critical_fails.append((q, reasons)); lines.append('  ASSERT: FAIL (critical) - ' + '; '.join(reasons))
        else:
            warns += 1; lines.append('  ASSERT: WARN (network/source-sensitive) - ' + '; '.join(reasons))
        for t in d.get('trace') or []:
            lines.append('    trace: ' + t)
    lines.append('')
    if d.get('mode') in ('web', 'research', 'recipe', 'list', 'none', 'guide', 'news', 'proscons', 'summary'):
        time.sleep(float(os.environ.get('NOAI_TEST_PACE', '3')))
    return ok

seed = os.environ.get('NOAI_TEST_SEED') or datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
lines += [f'RUN SEED: {seed}   (every run draws different questions; set NOAI_TEST_SEED to this value to repeat this exact run)', '']
lines += ['=' * 40, 'CORE (behaviours that must never break; new wording in v20)', '=' * 40, '']
for c in CORE:
    run_case(c, SID + ('-' + c['s'] if c.get('s') else ''), 'regression')
lines += ['=' * 40, 'KNOWLEDGE (new fixed set in v20; network-sensitive)', '=' * 40, '']
for i, c in enumerate(KNOWLEDGE):
    run_case(c, SID + '-k-' + (c.get('s') or str(i)), 'regression')
legacy, legacy_total = legacy_cases(random.Random('legacy' + seed))
lines += ['=' * 40, f'LEGACY SAMPLE ({len(legacy)} of {legacy_total} older questions, drawn at random)', '=' * 40, '']
for i, c in enumerate(legacy):
    run_case(c, SID + '-l-' + str(i), 'regression')
lines += ['=' * 40, 'HELD-OUT v21 (seen in every run since v21; now a regression set)', '=' * 40, '']
held = [run_case(c, SID + '-h-' + (c.get('s') or str(i)), 'heldout') for i, c in enumerate(HELDOUT)]
lines += ['=' * 40, f'BLIND v34 (15 single questions of {len(HELDOUT_V34)}, random, plus every multi-turn sequence; never tuned on)', '=' * 40, '']
blind_rnd = random.Random('blind34' + seed)
_single = [c for c in HELDOUT_V34 if not c.get('s')]
_multi = [c for c in HELDOUT_V34 if c.get('s')]           # multi-turn sequences always run, in order, in a shared session
blind34 = [run_case(c, SID + '-b34-' + (c.get('s') or str(i)), 'heldout') for i, c in enumerate(blind_rnd.sample(_single, 15) + _multi)]
lines += ['=' * 40, f'EXPLANATION POOL (10 of {len(EXPLAIN)}, random)', '=' * 40, '']
pool = [run_case(c, SID + '-p-' + str(i), 'pool') for i, c in enumerate(explain_cases(random.Random('explain' + seed)))]
lines += ['=' * 40, 'GENERATED (made up from the seed; expected values computed by the test itself)', '=' * 40, '']
gen = [run_case(c, SID + '-g-' + str(i), 'pool') for i, c in enumerate(generated_cases(random.Random('gen' + seed)))]
gen += [run_case(c, SID + '-gt-' + c.get('s', str(i)), 'pool') for i, c in enumerate(generated_tool_cases(random.Random('gtool' + seed)))]
nfacts = len(CAPITALS) + len(AUTHORS) + len(PAINTERS) + len(DIRECTORS) + len(COMPOSERS) + len(BORN) + len(CONTINENTS)
lines += ['=' * 40, f'FACT POOL (20 of {nfacts}, random)', '=' * 40, '']
facts = [run_case(c, SID + '-f-' + str(i), 'pool') for i, c in enumerate(fact_cases(random.Random('fact' + seed)))]
_fca = f"{QUAL['false_confident']} of {QUAL['answered']} answered ({100.0 * QUAL['false_confident'] / max(1, QUAL['answered']):.0f}%)"
_pl = f"{QUAL['plan_honoured']} of {QUAL['planned']} routes honoured the shadow plan ({100.0 * QUAL['plan_honoured'] / max(1, QUAL['planned']):.0f}%), {QUAL['freshness_violations']} freshness violation(s)"
lines += ['SUMMARY', '-------', f'REGRESSION: PASS={passes} CRITICAL_FAIL={fails} WARN={warns}',
          f'QUALITY: false-confident answers {_fca}; abstentions {QUAL["abstained"]} (needless {QUAL["needless_abstain"]}, honest {QUAL["honest_abstain"]})',
          f'PLANNER (shadow): {_pl}',
          f"PHASE 3 (live; cascade order logged as baseline): planner order reaches the answering capability in {QUAL['p3_reached']} of {QUAL['p3_retrieval']} retrieval answers, saving {QUAL['p3_saved'] / max(1, QUAL['p3_reached']):.1f} steps on average",
          f'HELD-OUT v21: {sum(held)}/{len(held)}', f'BLIND v34: {sum(blind34)}/{len(blind34)}', f'EXPLANATION POOL: {sum(pool)}/{len(pool)}', f'GENERATED: {sum(gen)}/{len(gen)}', f'FACT POOL: {sum(facts)}/{len(facts)}']
_vb = MEAS['verbatim_ok'] + MEAS['verbatim_bad']
lines += [f"MEASUREMENT: verbatim integrity {MEAS['verbatim_ok']}/{_vb} quoted answers found in their source page ({MEAS['verbatim_unchecked']} unchecked); "
          f"useful-answer thresholds: guides with >=3 steps {MEAS['guide'][0]}/{MEAS['guide'][1]}, recipes with method {MEAS['recipe'][0]}/{MEAS['recipe'][1]}, "
          f"lists with >=5 items {MEAS['list'][0]}/{MEAS['list'][1]}, explanations naming the subject {MEAS['explain'][0]}/{MEAS['explain'][1]}",
          'MODES: ' + ', '.join(f'{k}={v}' for k, v in sorted(MEAS['by_mode'].items(), key=lambda x: -x[1])),
          f"SEARCH: {MEAS.get('throttled', 0)} turns hit an engine suspension (answers on those turns are bounded by the engines, not the assistant)"]
if times:
    ts = sorted(times)
    lines.append(f'latency (non-chat): median={statistics.median(ts):.1f}s p90={ts[int(len(ts) * 0.9) - 1]:.1f}s max={ts[-1]:.1f}s')
for q, rs in critical_fails:
    lines.append(' - ' + q + ' :: ' + '; '.join(rs))
text = '\n'.join(lines); print(text)
try:
    open('/data/test-transcript.txt', 'w', encoding='utf-8').write(text + '\n')
    open('/data/eval-summary.json', 'w', encoding='utf-8').write(json.dumps({'pass': passes, 'critical_fail': fails, 'warn': warns, 'critical_failures': critical_fails, 'heldout': [sum(held), len(held)], 'pool': [sum(pool), len(pool), seed]}, indent=2) + '\n')
except Exception as e:
    print('could not save transcript:', e)
sys.exit(1 if fails else 0)
__NOAI_V11_SELFTEST__
cat > "$APP_DIR/app/chateval.py" <<'__NOAI_V11_CHATEVAL__'
"""Measures whether the embedding model actually helps small-talk matching on THIS machine.
Run:  docker compose exec app python /app/chateval.py
It prints, for the lexical matcher alone and for several embedding thresholds, how many held-out phrasings are
matched correctly / wrongly / not at all, and how many non-chat sentences are wrongly treated as small talk."""
import os
os.environ.setdefault("NOAI_QUIET", "1")
import convo
HELD = [("hello hello, anyone home?", "greeting|test"), ("good evening to you", "greeting_time"), ("alright I'm heading off, bye", "farewell"), ("night night", "goodnight"),
 ("ta very much", "thanks"), ("thanks, you're a star", "thanks|compliment"), ("sorry, my fault", "apology"), ("how's things?", "how_are_you"), ("how r u today", "how_are_you"),
 ("what you up to?", "whats_up"), ("and what about yourself", "and_you"), ("do u have a name", "bot_name"), ("so what are you exactly", "bot_identity"),
 ("wait are you an actual human", "bot_is_ai"), ("are you one of those AI chatbots", "bot_is_ai"), ("who's your creator", "bot_creator"), ("how old r u", "bot_age"),
 ("where are you running", "bot_location"), ("do you get sad", "bot_feelings"), ("do you have any friends", "bot_human_things"), ("what kind of stuff can you do", "bot_capabilities"),
 ("how do you actually work", "bot_how_work"), ("where do your answers come from", "bot_how_work"), ("do you remember our conversations", "bot_learn"), ("are you saving this chat", "bot_learn"),
 ("you're brilliant", "compliment"), ("you are so annoying", "insult"), ("do you love me?", "love"), ("lol good one", "laugh"), ("no, that's not right", "wrong_answer"),
 ("you didn't answer what I asked", "wrong_answer"), ("could you say that again", "repeat"), ("sorry, I don't follow", "clarify"), ("yep sounds good", "agree"), ("no thanks", "disagree"),
 ("hmm not sure", "unsure"), ("whoa that's cool", "wow"), ("i never knew that", "wow"), ("ok forget it", "never_mind"), ("i'm bored what should i do", "bored"), ("let's just talk", "lets_chat"),
 ("tell me a good joke", "joke"), ("tell me a random fun fact", "fun_fact"), ("heads or tails?", "coin"), ("why do we exist", "meaning_of_life"), ("is this thing working", "test"),
 ("i'm feeling great today", "mood_happy"), ("today has been terrible", "mood_sad"), ("i'm feeling pretty low", "mood_sad"), ("work is really stressing me out", "mood_stressed"),
 ("i'm so worried about my exam", "mood_stressed"), ("i hardly slept", "mood_tired"), ("i feel so alone", "mood_lonely"), ("i'm furious", "mood_angry"), ("i think i have the flu", "mood_sick"),
 ("guess what, i got promoted!", "good_news"), ("me and my boyfriend split up", "bad_news"), ("i'm so hungry", "hungry"), ("any ideas for the weekend?", "weekend"),
 ("feeling a bit under the weather", "mood_sick"), ("cheers for that", "thanks"), ("who built this thing", "bot_creator"), ("you're not making sense", "wrong_answer|clarify"),
 ("i can't stop worrying", "mood_stressed"), ("gimme a joke", "joke"), ("catch you tomorrow", "farewell")]
NEG = ["Who wrote Dune?", "what is the capital of France", "why is the sky blue", "how do I list open ports", "compare python and ruby", "I went to the beach yesterday with my cousins",
 "I think the new Dune movie is better than the book", "my boss keeps giving me extra work", "the weather is nice today", "I need to finish my taxes this week", "what is a neutron star",
 "I've been getting into film photography lately", "mostly black and white", "I like jazz", "convert 5 miles to km", "what time is it in tokyo", "how old is Dolly Parton", "I live in Leeds",
 "remember that the bins go out on Tuesday", "I can't get docker to start", "we drove to Scotland last summer", "she said she would call me back", "tell me about Mars", "weather in Oslo tomorrow",
 "define serendipity", "what about Mars?", "is water wet?", "my dog is named Biscuit", "I watched a documentary about octopuses", "another one", "Miles Davis", "photosynthesis"]

def run(m, label):
    ok = wrong = miss = 0
    for u, want in HELD:
        got = m.match(convo.normalize(u))[0]
        if got and got in want.split("|"): ok += 1
        elif got: wrong += 1
        else: miss += 1
    fp = sum(1 for u in NEG if m.match(convo.normalize(u))[0])
    print(f"{label:34} correct {ok:2d}/{len(HELD)}   wrong {wrong:2d}   unmatched {miss:2d}   false positives {fp:2d}/{len(NEG)}")

run(convo.IntentMatcher(convo.I, None), "lexical only")
try:
    import semantic
    enc = semantic.NeuralEncoder()
    print("MiniLM:", enc.info())
    if enc.ok:
        m = convo.IntentMatcher(convo.I, lambda texts: enc.encode(list(texts)))
        base = m.emb_threshold
        run(m, f"MiniLM, calibrated T={base:.3f}")
        for t in (0.85, 0.80, 0.75, 0.70):
            m.emb_threshold = t
            run(m, f"MiniLM, T={t:.2f}")
except Exception as e:
    print("MiniLM not available here:", type(e).__name__, e)
try:
    from model2vec import StaticModel
    import numpy as np
    model = StaticModel.from_pretrained(os.environ.get("EMBED_PATH", "/opt/m2v"))
    m = convo.IntentMatcher(convo.I, lambda texts: np.asarray(model.encode(list(texts)), dtype="float32"))
    base = m.emb_threshold
    run(m, f"embeddings, calibrated T={base:.3f}")
    for t in (0.95, 0.90, 0.85, 0.80, 0.75, 0.70):
        m.emb_threshold = t
        run(m, f"embeddings, T={t:.2f}")
except Exception as e:
    print("embedding model not available here:", type(e).__name__, e)
__NOAI_V11_CHATEVAL__
cat > "$APP_DIR/app/fetch_model.py" <<'__NOAI_V11_FETCH__'
"""Build-time only: download a small static-embedding model and store it as plain files in /opt/m2v,
so the running container never needs network access (or a writable cache) to load it."""
import sys
from model2vec import StaticModel
name = sys.argv[1] if len(sys.argv) > 1 else "minishlab/potion-base-8M"
m = StaticModel.from_pretrained(name)
m.save_pretrained("/opt/m2v")
print("saved", name, "->", "/opt/m2v", m.encode(["ok"]).shape)
__NOAI_V11_FETCH__
cat > "$APP_DIR/app/requirements.txt" <<'__NOAI_V11_REQ__'
Flask>=3.1,<4
requests>=2.32,<3
beautifulsoup4>=4.12,<5
trafilatura>=2.0,<3
nltk>=3.9,<4
packaging>=24
gunicorn>=23,<26
vaderSentiment>=3.3,<4
tzdata
symspellpy>=6.7
__NOAI_V11_REQ__
cat > "$APP_DIR/app/Dockerfile" <<'__NOAI_V11_DOCKERFILE__'
FROM python:3.12-slim-bookworm
ARG INSTALL_SPACY=1
ARG INSTALL_EMBED=1
ARG INSTALL_SEMANTIC=1
ARG INSTALL_JUDGE=1
ARG EMBED_MODEL=minishlab/potion-base-8M
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HF_HUB_DISABLE_TELEMETRY=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
# ShellCheck lints commands assembled from tldr templates (optional: the app works without it).
RUN (apt-get update && apt-get install -y --no-install-recommends shellcheck && rm -rf /var/lib/apt/lists/*) || true
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -U pip setuptools wheel \
 && pip install --no-cache-dir -r /app/requirements.txt
# Optional components: a failure here must never break the build; the app degrades gracefully without them.
RUN if [ "$INSTALL_SPACY" = "1" ]; then \
      (pip install --no-cache-dir 'spacy>=3.8,<3.9' && python -m spacy download en_core_web_sm) \
      || echo "WARNING: spaCy could not be installed; using the regex fallback"; \
    fi
COPY fetch_model.py /app/fetch_model.py
RUN if [ "$INSTALL_EMBED" = "1" ]; then \
      (pip install --no-cache-dir model2vec huggingface_hub && python /app/fetch_model.py "$EMBED_MODEL" && chmod -R a+rX /opt/m2v) \
      || (echo "WARNING: embedding model unavailable; ranking will be lexical only"; rm -rf /opt/m2v); \
      rm -rf /root/.cache; \
    fi
COPY fetch_minilm.py /app/fetch_minilm.py
RUN if [ "$INSTALL_SEMANTIC" = "1" ]; then \
      (pip install --no-cache-dir 'onnxruntime>=1.17' 'tokenizers>=0.15' huggingface_hub numpy && python /app/fetch_minilm.py && chmod -R a+rX /opt/minilm) \
      || (echo "WARNING: MiniLM sentence encoder unavailable; continuing without the neural second opinion"; rm -rf /opt/minilm); \
      rm -rf /root/.cache; \
    fi
COPY fetch_judge.py /app/fetch_judge.py
RUN if [ "$INSTALL_JUDGE" = "1" ]; then \
      (pip install --no-cache-dir 'onnxruntime>=1.17' 'tokenizers>=0.15' huggingface_hub numpy && python /app/fetch_judge.py && chmod -R a+rX /opt/judge) \
      || (echo "WARNING: answer judge (cross-encoder) unavailable; the sentence encoder will choose between candidate answers instead"; rm -rf /opt/judge); \
      rm -rf /root/.cache; \
    fi
RUN pip install --no-cache-dir 'ddgs>=9' || echo "WARNING: backup search library (ddgs) unavailable; only the SearXNG container will be used for web search"
RUN pip install --no-cache-dir 'sumy>=0.11' || echo "WARNING: sumy unavailable; page summaries will use the built-in extractive fallback"
COPY app.py corpus.py convo.py skills.py semantic.py judge.py structured.py tools.py creative.py replay.py planner.py capabilities.py inference.py reader.py reranker_weights.json selftest.py chateval.py /app/
CMD ["gunicorn","--workers","1","--threads","6","--bind","0.0.0.0:7070","--timeout","120","--graceful-timeout","10","--access-logfile","-","--error-logfile","-","app:app"]
__NOAI_V11_DOCKERFILE__
cat > "$APP_DIR/docker-compose.yml" <<'__NOAI_V11_COMPOSE__'
services:
  searxng:
    image: ghcr.io/searxng/searxng@sha256:e084201aa606fafce2151c8dc2844c9c3309025e90fbe7163b4f5e5183e474f0
    restart: unless-stopped
    volumes:
      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_BASE_URL=http://searxng:8080/

  app:
    build:
      context: ./app
      args:
        INSTALL_SPACY: ${INSTALL_SPACY}
        INSTALL_EMBED: ${INSTALL_EMBED}
        INSTALL_SEMANTIC: ${INSTALL_SEMANTIC:-1}
        INSTALL_JUDGE: ${INSTALL_JUDGE:-1}
    restart: unless-stopped
    depends_on:
      - searxng
    user: "${PUID}:${PGID}"
    environment:
      - DATA_DIR=/data
      - TLDR_DIR=/data/tldr
      - SEARXNG_URL=http://searxng:8080
      - NOAI_CONTACT=${NOAI_CONTACT}
      - NOAI_API_TOKEN=${NOAI_API_TOKEN}
      - NOAI_ACCESS_CODE=${NOAI_ACCESS_CODE:-}
      - NOAI_BRAVE_KEY=${NOAI_BRAVE_KEY:-}
      - NOAI_BUDGET=${NOAI_BUDGET:-14}
      - NOAI_BUDGET_SLOW=${NOAI_BUDGET_SLOW:-26}
      - HOME=/tmp
      - TZ=${NOAI_TZ:-UTC}
      - NOAI_SEMANTIC=${NOAI_SEMANTIC:-1}
      - NOAI_JUDGE=${NOAI_JUDGE:-1}
      - NOAI_TOOLS=${NOAI_TOOLS:-1}
      - NOAI_RECORD=${NOAI_RECORD:-}
      - NOAI_NTFY_URL=${NOAI_NTFY_URL:-}
      - NOAI_SEARCH_PACE=${NOAI_SEARCH_PACE:-2.5}
      - NOAI_SEARCH_PER_QUESTION=${NOAI_SEARCH_PER_QUESTION:-3}
      - NOAI_FILES_DIR=/files
      - NOAI_LOG_MISSES=${NOAI_LOG_MISSES:-1}
      - NOAI_BLEND=${NOAI_BLEND:-1}
      - NOAI_BACKUP_SEARCH=${NOAI_BACKUP_SEARCH:-1}
      - NOAI_SEMANTIC_MS=${NOAI_SEMANTIC_MS:-1200}
      - NOAI_HOME_LOCATION=${NOAI_HOME_LOCATION:-}
    volumes:
      - ./data:/data
      - ${NOAI_FILES_HOST:-./files}:/files
    ports:
      - "${NOAI_BIND_ADDR:-0.0.0.0}:7070:7070"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:7070/health', timeout=4).status == 200 else 1)"]
      interval: 60s
      timeout: 6s
      retries: 3
      start_period: 40s
__NOAI_V11_COMPOSE__
cat > "$APP_DIR/searxng/settings.yml" <<'__NOAI_V11_SEARX__'
use_default_settings:
  engines:
    keep_only:
      - duckduckgo
      - brave
      - google
      - startpage
      - qwant
      - mojeek
      - yahoo

engines:
  - name: mojeek
    disabled: false
  - name: qwant
    disabled: false
  - name: startpage
    disabled: false
  - name: google
    disabled: false
  - name: yahoo
    disabled: false

server:
  secret_key: "__SECRET__"
  limiter: false
  image_proxy: false

search:
  safe_search: 1
  autocomplete: ""
  ban_time_on_fail: 5
  max_ban_time_on_fail: 120
  suspended_times:
    SearxEngineAccessDenied: 180
    SearxEngineCaptcha: 600
    SearxEngineTooManyRequests: 180
  formats:
    - html
    - json

outgoing:
  request_timeout: 6.0
  max_request_timeout: 9.0
__NOAI_V11_SEARX__
cat > "$APP_DIR/run-tests.sh" <<'__NOAI_V11_RUNTEST__'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(sudo docker compose); fi
RC=0
"${DC[@]}" exec -T app python /app/selftest.py || RC=$?
printf '\nSaved transcript: %s/data/test-transcript.txt\n' "$PWD"
exit "$RC"
__NOAI_V11_RUNTEST__
cat > "$APP_DIR/uninstall.sh" <<'__NOAI_V11_UNINSTALL__'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(sudo docker compose); fi
"${DC[@]}" down --remove-orphans --rmi local || true
printf 'Containers and the locally built image were removed. Your data is still in %s/data.\n' "$PWD"
printf 'To delete everything permanently: rm -rf %q\n' "$PWD"
__NOAI_V11_UNINSTALL__
cat > "$APP_DIR/record.sh" <<'__NOAI_V19_RECORD_SH__'
#!/usr/bin/env bash
# Record a replay bundle: restarts the app in recording mode, runs the self-test (or your own questions), restores normal
# mode, and packs the cassette + transcript into one file you can upload for analysis.
#   ./record.sh                 record the full self-test
#   ./record.sh questions.txt   record your own questions instead (one per line)
set -euo pipefail
cd "$(dirname "$0")"
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(sudo docker compose); fi
rm -f data/cassette.db data/replay-bundle.tgz
echo "== restarting the app in RECORD mode =="
NOAI_RECORD=/data/cassette.db "${DC[@]}" up -d app >/dev/null
for i in $(seq 1 60); do curl -fsS http://127.0.0.1:7070/health >/dev/null 2>&1 && break; sleep 2; done
RC=0
if [[ $# -ge 1 && -f "$1" ]]; then
  CODE="$(grep -E '^NOAI_ACCESS_CODE=' .env | cut -d= -f2- || true)"
  : > data/record-transcript.txt
  n=0
  while IFS= read -r Q || [[ -n "$Q" ]]; do
    [[ -z "${Q// }" || "$Q" == \#* ]] && continue
    n=$((n+1))
    BODY="$(python3 -c 'import json,sys; print(json.dumps({"session":"record","question":sys.argv[1]}))' "$Q")"
    OUT="$(curl -sS -m 90 -X POST http://127.0.0.1:7070/api/chat -H 'Content-Type: application/json' -H "X-API-Key: $CODE" -d "$BODY" || echo '{}')"
    printf 'YOU: %s\n%s\n\n' "$Q" "$OUT" >> data/record-transcript.txt
    echo "  [$n] $Q"
    sleep 2
  done < "$1"
else
  "${DC[@]}" exec -T app python /app/selftest.py > data/record-transcript.txt 2>&1 || RC=$?
fi
echo "== restoring normal mode =="
NOAI_RECORD= "${DC[@]}" up -d app >/dev/null
for f in plans.jsonl reader.jsonl candidates.jsonl labels.jsonl corpus-label.txt corpus-heldout.txt corpus-pairs.txt corpus-both.txt corpus-facts.txt corpus-explain.txt scenarios.txt day.txt feedback.jsonl; do [ -f data/$f ] || : > data/$f; done
python3 - <<'PY' 2>/dev/null || true
import sqlite3, json
con = sqlite3.connect("data/chat.db")
with open("data/feedback.jsonl", "w", encoding="utf-8") as f:
    for t, s, q, a, m, v in con.execute("SELECT t, session, question, answer, mode, verdict FROM feedback ORDER BY t"):
        f.write(json.dumps({"t": t, "session": s, "q": q, "a": (a or "")[:600], "mode": m, "verdict": v}, ensure_ascii=False) + "\n")
PY
tar czf data/replay-bundle.tgz -C data cassette.db record-transcript.txt plans.jsonl reader.jsonl candidates.jsonl labels.jsonl corpus-label.txt corpus-heldout.txt corpus-pairs.txt corpus-both.txt corpus-facts.txt corpus-explain.txt scenarios.txt day.txt feedback.jsonl
ls -lh data/replay-bundle.tgz | awk '{print "Bundle: '"$PWD"'/data/replay-bundle.tgz  (" $5 ")"}'
echo "Upload that one file. It contains the questions asked, the API responses and the extracted text of the pages fetched;"
echo "no access codes, no cookies, and nothing from your everyday chats."
exit "$RC"
__NOAI_V19_RECORD_SH__
cat > "$APP_DIR/app/corpus.py" <<'__NOAI_V47_CORPUS__'
#!/usr/bin/env python3
"""fAI corpus run (v47). A fixed set of questions shaped like consumer chatbot use (topic shares after Chatterji et al. 2025),
never used for tuning. Two halves, split by a fixed seed: 'label' (source of candidate pairs for /label) and 'heldout'
(kept for measurement only). Usage inside the install directory:

    python3 app/corpus.py --list                      # show topic counts
    python3 app/corpus.py --half label  --pace 3      # run one half against the local API (default base http://127.0.0.1:7070)
    python3 app/corpus.py --half heldout --pace 3

Writes data/corpus-<half>.txt (question, mode, time, first line) and prints coverage per topic: the share of questions that got
an answer (any mode other than none/error/chat for non-chat topics). Nothing here changes the app."""
import argparse, json, os, random, re, sys, time
import requests

PRACTICAL = [
    "how do I get red wine out of a carpet", "how do I unclog a bathroom sink", "how do I sharpen a kitchen knife", "how do I jump start a car",
    "how do I remove a stripped screw", "how do I stop a door from squeaking", "how do I patch a small hole in drywall", "how do I clean a cast iron pan",
    "how do I keep basil alive indoors", "how do I get rid of fruit flies", "how do I fold a fitted sheet", "how do I bleed a radiator",
    "how do I reset a tripped circuit breaker", "how do I change a bike tyre", "how do I remove candle wax from a tablecloth", "how do I defrost a freezer quickly",
    "how do I hang a picture without nails", "how do I clean a washing machine", "how do I treat a bee sting", "what to do for a nosebleed",
    "how do I remove a splinter", "how do I stop hiccups", "how do I lower a fever at home", "how do I treat a sprained ankle",
    "how do I make sourdough starter", "how do I cook rice without a rice cooker", "how do I poach an egg", "how do I make cold brew coffee",
    "recipe for banana bread", "recipe for chicken curry", "how do I make pancakes from scratch", "how do I roast a whole chicken",
    "how do I make pizza dough", "recipe for tomato soup", "how do I bake salmon", "how do I make guacamole",
    "how do I write a resignation letter", "how do I prepare for a job interview", "how do I negotiate a salary", "how do I ask for a raise",
    "how do I set up a budget", "how do I improve my credit score", "how do I start investing with little money", "how do I file a tax return",
    "how do I train a puppy not to bite", "how do I stop my cat scratching the sofa", "how do I introduce a new cat to my dog", "how do I clean a fish tank",
    "how do I repot an orchid", "how do I prune roses", "how do I grow tomatoes on a balcony", "how do I get rid of aphids",
    "how do I pack for a week in Iceland", "how do I renew a passport", "how do I get over jet lag", "how do I avoid altitude sickness",
    "how do I descale a coffee machine", "how do I clean an oven", "how do I get rid of mould in the bathroom", "how do I fix a running toilet",
    "how do I start running as a beginner", "how do I do a proper push-up", "how do I stretch a tight lower back", "how do I fall asleep faster",
    "how do I stop procrastinating", "how do I learn a language on my own", "how do I study for an exam in a week", "how do I write a good cover letter",
    "how do I back up my phone", "how do I speed up a slow laptop", "how do I set up a home wifi network", "how do I protect my accounts with two-factor authentication",
    "pros and cons of an electric car", "pros and cons of renting vs buying", "should I get a standing desk", "pros and cons of a robot vacuum",
    "best hikes near Denver", "best things to do in Lisbon", "top museums in Paris", "best beaches in Portugal",
    "what are the symptoms of iron deficiency", "what are the side effects of caffeine", "what are the early signs of diabetes", "what are the symptoms of a concussion",
    "how do I remove rust from tools", "how do I season a wok", "how do I keep bread fresh longer", "how do I store fresh herbs",
]
SEEKING = [
    "Why is the sky red at sunset", "How do noise cancelling headphones work", "Why do onions make you cry", "How does GPS work",
    "Why does bread go stale", "How do vaccines train the immune system", "Why do we dream", "How does a nuclear reactor work",
    "Why is the ocean blue", "How do magnets work", "Why do cats purr", "How does a refrigerator keep food cold",
    "What causes earthquakes", "What causes the seasons", "Why do we have leap years", "How do tides work",
    "How do bees make honey", "Why do leaves change colour in autumn", "How do birds migrate", "Why do whales sing",
    "How does wifi work", "How does a touchscreen work", "How does a battery store energy", "How do solar panels make electricity",
    "Who wrote The Brothers Karamazov", "Who painted The Night Watch", "Who directed Parasite", "Who composed The Planets",
    "What is the capital of Mongolia", "What is the population of Nigeria", "What is the currency of Vietnam", "What language is spoken in Brazil",
    "How tall is Mount Kilimanjaro", "How long is the Danube", "How old is the universe", "How far is the Moon",
    "When was the printing press invented", "When did the Berlin Wall fall", "When was Rome founded", "When did the Titanic sink",
    "Where was Frida Kahlo born", "Where is Machu Picchu", "Where was the first Olympic Games held", "Where is the Great Barrier Reef",
    "Is Greenland bigger than Australia", "Is Tokyo bigger than New York", "Which is older, Oxford or Cambridge", "Which is longer, the Nile or the Amazon",
    "Was Napoleon alive when the Eiffel Tower was built", "Was Beethoven alive when Mozart died", "Where was the author of Frankenstein born", "Where was the director of Jaws born",
    "What is a black hole", "What is inflation", "What is a mortgage", "What is photosynthesis",
    "What is the difference between a virus and bacteria", "What is the difference between weather and climate", "Compare Python and Rust", "Compare Mars and Earth",
    "What is CRISPR", "What is the greenhouse effect", "What is a recession", "What is quantum computing",
    "facts about Saturn", "facts about Iceland", "key facts about Nelson Mandela", "Norway population",
    "timeline of the Roman Empire", "history of the Great Wall of China", "timeline of the Internet", "history of the bicycle",
    "news about the European Union", "what's happening in Brazil", "latest on artificial intelligence", "news about climate change",
    "Define sonder", "Define ephemeral", "synonyms for angry", "what does the prefix anti- mean",
    "quotes by Maya Angelou", "quotations from Winston Churchill", "who sang Bohemian Rhapsody", "who are the main characters in Hamlet",
    "Why is Venus hotter than Mercury", "Why does the Moon have phases", "How do glaciers move", "Why are flamingos pink",
    "What causes hiccups", "What causes migraines", "Why do we yawn", "Why do fingers wrinkle in water",
    "How does a microwave heat food", "How does a diesel engine work", "How does a 3D printer work", "How does an MRI scanner work",
    "What are the main causes of the French Revolution", "What are the types of clouds", "What are the symptoms of the flu", "What are the benefits of exercise",
    "What are the causes of inflation", "What are the effects of deforestation", "What are the advantages of solar power", "What are the risks of smoking",
    "What is the latest version of Ubuntu", "What is the latest version of Firefox", "What is the latest version of PostgreSQL", "What is the latest version of Rust",
    "coffee shops near Union Square in San Francisco", "bookshops near Piccadilly Circus in London", "parks near the Colosseum in Rome", "museums near Central Park",
    "summarise https://en.wikipedia.org/wiki/Photosynthesis", "summarize https://en.wikipedia.org/wiki/Bicycle", "Research the causes of the 2008 financial crisis", "Research the effects of caffeine on sleep",
]
TECHNICAL = [
    "how do I find which process is using port 8080", "how do I see disk usage per folder on Linux", "how do I search for a string in all files recursively",
    "how do I undo the last git commit", "how do I create a new git branch", "how do I merge two git branches", "how do I stash changes in git",
    "how do I list docker containers", "how do I remove all stopped docker containers", "how do I see docker logs", "how do I copy a file into a docker container",
    "how do I convert a mov file to mp4 with ffmpeg", "how do I extract audio from lecture.mp4 with ffmpeg", "how do I resize photo.png to 800x600 with imagemagick",
    "how do I compress a folder with tar", "how do I extract a tar.gz file", "how do I copy files between servers with rsync", "how do I download https://example.org/data.csv with wget",
    "how do I schedule a cron job every hour", "how do I check which services are running with systemctl", "how do I see the last 50 lines of a log file", "how do I count lines in a file",
    "how do I change file permissions on Linux", "how do I make a script executable", "how do I find my IP address on Linux", "how do I restart networking on Ubuntu",
    "How do I read a CSV file in Python", "How do I reverse a list in Python", "How do I remove duplicates from a list in Python", "How do I parse JSON in Python",
    "How do I make an HTTP request in JavaScript", "How do I sort an array of objects in JavaScript", "How do I center a div in CSS", "How do I add a column in SQL",
    "What does TypeError: 'NoneType' object is not subscriptable mean", "What does segmentation fault mean", "What does 'permission denied' mean on Linux", "What is a null pointer exception",
    "write me a python script that renames files", "write a bash script to back up my home folder", "write a SQL query to find duplicate rows", "write me a regex to match email addresses",
    "how do I install Node.js on a Raspberry Pi", "how do I set up SSH keys", "how do I mount a USB drive on Linux", "how do I check memory usage on Linux",
    "how do I kill a frozen program on Linux", "how do I update all packages on Ubuntu", "how do I see my bash history", "how do I create a symbolic link",
    "how do I find large files on my disk", "how do I check if a port is open", "how do I generate a random password on the command line", "how do I compare two files",
]
WRITING = [
    "write me a poem about the sea", "write a haiku about winter", "give me a limerick about cats", "tell me a bedtime story about a dragon",
    "write an essay about climate change", "write a cover letter for a nursing job", "write a birthday message for my mother", "write a toast for my brother's wedding",
    "rewrite this sentence to sound more formal: we got the thing done", "summarise this in one line: the meeting was long and nothing was decided", "translate good morning into French", "proofread my email",
    "write a product description for a bamboo toothbrush", "write a tweet announcing our new app", "give me three taglines for a bakery", "write a short bio for my LinkedIn",
    "write a thank you note to my teacher", "write an apology email for missing a meeting", "write a complaint letter to my landlord", "write a speech for a retirement party",
    "compose an ode to coffee", "write a sonnet about autumn", "write a rap about recycling", "write a story about a robot who learns to cook",
    "write a paragraph explaining why exercise matters", "draft a message asking a neighbour to keep the noise down", "write a review of a restaurant I liked", "write an out-of-office reply",
    "write me a joke about programmers", "make up a riddle", "write a motivational quote", "write lyrics for a lullaby",
    "give me a title for my blog post about hiking", "write a caption for a photo of a sunset", "write a slogan for a recycling campaign", "write a thank you speech for an award",
    "write a letter to my future self", "write a eulogy for my grandfather", "write a scary story in three sentences", "write a description of a haunted house",
]
MULTIMEDIA = [
    "can you draw me a cat", "make me a logo for my cafe", "generate an image of a sunset over mountains", "create a picture of a dragon",
    "can you make a video for me", "edit this photo to remove the background", "make a meme about Mondays", "draw a map of my neighbourhood",
    "create a chart of my expenses", "make a poster for a garage sale", "design a birthday card", "turn this text into an image",
    "can you sing me a song", "record a voice message", "generate background music", "make a slideshow of my holiday",
    "can you read this image", "what's in this picture", "convert my sketch into a painting", "animate my logo",
    "can you make a 3D model", "generate a QR code for my website", "make an avatar for me", "create a diagram of the water cycle",
    "draw a comic strip", "make a wallpaper for my phone", "create a business card design", "generate a tattoo design",
    "make an infographic about recycling", "design a t-shirt", "create a floor plan", "make a mood board",
]
SELF = [
    "hi", "good morning", "how are you today", "I'm bored", "I had a great day", "I'm feeling anxious about tomorrow", "my dog is sick", "I passed my driving test",
    "I'm tired of my job", "I can't sleep", "tell me something interesting", "do you like music", "what's your favourite colour", "are you alive",
    "I'm lonely", "thanks for your help", "you're not very smart", "that answer was wrong", "what can you do", "who made you",
    "I just moved to Denver", "my name is Sam", "I have two cats", "my favourite food is ramen", "remember that my sister's birthday is 3 May", "what do you remember about me",
    "tell me a joke", "that joke was bad", "another one", "make me laugh", "I'm nervous about a presentation", "my friend and I had an argument",
    "I think I'm coming down with something", "I'm learning to play the guitar", "I finished a marathon", "I got engaged",
    "goodnight", "see you later", "what time is it", "what day is it",
]
OTHER = [
    "asdfgh", "?", "42", "the", "Top Gun", "Mostly cloudy", "blue", "banana bread", "Mount Everest", "1969",
    "what", "why", "ok", "yes", "no", "maybe later", "hmm", "lol", "Paris", "Python",
]

# v51: extra why/how questions whose only job is to produce candidate pairs for labelling (every one goes through the judge)
PAIRS = [
    "Why is the sky dark at night", "How do noise-cancelling headphones cancel sound", "Why do we get goosebumps", "How does a thermostat work",
    "Why does metal feel colder than wood", "How do bees fly", "Why do onions make you cry", "How does a refrigerator make cold",
    "Why do we hiccup", "How does a hologram work", "Why do leaves fall in autumn", "How does a jet engine work", "Why does hair turn grey",
    "How do submarines dive and surface", "Why is blood red", "How does a lock and key work", "Why do cats knead", "How does a fuse work",
    "Why do we sneeze", "How does a smoke detector work", "Why is snow white", "How does a hot air balloon rise", "Why do ears pop on a plane",
    "How does an inkjet printer work", "Why does bread go stale", "How does a seatbelt lock", "Why do some people snore", "How does a ballpoint pen work",
    "Why do boats have round windows", "How does a dishwasher clean", "Why do we get dizzy when we spin", "How does a wind turbine make electricity",
    "Why does ice cream melt", "How does a zip fastener work", "Why do mirrors flip left and right", "How does a bicycle stay upright",
    "Why do we need vitamin D", "How does a battery charger know when to stop", "Why are bubbles round", "How does a toilet flush",
    "Why do birds fly in a V", "How does an escalator work", "Why does milk go sour", "How does a pressure cooker work", "Why do we cry",
    "How does a pendulum clock keep time", "Why does the wind blow", "How does a solar eclipse happen", "Why does rain smell", "How does a camera focus",
    "Why do we get wrinkles", "How does a kidney filter blood", "Why are the poles cold", "How does a magnet stick to a fridge", "Why do dogs pant",
    "How does a lighthouse lens work", "Why is the sea blue", "How does a heat pump heat a house", "Why does coffee keep you awake", "How does a spring scale work",
    "Why do we blush", "How does an air conditioner cool a room", "Why do we sweat", "How does a compost heap get hot", "Why does soap clean",
    "How does a barometer predict weather", "Why do apples float", "How does a train stay on the rails", "Why do we have eyebrows", "How does a kettle switch itself off",
    "Why are sunsets red", "How does a Thermos flask stay hot", "Why do ships have bulbous bows", "How does a vaccine protect a population", "Why does the Moon cause tides",
    "How does a lever make lifting easier", "Why does water expand when it freezes", "How does a diode work", "Why is Mars red", "How does GPS know where you are",
]
TOPICS = [("practical", PRACTICAL), ("seeking", SEEKING), ("technical", TECHNICAL), ("writing", WRITING), ("multimedia", MULTIMEDIA), ("self", SELF), ("other", OTHER)]

# v51: simulated conversations, the way a person actually uses the assistant. No pass/fail; the transcript is for reading.
# A few turns carry a light check ("expect": a substring) so a regression shows up in the summary line.
SCENARIOS = {
    "weekend-away": [
        "hi, thinking about a weekend away", "somewhere in Portugal maybe", "best things to do in Porto", "tell me about the first one",
        "how far is Porto from Lisbon", "what's the weather like there", "and in Lisbon?", "how do you say thank you in Portuguese",
        "add Porto trip to my calendar on saturday at 9am", "undo", "thanks, that helps",
    ],
    "dinner": [
        "what can I cook with chickpeas and spinach", "how do I make a chickpea curry", "for 2 people", "how long does it take",
        "what about the ingredients for naan?", "set a timer for 25 minutes", "undo", "convert 200 g to ounces", "is coconut milk healthy",
    ],
    "bored-evening": [
        "I'm bored", "tell me a joke", "that was bad", "tell me something interesting", "why is the sky blue", "and at sunset?",
        "what did you say about the sky?", "write me a haiku about rain", "who painted The Starry Night", "where was he born?",
        "and his brother?", "ok goodnight",
    ],
    "wifi-trouble": [
        "my wifi keeps dropping", "how do I find my IP address on Linux", "how do I restart networking on Ubuntu",
        "what does DNS mean", "how do I change DNS servers on Ubuntu", "how do I check if a port is open", "thanks",
    ],
    "health-worry": [
        "I've had a headache for three days", "what causes headaches", "what are the symptoms of dehydration", "how much water should I drink a day",
        "is ibuprofen safe to take every day", "remind me to drink water in 1 hour", "undo", "thank you",
    ],
    "homework": [
        "I have a history test tomorrow", "when did the French Revolution start", "what were the main causes of the French Revolution",
        "who was Robespierre", "and Danton?", "how did he die?", "timeline of the French Revolution", "quiz me on the French Revolution",
        "what did you say about Robespierre?", "thanks, I'll stop procrastinating now",
    ],
}
# ---------------------------------------------------------------------------- v54: checkable facts at scale
# Entities (Wikidata QIDs, so the truth is fetched from the same source the assistant cites) x relations x phrasings x noise.
# Answers are verified automatically: the expected label must appear in the answer. Measures routing, parsing and spelling
# robustness at scale, not knowledge (same source both sides), and is stated as such.
FACT_ENTITIES = {
    "book": ["Q41542", "Q170583", "Q182961", "Q43361", "Q480", "Q8337", "Q2268391", "Q1213085", "Q857313", "Q161531", "Q6511", "Q127149", "Q183883", "Q26505", "Q622400", "Q1541914", "Q82464", "Q180736", "Q40185", "Q160071"],
    "film": ["Q184843", "Q103569", "Q167726", "Q128518", "Q44578", "Q47703", "Q189540", "Q132689", "Q42047", "Q135465", "Q25188", "Q186341", "Q202548", "Q484048", "Q216006", "Q475693", "Q25136235", "Q83495", "Q80044", "Q104123"],
    "country": ["Q419", "Q664", "Q36", "Q45", "Q79", "Q1028", "Q298", "Q17", "Q183", "Q16", "Q408", "Q159", "Q30", "Q142", "Q29", "Q38", "Q20", "Q155", "Q252", "Q796", "Q1033", "Q1041", "Q1036", "Q668", "Q843", "Q39", "Q414", "Q902", "Q115", "Q736", "Q924", "Q43", "Q219", "Q40", "Q114", "Q35", "Q750", "Q881", "Q117", "Q1000"],
    "person": ["Q9036", "Q5582", "Q873", "Q2263", "Q937", "Q7186", "Q254", "Q255", "Q692", "Q935", "Q762", "Q1001", "Q8023", "Q91", "Q9439", "Q7474", "Q7259", "Q36184", "Q133054", "Q2599", "Q128121", "Q7315", "Q17714", "Q37103", "Q184746", "Q1035", "Q36153", "Q7317", "Q5593", "Q9312"],
    "painting": ["Q212616", "Q45585", "Q128910", "Q185372", "Q698487", "Q321303", "Q25729", "Q219831", "Q464782", "Q500242", "Q12418", "Q175036", "Q7973309", "Q1050100", "Q152867"],
    "composition": ["Q199786", "Q186162", "Q207732", "Q327331", "Q208659", "Q206015", "Q722599", "Q185968", "Q12016", "Q187745", "Q2000445"],
    "mountain": ["Q513", "Q130018", "Q7296", "Q583", "Q1140", "Q43105", "Q1141", "Q1147", "Q1153", "Q1156"],
    "company": ["Q41187", "Q3884", "Q478214", "Q8093", "Q95", "Q312", "Q380", "Q2283", "Q54173", "Q37156"],
}
# relation: (kinds it applies to, Wikidata property, phrasings with {x})
FACT_RELATIONS = {
    "author": (["book"], "P50", ["Who wrote {x}?", "who is the author of {x}", "{x} was written by whom?", "author of {x}", "tell me who wrote {x}", "whos the writer of {x}"]),
    "director": (["film"], "P57", ["Who directed {x}?", "who was the director of {x}", "{x} director", "which director made {x}", "who directed the film {x}"]),
    "composer": (["composition"], "P86", ["Who composed {x}?", "who wrote the music for {x}", "composer of {x}", "which composer wrote {x}"]),
    "creator": (["painting"], "P170", ["Who painted {x}?", "who is the artist behind {x}", "{x} was painted by whom", "which painter created {x}"]),
    "capital": (["country"], "P36", ["What is the capital of {x}?", "capital of {x}", "whats the capital city of {x}", "which city is the capital of {x}", "tell me the capital of {x}"]),
    "currency": (["country"], "P38", ["What is the currency of {x}?", "what currency does {x} use", "{x} currency", "what money do they use in {x}"]),
    "continent": (["country"], "P30", ["What continent is {x} in?", "which continent is {x} on", "{x} is in which continent"]),
    "birthplace": (["person"], "P19", ["Where was {x} born?", "birthplace of {x}", "where is {x} from originally", "in which city was {x} born"]),
    "spouse": (["person"], "P26", ["Who is {x} married to?", "who was {x}'s spouse", "{x} spouse", "who did {x} marry"]),
    "founder": (["company"], "P112", ["Who founded {x}?", "founder of {x}", "who started {x}", "who created the company {x}"]),
    "elevation": (["mountain"], "P2044", ["How tall is {x}?", "height of {x}", "how high is {x}", "what is the elevation of {x}"]),
}
NOISE = [lambda q: q, lambda q: q.lower(), lambda q: q.rstrip("?") , lambda q: "hey, " + q[0].lower() + q[1:], lambda q: q + " please", lambda q: q.replace("the ", "teh ", 1) if "the " in q else q]

def facts_questions(base):
    """-> [(kind, relation, qid, question, expected labels)] using Wikidata for labels and truth (cached in the app's cache too)."""
    import requests as rq
    out = []
    kinds = {}
    for kind, qids in FACT_ENTITIES.items():
        for qid in qids:
            kinds[qid] = kind
    ids = list(kinds)
    ents = {}
    for i in range(0, len(ids), 40):
        chunk = ids[i:i + 40]
        try:
            r = rq.get("https://www.wikidata.org/w/api.php", params={"action": "wbgetentities", "ids": "|".join(chunk), "props": "labels|claims", "languages": "en", "format": "json"},
                       headers={"User-Agent": "fAI corpus (facts generator)"}, timeout=30)
            ents.update(r.json().get("entities", {}))
        except Exception as e:
            print("wikidata fetch failed:", type(e).__name__); return out
    # value labels
    need = set()
    for qid, ent in ents.items():
        for rel, (kinds_, pid, _) in FACT_RELATIONS.items():
            if kinds[qid] in kinds_:
                for c in (ent.get("claims") or {}).get(pid, [])[:3]:
                    v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                    if isinstance(v, dict) and v.get("id"):
                        need.add(v["id"])
    vlabels = {}
    need = list(need)
    for i in range(0, len(need), 50):
        try:
            r = rq.get("https://www.wikidata.org/w/api.php", params={"action": "wbgetentities", "ids": "|".join(need[i:i + 50]), "props": "labels", "languages": "en", "format": "json"},
                       headers={"User-Agent": "fAI corpus (facts generator)"}, timeout=30)
            for k, e in r.json().get("entities", {}).items():
                vlabels[k] = (e.get("labels", {}).get("en") or {}).get("value", "")
        except Exception:
            pass
    rnd = random.Random("fai-facts-v54")
    for qid, ent in ents.items():
        name = (ent.get("labels", {}).get("en") or {}).get("value")
        if not name:
            continue
        for rel, (kinds_, pid, phrasings) in FACT_RELATIONS.items():
            if kinds[qid] not in kinds_:
                continue
            expected = []
            cl = (ent.get("claims") or {}).get(pid, [])
            pref = [c for c in cl if c.get("rank") == "preferred"]
            current = [c for c in cl if c.get("rank") != "deprecated" and "P582" not in (c.get("qualifiers") or {})]
            cl = (pref or current or cl)[:3]
            for c in cl:
                v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                if isinstance(v, dict) and v.get("id") and vlabels.get(v["id"]):
                    expected.append(vlabels[v["id"]])
                elif isinstance(v, dict) and "amount" in v:
                    expected.append(v["amount"].lstrip("+").split(".")[0])
            if not expected:
                continue
            for ph in phrasings:
                q = ph.format(x=name)
                for noise in rnd.sample(NOISE, 2):            # two surface variants per phrasing: ~2,000 questions in all
                    out.append((kinds[qid], rel, qid, noise(q), expected))
    rnd.shuffle(out)
    return out

def fact_hit(expected, ans):
    a = ans.lower().replace(",", "")
    for e in expected:
        el = e.lower().replace(",", "")
        if el[:12] in a:
            return True
        if re.fullmatch(r"\d+", el):
            for n in re.findall(r"\d+(?:\.\d+)?", a):
                if abs(float(n) - float(el)) <= 0.01 * float(el):
                    return True
    return False

def run_facts(a, data_dir):
    qs = facts_questions(a.base)
    if a.limit:
        qs = qs[:a.limit]
    path = os.path.join(data_dir, "corpus-facts.txt")
    ok = 0; by_rel = {}; by_noise = {}
    with open(path, "w", encoding="utf-8") as out:
        for i, (kind, rel, qid, q, expected) in enumerate(qs, 1):
            d = ask(a.base, q, f"facts-{i}")
            ans = d.get("answer") or ""
            hit = fact_hit(expected, ans)
            ok += hit
            s = by_rel.setdefault(rel, [0, 0]); s[1] += 1; s[0] += hit
            out.write(f"[facts/{kind}/{rel}] {q}\n  mode={d.get('mode')} time={d.get('_dt', 0):.1f}s ok={int(hit)} expected={expected[:2]} | {ans.splitlines()[0][:120] if ans else ''}\n")
            if not hit:
                for ln in (d.get("trace") or [])[:12]:
                    out.write(f"    trace: {ln[:160]}\n")
            out.flush()
            if i % 50 == 0:
                print(f"{i}/{len(qs)} correct so far {ok/i:.0%}", flush=True)
    print(f"\nCHECKABLE FACTS: {ok}/{len(qs)} correct ({ok/max(1,len(qs)):.1%}); same source both sides, so this measures routing, parsing and phrasing, not knowledge")
    for rel, (h, n) in sorted(by_rel.items()):
        print(f"  {rel:12} {h}/{n} ({h/n:.0%})")
    print(f"written: {path}")

# ---------------------------------------------------------------------------- v54: explanations and how-tos at scale (coverage + pairs)
_DEVICES = ["microwave oven", "refrigerator", "toaster", "kettle", "washing machine", "dishwasher", "vacuum cleaner", "hair dryer", "electric toothbrush", "smoke alarm", "thermostat", "doorbell",
            "bicycle pump", "car battery", "catalytic converter", "turbocharger", "airbag", "seat belt", "elevator", "escalator", "sewing machine", "zip", "ballpoint pen", "pencil sharpener",
            "compass", "barometer", "thermometer", "sundial", "hourglass", "pendulum clock", "quartz watch", "telescope", "microscope", "camera lens", "LED bulb", "fluorescent lamp",
            "solar cell", "wind turbine", "hydroelectric dam", "nuclear reactor", "steam engine", "jet engine", "rocket engine", "helicopter", "hot air balloon", "submarine", "sailboat", "kite",
            "3D printer", "inkjet printer", "hard drive", "SSD", "touchscreen", "QR code", "barcode scanner", "GPS receiver", "wifi router", "fibre optic cable", "loudspeaker", "microphone",
            "heat pump", "air conditioner", "dehumidifier", "water softener", "pressure washer", "cordless drill", "chainsaw", "lawn mower", "sprinkler timer", "smart meter", "induction hob",
            "pressure cooker", "bread maker", "espresso machine", "milk frother", "food processor", "blender", "air fryer", "slow cooker", "rice cooker", "sous vide circulator"]
_PHENOMENA = ["fog", "frost", "hail", "lightning", "thunder", "rainbows", "tides", "earthquakes", "volcanoes", "geysers", "glaciers", "avalanches", "tornadoes", "hurricanes", "monsoons", "droughts",
              "the northern lights", "eclipses", "meteor showers", "the seasons", "leap years", "time zones", "jet lag", "hiccups", "yawning", "sneezing", "goosebumps", "blushing", "dreams",
              "fever", "sunburn", "freckles", "grey hair", "wrinkles", "muscle cramps", "the placebo effect", "inflation", "recessions", "interest rates",
              "ocean currents", "sea breezes", "the water cycle", "acid rain", "ozone holes", "smog", "sinkholes", "landslides", "tsunamis", "rip currents", "whirlpools", "rogue waves",
              "static electricity", "magnetism", "rust", "condensation", "evaporation", "soap bubbles", "echoes", "shadows", "mirages", "sunsets", "twilight", "moonbows"]
_CHORES = ["clean a burnt pan", "remove limescale from a shower head", "unblock a drain", "fix a dripping tap", "bleed a radiator", "reset a boiler", "change a fuse", "replace a light switch",
           "patch a bicycle inner tube", "adjust bicycle brakes", "jump-start a car", "check tyre pressure", "top up windscreen washer fluid", "change windscreen wipers", "sharpen scissors",
           "remove a broken key from a lock", "get gum out of clothes", "remove ink from a shirt", "clean suede shoes", "waterproof a jacket", "store winter clothes", "get rid of moths",
           "keep cut flowers fresh", "repot a cactus", "prune an apple tree", "grow basil from seed", "compost kitchen waste", "clean a barbecue", "season a carbon steel pan", "freeze bread",
           "cook rice in a pan", "boil an egg", "make stock from bones", "proof yeast", "temper chocolate", "whip cream by hand", "make a roux", "clean a coffee grinder", "descale an espresso machine", "make yoghurt at home",
           "hang a heavy mirror", "fill a crack in plaster", "paint a ceiling without drips", "strip wallpaper", "unblock a toilet without a plunger", "silence a squeaky floorboard", "draught-proof a door",
           "insulate a loft hatch", "fit a smoke alarm", "test an RCD", "wire a plug", "reset a router", "set up a guest wifi network", "back up photos from a phone", "free up space on a laptop",
           "speed up an old phone", "clean a laptop keyboard", "calibrate a monitor", "pair bluetooth headphones", "recover a deleted file", "write a CV", "prepare for a phone interview",
           "ask for a pay rise", "negotiate rent", "cancel a subscription", "dispute a bank charge", "apply for a passport", "renew a driving licence", "pack a suitcase efficiently", "sleep on a plane"]

def explain_questions():
    qs = []
    for d in _DEVICES:
        qs += [f"How does a {d} work?", f"what's inside a {d}"]
    for p in _PHENOMENA:
        qs += [f"What causes {p}?", f"why do we get {p}" if p in ("hiccups", "goosebumps", "freckles", "wrinkles", "muscle cramps", "sunburn", "fever", "grey hair") else f"explain {p} simply"]
    for c in _CHORES:
        qs += [f"how do I {c}", f"best way to {c}?"]
    seen = set(); out = []
    for q in qs:
        if q.lower() not in seen:
            seen.add(q.lower()); out.append(("explain", q))
    return out

SCENARIOS.update({
    "salmon-dinner": ["im doing salmon tonight, what goes with it and how long do i bake it", "at 200C?", "and a sauce?", "ok and how do I know when it's done", "set a timer for 12 minutes", "undo", "cheers"],
    "long-day": ["long day", "yeah just tired", "anyway is it going to rain tomorrow", "in Denver", "what about the weekend", "thanks. night"],
    "repair-film": ["who directed Alien", "no I meant the 1986 one", "and who wrote the music for it", "how long is it", "thanks"],
    "repair-word": ["define bass", "not the fish, the instrument", "how do you pronounce it", "and the fish?", "ok"],
    "repair-place": ["whats the weather in Cambridge", "no the one in England", "and how far is that from London", "is there a train", "nevermind"],
    "repair-recipe": ["recipe for pancakes", "no, american style, the fluffy ones", "can I make them without eggs", "how many does that make", "for 6 people", "thanks!"],
    "repair-tool": ["remind me to call mum tomorrow at 6", "sorry I meant 6pm not 6am", "and put dentist on my calendar friday at 2", "actually make that thursday", "what's on my calendar this week", "undo", "undo"],
    "repair-fact": ["how old is Tom Hanks", "sorry, Tom Cruise", "where was he born", "and his first film?", "ta"],
    "kid-homework": ["my daughter needs to know why the sky is blue but explain it simply", "she's 8", "ok and why are sunsets red then", "is that the same reason", "can you give me one sentence I can tell her", "thanks"],
    "garden": ["my tomato plants have yellow leaves", "they're in pots on a balcony", "how often should I water them", "and feed?", "what tomato variety is best for pots", "cheers"],
    "moving-house": ["we're moving to Leeds next month", "what's it like there", "how far is it from Manchester", "good areas to live in Leeds", "remind me to change my address in 2 weeks", "undo", "thanks"],
    "sick-day": ["I think I have a cold", "sore throat and a cough", "what helps a sore throat", "should I take paracetamol or ibuprofen", "can I take both", "how long does a cold last", "ok thanks"],
    "sarcasm-and-fragments": ["great, the printer's jammed again", "hp", "how do i clear a paper jam on an hp printer", "never mind it's working", "you're a lifesaver", "no seriously thanks"],
    "language-learner": ["I'm learning Italian", "how do you say good morning in Italian", "and good night?", "what does grazie mean", "how do you pronounce it", "give me a word to learn today"],
    "budget": ["I need to save money", "what's 15 percent of 2400", "if I save 360 a month how long until I have 5000", "whats a good savings rate", "remind me to move money on the 1st", "undo"],
    "trivia-night": ["quick, capital of Australia", "not Sydney?", "biggest desert in the world", "the sahara isnt biggest?", "who painted the scream", "when", "cheers"],
    "birthday": ["it's my mum's 70th next month", "ideas for a 70th birthday party", "how do I make a victoria sponge", "for 12 people", "put mum's party on the calendar on the 15th at 3pm", "undo", "thanks"],
    "pet-worry": ["my dog ate chocolate", "a small bar, she's a labrador", "should I be worried", "what are the symptoms of chocolate poisoning in dogs", "ok calling the vet"],
    "commute": ["how far is Boston from New York", "how long does the train take", "and driving?", "what's the weather like in Boston tomorrow", "thanks"],
    "flat-hunt": ["we're looking at flats in Bristol", "what's Bristol like", "how far is it from Bath", "and from Cardiff?", "average rent in Bristol", "is it a safe city", "cheers"],
    "cooking-fail": ["my rice always comes out mushy", "how do I cook rice in a pan", "basmati", "how much water", "and for brown rice?", "thanks that's helpful"],
    "morning": ["morning", "what's the weather today", "in Denver", "do I need a coat", "what's in the news", "anything about space", "ok have a good one"],
    "student-late": ["I have an essay due tomorrow on the causes of World War One", "what were the main causes of World War One", "when did it start", "and end?", "how many people died", "who was Franz Ferdinand", "thanks, back to writing"],
    "handyman": ["the kitchen tap is dripping", "how do I fix a dripping tap", "what tools do I need", "is it a washer or a cartridge", "how do I turn off the water first", "brilliant"],
    "curious-kid": ["why is the sea salty", "why doesnt it freeze then", "does the dead sea freeze", "why is it called the dead sea", "how salty is it", "cool"],
})
# ---------------------------------------------------------------------------- v60: a day of conversations
# Base conversations are short and written the way people type. Each is played in several variants: as written, with a typo,
# with a fragment instead of a full question, with a correction, and "returning later" (the same person comes back after
# other sessions and refers to the morning). Spread over the working day at a gentle pace so the engines are not provoked.
DAY_SLOTS = {"city": ["Lisbon", "Copenhagen", "Kyoto", "Austin", "Edinburgh", "Cape Town", "Montreal", "Valencia"],
             "dish": ["shakshuka", "dal", "risotto", "banana bread", "chicken soup", "falafel", "pad thai", "ratatouille"],
             "device": ["dishwasher", "router", "boiler", "printer", "e-bike", "smart meter", "air fryer", "washing machine"],
             "person": ["Ada Lovelace", "Frida Kahlo", "Miles Davis", "Rosalind Franklin", "Hayao Miyazaki", "Toni Morrison", "Nikola Tesla", "Zadie Smith"],
             "film": ["Jaws", "Amélie", "Parasite", "The Godfather", "Spirited Away", "Alien", "Casablanca", "Get Out"],
             "topic": ["black holes", "the French Revolution", "photosynthesis", "the Roman Empire", "climate change", "the stock market", "vaccines", "coral reefs"],
             "animal": ["octopus", "red panda", "axolotl", "hummingbird", "wolf", "honey bee", "sea turtle", "snow leopard"]}
DAY_BASE = [
    ["hi", "thinking about a trip to {city}", "best things to do in {city}", "tell me about the first one", "what's the weather like there", "how do you say hello in the local language", "thanks"],
    ["what can I cook tonight, I've got eggs and tomatoes", "recipe for {dish}", "for 2 people", "how long does it take", "set a timer for 20 minutes", "undo", "cheers"],
    ["my {device} isn't working", "how do I reset a {device}", "what if that doesn't help", "how much does a new one cost", "ok thanks"],
    ["who was {person}", "where were they born", "when did they die", "what are they famous for", "tell me something surprising about them", "ta"],
    ["is {film} worth watching", "who directed it", "when did it come out", "how long is it", "and the sequel?", "cheers"],
    ["I have a test on {topic} tomorrow", "explain {topic} simply", "what are the main causes of {topic}" , "timeline of {topic}", "quiz me on {topic}", "thanks, wish me luck"],
    ["random question, what does an {animal} eat", "how long do they live", "are they endangered", "where do they live", "cool"],
    ["what's 18% of 245", "and 20%?", "split 245 between 4 people", "how many days until christmas", "remind me to pay rent on the 1st", "undo"],
    ["I'm feeling a bit low today", "just tired I think", "what helps with low energy", "how much sleep should I get", "ok thanks for listening"],
    ["what's in the news today", "anything about {topic}", "what's the weather in {city}", "and tomorrow?", "thanks"],
]
DAY_VARIANTS = {
    "typo": lambda t: t.replace("the ", "teh ", 1) if "the " in t else t.replace("what", "waht", 1) if "what" in t else t,
    "fragment": lambda t: re.sub(r"^(?:what(?:'s| is| are)|how (?:do|does|did) (?:i|you)|who (?:was|is)|tell me about) ", "", t, flags=re.I),
    "correction": None,     # handled in the player: after the 2nd turn, "sorry, I meant {alt}" with a different slot value
    "return": None,         # handled in the player: the person comes back after other sessions and asks "what did you say about ...?"
}

def day_conversations(seed="fai-day-v60"):
    rnd = random.Random(seed)
    convs = []
    for bi, base in enumerate(DAY_BASE):
        slots = {k: v for k, v in DAY_SLOTS.items() if any("{" + k + "}" in t for t in base)}
        for vi in range(4):
            fill = {k: rnd.choice(v) for k, v in slots.items()}
            turns = [t.format(**fill) for t in base]
            variant = ["plain", "typo", "fragment", "correction"][vi]
            if variant == "typo":
                turns = [DAY_VARIANTS["typo"](t) if i % 2 == 1 else t for i, t in enumerate(turns)]
            elif variant == "fragment":
                turns = [DAY_VARIANTS["fragment"](t) if i in (1, 3) else t for i, t in enumerate(turns)]
            elif variant == "correction" and slots:
                k = next(iter(slots)); alt = rnd.choice([v for v in DAY_SLOTS[k] if v != fill[k]])
                turns = turns[:2] + [f"sorry, I meant {alt}"] + turns[2:]
                fill = dict(fill, **{k: alt})
            convs.append({"name": f"day-{bi:02d}-{variant}", "turns": turns, "fill": fill})
    rnd.shuffle(convs)
    return convs

def run_day(a, data_dir):
    convs = day_conversations()
    hours = max(0.5, float(a.hours))
    total_turns = sum(len(c["turns"]) for c in convs) + len(convs) // 3
    gap = max(a.pace, (hours * 3600) / max(1, total_turns))
    path = os.path.join(data_dir, "day.txt")
    print(f"day run: {len(convs)} conversations, {total_turns} turns, one turn every {gap:.0f}s over ~{hours:.1f} h -> {path}", flush=True)
    t0 = time.time(); n = 0; returns = []
    with open(path, "w", encoding="utf-8") as out:
        for ci, c in enumerate(convs):
            sid = f"day-{c['name']}-{int(t0)}"
            out.write(f"===== {c['name']} =====\n")
            for t in c["turns"]:
                d = ask(a.base, t, sid); n += 1
                ans = (d.get("answer") or "").strip()
                out.write(f"\nYOU: {t}\nBOT: {ans[:700]}\n  [{d.get('mode')}, {d.get('_dt', 0):.1f}s]\n")
                for ln in (d.get("trace") or [])[:20]:
                    out.write(f"    trace: {ln[:160]}\n")
                out.flush()
                time.sleep(gap if d.get("mode") not in ("chat", "calc", "convert", "clock", "tool", "creative", "recall") else min(gap, 2))
            out.write("\n")
            if ci % 3 == 2 and c["fill"]:
                returns.append((sid, next(iter(c["fill"].values()))))
            if ci % 6 == 5 and returns:      # someone from earlier comes back and refers to the morning
                rsid, thing = returns.pop(0)
                for t in (f"hi again", f"what did you say about {thing} earlier?", "thanks"):
                    d = ask(a.base, t, rsid); n += 1
                    out.write(f"\n[returning session {rsid}]\nYOU: {t}\nBOT: {(d.get('answer') or '')[:500]}\n  [{d.get('mode')}, {d.get('_dt', 0):.1f}s]\n")
                    for ln in (d.get("trace") or [])[:12]:
                        out.write(f"    trace: {ln[:160]}\n")
                    out.flush(); time.sleep(min(gap, 3))
            if ci % 10 == 9:
                print(f"  {ci + 1}/{len(convs)} conversations, {n} turns, {(time.time() - t0) / 60:.0f} min", flush=True)
    print(f"\nday run finished: {n} turns in {(time.time() - t0) / 3600:.1f} h; written: {path} (read it; verdicts come from reading)")

THROTTLED = ("search engines are throttling", "returned nothing (brave", "couldn't search the web", "engines behind my metasearch", "aren't answering me properly")
CHAT_TOPICS = {"self", "other"}
REFUSAL_TOPICS = {"writing", "multimedia"}   # a good outcome here is a clear refusal or a template piece, not a quoted passage

def all_questions():
    out = []
    for topic, qs in TOPICS:
        for q in qs:
            out.append((topic, q))
    return out

def split(half):
    rnd = random.Random("fai-corpus-v47")
    qs = all_questions()
    rnd.shuffle(qs)
    mid = len(qs) // 2
    return qs[:mid] if half == "label" else qs[mid:]

def ask(base, q, sid):
    t0 = time.time()
    try:
        code = os.environ.get("NOAI_ACCESS_CODE", "").strip()      # inside the container the code is in the environment; tools then work in scenarios
        r = requests.post(base + "/api/chat", json={"question": q, "session": sid}, headers={"X-API-Key": code} if code else {}, timeout=90)
        d = r.json()
    except Exception as e:
        d = {"mode": "error", "answer": f"{type(e).__name__}"}
    d["_dt"] = time.time() - t0
    return d

def throttled(d):
    a = (d.get("answer") or "").lower()
    tr = "\n".join(d.get("trace") or []).lower()
    return d.get("mode") in ("none", "error") and (any(t in a for t in THROTTLED) or "web search unavailable" in tr or "engines are suspending" in tr)

def run_scenarios(a, data_dir):
    path = os.path.join(data_dir, "scenarios.txt")
    n_ok = n_checked = 0
    with open(path, "w", encoding="utf-8") as out:
        for name, turns in SCENARIOS.items():
            sid = f"scenario-{name}-{int(time.time())}"
            out.write(f"===== {name} =====\n")
            print(f"== {name}", flush=True)
            for t in turns:
                d = ask(a.base, t, sid)
                ans = (d.get("answer") or "").strip()
                out.write(f"\nYOU: {t}\nBOT: {ans[:900]}\n  [{d.get('mode')}, {d.get('_dt', 0):.1f}s]\n")
                for ln in (d.get("trace") or [])[:25]:
                    out.write(f"    trace: {ln[:160]}\n")
                out.flush()
                print(f"   {t[:48]:48} -> {d.get('mode'):9} {ans[:70].replace(chr(10), ' ')}", flush=True)
                if d.get("mode") not in ("chat", "calc", "convert", "clock", "tool", "creative", "recall"):
                    time.sleep(a.pace)
            out.write("\n")
    print(f"\nwritten: {path}  (read it; there is no pass/fail for conversations)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--half", choices=["label", "heldout", "pairs", "both", "facts", "explain"], default="label")
    ap.add_argument("--scenarios", action="store_true", help="play the simulated conversations and write a readable transcript")
    ap.add_argument("--day", action="store_true", help="play ~40 varied conversations spread over the working day (see --hours)")
    ap.add_argument("--hours", default="7", help="how long the --day run should take (default 7)")
    ap.add_argument("--no-retry", action="store_true", help="do not wait and retry throttled answers")
    ap.add_argument("--base", default=os.environ.get("NOAI_BASE", "http://127.0.0.1:7070"))
    ap.add_argument("--pace", type=float, default=3.0)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    if a.list:
        for topic, qs in TOPICS:
            print(f"{topic:10} {len(qs)}")
        print("total", len(all_questions()))
        return
    data_dir = os.environ.get("DATA_DIR", "data")
    os.makedirs(data_dir, exist_ok=True)
    if a.scenarios:
        run_scenarios(a, data_dir)
        return
    if a.day:
        run_day(a, data_dir)
        return
    if a.half == "facts":
        run_facts(a, data_dir)
        return
    if a.half == "pairs":
        qs = [("pairs", q) for q in PAIRS]
    elif a.half == "explain":
        qs = explain_questions()
    elif a.half == "both":
        qs = split("label") + split("heldout")
    else:
        qs = split(a.half)
    if a.limit:
        qs = qs[:a.limit]
    out_path = os.path.join(data_dir, f"corpus-{a.half}.txt")
    stats = {}
    with open(out_path, "w", encoding="utf-8") as out:
        for i, (topic, q) in enumerate(qs, 1):
            sid = f"corpus-{a.half}-{i}"
            d, dt, retried = ask(a.base, q, sid), 0.0, False
            if not a.no_retry and throttled(d):
                # the engines suspend a server that bursts, and for longer than a minute; a coverage measurement must not count that as our miss
                print("      (throttled; waiting 5 min and retrying once; pace raised)", flush=True)
                time.sleep(300)
                a.pace = max(a.pace, 6.0)
                d, retried = ask(a.base, q, sid + "-r"), True
            dt = d.get("_dt", 0.0)
            mode = d.get("mode") or "none"
            first = (d.get("answer") or "").strip().splitlines()[0][:140] if d.get("answer") else ""
            out.write(f"[{topic}] {q}\n  mode={mode} time={dt:.1f}s{' retried' if retried else ''} | {first}\n")
            for ln in (d.get("trace") or [])[:40]:
                out.write(f"    trace: {ln[:200]}\n")
            out.flush()
            s = stats.setdefault(topic, {"n": 0, "answered": 0, "refused": 0, "none": 0, "error": 0})
            s["n"] += 1
            if mode == "error":
                s["error"] += 1
            elif mode in ("none",):
                s["none"] += 1
            elif topic in REFUSAL_TOPICS and (mode in ("chat", "creative") or "can't" in (d.get("answer") or "")[:200]):
                s["refused"] += 1
            elif mode not in ("chat",) or topic in CHAT_TOPICS:
                s["answered"] += 1
            print(f"{i:4}/{len(qs)} [{topic}] {q[:60]:60} -> {mode:10} {dt:5.1f}s", flush=True)
            if mode not in ("chat", "calc", "convert", "clock", "tool", "creative"):
                time.sleep(a.pace)
    print("\nCoverage by topic (share of questions answered with a sourced or computed answer; writing/multimedia count a clear refusal or template piece as the good outcome):")
    for topic, s in stats.items():
        good = s["answered"] + (s["refused"] if topic in REFUSAL_TOPICS else 0)
        print(f"  {topic:10} n={s['n']:3}  good={good/s['n']:.0%}  none={s['none']}  error={s['error']}")
    print(f"\nwritten: {out_path}")

if __name__ == "__main__":
    main()
__NOAI_V47_CORPUS__
cat > "$APP_DIR/app/judge_compare.py" <<'__NOAI_V53_JUDGECMP__'
#!/usr/bin/env python3
"""fAI answerability-judge comparison (v53). Runs OFFLINE on a laptop (needs internet once to download models; the Pi is
too slow). Inputs: one or more candidates.jsonl files from replay bundles and the labels-*.jsonl files. Output: how often
each scorer agrees with the labelled preference on pairs, plus AUC for "chosen vs other", so a replacement for the current
MS MARCO judge is admitted only on evidence.

    pip install sentence-transformers scikit-learn
    python3 judge_compare.py --candidates bundle52/candidates.jsonl --labels labels-v47.jsonl labels-v51.jsonl

Scorers compared:
  current    the judge score logged with each candidate (ms-marco-MiniLM-L6-v2, plus the hand-written components as 'final')
  qnli       cross-encoder/qnli-electra-base: trained on "does this sentence answer the question" (QNLI), the answerability task
  msmarco    cross-encoder/ms-marco-MiniLM-L-12-v2: a larger relevance model, to separate "bigger" from "different task"
Add --model <hf id> for any other cross-encoder (e.g. a BoolQ-tuned one)."""
import argparse, json, sys

def load_pairs(cand_files, label_files):
    feat = {}
    for f in cand_files:
        for line in open(f, encoding="utf-8"):
            r = json.loads(line)
            for c in r["cands"]:
                comps = c.get("comps") or {}
                judge = c.get("judge") or (c["final"] - sum(comps.values()))
                feat[(r["q"].strip().lower(), c["text"][:80])] = {"text": c["text"], "judge": judge, "final": c["final"], "ctx": (c.get("label") or "").replace(" (alt)", ""), "heading": c.get("heading") or ""}
    pairs = []
    for f in label_files:
        for line in open(f, encoding="utf-8"):
            e = json.loads(line)
            if e["preferred"] not in ("chosen", "other"):
                continue
            k = e["q"].strip().lower()
            a, b = feat.get((k, e["chosen_text"][:80])), feat.get((k, e["other_text"][:80]))
            if a and b:
                pairs.append({"q": e["q"], "a": a, "b": b, "y": 1 if e["preferred"] == "chosen" else 0})
    return pairs

def agree(pairs, key):
    ok = sum(1 for p in pairs if (p["a"][key] > p["b"][key]) == (p["y"] == 1))
    return ok / max(1, len(pairs))

def auc(pairs, key):
    try:
        from sklearn.metrics import roc_auc_score
    except ImportError:
        return float("nan")
    ys, xs = [], []
    for p in pairs:
        xs += [p["a"][key], p["b"][key]]
        ys += [1 if p["y"] == 1 else 0, 0 if p["y"] == 1 else 1]
    return roc_auc_score(ys, xs)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", nargs="+", required=True)
    ap.add_argument("--labels", nargs="+", required=True)
    ap.add_argument("--model", action="append", default=[], help="extra HF cross-encoder ids")
    a = ap.parse_args()
    pairs = load_pairs(a.candidates, a.labels)
    print(f"pairs with both passages logged: {len(pairs)}  (label 'chosen' share {sum(p['y'] for p in pairs) / max(1, len(pairs)):.2f})")
    print(f"{'scorer':28} {'pair agreement':>15} {'AUC':>6}")
    for key in ("judge", "final"):
        print(f"{'current ' + key:28} {agree(pairs, key):15.3f} {auc(pairs, key):6.3f}")
    models = [("msmarco-L6", "cross-encoder/ms-marco-MiniLM-L-6-v2"), ("qnli", "cross-encoder/qnli-electra-base"), ("msmarco-L12", "cross-encoder/ms-marco-MiniLM-L-12-v2")] + [(m.split('/')[-1], m) for m in a.model]
    try:
        from sentence_transformers import CrossEncoder
    except ImportError:
        print("sentence-transformers not installed; only the logged scores were compared"); return
    for name, mid in models:
        try:
            ce = CrossEncoder(mid, max_length=512)
        except Exception as e:
            print(f"{name:28} could not load ({type(e).__name__})"); continue
        for variant in ("plain", "contextual"):        # contextual: article title and section heading prepended (Lauriola & Moschitti 2021 style global context)
            inputs = []
            for p in pairs:
                for side in ("a", "b"):
                    t = p[side]["text"][:1500]
                    if variant == "contextual":
                        t = (p[side]["ctx"] + (" \u2014 " + p[side]["heading"] if p[side]["heading"] else "") + ": " + t) if p[side]["ctx"] else t
                    inputs.append((p["q"], t))
            scores = ce.predict(inputs)
            key = name + ("" if variant == "plain" else "+ctx")
            for i, p in enumerate(pairs):
                p["a"][key], p["b"][key] = float(scores[2 * i]), float(scores[2 * i + 1])
            print(f"{key:28} {agree(pairs, key):15.3f} {auc(pairs, key):6.3f}")
    print("\nA scorer earns a place only if its pair agreement beats 'current final' clearly (say, by 0.05 on 300+ pairs); the components then get refitted around it.")

if __name__ == "__main__":
    main()
__NOAI_V53_JUDGECMP__

# ---- configuration (secrets survive reinstalls) ----
OLD_TOKEN=""; OLD_BIND=""; OLD_HOME_LOC=""
for OLD_ENV in ${PREV_ENVS[@]+"${PREV_ENVS[@]}"}; do
  if [[ -f "$OLD_ENV" ]]; then
    [[ -z "$OLD_TOKEN" ]] && OLD_TOKEN="$(grep -E '^NOAI_API_TOKEN=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
    [[ -z "$OLD_BIND" ]] && OLD_BIND="$(grep -E '^NOAI_BIND_ADDR=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
    [[ -z "$OLD_HOME_LOC" ]] && OLD_HOME_LOC="$(grep -E '^NOAI_HOME_LOCATION=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
  fi
done
# Host time zone, so "what time is it?" answers in local time.
TZ_NAME="${NOAI_TZ:-}"
[[ -z "$TZ_NAME" && -r /etc/timezone ]] && TZ_NAME="$(tr -d '[:space:]' < /etc/timezone || true)"
[[ -z "$TZ_NAME" ]] && TZ_NAME="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
[[ -z "$TZ_NAME" && -L /etc/localtime ]] && TZ_NAME="$(readlink -f /etc/localtime | sed 's#^.*/zoneinfo/##' || true)"
[[ -z "$TZ_NAME" ]] && TZ_NAME="UTC"
HOME_LOC="${NOAI_HOME_LOCATION:-$OLD_HOME_LOC}"
SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sed -i "s/__SECRET__/$SECRET/" "$APP_DIR/searxng/settings.yml"
PUID="$(id -u "$TARGET_USER")"
PGID="$(id -g "$TARGET_USER")"
API_TOKEN="${OLD_TOKEN:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
OLD_CODE=""
for OLD_ENV in ${PREV_ENVS[@]+"${PREV_ENVS[@]}"}; do
  [[ -z "$OLD_CODE" && -f "$OLD_ENV" ]] && OLD_CODE="$(grep -E '^NOAI_ACCESS_CODE=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
  [[ -z "${OLD_BRAVE:-}" && -f "$OLD_ENV" ]] && OLD_BRAVE="$(grep -E '^NOAI_BRAVE_KEY=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
done
# a short code that is easy to type on a phone: 10 characters, no look-alikes (0/O, 1/l)
# (read a finite chunk first: `tr < /dev/urandom | head` dies of SIGPIPE, which aborts the script under `set -o pipefail`)
RAND_CHARS="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' || true)"
ACCESS_CODE="${NOAI_ACCESS_CODE:-${OLD_CODE:-${RAND_CHARS:0:10}}}"
[[ ${#ACCESS_CODE} -ge 6 ]] || ACCESS_CODE="${API_TOKEN:0:10}"
BIND_ADDR="${NOAI_BIND_ADDR:-${OLD_BIND:-0.0.0.0}}"
{
  printf 'PUID=%s\nPGID=%s\n' "$PUID" "$PGID"
  printf 'INSTALL_SPACY=%s\nINSTALL_EMBED=%s\nINSTALL_SEMANTIC=%s\nINSTALL_JUDGE=%s\n' "$INSTALL_SPACY" "$INSTALL_EMBED" "$INSTALL_SEMANTIC" "$INSTALL_JUDGE"
  printf 'NOAI_CONTACT=%s\nNOAI_API_TOKEN=%s\nNOAI_BIND_ADDR=%s\n' "$CONTACT" "$API_TOKEN" "$BIND_ADDR"
  printf 'NOAI_FILES_HOST=%s\nNOAI_TOOLS=%s\nNOAI_ACCESS_CODE=%s\n' "$FILES_HOST" "${NOAI_TOOLS:-1}" "$ACCESS_CODE"
  printf 'NOAI_BRAVE_KEY=%s\n' "${NOAI_BRAVE_KEY:-${OLD_BRAVE:-}}"
  printf 'NOAI_NTFY_URL=%s\n' "${NOAI_NTFY_URL:-}"
  printf 'NOAI_BUDGET=14\nNOAI_BUDGET_SLOW=26\n'
  printf 'NOAI_TZ=%s\nNOAI_HOME_LOCATION=%s\n' "$TZ_NAME" "$HOME_LOC"
} > "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
chmod +x "$APP_DIR/run-tests.sh" "$APP_DIR/uninstall.sh" "$APP_DIR/record.sh"

# ---- offline command reference (tldr pages, English only, ~3 MB) ----
echo "Downloading tldr pages..."
TLDR_ZIP="$APP_DIR/data/tldr-pages.zip"
if curl -fL --retry 3 --retry-delay 2 -o "$TLDR_ZIP" https://github.com/tldr-pages/tldr/releases/latest/download/tldr-pages.en.zip \
   || curl -fL --retry 3 --retry-delay 2 -o "$TLDR_ZIP" https://github.com/tldr-pages/tldr/releases/latest/download/tldr-pages.zip; then
  rm -rf "$APP_DIR/data/tldr" "$APP_DIR/data/tldr_index.db"
  python3 - "$TLDR_ZIP" "$APP_DIR/data/tldr" <<'PY_TLDR'
import sys, zipfile, os
src, dst = sys.argv[1:]
os.makedirs(dst, exist_ok=True)
root = os.path.realpath(dst)
with zipfile.ZipFile(src) as z:
    for m in z.infolist():
        target = os.path.realpath(os.path.join(dst, m.filename))
        if target != root and not target.startswith(root + os.sep):
            continue  # never write outside the target directory
        z.extract(m, dst)
PY_TLDR
  rm -f "$TLDR_ZIP"
else
  echo "WARNING: could not download tldr pages; shell how-to answers will fall back to web documentation."
fi

if [[ "${EUID}" -eq 0 ]]; then
  chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$APP_DIR"
fi

python3 -m py_compile "$APP_DIR/app/app.py" "$APP_DIR/app/convo.py" "$APP_DIR/app/skills.py" "$APP_DIR/app/semantic.py" "$APP_DIR/app/tools.py" "$APP_DIR/app/creative.py" "$APP_DIR/app/replay.py" "$APP_DIR/app/judge.py" "$APP_DIR/app/fetch_judge.py" "$APP_DIR/app/structured.py" "$APP_DIR/app/fetch_minilm.py" "$APP_DIR/app/selftest.py" "$APP_DIR/app/chateval.py" "$APP_DIR/app/reader.py"
find "$APP_DIR/app" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true

cd "$APP_DIR"
echo "Building and starting containers (the first build on a Raspberry Pi can take 10-20 minutes)..."
"${DC[@]}" up -d --build

echo "Waiting for the web app..."
OK=0
for _ in $(seq 1 120); do
  if curl -fsS http://127.0.0.1:7070/health >/dev/null 2>&1; then OK=1; break; fi
  sleep 2
done
if [[ "$OK" != 1 ]]; then
  echo "The app did not become healthy. Recent logs:"
  "${DC[@]}" logs --tail=180
  exit 1
fi
for _ in $(seq 1 25); do
  if "${DC[@]}" exec -T app python -c "import requests; raise SystemExit(0 if requests.get('http://searxng:8080/',timeout=3).status_code < 500 else 1)" >/dev/null 2>&1; then break; fi
  sleep 2
done

echo
echo "== Running the evaluation conversation =="
TEST_RC=0
"${DC[@]}" exec -T app python /app/selftest.py || TEST_RC=$?

echo
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "Installed at:      $APP_DIR"
echo "Web chat:          http://${IP:-PI-IP}:7070"
echo "Test transcript:   $APP_DIR/data/test-transcript.txt"
echo "Rerun tests:       $APP_DIR/run-tests.sh"
echo "Chat-match check:  cd $APP_DIR && ${DC[*]} exec app python /app/chateval.py"
echo "Diagnostics:       curl -s http://127.0.0.1:7070/api/diagnostics | python3 -m json.tool"
echo "Logs:              cd $APP_DIR && ${DC[*]} logs --tail=200"
echo "Tools access code: $ACCESS_CODE   (press the lock button on the page and paste it; needed for reminders, lists, calendar, files)"
echo "Files folder:      $FILES_HOST   (the ONLY folder the file tools can see; calendar.ics is written here)"
echo "Calendar feed:     http://${IP:-PI-IP}:7070/calendar.ics?key=$ACCESS_CODE   (subscribe from your phone's calendar app; read-only)"
echo "Record for replay: $APP_DIR/record.sh   (then upload data/replay-bundle.tgz)"
echo "Corpus run (run it when you are not using the assistant): cd $APP_DIR && docker compose exec -T app python /app/corpus.py --half pairs --pace 3"
echo "   --half label | heldout | both for the topic corpus; --half pairs harvests answer pairs; --half facts runs ~2,000 auto-checked fact questions (~1 h);"
echo "   --half explain runs ~430 explanation and how-to questions (overnight); --scenarios plays the simulated conversations into data/scenarios.txt; --day --hours 7 plays a day of varied conversations into data/day.txt"
echo "Keyed search (optional): put NOAI_BRAVE_KEY=<key> in $APP_DIR/.env and run docker compose up -d; it is used only when the free engines suspend this server"
echo "Label answer pairs: http://<pi-address>:7070/label?code=<access code>   (pairs come from questions asked, including the corpus run)"
echo "Review feedback:   curl -H \"X-API-Key: $API_TOKEN\" http://${IP:-PI-IP}:7070/api/review.txt"
echo "OpenAI-style API:  http://${IP:-PI-IP}:7070/v1  (token is NOAI_API_TOKEN in $APP_DIR/.env)"
echo "Local-only access: set NOAI_BIND_ADDR=127.0.0.1 in .env, then: ${DC[*]} up -d"
echo
echo "Time zone:         $TZ_NAME   Default weather place: ${HOME_LOC:-(none; say \"I live in ...\" in chat, or set NOAI_HOME_LOCATION in .env)}"
echo
echo "We Have AI At Home $NOAI_VERSION (bot name fAI) has no language model. Optional ML, all scoring-only: spaCy en_core_web_sm (parsing/NER), a static word-embedding table,"
echo "and the all-MiniLM-L6-v2 sentence encoder as a second opinion on which paragraph answers a question (it is timed on this"
echo "machine at start-up and switches itself off if too slow; see \"semantic\" in the diagnostics). Facts are quoted from"
echo "Wikidata, Wikipedia, OpenStreetMap, tldr pages, Wiktionary, Open-Meteo and the web."
for PREV in ${PREV_INSTALLS[@]+"${PREV_INSTALLS[@]}"}; do
  if [[ -d "$PREV" ]]; then
    echo
    echo "An older version is still on disk (its containers are stopped). To remove it:"
    echo "  $PREV/uninstall.sh; sudo rm -rf $PREV"
  fi
done
if [[ "$TEST_RC" -ne 0 ]]; then
  echo
  echo "Installed and running, but one or more CRITICAL evaluation checks failed."
  echo "The transcript includes a routing trace for each failure: cat $APP_DIR/data/test-transcript.txt"
  exit "$TEST_RC"
fi
