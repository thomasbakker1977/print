# LifeChart

A personal iPhone coach built around the **NIMH Life Chart Method**, with a
self-hosted backend in your homelab.

- **Life chart**: daily mood on the −4…+4 Life Chart scale, self-rating,
  mixed states, sleep, anxiety, irritability, medication, life events, notes
  (typed or dictated) and mood photos/videos.
- **Garmin**: sleep, sleep score, HRV, resting heart rate, stress, Body Battery
  and steps are imported by the server and shown next to your own entries.
- **Coach** (Claude): energetic, action-oriented in the spirit of Tony Robbins,
  grounded in Mentalization-Based Treatment, Schema Therapy and NLP coaching
  techniques. It calms down automatically when your chart shows elevated mood,
  irritability or short sleep. Modes:
  *Talk it through*, *Make sense of a moment*, *Find my Why*,
  *Reflect on an event* and *Review & advice*.
  It knows your goals, your Why, your signaleringsplan, your crisis plan and
  summaries of earlier conversations, and can propose reminders, calendar
  blocks, goals and Schema Therapy flashcards (you confirm each one).
- **Assistant ("Jarvis")**: hands-free voice loop (speak → it answers aloud →
  listens again). It logs your day, life events and goal progress on request,
  gives a morning briefing and runs an evening check-in. Start it with
  *"Hey Siri, talk to LifeChart"*.
- **Check-ins**: local notifications when you have been quiet, when today is
  not logged, after tasks and calendar blocks you planned, for overdue
  reminders, and after several short nights according to your watch.
- **Calendar & tasks**: any account on your iPhone (iCloud, Google,
  Outlook/Exchange) through EventKit.

```
iPhone ──HTTPS──▶ Cloudflare Access ──Tunnel──▶ cloudflared ──▶ lifechart (FastAPI + SQLite)
                                                                 ├─▶ Garmin Connect
                                                                 └─▶ Claude API (optionally via AI Gateway)
```

> The coach is an AI. It supports your care team, therapist and GP; it does
> not replace them. In acute danger call 112; for suicidal thoughts call 113
> or 0800-0113 (free), or chat at 113.nl.

## 1. Backend in the homelab

Requirements: Docker with Compose, a domain on Cloudflare, an Anthropic API
key.

```bash
cd backend
cp .env.example .env
chmod 600 .env
openssl rand -hex 32          # → LIFECHART_API_TOKEN
mkdir -m 700 data
```

Fill in `.env`: `LIFECHART_API_TOKEN`, `ANTHROPIC_API_KEY` and the Cloudflare
values below.

### Cloudflare Tunnel

1. Zero Trust dashboard → **Networks → Tunnels → Create a tunnel**
   (cloudflared). Copy the token into `CLOUDFLARE_TUNNEL_TOKEN`.
2. Add a **public hostname**, e.g. `lifechart.example.nl`, service
   `http://lifechart:8080`.

The Compose file publishes **no ports**; cloudflared connects outwards, so
nothing has to be opened on your router.

### Cloudflare Access

1. **Access → Applications → Add → Self-hosted** for `lifechart.example.nl`.
2. **Access → Service credentials → Service tokens → Create**; keep the Client
   ID and Secret for the app.
3. Give the application a policy with action **Service Auth** that includes
   this service token (add an *Allow* policy for your own e-mail too if you
   want to open it in a browser).
4. Copy the application's **AUD tag** into `CF_ACCESS_AUD` and your team
   domain (`<team>.cloudflareaccess.com`) into `CF_ACCESS_TEAM_DOMAIN`. The
   backend then rejects every request that did not pass Cloudflare Access.

Optional: route coach traffic through **Cloudflare AI Gateway** by setting
`ANTHROPIC_BASE_URL` (see `.env.example`). Switch off request logging in the
gateway: prompts contain your health data. Set a spend limit there or in the
Anthropic console either way.

### Garmin

```bash
docker compose run --rm lifechart python -m app.garmin_login
```

Log in once (two-factor codes work); tokens are saved in `data/` and the
server imports your data every 4 hours. You do not need to keep your Garmin
password in `.env`. This uses the unofficial `garminconnect` library, so it can
break when Garmin changes its site; the app keeps working without it.

### Start

```bash
docker compose up -d --build
docker compose logs -f lifechart
```

Back up `backend/data/` (it holds your database and Garmin tokens) to an
encrypted location.

### Tests

```bash
pip install -r requirements.txt pytest httpx
python -m pytest -q
```

## 2. iPhone app

Requirements: a Mac with **Xcode 16** or later, an iPhone with **iOS 17** or
later.

1. Open `LifeChart.xcodeproj`.
2. Target **LifeChart → Signing & Capabilities**: choose your team and change
   the bundle identifier (`nl.lifechart.app`) to one of your own. If you change
   its prefix, also change `refreshTaskId` in `LifeChartApp.swift` and
   `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`.
   - A free Apple ID works, but the app must then be re-installed from Xcode
     every 7 days. A paid developer account (€99/year) removes that limit.
3. Run on your iPhone.
4. In the app: **More → Server & Cloudflare**: enter `https://lifechart.example.nl`,
   the API token and the Cloudflare service token, then **Save & test**.
5. **More → Profile & care plan**: your name, about you, care history,
   signaleringsplan, crisis plan and coach personality.
6. **More → Calendar & reminders** and **More → Check-ins**: allow access.

## 3. Privacy and security

- Life chart data lives on the iPhone (SwiftData) and on your own server.
  Photos and videos never leave the phone unless you share one with the coach
  (then it is used for that reply only and not stored on the server).
- Speech recognition runs on the iPhone when your language supports it.
- Your calendar is summarised on the phone and sent with coach messages only
  while *Share my agenda with the coach* is on. Calendar text is marked as
  untrusted for the coach, so instructions hidden in invites are ignored.
- Coach messages are processed by Anthropic's Claude API.
- Backend hardening: bearer token plus Cloudflare Access JWT, no published
  ports, read-only container without capabilities, private file permissions,
  rate and concurrency limits on the coach, input size limits, CSV formula
  neutralisation, API docs disabled.

## 4. Mirror to GitLab (gitlab01)

Once the code is in a private GitHub repository, either:

- in GitLab: **New project → Import project → GitHub**, select the repository; or
- from your own machine:

  ```bash
  git clone git@github.com:<you>/lifechart.git && cd lifechart
  git remote add gitlab git@gitlab01:<group>/lifechart.git
  git push gitlab --all && git push gitlab --tags
  ```

Create the GitLab project as **Private** first.
