# Hermes Mobile Cockpit Pocket Mode

Phase 2 adds a compile-targeted Android prototype around the Phase 1 server-side control foundation. It keeps the Android scope to foreground service plus push-to-talk/manual command plumbing. It does **not** implement a durable always-on `Hey Hermes` hotword and does **not** claim lock-screen microphone behavior without physical Android testing.

## What Phase 1 implements

Pocket Mode sessions are lightweight mobile-client records that wrap the existing `/v1/runs` machinery. This keeps approvals, run status, SSE events, and stop/interrupt on the same path as the existing API cockpit.

### API endpoints

All endpoints require the same API Server bearer token as the existing `/v1` API.

```http
POST /v1/pocket/sessions
GET  /v1/pocket/sessions/{session_id}
POST /v1/pocket/sessions/{session_id}/commands
GET  /v1/pocket/sessions/{session_id}/events
POST /v1/pocket/sessions/{session_id}/stop
```

Create/register a session:

```bash
AUTH_HEADER="Authorization: Bearer <api-server-token>"
curl -sS -X POST "$HERMES_BASE/v1/pocket/sessions" \
  -H "$AUTH_HEADER" \
  -H 'Content-Type: application/json' \
  -d '{"label":"Dalton phone","client":"android-phase1"}'
```

Submit a typed Pocket Mode command:

```bash
curl -sS -X POST "$HERMES_BASE/v1/pocket/sessions/$POCKET_ID/commands" \
  -H "$AUTH_HEADER" \
  -H 'Content-Type: application/json' \
  -d '{"command":"Give me a one sentence status check."}'
```

The command endpoint returns a `run_id`, Pocket-scoped `events_url` and
`status_url`, plus direct `run_events_url` and `run_status_url` fields for
debugging. Mobile clients should prefer the Pocket URLs so the active run can
change without changing client wiring.

Subscribe to Pocket events with:

```bash
curl -N "$HERMES_BASE/v1/pocket/sessions/$POCKET_ID/events" \
  -H "$AUTH_HEADER"
```

Stop the active Pocket Mode run:

```bash
curl -sS -X POST "$HERMES_BASE/v1/pocket/sessions/$POCKET_ID/stop" \
  -H "$AUTH_HEADER"
```

## Android limitations

Android Chrome/PWA pages cannot reliably keep microphone capture alive after screen lock or pocketing. For the Meta Glasses-style goal, use a native Android companion app with a foreground service and persistent notification. Phase 1 includes a skeleton only; physical device testing is still required.

## Android Phase 2 prototype

The Android prototype lives in `prototypes/android-pocket-mode`.

- `MainActivity` stores Hermes base URL, bearer token, and Pocket session ID in app-private `SharedPreferences`.
- The token is local-only; do not commit or hardcode API tokens.
- The UI can start/stop the foreground service, create a Pocket session, send a manual command, refresh status, and stop the active run.
- Networking uses the Pocket endpoints listed above over the configured base URL.
- The foreground service is a notification-backed foundation only. It does not perform hotword detection, background STT, or always-on microphone processing.
- Cleartext HTTP is allowed only for Android emulator/local loopback hosts (`10.0.2.2`, `localhost`, `127.0.0.1`). Use HTTPS for real devices, especially over Tailscale.

### Android build/run

Prerequisites:

- Android SDK installed, with a platform compatible with `compileSdk = 35`.
- JDK 17.
- Gradle 8.9 or Android Studio's Gradle integration available on `PATH`.

Build from the repo root:

```bash
./gradlew -p prototypes/android-pocket-mode build
```

Build from the prototype directory:

```bash
cd prototypes/android-pocket-mode
./gradlew build
```

Install on a connected device or emulator after a successful build:

```bash
adb install -r prototypes/android-pocket-mode/app/build/outputs/apk/debug/app-debug.apk
```

For emulator testing against a local API server, set `Hermes base URL` to
`http://10.0.2.2:<port>`. For a physical device, use an HTTPS URL reachable
from the device, such as a Tailscale HTTPS endpoint.

The checked-in `gradlew` files are lightweight launchers that delegate to a
local `gradle` binary. This environment does not contain Gradle or Android SDK,
and cannot generate or verify a full `gradle-wrapper.jar` offline. The intended
wrapper distribution is recorded in
`prototypes/android-pocket-mode/gradle/wrapper/gradle-wrapper.properties`.

Later phases can add:

1. Push-to-talk audio capture and upload.
2. Android TTS playback for concise replies.
3. Notification/Bluetooth/headset button activation.
4. VAD + STT phrase match for `Hey Hermes`.
5. A true offline wake-word engine if physical device tests show it is viable.

## Web cockpit integration note

`/cockpit` is not a concrete route in this checkout. The dashboard is served by
`hermes_cli/web_server.py::mount_spa()`, which falls back to the built React SPA
for arbitrary client-side paths, and the React app does not register a
`/cockpit` route. The only cockpit-specific source present is the dashboard
theme `layoutVariant: "cockpit"` sidebar slot system.

Phase 1 therefore uses `web/mobile-cockpit/pocket-mode-panel.html` as the
standalone/embeddable mobile-first Pocket Mode panel. If a real `/cockpit` PWA
source is restored later, move the panel behavior into that app and keep the
same `/v1/pocket/*` API.

### Standalone panel usage

From the repo checkout, open the file directly in a mobile browser or serve it
from a local static server:

```bash
python3 -m http.server 8765 --directory web/mobile-cockpit
```

Then open `http://<host>:8765/pocket-mode-panel.html`, set:

- `Hermes base URL` to the API server origin, for example a Tailscale HTTPS URL.
- `API bearer token` to `API_SERVER_KEY`.
- `Command` to the typed Pocket Mode request.

The panel persists the base URL, token, and Pocket session ID in browser
`localStorage`. `Start` creates a new Pocket session, `Send` delegates the typed
command to `/v1/runs` through the Pocket API, `Status` reads the Pocket session
including embedded active run status, `Stream events` reads the active run SSE
through the Pocket events endpoint, and `Stop` delegates to the active run stop
handler.

## Verification checklist

- `python3 -m py_compile gateway/platforms/api_server.py`
- `python3 -m pytest tests/gateway/test_api_server_pocket_mode.py -q`
- `npm --prefix web run build`
- `./gradlew -p prototypes/android-pocket-mode build`
- `POST /v1/pocket/sessions` returns `201` and a `pocket_*` session ID.
- `GET /v1/pocket/sessions/{id}` returns status and any active `run_status`.
- `POST /v1/pocket/sessions/{id}/commands` returns `202` and `run_id`.
- `GET /v1/pocket/sessions/{id}/events` streams the active run.
- `POST /v1/pocket/sessions/{id}/stop` stops or marks idle when no active run exists.
- Android compile requires Android SDK and Gradle/JDK 17.
- Physical Android test required before claiming locked-screen/pocket microphone reliability.
