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
import base64
import datetime as dt
import gzip
import hashlib
import html
import hmac
import io
import ipaddress
import json
import os
import re
import secrets
import shutil
import smtplib
import sqlite3
import sys
import tempfile
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
PRIMARY_URL = os.environ.get("LUMINO_PRIMARY_URL", "").strip().rstrip("/")
MIRROR_URL = os.environ.get("LUMINO_MIRROR_URL", "").strip().rstrip("/")
REPLICATION_TOKEN = os.environ.get("LUMINO_REPLICATION_TOKEN", "").strip()
REPLICATION_MAX_COMPRESSED = 256 * 1024 * 1024
REPLICATION_MAX_DATABASE = 512 * 1024 * 1024
PROXY_BODY_MAX = 24 * 1024 * 1024

APP_VERSION = "0.2.6"
CHUNK = 64 * 1024
TIMEOUT = 9

SESSION_COOKIE = "lumino_session"
SESSION_TTL = 60 * 60 * 24 * 30
STATE_MAX = 20 * 1024 * 1024          # предел размера состояния пользователя
AI_SKIP_DISMISS_THRESHOLD = 3
AI_RETRAIN_INTERVAL_SECONDS = 15 * 60
AI_RETRAIN_MIN_NEW_EVENTS = 20
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
_replication_lock = threading.Lock()
_replication_timer = None
_replication_running = False
_replication_pending = False
_search_cache: dict = {}
_search_status = {"error": "", "at": 0.0}
_lyrics_cache: dict = {}
_similar_cache: dict = {}
_musicbrainz_lock = threading.Lock()
_musicbrainz_last_request = 0.0


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


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
CREATE TABLE IF NOT EXISTS ai_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ai_events_user_id_id
    ON ai_events(user_id, id);
