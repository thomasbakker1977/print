"""LifeChart backend: sync, Garmin import and the personal coach.

Run with:  uvicorn --factory app.main:build_app --host 0.0.0.0 --port 8080
"""

import asyncio
import csv
import hmac
import io
import json
import logging
import os
from contextlib import asynccontextmanager
from datetime import date

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.responses import PlainTextResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from . import schemas
from .coach import Coach, CoachRefused, build_context, history_for_model
from .db import Database
from .garmin import GarminSync, run_periodically

log = logging.getLogger("lifechart")

MAX_HISTORY_MESSAGES = 40

SYNC_MODELS = {
    "entries": schemas.DayEntry,
    "medications": schemas.Medication,
    "events": schemas.LifeEvent,
    "flashcards": schemas.Flashcard,
    "goals": schemas.Goal,
}


def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


def create_app(
    db: Database,
    api_token: str,
    coach: Coach | None,
    garmin: GarminSync | None = None,
    garmin_interval_minutes: int = 240,
) -> FastAPI:
    garmin = garmin or GarminSync(db, None, None, "")
    background: set[asyncio.Task] = set()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        task = None
        if garmin.enabled and garmin_interval_minutes > 0:
            task = asyncio.create_task(run_periodically(garmin, garmin_interval_minutes))
        yield
        if task:
            task.cancel()

    app = FastAPI(title="LifeChart", version="1.0", lifespan=lifespan)
    bearer = HTTPBearer(auto_error=False)

    def authorize(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> None:
        if credentials is None or not hmac.compare_digest(
            credentials.credentials.encode(), api_token.encode()
        ):
            raise HTTPException(status_code=401, detail="Invalid or missing API token")

    auth = [Depends(authorize)]

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok"}

    @app.get("/api/status", dependencies=auth)
    def status() -> dict:
        return {"coach": coach is not None, "garmin": garmin.status(), "cursor": db.current_version()}

    # MARK: - Sync

    @app.post("/api/sync", dependencies=auth, response_model=schemas.SyncResponse)
    def sync(request: schemas.SyncRequest) -> dict:
        for kind in SYNC_MODELS:
            records = getattr(request, kind)
            db.apply_changes(
                kind,
                [(r.key, r.updatedAt, r.deleted, r.model_dump(by_alias=True)) for r in records],
            )
        response = {kind: db.changes_since(kind, request.cursor) for kind in SYNC_MODELS}
        response["wearables"] = db.changes_since("wearables", request.cursor)
        response["cursor"] = db.current_version()
        return response

    @app.get("/api/entries", dependencies=auth)
    def entries(
        start: str = Query(pattern=schemas.DATE_PATTERN),
        end: str = Query(pattern=schemas.DATE_PATTERN),
    ) -> dict:
        return {
            "entries": db.days_between("entries", start, end),
            "wearables": db.days_between("wearables", start, end),
        }

    @app.get("/api/export.csv", dependencies=auth, response_class=PlainTextResponse)
    def export_csv() -> PlainTextResponse:
        medications = {m["id"]: m["name"] for m in db.live_records("medications")}
        events: dict[str, list[str]] = {}
        for ev in db.live_records("events"):
            events.setdefault(ev["date"], []).append(ev["title"])
        wearables = {w["day"]: w for w in db.live_records("wearables")}
        entries = {e["day"]: e for e in db.live_records("entries")}

        out = io.StringIO()
        writer = csv.writer(out)
        writer.writerow([
            "date", "mood_level", "self_rating", "mixed", "mood_switches", "sleep_hours",
            "anxiety", "irritability", "menstruating", "weight", "medications",
            "life_events", "garmin_sleep_hours", "garmin_sleep_score", "resting_hr",
            "hrv", "stress_avg", "body_battery_high", "steps", "notes",
        ])
        for day in sorted(entries.keys() | wearables.keys() | events.keys()):
            e, w = entries.get(day, {}), wearables.get(day, {})
            doses = "; ".join(
                f"{medications.get(d['medicationId'], '?')} {d['amount']:g}"
                for d in e.get("doses", [])
            )
            writer.writerow([
                day, e.get("moodLevel"), e.get("moodRating"), e.get("mixed"),
                e.get("moodSwitches"), e.get("sleepHours"), e.get("anxiety"),
                e.get("irritability"), e.get("menstruating"), e.get("weight"), doses,
                "; ".join(events.get(day, [])), w.get("sleepHours"), w.get("sleepScore"),
                w.get("restingHeartRate"), w.get("hrv"), w.get("stressAvg"),
                w.get("bodyBatteryHigh"), w.get("steps"), e.get("notes", ""),
            ])
        return PlainTextResponse(
            out.getvalue(),
            media_type="text/csv",
            headers={"Content-Disposition": 'attachment; filename="lifechart.csv"'},
        )

    # MARK: - Garmin

    @app.post("/api/garmin/refresh", dependencies=auth)
    async def garmin_refresh() -> dict:
        if not garmin.enabled:
            raise HTTPException(status_code=409, detail="Garmin is not configured on the server")
        changed = await asyncio.to_thread(garmin.sync)
        return {"changed": changed, **garmin.status()}

    # MARK: - Profile

    @app.get("/api/profile", dependencies=auth, response_model=schemas.Profile)
    def get_profile() -> dict:
        return {"aboutMe": db.get_setting("aboutMe"), "myWhy": db.get_setting("myWhy")}

    @app.put("/api/profile", dependencies=auth, response_model=schemas.Profile)
    def put_profile(profile: schemas.Profile) -> dict:
        db.set_setting("aboutMe", profile.aboutMe)
        db.set_setting("myWhy", profile.myWhy)
        return profile.model_dump()

    # MARK: - Coach

    @app.get("/api/coach/conversations", dependencies=auth,
             response_model=list[schemas.Conversation])
    def conversations() -> list[dict]:
        return db.list_conversations()

    @app.get("/api/coach/conversations/{conversation_id}", dependencies=auth,
             response_model=schemas.ConversationDetail)
    def conversation(conversation_id: str) -> dict:
        found = db.get_conversation(conversation_id)
        if found is None:
            raise HTTPException(status_code=404, detail="Conversation not found")
        return found

    @app.delete("/api/coach/conversations/{conversation_id}", dependencies=auth, status_code=204)
    def delete_conversation(conversation_id: str) -> None:
        if not db.delete_conversation(conversation_id):
            raise HTTPException(status_code=404, detail="Conversation not found")

    async def refresh_summary(conversation_id: str) -> None:
        found = db.get_conversation(conversation_id)
        if coach is None or found is None:
            return
        try:
            summary = await coach.summarize(found["messages"])
        except Exception:
            log.exception("Summarising conversation %s failed", conversation_id)
            return
        if summary:
            db.set_summary(conversation_id, summary)

    @app.post("/api/coach/chat", dependencies=auth)
    async def chat(request: schemas.ChatRequest) -> StreamingResponse:
        if coach is None:
            raise HTTPException(status_code=503, detail="Coach is not configured (ANTHROPIC_API_KEY)")

        conversation_id = request.conversationId
        if conversation_id is None:
            title = " ".join(request.message.split())[:60]
            conversation_id = db.create_conversation(title, request.mode)
        elif not db.conversation_exists(conversation_id):
            raise HTTPException(status_code=404, detail="Conversation not found")

        mode = db.get_conversation(conversation_id)["mode"]
        db.add_message(conversation_id, "user", request.message)
        stored = db.get_conversation(conversation_id)["messages"][-MAX_HISTORY_MESSAGES:]
        history = history_for_model(stored)
        while history and history[0]["role"] != "user":
            history.pop(0)

        today = date.today()
        if request.localTime:
            try:
                today = date.fromisoformat(request.localTime[:10])
            except ValueError:
                pass
        context = build_context(
            db, today, request.localTime, request.agenda, request.spoken, conversation_id
        )

        async def events():
            yield sse("conversation", {"conversationId": conversation_id, "mode": mode})
            text_parts: list[str] = []
            suggestions: list[dict] = []
            try:
                async for kind, payload in coach.stream_reply(mode, context, history):
                    if kind == "text":
                        text_parts.append(payload)
                        yield sse("text", {"text": payload})
                    else:
                        suggestions.append(payload)
                        yield sse("suggestion", payload)
            except CoachRefused:
                yield sse("error", {"message": "The coach could not answer this message."})
            except Exception:
                log.exception("Coach reply failed")
                yield sse("error", {"message": "The coach is unavailable right now. Try again."})
            reply = "".join(text_parts).strip()
            if reply or suggestions:
                db.add_message(conversation_id, "assistant", reply, suggestions)
                task = asyncio.create_task(refresh_summary(conversation_id))
                background.add(task)
                task.add_done_callback(background.discard)
            yield sse("done", {})

        return StreamingResponse(
            events(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    return app


def build_app() -> FastAPI:
    """Builds the app from environment variables (used by uvicorn --factory)."""
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
    token = os.environ.get("LIFECHART_API_TOKEN", "")
    if len(token) < 16:
        raise RuntimeError("Set LIFECHART_API_TOKEN to a random string of at least 16 characters")

    db = Database(os.environ.get("LIFECHART_DB", "/data/lifechart.db"))

    coach = None
    if os.environ.get("ANTHROPIC_API_KEY"):
        import anthropic

        coach = Coach(
            anthropic.AsyncAnthropic(),
            model=os.environ.get("COACH_MODEL", "claude-opus-5-5"),
            crisis_info=os.environ.get(
                "COACH_CRISIS_INFO",
                "their local emergency number, a crisis line, or someone they trust",
            ),
        )
    else:
        log.warning("ANTHROPIC_API_KEY not set; the coach is disabled")

    garmin = GarminSync(db, None, None, "")
    tokenstore = os.environ.get("GARMIN_TOKENSTORE", "/data/garmin-tokens")
    email, password = os.environ.get("GARMIN_EMAIL"), os.environ.get("GARMIN_PASSWORD")
    if email or os.path.exists(tokenstore):
        from garminconnect import Garmin

        garmin = GarminSync(db, email, password, tokenstore, client_factory=Garmin)

    return create_app(
        db,
        token,
        coach,
        garmin,
        garmin_interval_minutes=int(os.environ.get("GARMIN_SYNC_MINUTES", "240")),
    )
