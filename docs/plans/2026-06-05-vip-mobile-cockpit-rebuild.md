# VIP Mobile Cockpit Rebuild

Goal: rebuild Dalton's phone-first Hermes cockpit on the current codebase without merging the stale `feat/mobile-cockpit` branch wholesale.

## Implemented scope

- `/cockpit` dashboard route and navigation item.
- Mobile/PWA shell with manifest + service worker.
- Big hold-to-talk button that records browser microphone audio and auto-submits after release.
- Typed fallback.
- Hands-free short-turn loop with spoken commands: stop, repeat, clear, approve, deny.
- Live `/v1/runs` creation + streamed `/v1/runs/{run_id}/events` display.
- `/v1/runs/{run_id}/stop` interrupt button.
- Approval cards for risky actions; no auto-approval.
- `/v1/cockpit/transcribe` server-side audio upload endpoint using lazy-loaded `faster-whisper`.
- Same-origin API-base normalization so copied `/cockpit` or `/v1` URLs do not create doubled paths.

## Safety

Customer-facing messages, emails, payments, legal/accounting changes, and other risky operations must remain approval-gated. The cockpit instructions explicitly require drafting/approval unless a trusted rule already exists.

## Verification checklist

- `npm --prefix web run build`
- `python3 -m py_compile gateway/platforms/api_server.py`
- `python3 -m pytest tests/gateway/test_api_server.py -q -o 'addopts='`
- dashboard route: `/cockpit`
- API smoke: `POST /v1/runs`, SSE events, stop endpoint
- audio smoke: multipart `POST /v1/cockpit/transcribe`
- Tailscale phone-facing HTTPS: `/cockpit`, `/v1/health`, `/v1/runs`, `/v1/cockpit/transcribe`
