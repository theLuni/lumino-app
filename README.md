# lumino

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

* [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
* [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
* [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.



123

## Share links

Lumino share URLs use `https://fascind.theluni.ru/share`. The server serves a
small fallback page with an `Open in Lumino` button, and the app accepts both
these HTTPS URLs and the internal `lumino://` URL scheme. The Windows runner
registers the internal protocol for the current user on startup, and the
installer also registers it. Android declares both URL forms in the
application manifest. Verified Android App Links require the domain's
`assetlinks.json` to include the production signing certificate.
Track shares use short URLs at `/s/<code>`; the server stores only the track
metadata needed to render and open the share. Deploy the updated server before
the app can create or resolve these short links. Keep `assets/icon.png` beside
the deployed project assets so share pages can display the Lumino app avatar.

Private playlist links are bearer links: anyone who has the link can view that
playlist. The server stores only a SHA-256 hash of each random token. Deploy
the updated `server/serv.py` before HTTPS share pages and private playlist
links can be created or opened on the production service.

Lyrics found through LRCLIB are stored in the server's SQLite database
(`lyrics_cache`) and served from that cache on later requests. With
`LUMINO_DATA=/data`, the cache is stored in `/data/fascind.db` and survives
server restarts.

### Primary and mirror server

Deploy the same updated server code (`server/serv.py` in this repository,
deployed as `/prj/fascind/server.py` on the current host) to both servers and
keep each host's database under its persistent `/data` directory
(`LUMINO_DATA=/data`). The Russian host remains the single source of truth.
Configure it with `LUMINO_MIRROR_URL=https://147.45.72.47.sslip.io` and a private
`LUMINO_REPLICATION_TOKEN` of at least 32 characters. Configure the other host
with `LUMINO_PRIMARY_URL=https://fascind.theluni.ru` and the exact same token.
Do not set both URL variables on one host, and do not expose the token publicly.

The primary sends a compressed SQLite snapshot to the mirror after database
changes and retries if the mirror is temporarily unreachable. Requests that
read or modify accounts, state, chats, profiles, and share links on the mirror
are forwarded to the primary, so writes have one ordering and cannot fork the
database. The mirror still serves music search, audio, and metadata locally.
If the primary is offline, those local music features can continue, but
account/chat/share operations are unavailable until it returns; this mode
does not promote the mirror to a writable primary. Configure the mirror's
HTTPS reverse proxy to allow `PUT /_internal/replica/db`, request bodies up to
256 MiB, and an upstream timeout of at least 60 seconds.

123

123
