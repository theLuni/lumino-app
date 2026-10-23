#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Lumino — серверная часть: подгрузка треков + авторизация.

Запуск
------
    python3 serv.py [порт]          (по умолчанию 8000)
    python3 serv.py --host 0.0.0.0 --port 8000

Переменные окружения
--------------------
    LUMINO_DATA     папка данных (по умолчанию ./data), там lumino.db
    LUMINO_SECRET   секрет для хеша кодов подтверждения (необязательно)
    SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM
                    почта для кодов (без неё регистрация и сброс пароля недоступны)

Треки
-----
  GET  /health                                  «ok»
  GET  /api/search?q=&limit=                    поиск треков на ru.hitmoz.org
  GET  /api/search/status                       доступность каталога
  GET  /api/lyrics?artist=&title=&artists=&album=&duration=   текст песни (lrclib)
  GET  /api/similar?names=A|B|C                 похожие исполнители (Deezer)
  GET  /api/audio?url=                          прокси аудио с Referer каталога

Авторизация
-----------
  POST /api/auth/register       {username, password, email, display_name}
  POST /api/auth/verify         {email, code}
  POST /api/auth/resend         {email}
  POST /api/auth/login          {username, password}
  POST /api/auth/logout
  GET  /api/auth/me
  GET  /api/users/profile?username=            public profile and liked releases
  POST /api/auth/password       {old_password, new_password}
  POST /api/auth/forgot         {email}
  POST /api/auth/reset/check    {email, code}
  POST /api/auth/reset          {email, code, new_password}

Состояние пользователя (лайки, плейлисты, настройки, история, профиль)
  GET  /api/state                               {state, updated_at} или state=null
  PUT  /api/state               тело: JSON-объект состояния целиком

"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import html
import ipaddress
import json
import os
import re
import secrets
import shutil
import smtplib
import sqlite3
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from email.message import EmailMessage
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ------------------------------------------------------------------ конфиг

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.environ.get("LUMINO_DATA") or os.path.join(HERE, "data")
DB_PATH = os.path.join(DATA_DIR, "fascind.db")

APP_VERSION = "0.2.6"
CHUNK = 64 * 1024
TIMEOUT = 9

SESSION_COOKIE = "lumino_session"
SESSION_TTL = 60 * 60 * 24 * 30
STATE_MAX = 20 * 1024 * 1024          # предел размера состояния пользователя
PBKDF2_ROUNDS = 120_000
CODE_TTL = 60 * 15
CODE_RESEND = 60
CODE_MAX_TRIES = 5
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_CODE_SECRET = os.environ.get("LUMINO_SECRET") or ""   # заполняется в init_db()

SMTP_HOST = os.environ.get("SMTP_HOST", "").strip()
SMTP_PORT = int(os.environ.get("SMTP_PORT", "465") or 465)
SMTP_USER = os.environ.get("SMTP_USER", "").strip()
SMTP_PASS = os.environ.get("SMTP_PASS", "")
SMTP_FROM = os.environ.get("SMTP_FROM", "").strip() or SMTP_USER

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
HITMOZ_ORIGIN = "https://ru.hitmoz.org"
HITMOZ_DOMAINS = ("hitmoz.org", "hitmoz.com")

# Запросы к каталогу hitmoz можно пустить через прокси, если IP сервера каталог не пускает
# (дата-центры часто блокируются: 403 или капча). Пример: HITMOZ_PROXY=http://user:pass@host:port
# Без переменной — прямое соединение, как раньше. Остальные сервисы (lrclib,
# Deezer, MusicBrainz и Cover Art Archive) — напрямую.
HITMOZ_PROXY = os.environ.get("HITMOZ_PROXY", "").strip()
_hitmoz_opener = (urllib.request.build_opener(
                      urllib.request.ProxyHandler({"http": HITMOZ_PROXY, "https": HITMOZ_PROXY}))
                  if HITMOZ_PROXY else urllib.request.build_opener())
LRCLIB = "https://lrclib.net"
LRCLIB_UA = "Lumino/0.2 (local music player)"

_lock = threading.RLock()        # кэши поиска, текстов и сходства
_db_lock = threading.RLock()     # запись в SQLite
_search_cache: dict = {}
_search_status = {"error": "", "at": 0.0}
_lyrics_cache: dict = {}
_similar_cache: dict = {}
_musicbrainz_lock = threading.Lock()
_musicbrainz_last_request = 0.0