CREATE TABLE IF NOT EXISTS ai_models (
    user_id    INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    model_json TEXT NOT NULL,
    trained_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS private_playlist_shares (
    token_hash  TEXT PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    playlist_id TEXT NOT NULL,
    created_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS track_shares (
    code       TEXT PRIMARY KEY,
    user_id    INTEGER REFERENCES users(id) ON DELETE SET NULL,
    track_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS lyrics_cache (
    cache_key  TEXT PRIMARY KEY,
    result_json TEXT NOT NULL,
    cached_at  TEXT NOT NULL
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
    last_read_message_id INTEGER NOT NULL DEFAULT 0,
    typing_at TEXT NOT NULL DEFAULT '',
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
        result = cur.lastrowid
    _schedule_database_replication()
    return result


def _replication_configuration_error() -> str:
    if PRIMARY_URL and MIRROR_URL:
        return "укажите только LUMINO_PRIMARY_URL или LUMINO_MIRROR_URL"
    if PRIMARY_URL or MIRROR_URL:
        for name, value in (("LUMINO_PRIMARY_URL", PRIMARY_URL),
                            ("LUMINO_MIRROR_URL", MIRROR_URL)):
            if value:
                parsed = urllib.parse.urlparse(value)
                if (parsed.scheme != "https" or not parsed.hostname
                        or parsed.username or parsed.password
                        or parsed.path or parsed.query or parsed.fragment):
                    return "%s должен быть корректным HTTPS URL" % name
        if len(REPLICATION_TOKEN) < 32:
            return "LUMINO_REPLICATION_TOKEN должен содержать минимум 32 символа"
    return ""


def _schedule_database_replication(delay: float = 0.5) -> None:
    global _replication_timer, _replication_pending
    if not MIRROR_URL or not REPLICATION_TOKEN:
        return
    with _replication_lock:
        if _replication_running:
            _replication_pending = True
            return
        if _replication_timer is not None:
            _replication_timer.cancel()
        _replication_timer = threading.Timer(delay, _replicate_database)
        _replication_timer.daemon = True
        _replication_timer.start()


def _replicate_database() -> None:
    global _replication_timer, _replication_running, _replication_pending
    with _replication_lock:
        _replication_timer = None
        if _replication_running:
            _replication_pending = True
            return
        _replication_running = True
        _replication_pending = False

    succeeded = False
    snapshot_path = ""
    try:
        with tempfile.NamedTemporaryFile(
                prefix=".fascind-replica-", suffix=".db", dir=DATA_DIR,
                delete=False) as snapshot:
            snapshot_path = snapshot.name
        with _db_lock, closing(sqlite3.connect(DB_PATH, timeout=15)) as source, \
                closing(sqlite3.connect(snapshot_path, timeout=15)) as target:
            source.backup(target)
        compressed = io.BytesIO()
        with open(snapshot_path, "rb") as snapshot_file, \
                gzip.GzipFile(fileobj=compressed, mode="wb", compresslevel=1) as archive:
            shutil.copyfileobj(snapshot_file, archive, CHUNK)
        payload = compressed.getvalue()
        if len(payload) > REPLICATION_MAX_COMPRESSED:
            raise ValueError("сжатая база превышает лимит репликации")
        request = urllib.request.Request(
            MIRROR_URL + "/_internal/replica/db",
            data=payload,
            headers={
                "Content-Type": "application/gzip",
                "Content-Length": str(len(payload)),
                "X-Lumino-Replication-Token": REPLICATION_TOKEN,
            },
            method="PUT",
        )
        with closing(urllib.request.urlopen(request, timeout=45)) as response:
            if response.status != 200:
                raise OSError("зеркало ответило HTTP %s" % response.status)
        succeeded = True
        log("база синхронизирована с зеркалом (%d байт)" % len(payload))
    except Exception as error:
        log("ошибка репликации базы: %s: %s" % (type(error).__name__, error))
    finally:
        if snapshot_path:
            try:
                os.unlink(snapshot_path)
            except OSError:
                pass
        with _replication_lock:
            _replication_running = False
            pending = _replication_pending
            _replication_pending = False
        if pending or not succeeded:
            _schedule_database_replication(0.5 if pending else 5.0)


def _receive_database_replica(handler) -> None:
    if not REPLICATION_TOKEN or not hmac.compare_digest(
            handler.headers.get("X-Lumino-Replication-Token", ""),
            REPLICATION_TOKEN):
        handler.close_connection = True
        return handler._fail("нет доступа", 403)
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > REPLICATION_MAX_COMPRESSED:
        handler.close_connection = True
        return handler._fail("некорректный размер снимка базы", 413)
    compressed = handler.rfile.read(length)
    if len(compressed) != length:
        handler.close_connection = True
        return handler._fail("снимок базы получен не полностью", 400)

    snapshot_path = ""
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(compressed), mode="rb") as archive, \
                tempfile.NamedTemporaryFile(
                    prefix=".fascind-replica-", suffix=".db", dir=DATA_DIR,
                    delete=False) as snapshot:
            snapshot_path = snapshot.name
            total = 0
            while True:
                chunk = archive.read(CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > REPLICATION_MAX_DATABASE:
                    raise ValueError("база превышает лимит репликации")
                snapshot.write(chunk)
        with closing(sqlite3.connect(snapshot_path, timeout=15)) as check:
            result = check.execute("PRAGMA integrity_check").fetchone()
            if not result or result[0] != "ok":
                raise ValueError("проверка целостности базы не пройдена")
            tables = {
                row[0] for row in check.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                )
            }
            if not {"users", "user_state", "sessions"}.issubset(tables):
                raise ValueError("в снимке отсутствуют основные таблицы Lumino")
        with _db_lock:
            for suffix in ("-wal", "-shm", "-journal"):
                try:
                    os.unlink(DB_PATH + suffix)
                except FileNotFoundError:
                    pass
            os.replace(snapshot_path, DB_PATH)
            snapshot_path = ""
        log("получена актуальная копия базы (%d байт)" % total)
        return handler._send(200, b"ok", "text/plain; charset=utf-8")
    except (OSError, sqlite3.Error, ValueError, EOFError) as error:
        log("не удалось применить копию базы: %s: %s" % (type(error).__name__, error))
        return handler._fail("не удалось применить копию базы", 400)
    finally:
        if snapshot_path:
            try:
                os.unlink(snapshot_path)
            except OSError:
                pass


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
        member_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(chat_members)")
        }
        if "last_read_message_id" not in member_columns:
            conn.execute(
                "ALTER TABLE chat_members ADD COLUMN last_read_message_id INTEGER NOT NULL DEFAULT 0"
            )
        if "typing_at" not in member_columns:
            conn.execute(
                "ALTER TABLE chat_members ADD COLUMN typing_at TEXT NOT NULL DEFAULT ''"
            )
        track_share_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(track_shares)")
        }
        if "user_id" not in track_share_columns:
            conn.execute(
                "ALTER TABLE track_shares ADD COLUMN user_id INTEGER REFERENCES users(id) ON DELETE SET NULL"
            )
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
    try:
        last_seen = dt.datetime.fromisoformat(row["last_seen"])
    except (TypeError, ValueError):
        last_seen = dt.datetime.min
    if last_seen.tzinfo is not None:
        last_seen = last_seen.astimezone().replace(tzinfo=None)
    if (now() - last_seen).total_seconds() >= 30:
        timestamp = iso()
        execute("UPDATE users SET last_seen = ? WHERE id = ?", (timestamp, row["id"]))
        row["last_seen"] = timestamp
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
        result.update(avatar="", liked_tracks=[], public_playlists=[])
        return result
    try:
        state = json.loads(row["data"])
    except (ValueError, TypeError):
        result.update(avatar="", liked_tracks=[], public_playlists=[])
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
    saved_tracks_by_id = {
        str(track.get("id") or ""): track
        for track in tracks if isinstance(track, dict)
    } if isinstance(tracks, list) else {}
    playlists = state.get("playlists", []) if isinstance(state, dict) else []
    public_playlists = []
    for playlist in playlists if isinstance(playlists, list) else []:
        if not isinstance(playlist, dict) or not playlist.get("public", False):
            continue
        ids = playlist.get("ids", [])
        ids = ids if isinstance(ids, list) else []
        playlist_tracks = []
        cover = str(playlist.get("cover") or "")
        if not cover:
            for track_id in ids:
                saved_track = saved_tracks_by_id.get(str(track_id))
                if saved_track and saved_track.get("cover"):
                    cover = str(saved_track["cover"])
                    break
        for track_id in ids:
            saved_track = saved_tracks_by_id.get(str(track_id))
            if not isinstance(saved_track, dict) or not saved_track.get("title"):
                continue
            artists = saved_track.get("artists", [])
            if not isinstance(artists, list):
                artists = []
            playlist_tracks.append({
                "id": str(saved_track.get("id") or track_id),
                "title": str(saved_track.get("title") or ""),
                "artists": artists,
                "album": str(saved_track.get("album") or ""),
                "cover": str(saved_track.get("cover") or ""),
                "duration": saved_track.get("duration") or 0,
                "releaseType": str(saved_track.get("releaseType") or ""),
            })
        public_playlists.append({
            "id": str(playlist.get("id") or ""),
            "name": str(playlist.get("name") or "Playlist"),
            "cover": cover,
            "tracks": playlist_tracks,
        })
    result["public_playlists"] = public_playlists
    return result


def _playlist_share_data(state: dict, playlist_id: str) -> dict | None:
    playlists = state.get("playlists", [])
    playlist = next(
        (item for item in playlists if isinstance(item, dict)
         and str(item.get("id") or "") == playlist_id),
        None,
    ) if isinstance(playlists, list) else None
    if not playlist:
        return None
    saved_tracks = {
        str(track.get("id") or ""): track
        for track in state.get("savedTracks", [])
        if isinstance(track, dict)
    } if isinstance(state.get("savedTracks"), list) else {}
    ids = playlist.get("ids", [])
    ids = ids if isinstance(ids, list) else []
    tracks = []
    cover = str(playlist.get("cover") or "")
    for track_id in ids:
        track = saved_tracks.get(str(track_id))
        if not isinstance(track, dict) or not track.get("title"):
            continue
        if not cover and track.get("cover"):
            cover = str(track["cover"])
        artists = track.get("artists", [])
        tracks.append({
            "id": str(track.get("id") or track_id),
            "title": str(track.get("title") or ""),
            "artists": artists if isinstance(artists, list) else [],
            "album": str(track.get("album") or ""),
            "cover": str(track.get("cover") or ""),
            "duration": track.get("duration") or 0,
            "releaseType": str(track.get("releaseType") or ""),
        })
    return {
        "id": playlist_id,
        "name": str(playlist.get("name") or "Playlist"),
        "cover": cover,
        "tracks": tracks,
    }


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
    cached = one("SELECT result_json FROM lyrics_cache WHERE cache_key = ?", (key,))
    if cached:
        try:
            hit = json.loads(cached["result_json"])
        except (TypeError, ValueError):
            log("повреждён кэш текста песни для ключа %s" % key)
            execute("DELETE FROM lyrics_cache WHERE cache_key = ?", (key,))
        else:
            if isinstance(hit, dict) and isinstance(hit.get("variants"), list) and hit["variants"]:
                with _lock:
                    _lyrics_cache[key] = hit
                return hit
            log("некорректная запись кэша текста песни для ключа %s" % key)
            execute("DELETE FROM lyrics_cache WHERE cache_key = ?", (key,))

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
    if variants:
        with _lock:
            _lyrics_cache[key] = result
        try:
            execute(
                """INSERT INTO lyrics_cache (cache_key, result_json, cached_at)
                   VALUES (?, ?, ?)
                   ON CONFLICT(cache_key) DO UPDATE SET
                       result_json = excluded.result_json,
                       cached_at = excluded.cached_at""",
                (key, json.dumps(result, ensure_ascii=False), iso()),
            )
        except sqlite3.Error as error:
            log("не удалось сохранить текст песни в кэш для ключа %s: %s" % (key, error))
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


def generate_ai_wave(user_id: int, model: dict, exclude_ids: set[str]) -> list:
    artist_scores = {
        item["key"]: {"name": item["name"], "score": float(item["score"])}
        for item in model.get("artists", [])
        if isinstance(item, dict) and item.get("key") and item.get("name")
    }
    track_scores = dict(model.get("track_scores", {}))
    skip_counts = {key: int(value)
                   for key, value in model.get("skip_counts", {}).items()}
    try:
        last_event_id = int(model.get("last_event_id") or 0)
    except (TypeError, ValueError):
        last_event_id = 0

    state_row = one("SELECT data FROM user_state WHERE user_id = ?", (user_id,))
    try:
        user_state = json.loads(state_row["data"]) if state_row else {}
    except (ValueError, TypeError):
        user_state = {}
    if not isinstance(user_state, dict):
        user_state = {}
    liked_keys = {norm(key) for key in user_state.get("liked", [])
                  if isinstance(key, str)}
    disliked_keys = {norm(key) for key in user_state.get("disliked", [])
                     if isinstance(key, str)}
    active_like_artists = set()
    active_dislike_artists = set()
    seed_like_ids = set(model.get("liked_seed_track_ids", []))
    seed_dislike_ids = set(model.get("disliked_seed_track_ids", []))
    saved_tracks = user_state.get("savedTracks", [])
    if isinstance(saved_tracks, list):
        for track in saved_tracks:
            if not isinstance(track, dict):
                continue
            names = track.get("artists", [])
            primary = str(track.get("primary") or (
                names[0] if isinstance(names, list) and names else ""))
            title = str(track.get("title") or "")
            track_key = norm("%s - %s" % (primary, title))
            if track_key in liked_keys:
                if str(track.get("id") or "") not in seed_like_ids:
                    for name in names if isinstance(names, list) else [primary]:
                        key = norm(name)
                        if not key:
                            continue
                        active_like_artists.add(key)
                        item = artist_scores.setdefault(
                            key, {"name": str(name), "score": 0.0})
                        item["score"] += 12.0
                if primary:
                    active_like_artists.add(norm(primary))
            if track_key in disliked_keys:
                if str(track.get("id") or "") not in seed_dislike_ids:
                    for name in names if isinstance(names, list) else [primary]:
                        key = norm(name)
                        if not key:
                            continue
                        active_dislike_artists.add(key)
                        item = artist_scores.setdefault(
                            key, {"name": str(name), "score": 0.0})
                        item["score"] -= 18.0
                if primary:
                    active_dislike_artists.add(norm(primary))

    fresh_rows = query(
        "SELECT event_json FROM ai_events WHERE user_id = ? AND id > ? ORDER BY id",
        (user_id, last_event_id),
    )
    live_weights = {
        "start": 0.05, "progress": 0.8, "complete": 3.0, "skip": 0.0,
        "seek_forward": -0.1, "seek_back": 0.1, "like": 10.0,
        "unlike": -15.0, "dislike": -25.0, "undislike": 20.0,
        "artist_open": 1.8,
    }
    for fresh_row in fresh_rows:
        try:
            event = json.loads(fresh_row["event_json"])
        except (ValueError, TypeError):
            continue
        kind = event.get("type")
        weight = live_weights.get(kind, 0.0)
        track = event.get("track") or {}
        track_id = str(track.get("id") or "")
        names = track.get("artists") or []
        primary = str(names[0] if names else "")
        track_key = norm("%s - %s" % (primary, track.get("title") or ""))
        if kind == "dislike" and track_key:
            disliked_keys.add(track_key)
        elif kind == "undislike" and track_key:
            disliked_keys.discard(track_key)
        if track_id and kind == "skip":
            skip_counts[track_id] = skip_counts.get(track_id, 0) + 1
        if track_id and kind in {"progress", "complete", "like", "unlike",
                                 "dislike", "undislike"}:
            track_scores[track_id] = track_scores.get(track_id, 0.0) + weight
        if kind == "artist_open" and event.get("artist"):
            names = [event["artist"]]
        for index, name in enumerate(names):
            key = norm(name)
            if not key:
                continue
            item = artist_scores.setdefault(
                key, {"name": str(name), "score": 0.0})
            item["score"] += weight * (1.0 if index == 0 else 0.45)

    seeds = sorted(artist_scores.items(),
                   key=lambda item: item[1]["score"], reverse=True)
    seed_names = [item[1]["name"] for item in seeds if item[1]["score"] > 0][:6]
    if not seed_names:
        return []
    similar_names = []
    with ThreadPoolExecutor(max_workers=min(4, len(seed_names))) as pool:
        for related in pool.map(related_artists, seed_names[:4]):
            for name in related:
                key = norm(name)
                if key and key not in artist_scores and all(
                        norm(existing) != key for existing in similar_names):
                    similar_names.append(name)

    jobs = [(name, False) for name in seed_names]
    jobs.extend((name, True) for name in similar_names[:8])
    candidates = {}

    def search_artist(job):
        name, discovery = job
        found, _ = search_catalog(name)
        artist_key = norm(name)
        matches = []
        for track in found:
            track_id = str(track.get("id") or "")
            names = track.get("artists", [])
            if not track_id or not isinstance(names, list):
                continue
            if not any(norm(artist) == artist_key or artist_key in norm(artist)
                       for artist in names if isinstance(artist, str)):
                continue
            primary = str(track.get("primary") or names[0] or "")
            title = str(track.get("title") or "")
            if (track_id in exclude_ids or
                    norm("%s - %s" % (primary, title)) in liked_keys or
                    norm("%s - %s" % (primary, title)) in disliked_keys or
                    skip_counts.get(track_id, 0) >= AI_SKIP_DISMISS_THRESHOLD):
                continue
            matches.append((track, discovery))
            if len(matches) >= 12:
                break
        return matches

    with ThreadPoolExecutor(max_workers=min(6, len(jobs))) as pool:
        for matches in pool.map(search_artist, jobs):
            for track, discovery in matches:
                candidates.setdefault(str(track.get("id") or ""), (track, discovery))

    familiar = []
    discoveries = []
    for index, (track_id, (track, discovery)) in enumerate(candidates.items()):
        names = track.get("artists", [])
        primary = str(track.get("primary") or (names[0] if names else ""))
        artist_key = norm(primary)
        artist_score = max(
            (artist_scores.get(norm(name), {}).get("score", 0.0)
             for name in names if isinstance(name, str)),
            default=0.0,
        )
        score = artist_score + float(track_scores.get(track_id, 0.0))
        if any(norm(name) in active_like_artists for name in names):
            score += 12.0
        if any(norm(name) in active_dislike_artists for name in names):
            score -= 18.0
        score -= min(skip_counts.get(track_id, 0), 2) * 0.08
        (discoveries if discovery else familiar).append(
            (score, index, artist_key, track))
    familiar.sort(key=lambda item: (-item[0], item[1]))
    discoveries.sort(key=lambda item: (-item[0], item[1]))

    selected = []
    used_artists = set()
    familiar_index = 0
    discovery_index = 0
    for position in range(6):
        prefer_discovery = position in {2, 5}
        sources = (discoveries, familiar) if prefer_discovery else (familiar, discoveries)
        chosen = None
        for source in sources:
            cursor = discovery_index if source is discoveries else familiar_index
            while cursor < len(source) and source[cursor][2] in used_artists:
                cursor += 1
            if cursor >= len(source):
                continue
            chosen = source[cursor]
            if source is discoveries:
                discovery_index = cursor + 1
            else:
                familiar_index = cursor + 1
            break
        if chosen is None:
            break
        used_artists.add(chosen[2])
        selected.append(proxy_track(chosen[3]))
    return selected


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

def _share_image_url(value) -> str:
    url = str(value or "").strip()
    if url.startswith("data:"):
        match = re.fullmatch(
            r"data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/]*={0,2})",
            url,
            flags=re.IGNORECASE,
        )
        if not match or not match.group(2) or len(match.group(2)) > 700_000:
            return ""
        try:
            base64.b64decode(match.group(2), validate=True)
        except ValueError:
            return ""
        return url
    if url.startswith("/api/image?"):
        query = urllib.parse.parse_qs(
            urllib.parse.urlparse(url).query, max_num_fields=2
        )
        source = (query.get("url") or [""])[0]
        if not _image_host_ok(source):
            return ""
        return "https://fascind.theluni.ru/api/image?url=" + urllib.parse.quote(
            source, safe=""
        )
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        return ""
    return url[:2048]


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

    def _forwards_to_primary(self, path: str) -> bool:
        return bool(PRIMARY_URL) and (
            path in ("/share", "/api/state", "/api/users/profile")
            or path.startswith("/s/")
            or path.startswith("/api/auth/")
            or path.startswith("/api/chat/")
            or path.startswith("/api/share/")
            or path.startswith("/api/ai/")
        )

    def _forward_to_primary(self) -> None:
        if self.headers.get("X-Lumino-Primary-Proxy") == "1":
            return self._fail("обнаружен цикл проксирования", 508)
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self._fail("некорректный размер запроса", 400)
        if length < 0 or length > PROXY_BODY_MAX:
            self.close_connection = True
            return self._fail("запрос слишком большой", 413)
        body = self.rfile.read(length) if length else None
        headers = {}
        for name in ("Accept", "Authorization", "Content-Type", "Cookie",
                     "Range", "X-Forwarded-For", "X-Forwarded-Proto"):
            value = self.headers.get(name)
            if value:
                headers[name] = value
        headers["Accept-Encoding"] = "identity"
        headers["X-Lumino-Primary-Proxy"] = "1"
        request = urllib.request.Request(
            PRIMARY_URL + self.path,
            data=body,
            headers=headers,
            method=self.command,
        )
        response = None
        response_started = False
        try:
            try:
                response = urllib.request.build_opener(_NoRedirect()).open(
                    request, timeout=60)
            except urllib.error.HTTPError as error:
                response = error
            self.send_response(response.status)
            response_started = True
            for name in (
                "Content-Type",
                "Content-Length",
                "Cache-Control",
                "Content-Disposition",
                "Content-Range",
                "Accept-Ranges",
                "Location",
                "Retry-After",
                "Content-Security-Policy",
                "X-Content-Type-Options",
                "Referrer-Policy",
            ):
                value = response.headers.get(name)
                if value:
                    self.send_header(name, value)
            for cookie in response.headers.get_all("Set-Cookie", []):
                self.send_header("Set-Cookie", cookie)
            if not response.headers.get("Content-Length"):
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if self.command != "HEAD":
                shutil.copyfileobj(response, self.wfile, CHUNK)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as error:
            log("ошибка прокси к главному серверу %s: %s" % (
                self.path.split("?", 1)[0], error))
            if not response_started and not self.wfile.closed:
                try:
                    self._fail("главный сервер временно недоступен", 503)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        finally:
            if response is not None:
                response.close()

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
            if self._forwards_to_primary(path):
                return self._forward_to_primary()
            if path == "/health":
                return self._send(200, b"ok", "text/plain; charset=utf-8")
            if path == "/share/lumino.png":
                return self.lumino_share_icon()
            if path == "/share" or path.startswith("/s/"):
                return self.share_page()
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

    def lumino_share_icon(self) -> None:
        icon_paths = (
            os.path.join(HERE, "assets", "icon.png"),
            os.path.join(HERE, os.pardir, "assets", "icon.png"),
        )
        icon = None
        for icon_path in icon_paths:
            try:
                with open(icon_path, "rb") as icon_file:
                    icon = icon_file.read(256 * 1024 + 1)
                break
            except OSError:
                continue
        if icon is None:
            log(
                "не удалось найти иконку Lumino для share-страницы: %s"
                % ", ".join(icon_paths)
            )
            return self._fail("иконка Lumino недоступна", 404)
        if len(icon) > 256 * 1024:
            log("иконка Lumino для share-страницы превышает допустимый размер")
            return self._fail("иконка Lumino недоступна", 404)
        return self._send(200, icon, "image/png")

    def share_page(self) -> None:
        parsed_path = urllib.parse.urlparse(self.path)
        if parsed_path.path.startswith("/s/"):
            code = parsed_path.path.removeprefix("/s/")
            if not re.fullmatch(r"[A-Za-z0-9_-]{10,16}", code):
                return self._fail("ссылка недействительна", 404)
            row = one(
                "SELECT track_json, user_id FROM track_shares WHERE code = ?",
                (code,),
            )
            if not row:
                return self._fail("ссылка недействительна или удалена", 404)
            try:
                track = json.loads(row["track_json"])
            except (ValueError, TypeError):
                return self._fail("трек недоступен", 404)
            if not isinstance(track, dict):
                return self._fail("трек недоступен", 404)
            encoded = base64.urlsafe_b64encode(
                json.dumps(track, ensure_ascii=False).encode("utf-8")
            ).decode("ascii").rstrip("=")
            kind = "track"
            params = {"data": encoded}
            if row["user_id"] is not None:
                owner_profile = _chat_user(int(row["user_id"]))
                if owner_profile:
                    params["_owner_avatar"] = _share_image_url(
                        owner_profile.get("avatar")
                    )
            app_link = "lumino://share/%s" % urllib.parse.quote(code, safe="")
        else:
            query = urllib.parse.parse_qs(parsed_path.query, max_num_fields=8)
            kind = (query.get("type") or [""])[0]
            params = {}
        allowed = {
            "track": {"data"},
            "profile": {"username"},
            "playlist": {"username", "id", "token"},
        }
        fields = allowed.get(kind)
        if fields is None:
            return self._fail("ссылка недействительна", 404)
        if parsed_path.path == "/share":
            params = {
                key: (query.get(key) or [""])[0] for key in fields if key in query
            }
        if kind == "track":
            valid = bool(re.fullmatch(r"[A-Za-z0-9_-]{1,12000}", params.get("data", "")))
            app_kind = "track"
        elif kind == "profile":
            username = params.get("username", "").strip()
            valid = bool(re.fullmatch(r"[\w.@+\- ]{3,32}", username))
            params["username"] = username
            app_kind = "profile"
        else:
            token = params.get("token", "").strip()
            if token:
                valid = bool(re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token))
                params = {"token": token}
            else:
                username = params.get("username", "").strip()
                playlist_id = params.get("id", "").strip()
                valid = (
                    bool(re.fullmatch(r"[\w.@+\- ]{3,32}", username))
                    and bool(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", playlist_id))
                )
                params = {"username": username, "id": playlist_id}
            app_kind = "playlist"
        if not valid:
            return self._fail("ссылка недействительна", 404)

        profile_data = None
        if kind == "profile":
            user = find_user(params["username"])
            profile_data = _public_user_profile(user) if user else {}
        title, author, cover, author_avatar = self._share_page_metadata(
            kind, params, profile_data
        )
        playlist_tracks = (
            self._share_page_playlist_tracks(params) if kind == "playlist" else []
        )
        if parsed_path.path == "/share":
            app_link = "lumino://%s?%s" % (
                app_kind,
                urllib.parse.urlencode(params),
            )
        safe_link = html.escape(app_link, quote=True)
        safe_title = html.escape(title)
        safe_author = html.escape(author)
        safe_cover = html.escape(cover, quote=True)
        safe_author_avatar = html.escape(author_avatar, quote=True)
        og_type = "profile" if kind == "profile" else "music.playlist" if kind == "playlist" else "music.song"
        nonce = secrets.token_urlsafe(18)
        cover_html = (
            '<img class="cover" src="%s" alt="" referrerpolicy="no-referrer">'
            % safe_cover
            if cover
            else '<div class="cover placeholder">L</div>'
        )
        author_avatar_html = (
            '<img class="author-avatar" src="%s" alt="" referrerpolicy="no-referrer">'
            % safe_author_avatar
            if author_avatar
            else '<span class="author-avatar placeholder-avatar">L</span>'
        )
        is_playlist = kind == "playlist"
        is_profile = kind == "profile"
        page_class = " playlist" if is_playlist else " profile" if is_profile else ""
        if is_playlist or is_profile:
            def track_rows(tracks: list[dict]) -> str:
                rows = []
                for track in tracks:
                    track_title = html.escape(str(track.get("title") or "Трек")[:200])
                    raw_artists = track.get("artists")
                    artists = (
                        ", ".join(
                            html.escape(str(value)[:120])
                            for value in raw_artists[:10]
                            if str(value).strip()
                        )
                        if isinstance(raw_artists, list)
                        else ""
                    )
                    track_cover = _share_image_url(track.get("cover"))
                    track_cover_html = (
                        '<img class="track-cover" src="%s" alt="" referrerpolicy="no-referrer">'
                        % html.escape(track_cover, quote=True)
                        if track_cover
                        else '<span class="track-cover track-placeholder">♪</span>'
                    )
                    try:
                        duration = max(0, int(track.get("duration") or 0))
                    except (ValueError, TypeError, OverflowError):
                        duration = 0
                    duration_html = (
                        '<span class="track-duration">%d:%02d</span>'
                        % (duration // 60, duration % 60)
                        if duration
                        else ""
                    )
                    rows.append(
                        '<button class="track-row" type="button">'
                        + track_cover_html
                        + '<span class="track-info"><span class="track-title">'
                        + track_title
                        + '</span><span class="track-artist">'
                        + (artists or "Неизвестный исполнитель")
                        + "</span></span>"
                        + duration_html
                        + "</button>"
                    )
                return "".join(rows)

            modal_html = (
                '<dialog id="download-modal" class="download-modal">'
                "<h2>Слушайте в приложении Lumino</h2>"
                "<p>Чтобы включать треки и слушать музыку, "
                "скачайте приложение.</p>"
                '<a class="open" href="https://theLuni.ru/lumino" '
                'target="_blank" rel="noopener">Скачать приложение</a>'
                '<button class="modal-close" type="button">Закрыть</button>'
                "</dialog>"
            )
            script = (
                "document.querySelectorAll('.track-row').forEach(function(row){"
                "row.addEventListener('click',function(){"
                "document.getElementById('download-modal').showModal();});});"
                "document.querySelector('.modal-close').addEventListener("
                "'click',function(){document.getElementById('download-modal').close();});"
            )
            if is_playlist:
                share_content = (
                    '<header class="playlist-header">'
                    + cover_html
                    + '<div class="playlist-info"><p class="eyebrow">ПЛЕЙЛИСТ</p>'
                    + '<h1 class="title playlist-title">'
                    + safe_title
                    + '</h1><p class="author">'
                    + author_avatar_html
                    + safe_author
                    + " · "
                    + str(len(playlist_tracks))
                    + (" трек" if len(playlist_tracks) == 1 else " треков")
                    + "</p></div></header>"
                    + '<section class="track-list"><h2>Треки</h2>'
                    + (
                        track_rows(playlist_tracks)
                        or (
                            '<p class="empty-state">В этом плейлисте '
                            "пока нет треков.</p>"
                        )
                    )
                    + "</section>"
                )
                action_html = (
                    '<a class="open" href="https://theLuni.ru/lumino" '
                    'target="_blank" rel="noopener">Скачать приложение</a>'
                )
                hint_html = (
                    '<p class="hint">Нажмите на трек, чтобы узнать, '
                    "как слушать "
                    "плейлист в приложении Lumino.</p>"
                )
            else:
                profile_data = profile_data or {}
                username = str(profile_data.get("username") or params["username"])
                safe_username = html.escape(username)
                public_playlists = profile_data.get("public_playlists", [])
                liked_tracks = profile_data.get("liked_tracks", [])
                playlist_cards = []
                for playlist in (
                    public_playlists if isinstance(public_playlists, list) else []
                ):
                    if not isinstance(playlist, dict):
                        continue
                    playlist_name = html.escape(
                        str(playlist.get("name") or "Плейлист")[:200]
                    )
                    playlist_id = str(playlist.get("id") or "")
                    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", playlist_id):
                        continue
                    playlist_url = "/share?" + urllib.parse.urlencode(
                        {"type": "playlist", "username": username, "id": playlist_id}
                    )
                    playlist_cover = _share_image_url(playlist.get("cover"))
                    playlist_cover_html = (
                        '<img class="playlist-cover" src="%s" alt="" '
                        'referrerpolicy="no-referrer">'
                        % html.escape(playlist_cover, quote=True)
                        if playlist_cover
                        else '<span class="playlist-cover playlist-placeholder">♪</span>'
                    )
                    tracks = playlist.get("tracks", [])
                    track_count = len(tracks) if isinstance(tracks, list) else 0
                    playlist_cards.append(
                        '<a class="playlist-card" href="%s">'
                        % html.escape(playlist_url, quote=True)
                        + playlist_cover_html
                        + '<span class="playlist-card-info"><span class="playlist-card-title">'
                        + playlist_name
                        + '</span><span class="playlist-card-meta">'
                        + str(track_count)
                        + (" трек" if track_count == 1 else " треков")
                        + "</span></span></a>"
                    )
                playlist_section = (
                    '<section class="profile-section"><h2>Публичные плейлисты</h2>'
                    + (
                        '<div class="playlist-grid">' + "".join(playlist_cards) + "</div>"
                        if playlist_cards
                        else (
                            '<p class="empty-state">Публичных плейлистов '
                            "пока нет.</p>"
                        )
                    )
                    + "</section>"
                )
                liked_tracks = (
                    [track for track in liked_tracks if isinstance(track, dict)]
                    if isinstance(liked_tracks, list)
                    else []
                )
                liked_section = (
                    '<section class="profile-section"><h2>Любимые треки</h2>'
                    + (
                        '<div class="track-list">'
                        + track_rows(liked_tracks)
                        + "</div>"
                        if liked_tracks
                        else (
                            '<p class="empty-state">Пользователь пока не '
                            "добавил любимые треки.</p>"
                        )
                    )
                    + "</section>"
                )
                share_content = (
                    '<header class="profile-header">'
                    + author_avatar_html
                    + '<div class="profile-info"><p class="eyebrow">ПРОФИЛЬ LUMINO</p>'
                    + '<h1 class="title profile-title">'
                    + safe_title
                    + '</h1><p class="profile-username">@'
                    + safe_username
                    + "</p></div></header>"
                    + playlist_section
                    + liked_section
                )
                action_html = (
                    '<a class="open" href="%s">Открыть профиль в Lumino</a>'
                    % safe_link
                )
                hint_html = (
                    '<p class="hint">Откройте профиль в приложении, '
                    "чтобы слушать "
                    "музыку и управлять плейлистами.</p>"
                )
        else:
            share_content = (
                cover_html
                + '<h1 class="title">'
                + safe_title
                + '</h1><p class="author">'
                + author_avatar_html
                + safe_author
                + "</p>"
            )
            action_html = (
                '<a id="open-app" class="open" href="%s">Открыть в Lumino</a>'
                % safe_link
            )
            hint_html = (
                '<p class="hint">Если приложение не открылось, установите Lumino '
                "и нажмите кнопку ещё раз.</p>"
            )
            modal_html = (
                '<div id="open-help" class="fallback" hidden>'
                "Lumino не открылся? На Windows установите приложение через Lumino "
                "Installer, чтобы зарегистрировать ссылку. Затем вернитесь сюда и "
                "нажмите «Открыть в Lumino» ещё раз.</div>"
            )
            script = (
                "document.getElementById('open-app').addEventListener("
                "'click',function(){setTimeout(function(){if(document.visibilityState"
                "==='visible'){document.getElementById('open-help').hidden=false;}},"
                "1400);});"
            )
        body = (
            "<!doctype html><html lang=\"ru\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<meta name=\"theme-color\" content=\"#111111\">"
            "<meta property=\"og:type\" content=\"%s\">"
            "<meta property=\"og:title\" content=\"%s\">"
            "<meta property=\"og:description\" content=\"%s · Lumino\">"
            "<meta name=\"twitter:card\" content=\"summary_large_image\">"
            "<meta name=\"twitter:title\" content=\"%s\">"
            "<meta name=\"twitter:description\" content=\"%s · Lumino\">"
            "%s<title>%s · Lumino</title><style>"
            "*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;"
            "place-items:center;padding:24px;background:#0a0a0b;color:#f7f7f7;"
            "font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;"
            "background-image:radial-gradient(900px 560px at 8%% -12%%,#ffffff18,transparent 65%%),"
            "radial-gradient(780px 560px at 95%% 4%%,#ffffff12,transparent 62%%),"
            "radial-gradient(900px 650px at 50%% 120%%,#ffffff10,transparent 65%%)}"
            ".card{width:min(100%%,420px);padding:24px;border:1px solid #ffffff20;"
            "border-radius:24px;background:linear-gradient(145deg,#1a1a1bea,#111112f5);"
            "box-shadow:0 24px 80px #000a;backdrop-filter:blur(16px)}"
            ".brand{display:flex;align-items:center;gap:9px;margin-bottom:22px;"
            "font-size:14px;font-weight:700;letter-spacing:.08em;color:#f2f2f2}"
            ".logo-avatar{display:block;width:30px;height:30px;border-radius:9px;"
            "object-fit:cover;background:#000}"
            ".cover{display:block;width:min(100%%,300px);aspect-ratio:1;"
            "margin:0 auto 22px;border-radius:18px;object-fit:cover;"
            "background:#252525}"
            ".placeholder{display:grid;place-items:center;font-size:64px;font-weight:800;"
            "color:#f2f2f2}.title{margin:0;text-align:center;font-size:25px;"
            "line-height:1.2;letter-spacing:-.03em}.author{display:flex;align-items:center;"
            "justify-content:center;gap:9px;margin:12px 0 24px;color:#c9c9c9}"
            ".author-avatar{width:30px;height:30px;border-radius:50%%;object-fit:cover;"
            "background:#353535}.placeholder-avatar{display:grid;place-items:center;"
            "font-weight:700;color:#f2f2f2}.open{display:block;width:100%%;padding:14px;"
            "border:1px solid #f2f2f2;border-radius:14px;background:#f2f2f2;color:#111;"
            "text-align:center;"
            "font:inherit;font-weight:700;text-decoration:none;cursor:pointer}"
            ".open:hover{background:#d8d8d8}.hint{margin:15px 0 0;text-align:center;"
            "font-size:13px;color:#a5a5a5}.hint a{color:#f2f2f2}"
            ".fallback{margin-top:14px;padding:12px;border:1px solid #343434;"
            "border-radius:12px;background:#202020;color:#c2c2c2;font-size:13px}"
            ".fallback[hidden]{display:none}"
            ".card.playlist{width:min(100%%,960px)}.playlist-header{display:flex;"
            "align-items:end;gap:24px;margin:10px 0 28px}.playlist-header .cover{"
            "flex:0 0 200px;width:200px;margin:0}.playlist-info{min-width:0;flex:1}"
            ".eyebrow{margin:0 0 8px;color:#a5a5a5;font-size:11px;"
            "font-weight:700;letter-spacing:.12em}.playlist-title{text-align:left;"
            "font-size:clamp(26px,5vw,40px);overflow-wrap:anywhere}.playlist-info .author{"
            "justify-content:flex-start;margin:12px 0 0}.track-list h2{margin:0 0 8px;"
            "font-size:19px}.track-row{display:flex;align-items:center;gap:14px;width:100%%;"
            "padding:6px 10px;border:0;border-radius:10px;background:transparent;"
            "color:#f7f7f7;text-align:left;font:inherit;cursor:pointer}.track-row:hover{"
            "background:#ffffff12}.track-cover{display:block;flex:0 0 48px;width:48px;"
            "height:48px;border-radius:7px;object-fit:cover;background:#252525}"
            ".track-placeholder{display:grid;place-items:center;font-size:22px}"
            ".track-info{display:flex;min-width:0;flex:1;flex-direction:column;gap:2px}"
            ".track-title,.track-artist{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"
            ".track-title{font-size:15px;font-weight:600}.track-artist,.track-duration{"
            "color:#a5a5a5;font-size:13px}.download-modal{width:min(100%% - 32px,440px);"
            "padding:24px;border:1px solid #383838;border-radius:18px;background:#171717;"
            "color:#f7f7f7}.download-modal::backdrop{background:#000b}.download-modal h2{"
            "margin:0 0 10px;font-size:21px}.download-modal p{color:#c9c9c9}"
            ".modal-close{display:block;width:100%%;margin-top:10px;padding:11px;border:0;"
            "border-radius:12px;background:#303030;color:#fff;font:inherit;cursor:pointer}"
            ".card.profile{width:min(100%%,960px)}.profile-header{display:flex;"
            "align-items:center;gap:20px;margin:4px 0 30px}.profile-header .author-avatar,"
            ".profile-header .placeholder-avatar{width:88px;height:88px;flex:0 0 88px;"
            "border-radius:50%%;object-fit:cover;background:#353535}.profile-info{min-width:0}"
            ".profile-title{text-align:left;font-size:clamp(28px,5vw,42px);"
            "overflow-wrap:anywhere}.profile-username{margin:6px 0 0;color:#a5a5a5}"
            ".profile-section{margin-top:28px}.profile-section h2,.track-list h2{"
            "margin:0 0 10px;font-size:19px;letter-spacing:-.02em}"
            ".playlist-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));"
            "gap:10px}.playlist-card{display:flex;align-items:center;gap:12px;min-width:0;"
            "padding:10px;border:1px solid #ffffff12;border-radius:14px;background:#ffffff08;"
            "color:#f7f7f7;text-decoration:none;transition:background .18s ease,border-color .18s ease}"
            ".playlist-card:hover{background:#ffffff14;border-color:#ffffff28}"
            ".playlist-cover{display:grid;place-items:center;width:56px;height:56px;flex:0 0 56px;"
            "border-radius:9px;object-fit:cover;background:#252525;font-size:24px}"
            ".playlist-card-info{display:flex;min-width:0;flex-direction:column;gap:3px}"
            ".playlist-card-title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}"
            ".playlist-card-meta,.empty-state{color:#a5a5a5;font-size:13px}"
            ".empty-state{margin:8px 0}.track-row:focus-visible,.playlist-card:focus-visible,"
            ".open:focus-visible,.modal-close:focus-visible{outline:2px solid #fff;outline-offset:3px}"
            "@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;"
            "transition-duration:.01ms!important}}"
            "@media(max-width:600px){body{padding:12px}.card{padding:18px;border-radius:20px}"
            ".playlist-header{align-items:center;gap:14px}"
            ".playlist-header .cover{flex-basis:112px;width:112px}.playlist-header .author{"
            "font-size:12px}.profile-header{gap:14px}.profile-header .author-avatar,"
            ".profile-header .placeholder-avatar{width:64px;height:64px;flex-basis:64px}"
            ".track-row{gap:10px;padding:6px 4px}.playlist-grid{grid-template-columns:1fr}}"
            "</style></head><body><main class=\"card%s\"><div class=\"brand\">"
            "<img class=\"logo-avatar\" src=\"/share/lumino.png\" alt=\"Lumino\">"
            "<span>LUMINO</span></div>%s%s%s%s</main>"
            "<script nonce=\"%s\">%s</script></body></html>"
            % (
                og_type,
                safe_title,
                safe_author,
                safe_title,
                safe_author,
                '<meta property="og:image" content="%s">' % safe_cover
                if cover
                else "",
                safe_title,
                page_class,
                share_content,
                action_html,
                hint_html,
                modal_html,
                nonce,
                script,
            )
        )
        return self._send(
            200,
            body.encode("utf-8"),
            "text/html; charset=utf-8",
            extra=(
                (
                    "Content-Security-Policy",
                    "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' https: data:; "
                    "script-src 'nonce-%s'" % nonce,
                ),
            ),
        )

    def _share_page_playlist_tracks(self, params: dict) -> list[dict]:
        if "token" in params:
            token_hash = hashlib.sha256(params["token"].encode("ascii")).hexdigest()
            share = one(
                "SELECT user_id, playlist_id FROM private_playlist_shares "
                "WHERE token_hash = ?",
                (token_hash,),
            )
            if not share:
                return []
            row = one(
                "SELECT data FROM user_state WHERE user_id = ?",
                (share["user_id"],),
            )
            try:
                state = json.loads(row["data"]) if row else {}
            except (ValueError, TypeError):
                return []
            playlist = _playlist_share_data(state, str(share["playlist_id"]))
        else:
            user = find_user(params.get("username", ""))
            if not user:
                return []
            profile = _public_user_profile(user)
            playlist = next(
                (
                    item
                    for item in profile.get("public_playlists", [])
                    if str(item.get("id") or "") == params.get("id")
                ),
                None,
            )
        tracks = playlist.get("tracks", []) if playlist else []
        return [track for track in tracks if isinstance(track, dict)]

    def _share_page_metadata(
        self, kind: str, params: dict, profile_data: dict | None = None
    ) -> tuple[str, str, str, str]:
        if kind == "track":
            try:
                raw = params["data"]
                decoded = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
                track = json.loads(decoded.decode("utf-8"))
            except (KeyError, ValueError, UnicodeDecodeError):
                return "Трек", "Lumino", "", ""
            if not isinstance(track, dict):
                return "Трек", "Lumino", "", ""
            title = str(track.get("title") or "Трек")[:200]
            artists = track.get("artists")
            author = ", ".join(str(value) for value in artists[:5]) if isinstance(artists, list) else ""
            return (
                title,
                author or "Lumino",
                _share_image_url(track.get("cover")),
                _share_image_url(params.get("_owner_avatar")),
            )

        if kind == "profile":
            if profile_data is None:
                user = find_user(params["username"])
                profile_data = _public_user_profile(user) if user else {}
            if not profile_data:
                return "Профиль не найден", "Lumino", "", ""
            avatar = _share_image_url(profile_data.get("avatar"))
            return (
                str(profile_data.get("display_name") or profile_data.get("username") or "Профиль")[:200],
                "Профиль Lumino",
                avatar,
                avatar,
            )

        if "token" in params:
            token_hash = hashlib.sha256(params["token"].encode("ascii")).hexdigest()
            share = one(
                "SELECT user_id, playlist_id FROM private_playlist_shares WHERE token_hash = ?",
                (token_hash,),
            )
            if not share:
                return "Плейлист недоступен", "Lumino", "", ""
            row = one("SELECT data FROM user_state WHERE user_id = ?", (share["user_id"],))
            try:
                state = json.loads(row["data"]) if row else {}
            except (ValueError, TypeError):
                state = {}
            playlist = _playlist_share_data(state, str(share["playlist_id"]))
            owner = one(
                "SELECT username, display_name FROM users WHERE id = ?",
                (share["user_id"],),
            )
            owner_profile = _public_user_profile(owner) if owner else {}
        else:
            owner = find_user(params["username"])
            playlist = None
            owner_profile = {}
            if owner:
                profile = _public_user_profile(owner)
                owner_profile = profile
                playlists = profile.get("public_playlists", [])
                playlist = next(
                    (
                        item
                        for item in playlists
                        if str(item.get("id") or "") == params["id"]
                    ),
                    None,
                )
        if not playlist:
            return "Плейлист не найден", "Lumino", "", ""
        author = (
            str(owner.get("display_name") or owner.get("username") or "Lumino")
            if owner
            else "Lumino"
        )
        return (
            str(playlist.get("name") or "Плейлист")[:200],
            author,
            _share_image_url(playlist.get("cover")),
            _share_image_url(owner_profile.get("avatar")),
        )

    def do_POST(self):
        path = self._route()
        try:
            if self._forwards_to_primary(path):
                return self._forward_to_primary()
            if (path.startswith("/api/auth/") or path.startswith("/api/chat/")
                    or path.startswith("/api/share/") or path.startswith("/api/ai/")):
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
            if path == "/_internal/replica/db" and PRIMARY_URL:
                return _receive_database_replica(self)
            if self._forwards_to_primary(path):
                return self._forward_to_primary()
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

    def ai_post(self, path: str, body: dict) -> None:
        user = self._user()
        if not user:
            return self._fail("нужно войти", 401)
        user_id = user["id"]

        if path == "/api/ai/events":
            events = body.get("events")
            if not isinstance(events, list) or len(events) > 32:
                return self._fail("ожидается до 32 событий", 400)
            allowed = {"start", "progress", "complete", "skip", "seek_forward",
                       "seek_back", "like", "unlike", "dislike", "undislike",
                       "artist_open"}
            now = iso()
            rows = []
            for event in events:
                if (not isinstance(event, dict)
                        or not isinstance(event.get("type"), str)
                        or event["type"] not in allowed):
                    return self._fail("некорректное событие модели", 400)
                track = event.get("track") if isinstance(event.get("track"), dict) else {}
                artists_raw = track.get("artists", [])
                artists = []
                if isinstance(artists_raw, list):
                    artists = [str(name).strip()[:100] for name in artists_raw[:8]
                               if str(name).strip()]
                progress = event.get("progress", 0)
                try:
                    progress = max(0.0, min(1.0, float(progress)))
                except (TypeError, ValueError):
                    progress = 0.0
                clean = {
                    "type": event["type"],
                    "artist": str(event.get("artist") or "").strip()[:100],
                    "progress": progress,
                    "track": {
                        "id": str(track.get("id") or "")[:128],
                        "title": str(track.get("title") or "")[:200],
                        "artists": artists,
                    },
                }
                rows.append((user_id, json.dumps(clean, ensure_ascii=False,
                                                  separators=(",", ":")), now))
            if rows:
                with _db_lock, closing(db()) as conn:
                    conn.executemany(
                        "INSERT INTO ai_events (user_id, event_json, created_at) VALUES (?,?,?)",
                        rows,
                    )
                    conn.execute(
                        "DELETE FROM ai_events WHERE user_id = ? AND id NOT IN "
                        "(SELECT id FROM ai_events WHERE user_id = ? ORDER BY id DESC LIMIT 5000)",
                        (user_id, user_id),
                    )
                    conn.commit()
                _schedule_database_replication()
                self._maybe_retrain_ai_model(user_id)
            return self._json({"ok": True, "accepted": len(rows)})

        if path == "/api/ai/wave":
            exclude_ids = body.get("exclude_ids", [])
            if not isinstance(exclude_ids, list) or len(exclude_ids) > 500:
                return self._fail("некорректный список исключений", 400)
            model_row = one(
                "SELECT model_json FROM ai_models WHERE user_id = ?", (user_id,)
            )
            try:
                model = json.loads(model_row["model_json"]) if model_row else {}
            except (ValueError, TypeError):
                model = {}
            if not isinstance(model, dict) or not model.get("trained"):
                model = self._train_ai_model(user_id)
            tracks = generate_ai_wave(user_id, model, {
                str(track_id)[:128] for track_id in exclude_ids
            })
            return self._json({"tracks": tracks})

        if path == "/api/ai/train":
            model = self._train_ai_model(user_id)
            return self._json({"ok": True, "model": model})

        if path == "/api/ai/recommend":
            candidates = body.get("candidates")
            if not isinstance(candidates, list) or len(candidates) > 250:
                return self._fail("ожидается до 250 треков-кандидатов", 400)
            row = one("SELECT model_json FROM ai_models WHERE user_id = ?", (user_id,))
            try:
                model = json.loads(row["model_json"]) if row else self._train_ai_model(user_id)
            except (ValueError, TypeError):
                return self._fail("модель повреждена", 500)
            artist_weights = {item["key"]: float(item["score"])
                              for item in model.get("artists", [])}
            track_weights = dict(model.get("track_scores", {}))
            skip_counts = {key: int(value)
                           for key, value in model.get("skip_counts", {}).items()}
            seen = set(model.get("seen_track_ids", []))
            state_row = one("SELECT data FROM user_state WHERE user_id = ?", (user_id,))
            try:
                user_state = json.loads(state_row["data"]) if state_row else {}
            except (ValueError, TypeError):
                user_state = {}
            if not isinstance(user_state, dict):
                user_state = {}
            liked_keys = {norm(key) for key in user_state.get("liked", [])
                          if isinstance(key, str)}
            disliked_keys = {norm(key) for key in user_state.get("disliked", [])
                             if isinstance(key, str)}
            active_like_artists = set()
            active_dislike_artists = set()
            saved_tracks = user_state.get("savedTracks", [])
            if isinstance(saved_tracks, list):
                for track in saved_tracks:
                    if not isinstance(track, dict):
                        continue
                    names = track.get("artists", [])
                    primary = str(track.get("primary") or (
                        names[0] if isinstance(names, list) and names else ""))
                    title = str(track.get("title") or "")
                    if norm("%s - %s" % (primary, title)) in liked_keys:
                        active_like_artists.update(norm(name) for name in names
                                                   if isinstance(name, str))
                        if primary:
                            active_like_artists.add(norm(primary))
                    if norm("%s - %s" % (primary, title)) in disliked_keys:
                        active_dislike_artists.update(norm(name) for name in names
                                                      if isinstance(name, str))
                        if primary:
                            active_dislike_artists.add(norm(primary))
            try:
                last_event_id = int(model.get("last_event_id") or 0)
            except (TypeError, ValueError):
                last_event_id = 0
            fresh_rows = query(
                "SELECT event_json FROM ai_events WHERE user_id = ? AND id > ? ORDER BY id",
                (user_id, last_event_id),
            )
            for fresh_row in fresh_rows:
                try:
                    event = json.loads(fresh_row["event_json"])
                except (ValueError, TypeError):
                    continue
                track = event.get("track") or {}
                track_id = str(track.get("id") or "")
                kind = event.get("type")
                names = track.get("artists") or []
                primary = str(names[0] if names else "")
                track_key = norm("%s - %s" % (primary, track.get("title") or ""))
                if kind == "dislike" and track_key:
                    disliked_keys.add(track_key)
                elif kind == "undislike" and track_key:
                    disliked_keys.discard(track_key)
                if track_id and kind == "skip":
                    skip_counts[track_id] = skip_counts.get(track_id, 0) + 1
                if track_id and kind in {
                    "like", "unlike", "dislike", "undislike", "complete", "progress"
                }:
                    weights = {"like": 10.0, "unlike": -15.0,
                               "dislike": -25.0, "undislike": 20.0,
                               "complete": 3.0, "progress": 1.0}
                    track_weights[track_id] = track_weights.get(track_id, 0.0) + weights[kind]
                    delta = weights[kind]
                    for index, name in enumerate(names):
                        key = norm(name)
                        if key:
                            artist_weights[key] = artist_weights.get(key, 0.0) + delta * (
                                1.0 if index == 0 else 0.45)
            scored = []
            for index, candidate in enumerate(candidates):
                if not isinstance(candidate, dict):
                    continue
                track_id = str(candidate.get("id") or "")[:128]
                names = candidate.get("artists", [])
                if not track_id or not isinstance(names, list):
                    continue
                primary = str(candidate.get("primary") or (
                    names[0] if names else ""))
                title = str(candidate.get("title") or "")
                if norm("%s - %s" % (primary, title)) in liked_keys:
                    continue
                if norm("%s - %s" % (primary, title)) in disliked_keys:
                    continue
                if skip_counts.get(track_id, 0) >= AI_SKIP_DISMISS_THRESHOLD:
                    continue
                weights = [artist_weights.get(norm(name), 0.0)
                           for name in names[:8] if str(name).strip()]
                artist_score = max(weights, default=0.0)
                collab_score = sum(sorted(weights, reverse=True)[1:]) * 0.12
                score = artist_score + collab_score
                score += float(track_weights.get(track_id, 0.0))
                score += max((12.0 for name in names
                              if norm(name) in active_like_artists), default=0.0)
                score -= max((18.0 for name in names
                              if norm(name) in active_dislike_artists), default=0.0)
                score -= min(skip_counts.get(track_id, 0), 2) * 0.08
                if track_id in seen:
                    score -= 0.15
                discovery = candidate.get("source") == "discovery"
                scored.append((score, index, track_id, norm(primary), discovery))
            limit = body.get("limit", 0)
            try:
                limit = max(0, min(25, int(limit)))
            except (TypeError, ValueError):
                limit = 0
            if limit:
                familiar = sorted(
                    (item for item in scored if not item[4]),
                    key=lambda item: (-item[0], item[1]),
                )
                discovery = sorted(
                    (item for item in scored if item[4]),
                    key=lambda item: (-item[0], item[1]),
                )
                selected = []
                used_artists = set()
                familiar_index = 0
                discovery_index = 0
                for position in range(limit):
                    prefer_discovery = position in {2, 5}
                    sources = (discovery, familiar) if prefer_discovery else (familiar, discovery)
                    for source_index, source in enumerate(sources):
                        cursor = discovery_index if source is discovery else familiar_index
                        while cursor < len(source) and source[cursor][3] in used_artists:
                            cursor += 1
                        if cursor >= len(source):
                            continue
                        item = source[cursor]
                        used_artists.add(item[3])
                        selected.append(item)
                        if source is discovery:
                            discovery_index = cursor + 1
                        else:
                            familiar_index = cursor + 1
                        break
                scored = selected
            else:
                scored.sort(key=lambda item: (-item[0], item[1]))
            return self._json({"ids": [item[2] for item in scored],
                               "trained_at": model.get("trained_at", "")})

        if path == "/api/ai/clear":
            with _db_lock, closing(db()) as conn:
                conn.execute("DELETE FROM ai_events WHERE user_id = ?", (user_id,))
                conn.execute("DELETE FROM ai_models WHERE user_id = ?", (user_id,))
                conn.commit()
            _schedule_database_replication()
            return self._json({"ok": True})
        return self._fail("нет такого метода: %s" % path, 404)

    def _train_ai_model(self, user_id: int) -> dict:
        rows = query(
            "SELECT id, event_json FROM ai_events WHERE user_id = ? ORDER BY id",
            (user_id,),
        )
        previous_row = one(
            "SELECT model_json FROM ai_models WHERE user_id = ?", (user_id,)
        )
        try:
            previous_model = json.loads(previous_row["model_json"]) if previous_row else {}
        except (ValueError, TypeError):
            previous_model = {}
        if not isinstance(previous_model, dict):
            previous_model = {}
        try:
            previous_event_id = int(previous_model.get("last_event_id") or 0)
            skip_counts = {
                str(key): max(0, int(value))
                for key, value in previous_model.get("skip_counts", {}).items()
            }
        except (AttributeError, TypeError, ValueError):
            previous_event_id = 0
            skip_counts = {}
        state_row = one("SELECT data FROM user_state WHERE user_id = ?", (user_id,))
        try:
            user_state = json.loads(state_row["data"]) if state_row else {}
        except (ValueError, TypeError):
            user_state = {}
        if not isinstance(user_state, dict):
            user_state = {}
        liked_order = user_state.get("liked", [])
        saved_tracks = user_state.get("savedTracks", [])
        tracks_by_key = {}
        if isinstance(saved_tracks, list):
            for track in saved_tracks:
                if not isinstance(track, dict):
                    continue
                artists = track.get("artists", [])
                primary = str(track.get("primary") or (
                    artists[0] if isinstance(artists, list) and artists else ""))
                title = str(track.get("title") or "")
                key = norm("%s - %s" % (primary, title))
                if key:
                    tracks_by_key[key] = track

        active_likes = []
        if isinstance(liked_order, list):
            for liked_key in reversed(liked_order):
                track = tracks_by_key.get(norm(liked_key))
                if track:
                    active_likes.append(track)
                if len(active_likes) >= 50:
                    break
        active_dislikes = []
        disliked_order = user_state.get("disliked", [])
        if isinstance(disliked_order, list):
            for disliked_key in reversed(disliked_order):
                track = tracks_by_key.get(norm(disliked_key))
                if track:
                    active_dislikes.append(track)
                if len(active_dislikes) >= 50:
                    break

        events = []
        for row in rows:
            try:
                event = json.loads(row["event_json"])
            except (ValueError, TypeError):
                continue
            if isinstance(event, dict):
                events.append((int(row["id"]), event))
        events.extend((0, {"type": "active_like", "track": track})
                      for track in active_likes)
        events.extend((0, {"type": "active_dislike", "track": track})
                  for track in active_dislikes)

        artists = {}
        track_scores = {}
        seen_tracks = []
        for event_id, event in events:
            kind = event.get("type")
            try:
                progress = max(0.0, min(1.0, float(event.get("progress") or 0)))
            except (TypeError, ValueError):
                progress = 0.0
            score = {
                "start": 0.05,
                "progress": 0.8 + progress,
                "complete": 3.0,
                "skip": 0.0,
                "seek_forward": -0.1,
                "seek_back": 0.1,
                "like": 10.0,
                "active_like": 12.0,
                "dislike": -25.0,
                "active_dislike": -18.0,
                "undislike": 20.0,
                "unlike": -15.0,
                "artist_open": 1.8,
            }.get(kind, 0.0)
            track = event.get("track") or {}
            track_id = str(track.get("id") or "")
            if track_id:
                if kind == "start":
                    seen_tracks.append(track_id)
                if kind == "skip" and event_id > previous_event_id:
                    skip_counts[track_id] = skip_counts.get(track_id, 0) + 1
                if kind in {"progress", "complete", "skip", "like", "active_like",
                            "unlike", "dislike", "active_dislike", "undislike"}:
                    track_scores[track_id] = track_scores.get(track_id, 0.0) + score
            names = track.get("artists") or []
            if kind == "artist_open" and event.get("artist"):
                names = [event["artist"]]
            for index, name in enumerate(names):
                key = norm(name)
                if not key:
                    continue
                item = artists.setdefault(
                    key, {"key": key, "name": str(name), "score": 0.0})
                item["score"] += score * (1.0 if index == 0 else 0.45)

        trained_at = iso()
        trained_at_epoch = int(time.time())
        last_event_id = max(previous_event_id, int(rows[-1]["id"]) if rows else 0)
        ranked_artists = sorted(
            artists.values(), key=lambda item: item["score"], reverse=True)
        model = {
            "trained": bool(events),
            "trained_at": trained_at,
            "trained_at_epoch": trained_at_epoch,
            "last_event_id": last_event_id,
            "event_count": len(rows),
            "liked_seed_count": len(active_likes),
            "disliked_seed_count": len(active_dislikes),
            "liked_seed_track_ids": [str(track.get("id") or "")
                                     for track in active_likes if track.get("id")],
            "disliked_seed_track_ids": [str(track.get("id") or "")
                                        for track in active_dislikes if track.get("id")],
            "artists": ranked_artists[:50],
            "top_artists": [item for item in ranked_artists if item["score"] > 0][:20],
            "track_scores": track_scores,
            "skip_counts": skip_counts,
            "seen_track_ids": list(dict.fromkeys(seen_tracks))[-500:],
        }
        execute(
            "INSERT INTO ai_models (user_id, model_json, trained_at) VALUES (?,?,?) "
            "ON CONFLICT(user_id) DO UPDATE SET model_json = excluded.model_json, "
            "trained_at = excluded.trained_at",
            (user_id, json.dumps(model, ensure_ascii=False, separators=(",", ":")), trained_at),
        )
        return model

    def _maybe_retrain_ai_model(self, user_id: int) -> bool:
        row = one("SELECT model_json FROM ai_models WHERE user_id = ?", (user_id,))
        model = {}
        if row:
            try:
                model = json.loads(row["model_json"])
            except (ValueError, TypeError):
                model = {}
        try:
            last_event_id = int(model.get("last_event_id") or 0)
            trained_at = int(model.get("trained_at_epoch") or 0)
        except (TypeError, ValueError):
            last_event_id = 0
            trained_at = 0
        pending = one(
            "SELECT COUNT(*) AS count FROM ai_events WHERE user_id = ? AND id > ?",
            (user_id, last_event_id),
        )
        if int(pending["count"] if pending else 0) < AI_RETRAIN_MIN_NEW_EVENTS:
            return False
        if trained_at and time.time() - trained_at < AI_RETRAIN_INTERVAL_SECONDS:
            return False
        self._train_ai_model(user_id)
        return True

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
                          msg.text AS last_text, msg.image_data AS last_image,
                          msg.track_json AS last_track, msg.created_at AS last_at,
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
                        """SELECT user_id, typing_at FROM chat_members
                           WHERE chat_id = ? AND user_id != ? AND active = 1 LIMIT 1""",
                        (row["id"], user["id"]),
                    )
                    item["peer"] = _chat_user(member["user_id"]) if member else None
                    if item["peer"]:
                        item["name"] = item["peer"]["display_name"] or item["peer"]["username"]
                        typing_at = member["typing_at"] or ""
                        try:
                            item["peer"]["is_typing"] = (
                                bool(typing_at)
                                and (now() - dt.datetime.fromisoformat(typing_at)).total_seconds() < 8
                            )
                        except ValueError:
                            item["peer"]["is_typing"] = False
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
            try:
                around_id = max(0, int(self._param("around_id", "0") or 0))
            except ValueError:
                return self._fail("некорректный номер сообщения", 400)
            term = self._param("q").strip()
            if len(term) > 200:
                return self._fail("поисковый запрос слишком длинный", 400)
            day = self._param("day").strip()
            if day:
                try:
                    parsed_day = dt.date.fromisoformat(day)
                except ValueError:
                    return self._fail("некорректная дата", 400)
                if parsed_day.isoformat() != day:
                    return self._fail("некорректная дата", 400)
                if parsed_day.year < 2026:
                    return self._fail("дата вне периода существования плеера", 400)
            if around_id:
                anchor = one(
                    "SELECT id FROM chat_messages WHERE id = ? AND chat_id = ?",
                    (around_id, chat_id),
                )
                if not anchor:
                    return self._fail("сообщение не найдено", 404)
                rows = query(
                    """SELECT id, sender_id, text, image_data, track_json, created_at
                       FROM chat_messages
                       WHERE chat_id = ?
                       ORDER BY ABS(id - ?) LIMIT 101""",
                    (chat_id, around_id),
                )
                rows.sort(key=lambda row: row["id"])
            elif day:
                rows = query(
                    """SELECT id, sender_id, text, image_data, track_json, created_at
                       FROM chat_messages
                       WHERE chat_id = ? AND substr(created_at, 1, 10) = ?
                       ORDER BY id DESC""",
                    (chat_id, day),
                )
                rows.reverse()
            elif term:
                candidates = query(
                    """SELECT id, text, track_json FROM chat_messages
                       WHERE chat_id = ? AND id > ?""",
                    (chat_id, after),
                )
                needle = term.casefold()
                matching_ids = [
                    row["id"] for row in candidates
                    if needle in str(row["text"] or "").casefold()
                    or needle in str(row["track_json"] or "").casefold()
                ]
                rows = []
                for offset in range(0, len(matching_ids), 500):
                    batch = matching_ids[offset:offset + 500]
                    placeholders = ",".join("?" for _ in batch)
                    rows.extend(query(
                        """SELECT id, sender_id, text, image_data, track_json, created_at
                           FROM chat_messages
                           WHERE chat_id = ? AND id IN (%s)""" % placeholders,
                        (chat_id, *batch),
                    ))
                rows.sort(key=lambda row: row["id"], reverse=True)
            else:
                rows = query(
                    """SELECT id, sender_id, text, image_data, track_json, created_at
                       FROM chat_messages WHERE chat_id = ? AND id > ?
                       ORDER BY id DESC LIMIT 100""",
                    (chat_id, after),
                )
            if rows and not term:
                last_incoming_id = max(
                    row["id"] for row in rows if row["sender_id"] != user["id"]
                ) if any(row["sender_id"] != user["id"] for row in rows) else 0
                if last_incoming_id:
                    execute(
                        """UPDATE chat_members SET last_read_message_id =
                           MAX(last_read_message_id, ?) WHERE chat_id = ? AND user_id = ?""",
                        (last_incoming_id, chat_id, user["id"]),
                    )
            peer = one(
                """SELECT user_id FROM chat_members
                   WHERE chat_id = ? AND user_id != ? AND active = 1 LIMIT 1""",
                (chat_id, user["id"]),
            )
            peer_read_id = 0
            if peer:
                peer_read = one(
                    """SELECT last_read_message_id FROM chat_members
                       WHERE chat_id = ? AND user_id = ?""",
                    (chat_id, peer["user_id"]),
                )
                peer_read_id = peer_read["last_read_message_id"] if peer_read else 0
            messages = []
            for row in rows if around_id or day else reversed(rows):
                item = dict(row)
                item["sender"] = _chat_user(row["sender_id"])
                item["is_read"] = (
                    row["sender_id"] == user["id"] and row["id"] <= peer_read_id
                )
                try:
                    item["track"] = json.loads(item.pop("track_json")) if item["track_json"] else None
                except ValueError:
                    item["track"] = None
                item["image"] = item.pop("image_data")
                messages.append(item)
            return self._json({"messages": messages})
        if path == "/api/chat/typing":
            return self._fail("метод требует POST", 405)
        if path == "/api/chat/message/delete":
            return self._fail("метод требует POST", 405)
        if path == "/api/chat/days":
            chat_id = self._param("chat_id").strip()
            member = one(
                """SELECT m.active FROM chat_members m JOIN chats c ON c.id = m.chat_id
                   WHERE m.chat_id = ? AND m.user_id = ? AND c.type = 'direct'""",
                (chat_id, user["id"]),
            )
            if not member or not member["active"]:
                return self._fail("нет доступа к этому чату", 403)
            rows = query(
                """SELECT DISTINCT substr(created_at, 1, 10) AS day
                   FROM chat_messages
                   WHERE chat_id = ? AND substr(created_at, 1, 10) >= '2026-01-01'
                   ORDER BY day""",
                (chat_id,),
            )
            return self._json({"days": [row["day"] for row in rows]})
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
        if path == "/api/chat/typing":
            chat_id = str(body.get("chat_id") or "").strip()
            member = one(
                """SELECT m.active FROM chat_members m JOIN chats c ON c.id = m.chat_id
                   WHERE m.chat_id = ? AND m.user_id = ? AND c.type = 'direct'""",
                (chat_id, user["id"]),
            )
            if not member or not member["active"]:
                return self._fail("нет доступа к этому чату", 403)
            typing_at = iso() if body.get("is_typing") is True else ""
            execute(
                "UPDATE chat_members SET typing_at = ? WHERE chat_id = ? AND user_id = ?",
                (typing_at, chat_id, user["id"]),
            )
            return self._json({"ok": True})
        if path == "/api/chat/message/delete":
            chat_id = str(body.get("chat_id") or "").strip()
            try:
                message_id = int(body.get("message_id") or 0)
            except (TypeError, ValueError):
                return self._fail("некорректный номер сообщения", 400)
            member = one(
                """SELECT m.active FROM chat_members m JOIN chats c ON c.id = m.chat_id
                   WHERE m.chat_id = ? AND m.user_id = ? AND c.type = 'direct'""",
                (chat_id, user["id"]),
            )
            if not member or not member["active"]:
                return self._fail("нет доступа к этому чату", 403)
            message = one(
                """SELECT id FROM chat_messages
                   WHERE id = ? AND chat_id = ? AND sender_id = ?""",
                (message_id, chat_id, user["id"]),
            )
            if not message:
                return self._fail("сообщение не найдено или принадлежит другому пользователю", 404)
            execute(
                "DELETE FROM chat_messages WHERE id = ? AND chat_id = ? AND sender_id = ?",
                (message_id, chat_id, user["id"]),
            )
            return self._json({"ok": True, "deleted": True})
        if path in ("/api/chat/hide", "/api/chat/delete"):
            chat_id = str(body.get("chat_id") or "").strip()
            member = one(
                """SELECT m.user_id FROM chat_members m JOIN chats c ON c.id = m.chat_id
                   WHERE m.chat_id = ? AND m.user_id = ? AND c.type = 'direct'""",
                (chat_id, user["id"]),
            )
            if not member:
                return self._fail("чат не найден", 404)
            if path == "/api/chat/hide":
                execute(
                    "UPDATE chat_members SET active = 0 WHERE chat_id = ? AND user_id = ?",
                    (chat_id, user["id"]),
                )
                return self._json({"ok": True, "hidden": True})
            execute("DELETE FROM chats WHERE id = ?", (chat_id,))
            return self._json({"ok": True, "deleted": True})
        return self._fail("нет такого метода: %s" % path, 404)

    def api_get(self, path: str) -> None:
        if path == "/api/ai/model":
            user = self._user()
            if not user:
                return self._fail("нужно войти", 401)
            row = one(
                "SELECT model_json FROM ai_models WHERE user_id = ?",
                (user["id"],),
            )
            model = None
            if row:
                try:
                    model = json.loads(row["model_json"])
                except (ValueError, TypeError):
                    return self._fail("модель повреждена", 500)
            if isinstance(model, dict):
                artists = {
                    item["key"]: dict(item)
                    for item in model.get("artists", [])
                    if isinstance(item, dict) and item.get("key")
                }

                def add_live_artist(name, weight):
                    key = norm(name)
                    if not key:
                        return
                    item = artists.setdefault(
                        key, {"key": key, "name": str(name), "score": 0.0})
                    item["score"] += weight

                try:
                    last_event_id = int(model.get("last_event_id") or 0)
                except (TypeError, ValueError):
                    last_event_id = 0
                fresh_rows = query(
                    "SELECT event_json FROM ai_events WHERE user_id = ? AND id > ? ORDER BY id",
                    (user["id"], last_event_id),
                )
                live_event_weights = {
                    "start": 0.05,
                    "progress": 0.8,
                    "complete": 3.0,
                    "skip": 0.0,
                    "seek_forward": -0.1,
                    "seek_back": 0.1,
                    "like": 10.0,
                    "unlike": -15.0,
                    "dislike": -25.0,
                    "undislike": 20.0,
                    "artist_open": 1.8,
                }
                for fresh_row in fresh_rows:
                    try:
                        event = json.loads(fresh_row["event_json"])
                    except (ValueError, TypeError):
                        continue
                    kind = event.get("type")
                    weight = live_event_weights.get(kind, 0.0)
                    track = event.get("track") or {}
                    names = track.get("artists") or []
                    if kind == "artist_open" and event.get("artist"):
                        names = [event["artist"]]
                    for index, name in enumerate(names):
                        add_live_artist(name, weight * (1.0 if index == 0 else 0.45))

                state_row = one(
                    "SELECT data FROM user_state WHERE user_id = ?", (user["id"],)
                )
                try:
                    user_state = json.loads(state_row["data"]) if state_row else {}
                except (ValueError, TypeError):
                    user_state = {}
                if isinstance(user_state, dict):
                    liked_keys = {
                        norm(key) for key in user_state.get("liked", [])
                        if isinstance(key, str)
                    }
                    disliked_keys = {
                        norm(key) for key in user_state.get("disliked", [])
                        if isinstance(key, str)
                    }
                    seed_ids = set(model.get("liked_seed_track_ids", []))
                    dislike_seed_ids = set(model.get("disliked_seed_track_ids", []))
                    saved_tracks = user_state.get("savedTracks", [])
                    if isinstance(saved_tracks, list):
                        for track in saved_tracks:
                            if not isinstance(track, dict):
                                continue
                            names = track.get("artists", [])
                            primary = str(track.get("primary") or (
                                names[0] if isinstance(names, list) and names else ""))
                            title = str(track.get("title") or "")
                            track_key = norm("%s - %s" % (primary, title))
                            track_id = str(track.get("id") or "")
                            if track_key in liked_keys and track_id not in seed_ids:
                                for name in names if isinstance(names, list) else [primary]:
                                    add_live_artist(name, 12.0)
                            if track_key in disliked_keys and track_id not in dislike_seed_ids:
                                for name in names if isinstance(names, list) else [primary]:
                                    add_live_artist(name, -18.0)
                live_ranked = sorted(
                    artists.values(), key=lambda item: item["score"], reverse=True)
                model["top_artists"] = [
                    item for item in live_ranked if item["score"] > 0
                ][:20]
            count = one(
                "SELECT COUNT(*) AS count FROM ai_events WHERE user_id = ?",
                (user["id"],),
            )["count"]
            return self._json({"model": model, "event_count": count})
        if path.startswith("/api/chat/"):
            return self.chat_get(path)
        if path == "/api/share/track":
            code = self._param("code").strip()
            if not re.fullmatch(r"[A-Za-z0-9_-]{10,16}", code):
                return self._fail("ссылка недействительна", 404)
            row = one(
                "SELECT track_json FROM track_shares WHERE code = ?", (code,)
            )
            if not row:
                return self._fail("ссылка недействительна или удалена", 404)
            try:
                track = json.loads(row["track_json"])
            except (ValueError, TypeError):
                return self._fail("трек недоступен", 404)
            if not isinstance(track, dict):
                return self._fail("трек недоступен", 404)
            return self._json({"track": track})
        if path == "/api/share/private-playlist":
            token = self._param("token").strip()
            if not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", token):
                return self._fail("ссылка недействительна", 404)
            token_hash = hashlib.sha256(token.encode("ascii")).hexdigest()
            share = one(
                "SELECT user_id, playlist_id FROM private_playlist_shares WHERE token_hash = ?",
                (token_hash,),
            )
            if not share:
                return self._fail("ссылка недействительна или отозвана", 404)
            row = one("SELECT data FROM user_state WHERE user_id = ?", (share["user_id"],))
            try:
                state = json.loads(row["data"]) if row else {}
            except (ValueError, TypeError):
                return self._fail("плейлист недоступен", 404)
            playlist = _playlist_share_data(state, str(share["playlist_id"]))
            if playlist is None:
                return self._fail("плейлист больше не существует", 404)
            owner = one(
                "SELECT username, display_name FROM users WHERE id = ?",
                (share["user_id"],),
            )
            if not owner:
                return self._fail("плейлист недоступен", 404)
            playlist["username"] = owner["username"]
            playlist["owner"] = owner["display_name"] or owner["username"]
            return self._json({"playlist": playlist})
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
        if path.startswith("/api/ai/"):
            return self.ai_post(path, body)
        if path == "/api/auth/username":
            user = self._user()
            if not user:
                return self._fail("нужно войти", 401)
            username = str(body.get("username") or "").strip()
            if not 3 <= len(username) <= 32:
                return self._fail("имя от 3 до 32 символов")
            if not re.fullmatch(r"[\w.@+\- ]+", username):
                return self._fail("в имени только буквы, цифры и . _ @ + -")
            duplicate = one(
                "SELECT id FROM users WHERE lower(username) = lower(?) AND id != ?",
                (username, user["id"]),
            )
            if duplicate:
                return self._fail("такое имя уже занято", 409)
            execute("UPDATE users SET username = ? WHERE id = ?",
                    (username, user["id"]))
            return self._json({"ok": True, "user": public_user(find_user(username))})
        if path == "/api/share/private-playlist":
            user = self._user()
            if not user:
                return self._fail("нужно войти", 401)
            playlist_id = str(body.get("playlist_id") or "").strip()
            if not playlist_id or len(playlist_id) > 128:
                return self._fail("нужен корректный playlist_id", 400)
            row = one("SELECT data FROM user_state WHERE user_id = ?", (user["id"],))
            try:
                state = json.loads(row["data"]) if row else {}
            except (ValueError, TypeError):
                return self._fail("состояние плейлиста повреждено", 500)
            playlist = next(
                (item for item in state.get("playlists", [])
                 if isinstance(item, dict)
                 and str(item.get("id") or "") == playlist_id),
                None,
            ) if isinstance(state, dict) and isinstance(state.get("playlists"), list) else None
            if not playlist:
                return self._fail("плейлист не найден", 404)
            if playlist.get("public") is True:
                return self._fail("для публичного плейлиста используйте публичную ссылку", 400)
            token = secrets.token_urlsafe(32)
            token_hash = hashlib.sha256(token.encode("ascii")).hexdigest()
            execute(
                "INSERT INTO private_playlist_shares (token_hash, user_id, playlist_id, created_at) "
                "VALUES (?,?,?,?)",
                (token_hash, user["id"], playlist_id, iso()),
            )
            return self._json({"token": token})

        if path == "/api/share/track":
            user = self._user()
            if not user:
                return self._fail("нужно войти", 401)
            title = str(body.get("title") or "").strip()[:200]
            raw_artists = body.get("artists")
            artists = (
                [str(artist).strip()[:120] for artist in raw_artists[:10] if str(artist).strip()]
                if isinstance(raw_artists, list)
                else []
            )
            if not title or not artists:
                return self._fail("нужны название и исполнитель трека", 400)
            try:
                duration = max(0, min(86400, int(body.get("duration") or 0)))
            except (ValueError, TypeError, OverflowError):
                duration = 0
            track = {
                "id": str(body.get("id") or "")[:128],
                "title": title,
                "artists": artists,
                "album": str(body.get("album") or "")[:200],
                "cover": _share_image_url(body.get("cover")),
                "duration": duration,
                "releaseType": str(body.get("releaseType") or "")[:40],
            }
            track_json = json.dumps(track, ensure_ascii=False, separators=(",", ":"))
            code = secrets.token_urlsafe(8)
            execute(
                "INSERT INTO track_shares (code, user_id, track_json, created_at) "
                "VALUES (?,?,?,?)",
                (code, user["id"], track_json, iso()),
            )
            return self._json({"code": code})

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
    replication_error = _replication_configuration_error()
    if replication_error:
        raise SystemExit(replication_error)
    init_db()
    if not SMTP_HOST or not SMTP_USER:
        log("внимание: почта не настроена — регистрация и сброс пароля будут недоступны")

    srv = ThreadingHTTPServer((args.host, port), Handler)
    srv.daemon_threads = True
    if MIRROR_URL:
        _schedule_database_replication(0.1)
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
