# Hermes VIP Mobile Cockpit

The VIP Mobile Cockpit is a phone-first/PWA driving-mode control center for Dalton to use Hermes like an assistant riding in the truck: hold to talk, transcribe locally/server-side, watch live work, stop/interrupt, approve risky actions, and hear concise voice replies.

## Routes and endpoints

- Dashboard route: `/cockpit`
- Server-side STT: `POST /v1/cockpit/transcribe`
- Run control:
  - `POST /v1/runs`
  - `GET /v1/runs/{run_id}`
  - `GET /v1/runs/{run_id}/events`
  - `POST /v1/runs/{run_id}/approval`
  - `POST /v1/runs/{run_id}/stop`
- PWA files:
  - `/manifest.webmanifest`
  - `/sw.js`

## Driving-mode behavior

- **Hold to talk:** press and hold the big button, speak, release to transcribe and auto-submit.
- **Typed fallback:** type a command and tap Send.
- **Hands-free:** records short turns, transcribes, auto-submits recognized commands, speaks the result, then listens again.
- **Voice controls:** `stop`, `cancel`, `interrupt`, `repeat`, `clear`, `approve`, `deny`.
- **Approval cards:** risky actions pause and show explicit approve/deny controls. Spoken approvals only resolve the current approval card.

## API base URL rule

In Cockpit settings, the API base should be the server origin/base, not a final endpoint path.

Correct:

```text
https://desktop-vcb4ksf-1.tail87092b.ts.net
https://desktop-vcb4ksf-1.tail87092b.ts.net:8642
http://127.0.0.1:8642
```

Incorrect:

```text
https://desktop-vcb4ksf-1.tail87092b.ts.net/v1
https://desktop-vcb4ksf-1.tail87092b.ts.net/cockpit
```

The UI normalizes copied `/cockpit`, `/dashboard`, and `/v1` URLs back to the origin/base before appending `/v1/...` endpoints.

## Phone access

Android microphone access and PWA install require HTTPS or localhost. For Dalton, prefer private Tailscale HTTPS rather than a public tunnel.

Typical phone URL:

```text
https://desktop-vcb4ksf-1.tail87092b.ts.net/cockpit
```

If dashboard and API are served on one Tailscale origin, route `/` to the dashboard and `/v1` to the API/proxy that injects `API_SERVER_KEY` server-side.

## Start locally

```bash
cd /home/dalton/.hermes/hermes-agent
npm --prefix web install
npm --prefix web run build
hermes dashboard --host 127.0.0.1 --port 9119 --tui --skip-build --no-open
```

Open locally:

```text
http://127.0.0.1:9119/cockpit
```

## STT configuration

The transcribe endpoint lazy-loads `faster-whisper` on first use.

Optional environment overrides:

```bash
COCKPIT_STT_MODEL=base
COCKPIT_STT_DEVICE=cpu
COCKPIT_STT_COMPUTE_TYPE=int8
COCKPIT_STT_LANGUAGE=en
```

## Verification

- `npm --prefix web run build`
- `python3 -m py_compile gateway/platforms/api_server.py`
- `python3 -m pytest tests/gateway/test_api_server.py -q -o 'addopts='`
- phone-facing smoke:
  - `GET /cockpit`
  - `GET /v1/health`
  - `POST /v1/runs`
  - stream `GET /v1/runs/{run_id}/events`
  - `POST /v1/runs/{run_id}/stop`
  - multipart `POST /v1/cockpit/transcribe`

## Safety

The cockpit must not auto-send texts/emails/customer-facing messages, spend money, approve accounting/legal changes, or make risky system edits unless Dalton explicitly approves the specific action or has established a trusted auto-send rule.