def log(msg: str) -> None:
    sys.stderr.write("%s  %s\n" % (dt.datetime.now().strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def now() -> dt.datetime:
    return dt.datetime.now()


def iso(ts: dt.datetime | None = None) -> str:
    return (ts or now()).replace(microsecond=0).isoformat()


def norm(s) -> str:
    """Ключ для сравнения: без регистра, акцентов и знаков."""
    text = unicodedata.normalize("NFKD", str(s or "").lower())
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return re.sub(r"[\W_]+", "", text)


# ------------------------------------------------------------------ SQLite

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    username       TEXT UNIQUE NOT NULL,
    password       TEXT NOT NULL,
    email          TEXT NOT NULL DEFAULT '',
    email_verified INTEGER NOT NULL DEFAULT 0,
    display_name   TEXT NOT NULL DEFAULT '',
    created_at     TEXT NOT NULL,
    last_seen      TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
    token      TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS user_state (
    user_id    INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    data       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS email_codes (
    user_id    INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    code_hash  TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    attempts   INTEGER NOT NULL DEFAULT 0,
    last_sent  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS chats (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL DEFAULT '',
    type       TEXT NOT NULL,
    created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_members (
    chat_id   TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    active    INTEGER NOT NULL DEFAULT 1,
    joined_at TEXT NOT NULL,
    PRIMARY KEY (chat_id, user_id)
);
CREATE TABLE IF NOT EXISTS chat_messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id    TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    sender_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text       TEXT NOT NULL DEFAULT '',
    image_data TEXT NOT NULL DEFAULT '',
    track_json TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS chat_messages_chat_id_id
    ON chat_messages(chat_id, id);
"""


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=15, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def query(sql: str, args=()):
    with _db_lock, closing(db()) as conn:
        return [dict(r) for r in conn.execute(sql, args).fetchall()]


def one(sql: str, args=()):
    rows = query(sql, args)
    return rows[0] if rows else None


def execute(sql: str, args=()):
    with _db_lock, closing(db()) as conn:
        cur = conn.execute(sql, args)
        conn.commit()
        return cur.lastrowid


def _load_code_secret() -> None:
    """Секрет для хеша кодов: из LUMINO_SECRET или файла в DATA_DIR.
    Файл переживает перезапуск, поэтому коды из письма не сбрасываются при рестарте."""
    global _CODE_SECRET
    env = os.environ.get("LUMINO_SECRET")
    if env:
        _CODE_SECRET = env
        return
    path = os.path.join(DATA_DIR, "secret.key")
    try:
        with open(path, "r", encoding="utf-8") as f:
            value = f.read().strip()
    except FileNotFoundError:
        value = ""
    if not value:
        value = secrets.token_hex(32)
        with open(path, "w", encoding="utf-8") as f:
            f.write(value)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    _CODE_SECRET = value


def init_db() -> None:
    os.makedirs(DATA_DIR, exist_ok=True)
    _load_code_secret()
    with _db_lock, closing(db()) as conn:
        conn.executescript(SCHEMA)
        conn.execute("DELETE FROM chats WHERE type != 'direct'")
        conn.execute("DELETE FROM sessions WHERE expires_at < ?", (iso(),))
        conn.commit()


# ------------------------------------------------------------------ пароли и сессии

def hash_password(password: str, salt: str | None = None) -> str:
    salt = salt or secrets.token_hex(12)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                                 salt.encode("utf-8"), PBKDF2_ROUNDS).hex()
    return "pbkdf2_sha256$%s$%s" % (salt, digest)


def check_password(password: str, stored: str) -> bool:
    try:
        algo, salt, digest = stored.split("$", 2)
    except (ValueError, AttributeError):
        return False
    if algo != "pbkdf2_sha256":
        return False
    calc = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                               salt.encode("utf-8"), PBKDF2_ROUNDS).hex()
    return hmac.compare_digest(calc, digest)


def new_session(user_id: int) -> str:
    token = secrets.token_urlsafe(32)
    expires = now() + dt.timedelta(seconds=SESSION_TTL)
    execute("INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?,?,?,?)",
            (token, user_id, iso(), iso(expires)))
    return token


def drop_session(token: str) -> None:
    if token:
        execute("DELETE FROM sessions WHERE token = ?", (token,))


def user_by_token(token: str):
    if not token:
        return None
    row = one("""SELECT u.id, u.username, u.display_name, u.created_at, u.last_seen, s.expires_at
                   FROM sessions s JOIN users u ON u.id = s.user_id
                  WHERE s.token = ?""", (token,))
    if not row:
        return None
    try:
        expires = dt.datetime.fromisoformat(row["expires_at"])
    except ValueError:
        return None
    if expires < now():
        drop_session(token)
        return None
    # Активная сессия продлевается: вход не слетает, пока пользователь заходит хотя бы раз в 15 дней.
    if (expires - now()).total_seconds() < SESSION_TTL / 2:
        execute("UPDATE sessions SET expires_at = ? WHERE token = ?",
                (iso(now() + dt.timedelta(seconds=SESSION_TTL)), token))
    return row


def find_user(username: str):
    if not username:
        return None
    return one("SELECT id, username, display_name, created_at, last_seen "
               "FROM users WHERE lower(username) = lower(?)", (username.strip(),))


def public_user(user: dict) -> dict:
    name = user.get("display_name") or user["username"]
    return {
        "username": user["username"],
        "display_name": user.get("display_name") or "",
        "created_at": user.get("created_at") or "",
        "last_seen": user.get("last_seen") or "",
        "initial": (name[:1] or "?").upper(),
    }


def _chat_user(user_id: int) -> dict | None:
    user = one("SELECT id, username, display_name, created_at, last_seen FROM users WHERE id = ?",
               (user_id,))
    if not user:
        return None
    result = public_user(user)
    state = one("SELECT data FROM user_state WHERE user_id = ?", (user_id,))
    try:
        profile = json.loads(state["data"]).get("profile", {}) if state else {}
        result["avatar"] = str(profile.get("avatar") or "") if isinstance(profile, dict) else ""
    except (ValueError, TypeError):
        result["avatar"] = ""
    return result


def _public_user_profile(user) -> dict:
    result = public_user(dict(user))
    row = one("SELECT data FROM user_state WHERE user_id = ?", (user["id"],))
    if not row:
        result.update(avatar="", liked_tracks=[])
        return result
    try:
        state = json.loads(row["data"])
    except (ValueError, TypeError):
        result.update(avatar="", liked_tracks=[])
        return result

    profile = state.get("profile", {}) if isinstance(state, dict) else {}
    result["avatar"] = str(profile.get("avatar") or "") if isinstance(profile, dict) else ""
    likes = {
        re.sub(r"\s+", " ", str(value).lower()).strip()
        for value in state.get("liked", [])
    } if isinstance(state, dict) and isinstance(state.get("liked"), list) else set()
    tracks = state.get("savedTracks", []) if isinstance(state, dict) else []
    liked_tracks = []
    for track in tracks if isinstance(tracks, list) else []:
        if not isinstance(track, dict):
            continue
        artists = track.get("artists", [])
        artist = str(track.get("primary") or (
            artists[0] if isinstance(artists, list) and artists else ""))
        title = str(track.get("title") or "")
        key = re.sub(r"\s+", " ", f"{artist} - {title}".lower()).strip()
        if not title or key not in likes:
            continue
        liked_tracks.append({
            "id": str(track.get("id") or ""),
            "title": title,
            "artists": artists if isinstance(artists, list) else [artist],
            "primary": artist,
            "album": str(track.get("album") or ""),
            "cover": str(track.get("cover") or ""),
            "duration": track.get("duration") or 0,
            "releaseType": str(track.get("releaseType") or ""),
        })
    result["liked_tracks"] = liked_tracks
    return result


# ------------------------------------------------------------------ почта и коды

def send_email(to: str, subject: str, text: str) -> None:
    if not SMTP_HOST or not SMTP_USER:
        raise RuntimeError("почта не настроена на сервере")
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = to
    msg.set_content(text)
    if SMTP_PORT == 465:
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=20) as smtp:
            smtp.login(SMTP_USER, SMTP_PASS)
            smtp.send_message(msg)
    else:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as smtp:
            smtp.starttls()
            smtp.login(SMTP_USER, SMTP_PASS)
            smtp.send_message(msg)


def _code_hash(user_id: int, code: str) -> str:
    return hashlib.sha256(("%s:%s:%s" % (user_id, code, _CODE_SECRET)).encode("utf-8")).hexdigest()


def issue_code(user_id: int, email: str, reset: bool = False) -> None:
    code = "%06d" % secrets.randbelow(1000000)
    execute("""INSERT INTO email_codes (user_id, code_hash, expires_at, attempts, last_sent)
               VALUES (?,?,?,0,?)
               ON CONFLICT(user_id) DO UPDATE SET
                   code_hash=excluded.code_hash, expires_at=excluded.expires_at,
                   attempts=0, last_sent=excluded.last_sent""",
            (user_id, _code_hash(user_id, code), iso(now() + dt.timedelta(seconds=CODE_TTL)), iso()))
    if reset:
        send_email(email, "Сброс пароля Lumino",
                   "Код для смены пароля: %s\n\nКод действует 15 минут.\n"
                   "Если вы не запрашивали смену пароля, просто проигнорируйте письмо." % code)
    else:
        send_email(email, "Код подтверждения Lumino",
                   "Ваш код подтверждения: %s\n\nКод действует 15 минут.\n"
                   "Если вы не регистрировались в Lumino, просто проигнорируйте письмо." % code)


def _code_error(row, code: str):
    """None — код верный, иначе текст ошибки для пользователя."""
    if not row or not row.get("code_hash"):
        return "код не найден — запросите новый"
    if dt.datetime.fromisoformat(row["expires_at"]) < now():
        return "код истёк — запросите новый"
    if row["attempts"] >= CODE_MAX_TRIES:
        return "слишком много попыток — запросите новый код"
    if not hmac.compare_digest(_code_hash(row["id"], code), row["code_hash"]):
        execute("UPDATE email_codes SET attempts = attempts + 1 WHERE user_id = ?", (row["id"],))
        return "неверный код"
    return None


def _pending_row(email: str):
    return one("""SELECT u.id, u.username, c.code_hash, c.expires_at, c.attempts
                    FROM users u LEFT JOIN email_codes c ON c.user_id = u.id
                   WHERE lower(u.email) = ? AND u.email_verified = 0""", (email,))


def _reset_row(email: str):
    return one("""SELECT u.id, u.username, c.code_hash, c.expires_at, c.attempts
                    FROM users u LEFT JOIN email_codes c ON c.user_id = u.id
                   WHERE lower(u.email) = ? AND u.email_verified = 1""", (email,))


# ------------------------------------------------------------------ HTTP-клиент каталога

def _host_allowed(host: str) -> bool:
    host = (host or "").lower()
    return any(host == d or host.endswith("." + d) for d in HITMOZ_DOMAINS)


def _host_ok(url: str) -> bool:
    try:
        p = urllib.parse.urlparse(url)
    except ValueError:
        return False
    return p.scheme == "https" and _host_allowed(p.hostname or "")


def _safe_url(url: str) -> str:
    """Кодирует пробелы и не-ASCII в пути/запросе: http.client не умеет отправлять такие строки.
    Уже закодированные %XX сохраняются."""
    parts = urllib.parse.urlsplit(url)
    path = urllib.parse.quote(parts.path, safe="/%:@!$&'()*+,;=-._~")
    query = urllib.parse.quote(parts.query, safe="=&%:/?@!$'()*+,;-._~[]")
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, query, ""))


def _cdn_ok(url: str) -> bool:
    """Редирект каталога на CDN: только https, публичное доменное имя, без IP и localhost."""
    try:
        p = urllib.parse.urlparse(url)
    except ValueError:
        return False
    host = (p.hostname or "").lower()
    if p.scheme != "https" or "." not in host or host == "localhost":
        return False
    try:
        ipaddress.ip_address(host)
        return False            # IP-адреса не пускаем: иначе прокси достучится до внутренней сети
    except ValueError:
        return True


def _is_access_gate(page: str) -> bool:
    head = (page or "")[:12000].lower()
    return bool(re.search(r"403 forbiden|403 forbidden|access denied|доступ запрещ|"
                          r"подтвердите, что вы не робот|captcha|cf-challenge", head))


def _fetch_text(url: str) -> str:
    """HTML каталога. Бросает исключение при ошибке, капче или чужом домене."""
    if not _host_ok(url):
        raise ValueError("адрес каталога не разрешён")
    req = urllib.request.Request(_safe_url(url), headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.7",
        "Accept-Encoding": "identity",
        "Referer": HITMOZ_ORIGIN + "/",
    })
    with closing(_hitmoz_opener.open(req, timeout=TIMEOUT)) as resp:
        if not _host_allowed(urllib.parse.urlparse(resp.geturl()).hostname or ""):
            raise ValueError("каталог перенаправил на чужой домен")
        charset = resp.headers.get_content_charset() or "utf-8"
        text = resp.read().decode(charset, "replace")
    if _is_access_gate(text):
        raise PermissionError("каталог показывает капчу или блокировку")
    return text


# ------------------------------------------------------------------ каталог hitmoz (порт audio.js)

def _strip(s) -> str:
    s = re.sub(r"<script[\s\S]*?</script>|<style[\s\S]*?</style>", " ", str(s or ""), flags=re.I)
    s = re.sub(r"<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", html.unescape(s)).strip()


def _attrs(tag: str) -> dict:
    out = {}
    for m in re.finditer(r"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))", tag):
        out[m.group(1).lower()] = html.unescape(m.group(2) or m.group(3) or m.group(4) or "")
    return out


def _first_tag(chunk: str, pattern: str) -> str:
    m = re.search(pattern, chunk, re.I)
    return m.group(0) if m else ""


def _abs(value, base: str = HITMOZ_ORIGIN) -> str:
    v = html.unescape(str(value or "")).strip()
    if not v:
        return ""
    absolute = urllib.parse.urljoin(base, v)
    return absolute if _host_ok(absolute) else ""


def _is_direct_audio(u) -> bool:
    return bool(re.search(r"(?:\.mp3|\.m4a|\.aac|\.ogg|\.opus|\.flac|\.wav)(?:[?#]|$)|/get/music/",
                          str(u or ""), re.I))


def _duration(v) -> int:
    if isinstance(v, (int, float)):
        return int(v)
    text = str(v or "").strip()
    if re.fullmatch(r"\d+", text):
        return int(text)
    parts = text.split(":")
    if len(parts) in (2, 3) and all(re.fullmatch(r"\d+", p.strip()) for p in parts):
        total = 0
        for p in parts:
            total = total * 60 + int(p.strip())
        return total
    return 0


def _fnv(s: str) -> str:
    h = 2166136261
    for ch in str(s):
        h ^= ord(ch)
        h = (h * 16777619) & 0xFFFFFFFF
    return format(h, "x")


def _s(v) -> str:
    return v if isinstance(v, str) else ""


def _parse_catalog(page: str, base: str = HITMOZ_ORIGIN) -> list:
    """Разбор выдачи: JSON-LD, карточки tracks__item и альтернативная разметка h2/artistTag."""
    found: list = []
    by_identity: dict = {}
    by_audio: dict = {}

    def add(raw: dict) -> None:
        title = _strip(raw.get("title"))
        artists_raw = _strip(raw.get("artist"))
        stream = _abs(raw.get("audio"), base)
        cover = _abs(raw.get("cover"), base)
        url = _abs(raw.get("url"), base)
        if not title or (not stream and not url) or len(title) >= 240:
            return
        artists = ([a for a in re.split(r"\s*,\s*|\s+feat\.?\s+", artists_raw, flags=re.I) if a.strip()]
                   if artists_raw else ["Unknown artist"])
        primary = artists[0]
        id_artist = "" if re.match(r"^(?:unknown artist|неизвестный исполнитель)$", primary, re.I) else norm(primary)
        seconds = _duration(raw.get("duration"))
        identity = (id_artist + "|" + norm(title)) if id_artist else (norm(title) + "|" + str(seconds or norm(url)))
        direct = stream if _is_direct_audio(stream) else (url if _is_direct_audio(url) else "")
        existing = by_identity.get(identity) or (by_audio.get(direct) if direct else None)
        if existing:
            if (not existing["src"] or not _is_direct_audio(existing["src"])) and direct:
                existing["src"] = direct
            if not existing["cover"] and cover:
                existing["cover"] = cover
            if not existing["url"] and url:
                existing["url"] = url
            if not existing["duration"] and seconds:
                existing["duration"] = seconds
            by_identity[identity] = existing
            if direct:
                by_audio[direct] = existing
            return
        track = {"id": "hitmo-" + _fnv(identity), "title": title, "artists": artists,
                 "album": _strip(raw.get("album")), "cover": cover, "duration": seconds,
                 "src": direct, "url": url, "source": "catalog"}
        found.append(track)
        by_identity[identity] = track
        if direct:
            by_audio[direct] = track

    # 1. JSON-LD
    for m in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>([\s\S]*?)</script>', page, re.I):
        try:
            data = json.loads(m.group(1))
        except ValueError:
            continue
        stack = [data]
        while stack:
            x = stack.pop()
            if isinstance(x, list):
                stack.extend(x)
                continue
            if not isinstance(x, dict):
                continue
            types = x.get("@type")
            types = types if isinstance(types, list) else [types]
            if any(t in ("MusicRecording", "AudioObject", "MusicAlbum") for t in types):
                by = x.get("byArtist") or x.get("author") or {}
                album = x.get("inAlbum") or {}
                add({"title": _s(x.get("name")),
                     "artist": _s(by.get("name")) if isinstance(by, dict) else "",
                     "album": _s(album.get("name")) if isinstance(album, dict) else "",
                     "audio": _s(x.get("contentUrl")) or _s(x.get("audio")),
                     "url": _s(x.get("url")), "cover": _s(x.get("image")),
                     "duration": x.get("duration") or ""})
            stack.extend(x.values())

    # 2. карточки треков
    for m in re.finditer(r'<li\b[^>]*class=["\'][^"\']*\btracks__item\b[^"\']*["\'][^>]*>[\s\S]*?</li>', page, re.I):
        chunk = m.group(0)

        def cls(name: str) -> str:
            mm = re.search(r'<([a-z][\w:-]*)\b[^>]*class=["\'][^"\']*\b' + name +
                           r'\b[^"\']*["\'][^>]*>([\s\S]*?)</\1>', chunk, re.I)
            return _strip(mm.group(2)) if mm else ""

        dl = _attrs(_first_tag(chunk, r'<a\b[^>]*class=["\'][^"\']*\btrack__download-btn\b[^"\']*["\'][^>]*>'))
        ti = _attrs(_first_tag(chunk, r'<a\b[^>]*class=["\'][^"\']*\btrack__title\b[^"\']*["\'][^>]*>'))
        im = _attrs(_first_tag(chunk, r"<img\b[^>]*>"))
        pl = _attrs(_first_tag(chunk, r"<(?:audio|source)\b[^>]*>"))
        add({"title": cls("track__title") or ti.get("title") or ti.get("data-title") or "",
             "artist": cls("track__desc"), "duration": cls("track__fulltime"),
             "audio": pl.get("src") or pl.get("data-src") or dl.get("href") or "",
             "url": ti.get("href") or dl.get("href") or "",
             "cover": im.get("src") or im.get("data-src") or im.get("data-lazy-src") or ""})

    # 3. альтернативная разметка h2 > a, artistTag
    for m in re.finditer(r"<li\b[^>]*>[\s\S]*?</li>", page, re.I):
        chunk = m.group(0)
        t = re.search(r"<h2\b[^>]*>[\s\S]*?<a\b([^>]*)>([\s\S]*?)</a>[\s\S]*?</h2>", chunk, re.I)
        if not t:
            continue
        ta = _attrs("<a " + t.group(1) + ">")
        art = re.search(r'<[^>]*class=["\'][^"\']*\bartistTag\b[^"\']*["\'][^>]*>([\s\S]*?)</[^>]+>', chunk, re.I)
        dur = re.search(r"(?:duration|time|track__fulltime)[^>]*>([\s\S]*?)</[^>]+>", chunk, re.I)
        im = _attrs(_first_tag(chunk, r"<img\b[^>]*>"))
        pl = _attrs(_first_tag(chunk, r"<(?:audio|source)\b[^>]*>"))
        anchors = [_attrs(a) for a in re.findall(r"<a\b[^>]*>", chunk, re.I)]
        direct_a = next((a for a in anchors
                         if _is_direct_audio(a.get("href") or a.get("download") or a.get("data-href") or "")), {})
        add({"title": re.sub(r"\s*\.(?:mp3|flac|m4a|ogg|opus|wav)\s*$", "", _strip(t.group(2)), flags=re.I),
             "artist": _strip(art.group(1)) if art else "",
             "duration": _strip(dur.group(1)) if dur else "",
             "url": ta.get("href") or "",
             "audio": (pl.get("src") or pl.get("data-src") or direct_a.get("href")
                       or direct_a.get("download") or direct_a.get("data-href") or ""),
             "cover": im.get("src") or im.get("data-src") or im.get("data-original") or im.get("data-lazy-src") or ""})
    return found


def _find_direct_audio(page: str, base: str) -> str:
    """Прямая ссылка на аудиофайл внутри страницы трека."""
    src = page.replace("\\/", "/").replace("\\u0026", "&").replace("&amp;", "&")
    cands = []
    for m in re.finditer(r"<(?:audio|source|a|link|meta|button|div|span)\b[^>]*>", src, re.I):
        a = _attrs(m.group(0))
        for key in ("src", "href", "download", "data-src", "data-audio", "data-file",
                    "data-url", "data-href", "content", "data-download"):
            value = a.get(key)
            if value:
                absolute = _abs(value, base)
                if absolute and _is_direct_audio(absolute):
                    cands.append(absolute)
    for m in re.finditer(r"(?:https?://[^\s\"'<>\\]+|/(?:get/music|download|uploads?/music)[^\s\"'<>\\]*)"
                         r"(?:\.mp3|\.m4a|\.aac|\.ogg|\.opus|\.flac|\.wav|/get/music/[^\s\"'<>\\]*)?"
                         r"(?:\?[^\s\"'<>\\]*)?", src, re.I):
        absolute = _abs(m.group(0), base)
        if absolute and _is_direct_audio(absolute):
            cands.append(absolute)
    return cands[0] if cands else ""


def _resolve_missing_audio(tracks: list) -> None:
    todo = [t for t in tracks if not t["src"] and t["url"] and not _is_direct_audio(t["url"]) and _host_ok(t["url"])]

    def resolve(t: dict) -> None:
        try:
            direct = _find_direct_audio(_fetch_text(t["url"]), t["url"])
        except Exception:
            direct = ""
        if direct:
            t["src"] = direct

    with ThreadPoolExecutor(max_workers=3) as ex:
        list(ex.map(resolve, todo))


def search_catalog(q: str) -> tuple[list, str]:
    """Поиск по каталогу. Возвращает (треки, текст ошибки)."""
    q = (q or "").strip()
    if len(q) < 2:
        return [], ""
    key = q.lower()
    ts = time.time()
    with _lock:
        hit = _search_cache.get(key)
        if hit and ts - hit[0] < 45:
            return hit[1], ""

    enc = urllib.parse.quote(q)
    urls = [
        "%s/search?name=%s&page=1" % (HITMOZ_ORIGIN, enc),
        "%s/search?query=%s" % (HITMOZ_ORIGIN, enc),
        "%s/search?q=%s" % (HITMOZ_ORIGIN, enc),
        "%s/?do=search&subaction=search&story=%s" % (HITMOZ_ORIGIN, enc),
    ]
    errors: list = []
    by_id: dict = {}
    readable = False
    for url in urls:
        try:
            page = _fetch_text(url)
        except urllib.error.HTTPError as e:
            errors.append("каталог ответил %s" % e.code)
            if e.code not in (400, 404):
                break
            continue
        except Exception as e:
            errors.append(str(e) or type(e).__name__)
            break
        readable = True
        for t in _parse_catalog(page):
            ex = by_id.get(t["id"])
            if ex is None:
                by_id[t["id"]] = t
            else:
                for k in ("src", "cover", "url", "album", "duration"):
                    if not ex.get(k) and t.get(k):
                        ex[k] = t[k]

    tracks = list(by_id.values())
    if tracks:
        _resolve_missing_audio(tracks)
        seen_ident, seen_audio, out = set(), set(), []
        for t in tracks:
            if not t["src"] or not _is_direct_audio(t["src"]):
                continue
            _apply_track_alias(t)
            ident = norm(t["artists"][0]) + "|" + norm(t["title"])
            audio = t["src"].lower().split("#")[0]
            if audio in seen_audio or ident in seen_ident:
                continue
            seen_audio.add(audio)
            seen_ident.add(ident)
            out.append(t)
        if out:
            with _lock:
                _search_status.update(error="", at=0.0)
                _search_cache[key] = (ts, out)
            return out, ""

    err = "; ".join(dict.fromkeys(errors)) or "каталог не вернул треков с прямыми ссылками"
    with _lock:
        _search_status.update(error="" if readable else err, at=0.0 if readable else ts)
    return [], err


TRACK_ALIASES = [
    ("Kai Angel", "damage", ("naive", "slave to the rhythm"), "slave to the rhythm"),
    ("Kai Angel", "MM", ("MM", "MARILYN MANSON"), "MARILYN MANSON"),
    ("Kai Angel", "ANGEL MAY CRY", ("KYLIE", "KYLIE MINOGUE"), "KYLIE MINOGUE"),
]


def _apply_track_alias(track: dict) -> dict:
    artists = track.get("artists") or []
    artist = artists[0] if artists else ""
    for owner, album, sources, title in TRACK_ALIASES:
        if (norm(artist) == norm(owner)
                and norm(track.get("album")) == norm(album)
                and norm(track.get("title")) in {norm(s) for s in sources}):
            track["title"] = title
            break
    if (norm(artist) == norm("Kai Angel")
            and norm(track.get("title")) == norm("amy")):
        track["album"] = "damage"
    return track


def proxy_track(t: dict) -> dict:
    """Ссылку на аудио отдаём через /api/audio: сервер сам подставляет Referer каталога."""
    out = dict(t)
    if out.get("src"):
        out["src"] = "/api/audio?url=" + urllib.parse.quote(out["src"], safe="")
    return out


# ------------------------------------------------------------------ тексты песен (lrclib)

LYRICS_ALIASES = TRACK_ALIASES


def _clean_title(title) -> str:
    s = str(title or "")
    s = re.sub(r"[(\[]\s*(?:feat\.?|ft\.?|featuring|prod\.?|prod by|при уч\.?)[^)\]]*[)\]]", "", s, flags=re.I)
    s = re.sub(r"\s+-\s+(?:remaster(?:ed)?|live|single version|radio edit)\b.*$", "", s, flags=re.I)
    return re.sub(r"\s{2,}", " ", s).strip()


def _parse_lrc(text) -> list:
    lines = []
    for raw in str(text or "").splitlines():
        stamps = list(re.finditer(r"\[(\d+):(\d+(?:\.\d+)?)\]", raw))
        if not stamps:
            continue
        body = re.sub(r"\[[^\]]*\]", "", raw).strip()
        for m in stamps:
            lines.append({"t": int(m.group(1)) * 60 + float(m.group(2)), "text": body})
    lines.sort(key=lambda x: x["t"])
    return lines


def _lrclib_get(url: str):
    # Два быстрых попытки: клиент ждёт ответ 30 с, и длинные повторы его не укладывают.
    for attempt in range(2):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": LRCLIB_UA, "Accept": "application/json"})
            with closing(urllib.request.urlopen(req, timeout=5)) as resp:
                return {"data": json.loads(resp.read().decode("utf-8", "replace"))}
        except urllib.error.HTTPError as e:
            if e.code == 404 or (e.code != 429 and e.code < 500):
                return {"notFound": True}
        except Exception:
            pass
        if attempt < 1:
            time.sleep(0.4)
    return {"failed": True}


def _lrclib_batch(jobs: list) -> list:
    """Запросы к lrclib параллельно. jobs: [(url, trusted)] -> [(trusted, result)]."""
    if not jobs:
        return []
    with ThreadPoolExecutor(max_workers=min(4, len(jobs))) as ex:
        futures = [(trusted, ex.submit(_lrclib_get, url)) for url, trusted in jobs]
        return [(trusted, f.result()) for trusted, f in futures]


def _lyrics_for(title, artist, artists, album, duration) -> dict:
    cleaned = _clean_title(title)
    if not cleaned:
        return {"variants": []}
    names: list = []
    for a in [artist] + list(artists or []):
        a = str(a or "").strip()
        if a and a not in names:
            names.append(a)
    names = names[:3]
    dur = round(float(duration or 0))
    key = "%s|%s|%s|%d" % (
        norm(names[0] if names else ""), norm(album), norm(cleaned), dur)
    with _lock:
        hit = _lyrics_cache.get(key)
    if hit:
        return hit

    want = norm(cleaned)
    found: dict = {}
    state = {"ok": False, "failed": False}

    def take(item, trusted: bool) -> None:
        if not isinstance(item, dict) or not item.get("id"):
            return
        t = norm(item.get("trackName"))
        if not t or t != want:
            return
        a = norm(item.get("artistName"))
        if names and not any(norm(n) and norm(n) in a for n in names):
            return
        found.setdefault(item["id"], item)

    def absorb(results) -> None:
        for trusted, r in results:
            if r.get("failed"):
                state["failed"] = True
                continue
            state["ok"] = True
            d = r.get("data")
            if isinstance(d, list):
                for x in d:
                    take(x, trusted)
            elif isinstance(d, dict):
                take(d, True)

    def has_synced() -> bool:
        return any(x.get("syncedLyrics") for x in found.values())

    # Этап 1: точные совпадения, всё параллельно.
    stage1 = []
    if dur:
        for n in names[:2]:
            stage1.append((LRCLIB + "/api/get?" + urllib.parse.urlencode(
                {"track_name": cleaned, "artist_name": n, "album_name": album or "", "duration": str(dur)}), True))
    for n in names[:2]:
        stage1.append((LRCLIB + "/api/search?" + urllib.parse.urlencode(
            {"track_name": cleaned, "artist_name": n}), True))
    absorb(_lrclib_batch(stage1))

    # Этап 2: только если синхронизированного текста ещё нет.
    if not has_synced():
        absorb(_lrclib_batch([
            (LRCLIB + "/api/search?" + urllib.parse.urlencode(
                {"q": ("%s %s" % (names[0] if names else "", cleaned)).strip()}), False),
            (LRCLIB + "/api/search?" + urllib.parse.urlencode({"track_name": cleaned}), False),
        ]))

    everything = list(found.values())

    def dist(x) -> int:
        return abs(x.get("duration", 0) - dur) if dur and x.get("duration") else 0

    variants = []
    for x in sorted([x for x in everything if x.get("syncedLyrics")], key=dist)[:8]:
        lines = _parse_lrc(x["syncedLyrics"])
        if lines:
            variants.append({"label": x.get("albumName") or x.get("trackName") or "LRCLIB",
                             "synced": True, "lines": lines})
    if not variants:
        plain = next((x for x in everything if x.get("plainLyrics")), None)
        if plain:
            lines = [{"t": None, "text": s.strip()} for s in plain["plainLyrics"].splitlines() if s.strip()]
            variants.append({"label": plain.get("albumName") or plain.get("trackName") or "LRCLIB",
                             "synced": False, "lines": lines})
    result = {"variants": variants, "failed": (not state["ok"] and state["failed"])}
    if any(v["synced"] for v in variants):
        with _lock:
            _lyrics_cache[key] = result
    return result


def get_lyrics(t: dict) -> dict:
    title = t.get("title") or ""
    artists = [t.get("artist") or ""] + list(t.get("artists") or [])
    names = [norm(x) for x in artists if x]
    album = t.get("album") or ""
    alias = next(
        (a for a in LYRICS_ALIASES
         if norm(a[0]) in names and norm(a[1]) == norm(album)
         and norm(title) in {norm(s) for s in a[2]}),
        None,
    )
    args = (t.get("artist") or "", t.get("artists") or [], album,
            t.get("duration") or 0)
    if not alias:
        return _lyrics_for(title, *args)
    canonical = alias[3]
    result = _lyrics_for(canonical, *args)
    if result["variants"]:
        return result
    for source in alias[2]:
        if norm(source) == norm(canonical):
            continue
        fallback = _lyrics_for(source, *args)
        if fallback["variants"]:
            return fallback
    return result


# ------------------------------------------------------------------ похожие исполнители (Deezer)

def _deezer(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with closing(urllib.request.urlopen(req, timeout=7)) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def related_artists(name: str) -> list:
    key = norm(name)
    if not key:
        return []
    with _lock:
        if key in _similar_cache:
            return _similar_cache[key]
    try:
        found = _deezer("https://api.deezer.com/search/artist?" + urllib.parse.urlencode({"q": name, "limit": 5}))
        hit = next((a for a in (found.get("data") or []) if norm(a.get("name")) == key), None)
        if not hit:
            return []          # не угадываем: чужой исполнитель даст чужие рекомендации
        rel = _deezer("https://api.deezer.com/artist/%s/related?limit=15" % hit["id"])
        names = [str(a.get("name") or "").strip() for a in (rel.get("data") or [])
                 if a.get("name") and norm(a.get("name")) != key]
    except Exception:
        return []
    if names:
        with _lock:
            _similar_cache[key] = names
    return names


# ------------------------------------------------------------------ обложки (Deezer -> Cover Art Archive)

COVER_HOSTS = ("dzcdn.net", "deezer.com")
IMAGE_HOSTS = (*COVER_HOSTS, "coverartarchive.org", "archive.org",
               "mzstatic.com", "apple.com")
MUSICBRAINZ_UA = "Lumino/0.3 (https://theluni.ru/)"
_cover_cache: dict = {}


def _host_in(url: str, hosts) -> bool:
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    return any(host == h or host.endswith("." + h) for h in hosts)


def _cover_title_ok(a: str, b: str) -> bool:
    a, b = norm(a), norm(b)
    return bool(a) and (a == b or a.startswith(b) or b.startswith(a))


def _cover_artist_ok(want: str, got: str) -> bool:
    w, g = norm(want), norm(got)
    return bool(w) and bool(g) and (w == g or w in g or g in w)


def _find_cover(artist: str, title: str, album: str) -> str:
    query = (artist + " " + title).strip()
    if not query:
        return ""
    try:
        found = _deezer("https://api.deezer.com/search?" + urllib.parse.urlencode({"q": query, "limit": 10}))
        for item in found.get("data") or []:
            if not _cover_title_ok(title, item.get("title") or ""):
                continue
            if artist and not _cover_artist_ok(artist, (item.get("artist") or {}).get("name") or ""):
                continue
            album_obj = item.get("album") or {}
            cover = album_obj.get("cover_xl") or album_obj.get("cover_big") or ""
            if cover and _cover_host_ok(cover):
                return cover
    except Exception as error:
        log("Deezer cover lookup failed: %s" % error)
    return _cover_art_archive(artist, title, album)


def _musicbrainz_json(resource: str, query: str):
    global _musicbrainz_last_request
    url = "https://musicbrainz.org/ws/2/%s/?%s" % (
        resource,
        urllib.parse.urlencode({"query": query, "fmt": "json", "limit": 5}),
    )
    with _musicbrainz_lock:
        delay = 1.05 - (time.monotonic() - _musicbrainz_last_request)
        if delay > 0:
            time.sleep(delay)
        _musicbrainz_last_request = time.monotonic()
        req = urllib.request.Request(
            url,
            headers={"User-Agent": MUSICBRAINZ_UA, "Accept": "application/json"},
        )
        with closing(urllib.request.urlopen(req, timeout=8)) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))


def _musicbrainz_releases(artist: str, title: str, album: str) -> list:
    def phrase(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"')

    artist_query = 'artist:"%s"' % phrase(artist)
    releases = []
    if album:
        try:
            found = _musicbrainz_json(
                "release",
                'release:"%s" AND %s' % (phrase(album), artist_query),
            )
            for release in found.get("releases") or []:
                artist_name = str(release.get("artist-credit-phrase") or "")
                if (not _cover_title_ok(album, str(release.get("title") or "")) or
                        (artist and not _cover_artist_ok(artist, artist_name))):
                    continue
                releases.append(release)
        except Exception as error:
            log("MusicBrainz release search failed: %s" % error)

    if not releases:
        try:
            found = _musicbrainz_json(
                "recording",
                'recording:"%s" AND %s' % (phrase(title), artist_query),
            )
            for recording in found.get("recordings") or []:
                recording_artist = str(
                    recording.get("artist-credit-phrase") or "")
                if (not _cover_title_ok(title, str(recording.get("title") or "")) or
                        (artist and not _cover_artist_ok(artist, recording_artist))):
                    continue
                for release in recording.get("releases") or []:
                    release_artist = str(
                        release.get("artist-credit-phrase") or recording_artist)
                    if (album and
                            not _cover_title_ok(album, str(release.get("title") or ""))):
                        continue
                    if artist and not _cover_artist_ok(artist, release_artist):
                        continue
                    releases.append(release)
        except Exception as error:
            log("MusicBrainz recording search failed: %s" % error)
    return releases


def _cover_art_archive(artist: str, title: str, album: str) -> str:
    if not artist or not title:
        return ""
    for release in _musicbrainz_releases(artist, title, album):
        mbid = str(release.get("id") or "")
        if not re.fullmatch(
                r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", mbid):
            continue
        try:
            metadata_url = "https://coverartarchive.org/release/" + mbid
            req = urllib.request.Request(
                metadata_url,
                headers={"User-Agent": MUSICBRAINZ_UA, "Accept": "application/json"},
            )
            with closing(urllib.request.urlopen(req, timeout=8)) as resp:
                metadata = json.loads(resp.read().decode("utf-8", "replace"))
            images = metadata.get("images") or []
            for image in images:
                if not (image.get("front") or any(
                        str(kind).lower() == "front"
                        for kind in image.get("types") or [])):
                    continue
                thumbnails = image.get("thumbnails") or {}
                cover = thumbnails.get("500") or thumbnails.get("large")
                cover = cover or image.get("image") or ""
                if (cover and _cdn_ok(cover) and
                        _host_in(cover, ("coverartarchive.org",))):
                    return cover
                return metadata_url + "/front"
        except urllib.error.HTTPError as error:
            if error.code != 404:
                log("Cover Art Archive lookup failed: HTTP %s" % error.code)
        except Exception as error:
            log("Cover Art Archive lookup failed: %s" % error)
    return ""


def _cover_host_ok(url: str) -> bool:
    return _cdn_ok(url) and _host_in(
        url, (*COVER_HOSTS, "coverartarchive.org"))


def _image_host_ok(url: str) -> bool:
    return _cdn_ok(url) and _host_in(url, IMAGE_HOSTS)


def cover_for(artist: str, title: str, album: str) -> str:
    """Ссылка на обложку (внешний CDN). Кэшируем и пустые ответы, чтобы не долбить источники."""
    key = norm(artist) + "|" + norm(title) + "|" + norm(album)
    with _lock:
        if key in _cover_cache:
            return _cover_cache[key]
    cover = _find_cover(artist, title, album)
    with _lock:
        _cover_cache[key] = cover
        if len(_cover_cache) > 5000:
            _cover_cache.clear()
    return cover


def fetch_image(url: str, limit: int = 4_000_000):
    if not _cdn_ok(url) or not _host_in(url, IMAGE_HOSTS):
        raise ValueError("хост изображения не разрешён")
    req = urllib.request.Request(_safe_url(url), headers={"User-Agent": UA, "Accept": "image/*,*/*"})
    with closing(urllib.request.urlopen(req, timeout=10)) as resp:
        if not _cdn_ok(resp.geturl()) or not _host_in(resp.geturl(), IMAGE_HOSTS):
            raise ValueError("редирект на чужой хост")
        ctype = resp.headers.get("Content-Type") or "image/jpeg"
        data = resp.read(limit + 1)
    if len(data) > limit:
        raise ValueError("картинка слишком большая")
    return data, (ctype if ctype.startswith("image/") else "image/jpeg")


# ------------------------------------------------------------------ HTTP-обработчик

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "lumino/" + APP_VERSION

    # ---------- мелочи ----------

    def _route(self) -> str:
        return urllib.parse.urlparse(self.path).path

    def _param(self, name: str, default: str = "") -> str:
        return (urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get(name) or [default])[0]

    def _send(self, code: int, body: bytes, ctype: str, cookies=(), extra=()) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in extra:
            self.send_header(k, v)
        for c in cookies:
            self.send_header("Set-Cookie", c)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code: int = 200, cookies=()) -> None:
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8", cookies)

    def _fail(self, message: str, code: int = 400) -> None:
        self._json({"error": message}, code)

    def _secure(self) -> str:
        # За HTTPS-прокси (nginx и т.п.) ставим флаг Secure на cookie.
        proto = (self.headers.get("X-Forwarded-Proto") or "").split(",")[0].strip().lower()
        return "; Secure" if proto == "https" else ""

    def _cookie(self, token: str) -> str:
        return "%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax%s" % (
            SESSION_COOKIE, token, SESSION_TTL, self._secure())

    def _expire_cookie(self) -> str:
        return "%s=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax%s" % (SESSION_COOKIE, self._secure())

    def _token(self) -> str:
        raw = self.headers.get("Cookie")
        if raw:
            jar = SimpleCookie()
            try:
                jar.load(raw)
            except Exception:
                jar = SimpleCookie()
            morsel = jar.get(SESSION_COOKIE)
            if morsel and morsel.value:
                return morsel.value
        auth = (self.headers.get("Authorization") or "").strip()
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return ""

    def _user(self):
        return user_by_token(self._token())

    def _body(self, limit: int = 64 * 1024):
        """JSON-тело. None — тело больше лимита (не читаем)."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0:
            return {}
        if length > limit:
            self.close_connection = True
            return None
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    # ---------- маршруты ----------

    def do_GET(self):
        path = self._route()
        try:
            if path == "/health":
                return self._send(200, b"ok", "text/plain; charset=utf-8")
            if path.startswith("/api/"):
                return self.api_get(path)
            return self._fail("не найдено", 404)
        except (BrokenPipeError, ConnectionResetError):
            return          # клиент сам закрыл соединение (таймаут или перемотка)
        except Exception as e:
            log("ОШИБКА GET %s: %s: %s" % (path, type(e).__name__, e))
            try:
                self._fail("внутренняя ошибка", 500)
            except Exception:
                pass

    def do_POST(self):
        path = self._route()
        try:
            if path.startswith("/api/auth/") or path.startswith("/api/chat/"):
                return self.api_post(path)
            return self._fail("не найдено", 404)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            log("ОШИБКА POST %s: %s: %s" % (path, type(e).__name__, e))
            try:
                self._fail("внутренняя ошибка", 500)
            except Exception:
                pass

    def do_PUT(self):
        path = self._route()
        try:
            if path == "/api/state":
                return self.api_put_state()
            return self._fail("не найдено", 404)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            log("ОШИБКА PUT %s: %s: %s" % (path, type(e).__name__, e))
            try:
                self._fail("внутренняя ошибка", 500)
            except Exception:
                pass

    def api_put_state(self) -> None:
        # Сначала читаем тело целиком, иначе при keep-alive оно попадёт в следующий запрос.
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > STATE_MAX:
            self.close_connection = True
            return self._fail("состояние пустое или слишком большое", 413)
        raw = self.rfile.read(length)
        user = self._user()
        if not user:
            return self._fail("нужно войти", 401)
        try:
            data = json.loads(raw.decode("utf-8"))
        except ValueError:
            return self._fail("некорректный JSON", 400)
        if not isinstance(data, dict):
            return self._fail("ожидается объект состояния", 400)
        text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        updated = iso()
        execute("""INSERT INTO user_state (user_id, data, updated_at) VALUES (?,?,?)
                   ON CONFLICT(user_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at""",
                (user["id"], text, updated))
        return self._json({"ok": True, "updated_at": updated})

    def do_HEAD(self):
        # HEAD отдаёт те же заголовки, что GET; тело _send не пишет сам.
        return self.do_GET()

    # ---------- GET ----------

    def chat_get(self, path: str) -> None:
        user = self._user()
        if not user:
            return self._fail("нужно войти", 401)
        if path == "/api/chat/users":
            term = self._param("q").strip()
            if len(term) < 2:
                return self._json({"users": []})
            rows = query(
                """SELECT id FROM users
                   WHERE email_verified = 1 AND id != ?
                     AND (username LIKE ? OR display_name LIKE ?)
                   ORDER BY CASE WHEN username LIKE ? THEN 0 ELSE 1 END,
                            username COLLATE NOCASE LIMIT 30""",
                (user["id"], "%" + term + "%", "%" + term + "%",
                 term + "%"),
            )
            return self._json({"users": [u for row in rows
                                          if (u := _chat_user(row["id"]))]})
        if path == "/api/chat/chats":
            rows = query(
                """SELECT c.id, c.name, c.type,
                          msg.text AS last_text, msg.created_at AS last_at,
                          msg.sender_id AS last_sender
                   FROM chat_members mine JOIN chats c ON c.id = mine.chat_id
                   LEFT JOIN chat_messages msg ON msg.id = (
                       SELECT MAX(id) FROM chat_messages WHERE chat_id = c.id)
                   WHERE mine.user_id = ? AND mine.active = 1 AND c.type = 'direct'
                   ORDER BY COALESCE(msg.id, 0) DESC""",
                (user["id"],),
            )
            chats = []
            for row in rows:
                item = dict(row)
                if row["type"] == "direct":
                    member = one(
                        """SELECT user_id FROM chat_members
                           WHERE chat_id = ? AND user_id != ? AND active = 1 LIMIT 1""",
                        (row["id"], user["id"]),
                    )
                    item["peer"] = _chat_user(member["user_id"]) if member else None
                    if item["peer"]:
                        item["name"] = item["peer"]["display_name"] or item["peer"]["username"]
                chats.append(item)
            return self._json({"chats": chats, "user": _chat_user(user["id"])})
        if path == "/api/chat/messages":
            chat_id = self._param("chat_id").strip()
            member = one(
                """SELECT m.active FROM chat_members m JOIN chats c ON c.id = m.chat_id
                   WHERE m.chat_id = ? AND m.user_id = ? AND c.type = 'direct'""",
                (chat_id, user["id"]),
            )
            if not member or not member["active"]:
                return self._fail("нет доступа к этому чату", 403)
            try:
                after = max(0, int(self._param("after", "0") or 0))
            except ValueError:
                return self._fail("некорректный номер сообщения", 400)
            rows = query(
                """SELECT id, sender_id, text, image_data, track_json, created_at
                   FROM chat_messages WHERE chat_id = ? AND id > ?
                   ORDER BY id DESC LIMIT 100""",
                (chat_id, after),
            )
            messages = []
            for row in reversed(rows):
                item = dict(row)
                item["sender"] = _chat_user(row["sender_id"])
                try:
                    item["track"] = json.loads(item.pop("track_json")) if item["track_json"] else None
                except ValueError:
                    item["track"] = None
                item["image"] = item.pop("image_data")
                messages.append(item)
            return self._json({"messages": messages})
        return self._fail("нет такого метода: %s" % path, 404)

    def chat_post(self, path: str, body: dict) -> None:
        user = self._user()
        if not user:
            return self._fail("нужно войти", 401)
        if path == "/api/chat/create":
            username = str(body.get("username") or "").strip()
            peer = one(
                """SELECT id FROM users WHERE lower(username) = lower(?)
                   AND email_verified = 1""",
                (username,),
            )
            if not peer or peer["id"] == user["id"]:
                return self._fail("пользователь не найден", 404)
            low, high = sorted((user["id"], peer["id"]))
            chat_id = "dm:%d:%d" % (low, high)
            execute(
                "INSERT OR IGNORE INTO chats (id, name, type, created_by, created_at) VALUES (?,?,?,?,?)",
                (chat_id, "", "direct", user["id"], iso()),
            )
            for member_id in (low, high):
                execute(
                    """INSERT INTO chat_members (chat_id, user_id, active, joined_at)
                       VALUES (?,?,1,?) ON CONFLICT(chat_id,user_id)
                       DO UPDATE SET active=1""",
                    (chat_id, member_id, iso()),
                )
            return self._json({"ok": True, "chat_id": chat_id})
        if path == "/api/chat/send":
            chat_id = str(body.get("chat_id") or "").strip()
            member = one(
                """SELECT m.active FROM chat_members m JOIN chats c ON c.id = m.chat_id
                   WHERE m.chat_id = ? AND m.user_id = ? AND c.type = 'direct'""",
                (chat_id, user["id"]),
            )
            if not member or not member["active"]:
                return self._fail("нет доступа к этому чату", 403)
            text = str(body.get("text") or "").strip()
            image = str(body.get("image") or "")
            track = body.get("track")
            if len(text) > 4000:
                return self._fail("сообщение слишком длинное", 413)
            if image and (len(image) > 3_500_000 or not image.startswith("data:image/")):
                return self._fail("изображение слишком большое или имеет неверный формат", 413)
            if track is not None and not isinstance(track, dict):
                return self._fail("некорректный трек", 400)
            if not text and not image and track is None:
                return self._fail("сообщение пустое", 400)
            msg_id = execute(
                """INSERT INTO chat_messages (chat_id, sender_id, text, image_data, track_json, created_at)
                   VALUES (?,?,?,?,?,?)""",
                (chat_id, user["id"], text, image,
                 json.dumps(track, ensure_ascii=False) if track is not None else "", iso()),
            )
            return self._json({"ok": True, "id": msg_id})
        return self._fail("нет такого метода: %s" % path, 404)

    def api_get(self, path: str) -> None:
        if path.startswith("/api/chat/"):
            return self.chat_get(path)
        if path == "/api/users/profile":
            username = self._param("username").strip()
            if not username:
                return self._fail("нужен username", 400)
            user = find_user(username)
            if not user:
                return self._fail("пользователь не найден", 404)
            return self._json({"user": _public_user_profile(user)})
        if path == "/api/auth/me":
            user = self._user()
            return self._json({"user": public_user(user) if user else None, "version": APP_VERSION})

        if path == "/api/search":
            q = self._param("q")
            try:
                limit = max(1, min(50, int(self._param("limit", "20"))))
            except ValueError:
                limit = 20
            tracks, error = search_catalog(q)
            tracks = [proxy_track(t) for t in tracks[:limit]]
            return self._json({"query": q, "tracks": tracks, "count": len(tracks), "error": error or None})

        if path == "/api/search/status":
            with _lock:
                err = _search_status["error"]
                at = _search_status["at"]
            unavailable = bool(err) and time.time() - at < 60
            return self._json({"unavailable": unavailable, "error": err})

        if path == "/api/lyrics":
            artist = self._param("artist").strip()
            title = self._param("title").strip()
            if not artist or not title:
                return self._fail("нужны artist и title")
            artists = [a for a in self._param("artists").split(",") if a.strip()]
            album = self._param("album").strip()
            try:
                duration = float(self._param("duration", "0") or 0)
            except ValueError:
                duration = 0
            return self._json(get_lyrics({"title": title, "artist": artist, "artists": artists,
                                          "album": album, "duration": duration}))

        if path == "/api/similar":
            names = [n.strip() for n in self._param("names").split("|") if n.strip()][:8]
            return self._json({n: related_artists(n) for n in names})

        if path == "/api/audio":
            return self.proxy_audio(self._param("url").strip())

        if path == "/api/cover":
            artist = self._param("artist").strip()
            title = self._param("title").strip()
            if not title:
                return self._json({"cover": ""})
            album = self._param("album").strip()
            raw = cover_for(artist, title, album)
            if not raw:
                return self._json({"cover": ""})
            return self._json({"cover": "/api/image?url=" + urllib.parse.quote(raw, safe="")})

        if path == "/api/image":
            return self.proxy_image(self._param("url").strip())

        if path == "/api/state":
            user = self._user()
            if not user:
                return self._fail("нужно войти", 401)
            row = one("SELECT data, updated_at FROM user_state WHERE user_id = ?", (user["id"],))
            if not row:
                return self._json({"state": None, "updated_at": ""})
            # data уже хранится как JSON-текст: отдаём без повторного разбора
            body = ('{"state":%s,"updated_at":%s}' % (row["data"], json.dumps(row["updated_at"]))).encode("utf-8")
            return self._send(200, body, "application/json; charset=utf-8")

        return self._fail("нет такого метода: %s" % path, 404)

    def proxy_image(self, url: str) -> None:
        """Обложка через сервер: клиент не ходит к CDN напрямую."""
        if not url or not _image_host_ok(url):
            return self._fail("этот источник не поддерживается", 403)
        try:
            data, ctype = fetch_image(url)
        except Exception as e:
            log("обложка не загружена: %s" % e)
            return self._fail("картинка недоступна", 502)
        self._send(200, data, ctype)

    def proxy_audio(self, url: str) -> None:
        """Стрим аудио каталога: Referer и User-Agent подставляем сами, Range пробрасываем."""
        host = urllib.parse.urlparse(url).hostname if url else ""
        log("аудио запрос: host=%s range=%s" % (host, self.headers.get("Range") or "-"))
        if not url or not _host_ok(url):
            log("аудио отказ: источник не разрешён (%s)" % (host or "пусто"))
            return self._fail("этот источник не поддерживается", 403)
        headers = {"User-Agent": UA, "Referer": HITMOZ_ORIGIN + "/", "Accept": "*/*",
                   "Accept-Encoding": "identity"}
        # Всегда просим диапазон: без Range каталог редиректит на CDN, а с Range отдаёт файл сам.
        client_range = self.headers.get("Range")
        headers["Range"] = client_range or "bytes=0-"
        target = _safe_url(url)
        short = "%s%s" % (host, urllib.parse.urlparse(url).path)
        up = None
        last_error = ""
        for attempt in range(2):
            try:
                up = _hitmoz_opener.open(urllib.request.Request(target, headers=headers), timeout=30)
                break
            except urllib.error.HTTPError as e:
                if e.code == 416:      # перемотка за конец файла — честно передаём плееру
                    self.send_response(416)
                    self.send_header("Content-Range", e.headers.get("Content-Range") or "bytes */0")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                log("аудио ошибка: каталог ответил %s (%s)" % (e.code, short))
                return self._fail("каталог ответил %s" % e.code, 502)
            except Exception as e:     # сетевой сбой: пробуем ещё раз один раз
                last_error = "%s: %s" % (type(e).__name__, e)
                log("аудио ошибка, попытка %d/2 (%s): %s" % (attempt + 1, short, last_error))
                time.sleep(0.5)
        if up is None:
            return self._fail("каталог недоступен: %s" % last_error, 502)
        with closing(up):
            final = up.geturl()
            final_host = urllib.parse.urlparse(final).hostname or ""
            if not _host_allowed(final_host):
                ctype = (up.headers.get("Content-Type") or "").lower()
                if not (_cdn_ok(final) and (ctype.startswith("audio/") or "octet-stream" in ctype)):
                    log("аудио отказ: редирект на %s, тип %s" % (final_host, ctype or "-"))
                    return self._fail("редирект на чужой домен", 502)
                log("аудио: каталог перенаправил на CDN %s" % final_host)
            length = up.headers.get("Content-Length")
            if client_range:
                # плеер сам просил диапазон: отдаём 206 как есть
                self.send_response(206 if up.status == 206 else 200)
                if up.headers.get("Content-Range"):
                    self.send_header("Content-Range", up.headers.get("Content-Range"))
            else:
                # плеер просил весь файл: если каталог ответил 206 из-за нашего bytes=0-,
                # отдаём 200 и полный размер из Content-Range (…/ВСЕГО)
                self.send_response(200)
                if up.status == 206:
                    m = re.search(r"/(\d+)\s*$", up.headers.get("Content-Range") or "")
                    length = m.group(1) if m else None
            self.send_header("Content-Type", up.headers.get("Content-Type") or "audio/mpeg")
            self.send_header("Accept-Ranges", "bytes")
            if length:
                self.send_header("Content-Length", str(length))
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.send_header("Cache-Control", "public, max-age=600")
            self.end_headers()
            if self.command == "HEAD":
                return
            try:
                shutil.copyfileobj(up, self.wfile, CHUNK)
            except (BrokenPipeError, ConnectionResetError):
                pass          # плеер перемотал или сменил трек

    # ---------- POST /api/auth ----------

    def api_post(self, path: str) -> None:
        body = self._body(limit=4 * 1024 * 1024 if path == "/api/chat/send" else 64 * 1024)
        if body is None:
            return self._fail("запрос слишком большой", 413)

        if path.startswith("/api/chat/"):
            return self.chat_post(path, body)

        if path == "/api/auth/register":
            username = str(body.get("username") or "").strip()
            password = str(body.get("password") or "")
            email = str(body.get("email") or "").strip().lower()
            display = re.sub(r"\s+", " ", str(body.get("display_name") or "")).strip()[:64]
            if len(username) < 3 or len(username) > 32:
                return self._fail("имя от 3 до 32 символов")
            if not re.match(r"^[\w.@+\- ]+$", username):
                return self._fail("в имени только буквы, цифры и . _ @ + -")
            if len(password) < 4:
                return self._fail("пароль минимум из 4 символов")
            if not EMAIL_RE.match(email):
                return self._fail("введите корректную почту")
            if not SMTP_HOST or not SMTP_USER:
                return self._fail("отправка писем не настроена на сервере", 503)
            pending = one("SELECT id, password FROM users WHERE lower(username) = lower(?) AND email_verified = 0",
                          (username,))
            if pending:
                if not check_password(password, pending["password"]):
                    return self._fail("такое имя уже занято", 409)
                execute("UPDATE users SET email = ?, display_name = ? WHERE id = ?", (email, display, pending["id"]))
                user_id = pending["id"]
            else:
                if one("SELECT id FROM users WHERE lower(username) = lower(?)", (username,)):
                    return self._fail("такое имя уже занято", 409)
                if one("SELECT id FROM users WHERE lower(email) = ? AND email_verified = 1", (email,)):
                    return self._fail("на эту почту уже зарегистрирован аккаунт", 409)
                user_id = execute(
                    "INSERT INTO users (username, password, email, email_verified, display_name, created_at, last_seen) "
                    "VALUES (?,?,?,0,?,?,?)",
                    (username, hash_password(password), email, display, iso(), iso()))
            try:
                issue_code(user_id, email)
            except Exception as e:
                log("почта: не отправлено (%s): %s" % (email, e))
                return self._fail("не удалось отправить письмо: %s" % e, 502)
            log("регистрация: %s, код отправлен" % username)
            return self._json({"ok": True, "need_verify": True, "email": email})

        if path == "/api/auth/verify":
            email = str(body.get("email") or "").strip().lower()
            code = re.sub(r"\D", "", str(body.get("code") or ""))
            row = _pending_row(email)
            err = _code_error(row, code)
            if err:
                return self._fail(err, 400)
            execute("UPDATE users SET email_verified = 1 WHERE id = ?", (row["id"],))
            execute("DELETE FROM email_codes WHERE user_id = ?", (row["id"],))
            token = new_session(row["id"])
            log("почта подтверждена: %s" % row["username"])
            return self._json({"ok": True, "user": public_user(find_user(row["username"]))},
                              cookies=[self._cookie(token)])

        if path == "/api/auth/resend":
            email = str(body.get("email") or "").strip().lower()
            row = one("""SELECT u.id, c.last_sent FROM users u LEFT JOIN email_codes c ON c.user_id = u.id
                          WHERE lower(u.email) = ? AND u.email_verified = 0""", (email,))
            if not row:
                return self._fail("аккаунт не найден", 404)
            if row["last_sent"] and (now() - dt.datetime.fromisoformat(row["last_sent"])).total_seconds() < CODE_RESEND:
                return self._fail("подождите минуту перед повторной отправкой", 429)
            try:
                issue_code(row["id"], email)
            except Exception as e:
                return self._fail("не удалось отправить письмо: %s" % e, 502)
            return self._json({"ok": True})

        if path == "/api/auth/login":
            username = str(body.get("username") or "").strip()
            password = str(body.get("password") or "")
            row = one("SELECT id, password, email_verified FROM users WHERE lower(username) = lower(?)", (username,))
            if not row or not check_password(password, row["password"]):
                return self._fail("неверное имя или пароль", 401)
            if not row["email_verified"]:
                return self._json({"error": "почта не подтверждена — введите код из письма",
                                   "need_verify": True}, 403)
            token = new_session(row["id"])
            execute("UPDATE users SET last_seen = ? WHERE id = ?", (iso(), row["id"]))
            log("вход: %s" % username)
            return self._json({"ok": True, "user": public_user(find_user(username))},
                              cookies=[self._cookie(token)])

        if path == "/api/auth/logout":
            drop_session(self._token())
            return self._json({"ok": True}, cookies=[self._expire_cookie()])

        if path == "/api/auth/password":
            user = self._user()
            if not user:
                return self._fail("нужно войти", 401)
            row = one("SELECT password FROM users WHERE id = ?", (user["id"],))
            if not row or not check_password(str(body.get("old_password") or ""), row["password"]):
                return self._fail("старый пароль неверный", 401)
            new_pw = str(body.get("new_password") or "")
            if len(new_pw) < 4:
                return self._fail("новый пароль минимум из 4 символов")
            execute("UPDATE users SET password = ? WHERE id = ?", (hash_password(new_pw), user["id"]))
            return self._json({"ok": True})

        if path == "/api/auth/forgot":
            email = str(body.get("email") or "").strip().lower()
            if not SMTP_HOST or not SMTP_USER:
                return self._fail("отправка писем не настроена на сервере", 503)
            # ответ одинаковый, есть ли аккаунт с такой почтой — чтобы не выдавать чужие адреса
            row = one("""SELECT u.id, u.username, c.last_sent FROM users u
                           LEFT JOIN email_codes c ON c.user_id = u.id
                          WHERE lower(u.email) = ? AND u.email_verified = 1""", (email,))
            if not row:
                log("сброс пароля: нет аккаунта с подтверждённой почтой %r" % email)
            elif row["last_sent"] and (now() - dt.datetime.fromisoformat(row["last_sent"])).total_seconds() < CODE_RESEND:
                log("сброс пароля: код уже отправлен, ждём минуту (%s)" % row["username"])
            else:
                try:
                    issue_code(row["id"], email, reset=True)
                except Exception as e:
                    log("сброс пароля: письмо не отправлено (%s): %s" % (email, e))
                    return self._fail("не удалось отправить письмо: %s" % e, 502)
                log("сброс пароля: код отправлен %s" % row["username"])
            return self._json({"ok": True})

        if path == "/api/auth/reset/check":
            email = str(body.get("email") or "").strip().lower()
            code = re.sub(r"\D", "", str(body.get("code") or ""))
            err = _code_error(_reset_row(email), code)
            if err:
                return self._fail(err, 400)
            return self._json({"ok": True})

        if path == "/api/auth/reset":
            email = str(body.get("email") or "").strip().lower()
            code = re.sub(r"\D", "", str(body.get("code") or ""))
            new_pw = str(body.get("new_password") or "")
            row = _reset_row(email)
            err = _code_error(row, code)
            if err:
                return self._fail(err, 400)
            if len(new_pw) < 4:
                return self._fail("новый пароль минимум из 4 символов")
            execute("UPDATE users SET password = ? WHERE id = ?", (hash_password(new_pw), row["id"]))
            execute("DELETE FROM email_codes WHERE user_id = ?", (row["id"],))
            # выходим на всех устройствах: старые сессии больше не действуют
            execute("DELETE FROM sessions WHERE user_id = ?", (row["id"],))
            log("пароль сброшен: %s" % row["username"])
            return self._json({"ok": True})

        return self._fail("нет такого метода: %s" % path, 404)

    def log_message(self, fmt, *args):
        try:
            log("%s  %s" % (self.address_string(), fmt % args))
        except Exception:
            pass


# ------------------------------------------------------------------ запуск

def main() -> None:
    parser = argparse.ArgumentParser(description="Lumino — серверная часть")
    parser.add_argument("port_pos", nargs="?", default=None, help="порт (по умолчанию 8000)")
    parser.add_argument("--port", "-p", default=None, help="порт")
    parser.add_argument("--host", default="0.0.0.0", help="хост (по умолчанию 0.0.0.0)")
    args = parser.parse_args()

    port = int(args.port or args.port_pos or os.environ.get("PORT") or 8000)
    init_db()
    if not SMTP_HOST or not SMTP_USER:
        log("внимание: почта не настроена — регистрация и сброс пароля будут недоступны")

    srv = ThreadingHTTPServer((args.host, port), Handler)
    srv.daemon_threads = True
    label = "127.0.0.1" if args.host in ("0.0.0.0", "") else args.host
    print("")
    print("  Lumino %s — сервер готов на http://%s:%d/" % (APP_VERSION, label, port))
    print("  база: %s" % DB_PATH)
    print("  Ctrl+C — остановить")
    print("")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  пока!")
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
