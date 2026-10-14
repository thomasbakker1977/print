import json
from datetime import date, timedelta
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.coach import Coach, build_context, history_for_model
from app.db import Database
from app.garmin import GarminSync
from app.main import create_app

TOKEN = "test-token-0123456789"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


# MARK: - Fakes


class FakeStream:
    def __init__(self, response):
        self._response = response

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    @property
    async def text_stream(self):
        for block in self._response.content:
            if block.type == "text":
                yield block.text

    async def get_final_message(self):
        return self._response


class FakeMessages:
    """Replays scripted responses and records each request."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.summary_requests = []

    def stream(self, **kwargs):
        self.requests.append(json.loads(json.dumps(kwargs, default=str)))
        return FakeStream(self.responses.pop(0))

    async def create(self, **kwargs):
        self.summary_requests.append(kwargs)
        return SimpleNamespace(stop_reason="end_turn", content=[text("They talked about work.")])


def text(value):
    return SimpleNamespace(type="text", text=value)


def tool_use(name, tool_input, block_id="toolu_1"):
    return SimpleNamespace(type="tool_use", name=name, input=tool_input, id=block_id)


def fake_coach(responses):
    messages = FakeMessages(responses)
    client = SimpleNamespace(beta=SimpleNamespace(messages=messages))
    return Coach(client, model="claude-opus-5-5", crisis_info="call 112"), messages


class FakeGarmin:
    def __init__(self, email, password):
        pass

    def login(self, tokenstore):
        pass

    def get_stats(self, day):
        return {
            "totalSteps": 8000,
            "restingHeartRate": 55,
            "averageStressLevel": 30,
            "bodyBatteryHighestValue": 80,
            "bodyBatteryLowestValue": 20,
        }

    def get_sleep_data(self, day):
        return {"dailySleepDTO": {"sleepTimeSeconds": 27000, "sleepScores": {"overall": {"value": 81}}}}

    def get_hrv_data(self, day):
        return {"hrvSummary": {"lastNightAvg": 48, "status": "BALANCED"}}


def make_client(responses=(), garmin=None):
    db = Database(":memory:")
    coach, messages = fake_coach(responses)
    app = create_app(db, TOKEN, coach, garmin, garmin_interval_minutes=0)
    return TestClient(app), db, messages


def read_sse(body: str) -> list[tuple[str, dict]]:
    events = []
    for chunk in body.strip().split("\n\n"):
        lines = dict(line.split(": ", 1) for line in chunk.splitlines())
        events.append((lines["event"], json.loads(lines["data"])))
    return events


# MARK: - Auth and sync


def test_requires_token():
    client, _, _ = make_client()
    assert client.get("/health").status_code == 200
    assert client.post("/api/sync", json={}).status_code == 401
    assert client.post("/api/sync", json={}, headers={"Authorization": "Bearer nope"}).status_code == 401


def test_sync_round_trip_and_last_writer_wins():
    client, _, _ = make_client()
    entry = {"day": "2026-10-01", "updatedAt": 1000, "moodLevel": -2, "sleepHours": 6.5}
    first = client.post("/api/sync", json={"cursor": 0, "entries": [entry]}, headers=AUTH).json()
    assert first["cursor"] == 1
    assert first["entries"][0]["moodLevel"] == -2

    # A stale write from another device is ignored.
    stale = {**entry, "updatedAt": 500, "moodLevel": 3}
    second = client.post("/api/sync", json={"cursor": 1, "entries": [stale]}, headers=AUTH).json()
    assert second["cursor"] == 1
    assert second["entries"] == []

    # A newer write wins and shows up for a device that synced from scratch.
    newer = {**entry, "updatedAt": 2000, "moodLevel": 1}
    client.post("/api/sync", json={"cursor": 1, "entries": [newer]}, headers=AUTH)
    full = client.post("/api/sync", json={"cursor": 0}, headers=AUTH).json()
    assert [e["moodLevel"] for e in full["entries"]] == [1]


def test_sync_all_kinds_and_tombstones():
    client, db, _ = make_client()
    payload = {
        "medications": [{"id": "m1", "name": "Lithium", "updatedAt": 1, "defaultDose": 800}],
        "events": [{"id": "e1", "date": "2026-10-02", "title": "Moved house", "impact": -2, "updatedAt": 1}],
        "flashcards": [{"id": "f1", "title": "Criticism at work", "schema": "Defectiveness", "updatedAt": 1}],
        "goals": [{"id": "g1", "title": "Walk 3x a week", "updatedAt": 1}],
    }
    result = client.post("/api/sync", json=payload, headers=AUTH).json()
    assert result["flashcards"][0]["schema"] == "Defectiveness"
    assert result["goals"][0]["status"] == "active"

    deleted = {**payload["goals"][0], "updatedAt": 2, "deleted": True}
    result = client.post("/api/sync", json={"cursor": result["cursor"], "goals": [deleted]}, headers=AUTH).json()
    assert result["goals"][0]["deleted"] is True
    assert db.live_records("goals") == []


def test_rejects_invalid_records():
    client, _, _ = make_client()
    bad = {"entries": [{"day": "yesterday", "updatedAt": 1}]}
    assert client.post("/api/sync", json=bad, headers=AUTH).status_code == 422
    bad = {"entries": [{"day": "2026-10-01", "updatedAt": 1, "moodLevel": 9}]}
    assert client.post("/api/sync", json=bad, headers=AUTH).status_code == 422


def test_profile_and_export():
    client, _, _ = make_client()
    client.put("/api/profile", json={"aboutMe": "Bipolar II", "myWhy": "To help",
                                     "warningSigns": "Sleeping < 6h"}, headers=AUTH)
    profile = client.get("/api/profile", headers=AUTH).json()
    assert profile["myWhy"] == "To help" and profile["warningSigns"] == "Sleeping < 6h"
    assert profile["crisisPlan"] == ""

    client.post("/api/sync", json={
        "medications": [{"id": "m1", "name": "Lamotrigine", "updatedAt": 1}],
        "entries": [{"day": "2026-10-03", "updatedAt": 1, "moodLevel": 0,
                     "notes": "ok, \"fine\"", "doses": [{"medicationId": "m1", "amount": 200}]}],
    }, headers=AUTH)
    csv_text = client.get("/api/export.csv", headers=AUTH).text
    assert csv_text.splitlines()[0].startswith("date,mood_level")
    assert 'Lamotrigine 200' in csv_text
    assert '"ok, ""fine"""' in csv_text


# MARK: - Garmin


def test_garmin_sync_backfills_and_skips_unchanged():
    db = Database(":memory:")
    garmin = GarminSync(db, "a@b.c", "pw", "/tmp/none", client_factory=FakeGarmin)
    today = date(2026, 10, 14)
    assert garmin.sync(today) == 30
    day = db.get_record("wearables", "2026-10-14")
    assert day["sleepHours"] == 7.5 and day["hrv"] == 48 and day["sleepScore"] == 81
    # Nothing changed on Garmin's side, so no new versions are created.
    version = db.current_version()
    assert garmin.sync(today) == 0
    assert db.current_version() == version


def test_garmin_failure_is_reported():
    class Broken(FakeGarmin):
        def login(self, tokenstore):
            raise RuntimeError("Cloudflare says no")

    db = Database(":memory:")
    garmin = GarminSync(db, "a@b.c", "pw", "/tmp/none", client_factory=Broken)
    assert garmin.sync() == 0
    assert "Cloudflare" in garmin.status()["lastError"]


def test_wearables_are_server_only():
    db = Database(":memory:")
    garmin = GarminSync(db, "a", "b", "/tmp/none", client_factory=FakeGarmin)
    garmin.sync(date.today())
    app = create_app(db, TOKEN, None, garmin, garmin_interval_minutes=0)
    client = TestClient(app)
    result = client.post("/api/sync", json={"cursor": 0, "wearables": [{"day": "2026-01-01"}]}, headers=AUTH).json()
    assert len(result["wearables"]) == 30
    assert db.get_record("wearables", "2026-01-01") is None


# MARK: - Coach


def test_context_combines_mood_watch_goals_and_history():
    db = Database(":memory:")
    today = date(2026, 10, 14)
    db.set_setting("myWhy", "To make people feel seen")
    db.set_setting("warningSigns", "Yellow: sleeping under 6 hours -> call my nurse")
    db.apply_changes("entries", [("2026-10-13", 1, False, {
        "day": "2026-10-13", "moodLevel": 2, "sleepHours": 4, "notes": "racing thoughts", "doses": []})])
    db.apply_changes("wearables", [("2026-10-13", 1, False, {
        "day": "2026-10-13", "sleepHours": 4.2, "hrv": 31, "hrvStatus": "LOW", "stressAvg": 55})])
    db.apply_changes("goals", [("g1", 1, False, {
        "id": "g1", "title": "Sleep by 23:00", "status": "active", "progress": 40})])
    old = today - timedelta(days=60)
    db.apply_changes("entries", [(old.isoformat(), 1, False, {"day": old.isoformat(), "moodLevel": -3})])
    conv = db.create_conversation("Work stress", "talk")
    db.set_summary(conv, "They felt criticised by their manager.")

    context = build_context(db, today, "2026-10-14T21:00:00+02:00", "Tomorrow 09:00 Team meeting", True)
    assert "To make people feel seen" in context
    assert "signaleringsplan" in context and "call my nurse" in context
    assert "crisis plan" not in context.lower().split("signaleringsplan")[0]
    assert "mood +2 moderate mania" in context
    assert "watch: sleep 4.2h" in context and "HRV status low" in context
    assert "Sleep by 23:00 | active | 40% done" in context
    assert "criticised by their manager" in context
    assert "Earlier weekly trends" in context and "mood avg -3.0" in context
    assert "Team meeting" in context
    assert "read aloud" in context

    # The conversation being continued is not listed as an "earlier" one.
    assert "criticised" not in build_context(db, today, None, "", False, conv)


def test_history_mentions_earlier_suggestions():
    history = history_for_model([
        {"role": "user", "content": "Help me plan", "suggestions": []},
        {"role": "assistant", "content": "Let's add a walk.",
         "suggestions": [{"kind": "event", "title": "Walk"}]},
    ])
    assert history[1]["content"].endswith("[Proposed in the app: event: Walk]")


def test_chat_streams_text_and_suggestions_and_persists():
    responses = [
        SimpleNamespace(stop_reason="tool_use", content=[
            text("Good plan."),
            tool_use("suggest_task", {"title": "Call Anna", "due": "2026-10-15T10:00", "notes": ""}),
            tool_use("suggest_flashcard", {"title": "Criticism", "trigger": "t", "schema": "s",
                                           "reality": "r", "action": "a"}, "toolu_2"),
            tool_use("suggest_goal", {"title": "", "details": "", "area": "", "targetDate": None}, "toolu_3"),
        ]),
        SimpleNamespace(stop_reason="end_turn", content=[text("I've added it as a card.")]),
    ]
    client, db, messages = make_client(responses)
    body = client.post("/api/coach/chat", headers=AUTH, json={
        "message": "I keep putting off calling Anna", "mode": "perspective",
        "localTime": "2026-10-14T20:00:00+02:00", "agenda": "No events",
    }).text
    events = read_sse(body)
    kinds = [kind for kind, _ in events]
    assert kinds[0] == "conversation" and kinds[-1] == "done"
    suggestions = [data for kind, data in events if kind == "suggestion"]
    assert [s["kind"] for s in suggestions] == ["task", "flashcard"]
    assert "".join(data["text"] for kind, data in events if kind == "text").startswith("Good plan.")

    # The invalid goal went back to the model as an error tool result.
    second_request = messages.requests[1]
    results = second_request["messages"][-1]["content"]
    assert [r.get("is_error", False) for r in results] == [False, False, True]
    assert second_request["fallbacks"] == "default"
    assert "Mode: making sense of a moment" in second_request["system"][1]["text"]

    conversation_id = events[0][1]["conversationId"]
    stored = client.get(f"/api/coach/conversations/{conversation_id}", headers=AUTH).json()
    assert stored["mode"] == "perspective"
    assert [m["role"] for m in stored["messages"]] == ["user", "assistant"]
    assert len(stored["messages"][1]["suggestions"]) == 2
    assert db.recent_summaries(None)[0]["summary"] == "They talked about work."


def test_chat_continues_conversation_with_history():
    responses = [
        SimpleNamespace(stop_reason="end_turn", content=[text("Hi, how are you?")]),
        SimpleNamespace(stop_reason="end_turn", content=[text("Tell me more.")]),
    ]
    client, _, messages = make_client(responses)
    first = read_sse(client.post("/api/coach/chat", headers=AUTH, json={"message": "Hello"}).text)
    conversation_id = first[0][1]["conversationId"]
    client.post("/api/coach/chat", headers=AUTH,
                json={"message": "Rough day", "conversationId": conversation_id})
    sent = messages.requests[-1]["messages"]
    assert [m["role"] for m in sent] == ["user", "assistant", "user"]
    assert sent[-1]["content"] == "Rough day"


def test_chat_refusal_and_unknown_conversation():
    responses = [SimpleNamespace(stop_reason="refusal", content=[])]
    client, _, _ = make_client(responses)
    events = read_sse(client.post("/api/coach/chat", headers=AUTH, json={"message": "x"}).text)
    assert ("error", {"message": "The coach could not answer this message."}) in events
    missing = client.post("/api/coach/chat", headers=AUTH, json={"message": "x", "conversationId": "nope"})
    assert missing.status_code == 404


def test_coach_disabled_without_key():
    app = create_app(Database(":memory:"), TOKEN, None, garmin_interval_minutes=0)
    response = TestClient(app).post("/api/coach/chat", headers=AUTH, json={"message": "hi"})
    assert response.status_code == 503


@pytest.mark.parametrize("mode", ["talk", "perspective", "why", "review"])
def test_every_mode_has_a_prompt(mode):
    coach, _ = fake_coach([])
    blocks = coach.system_blocks(mode, "ctx")
    assert blocks[1]["cache_control"] == {"type": "ephemeral"}
    assert "call 112" in blocks[0]["text"]


# MARK: - Assistant actions


def test_assistant_logs_day_event_and_goal():
    today = date.today().isoformat()
    responses = [
        SimpleNamespace(stop_reason="tool_use", content=[
            tool_use("log_day", {"day": today, "moodLevel": -1, "sleepHours": 6, "anxiety": None,
                                 "irritability": None, "mixed": None, "note": "Tired"}),
            tool_use("log_life_event", {"date": today, "title": "Job interview", "impact": 2,
                                        "details": ""}, "toolu_2"),
            tool_use("update_goal", {"goalId": "g1", "progress": 60, "status": None}, "toolu_3"),
            tool_use("update_goal", {"goalId": "missing", "progress": 10, "status": None}, "toolu_4"),
        ]),
        SimpleNamespace(stop_reason="end_turn", content=[text("Done.")]),
    ]
    client, db, messages = make_client(responses)
    db.apply_changes("entries", [(today, 1, False, {"day": today, "notes": "Morning walk", "anxiety": 2})])
    db.apply_changes("goals", [("g1", 1, False, {"id": "g1", "title": "Walk", "updatedAt": 1})])

    events = read_sse(client.post("/api/coach/chat", headers=AUTH, json={
        "message": "Log minus one, six hours sleep, tired. Had a job interview. Walking goal at 60.",
        "mode": "assistant", "spoken": True, "assistantName": "Friday",
    }).text)
    actions = [data["summary"] for kind, data in events if kind == "action"]
    assert len(actions) == 3

    entry = db.get_record("entries", today)
    assert entry["moodLevel"] == -1 and entry["sleepHours"] == 6
    assert entry["anxiety"] == 2  # untouched
    assert entry["notes"] == "Morning walk\nTired"
    assert [e["title"] for e in db.live_records("events")] == ["Job interview"]
    assert db.get_record("goals", "g1")["progress"] == 60

    results = messages.requests[1]["messages"][-1]["content"]
    assert results[-1]["is_error"] is True
    assert '"Friday"' in messages.requests[0]["system"][2]["text"]
    assert "Mode: personal assistant" in messages.requests[0]["system"][1]["text"]

    # Changes reach the phone through the normal sync.
    synced = client.post("/api/sync", json={"cursor": 2}, headers=AUTH).json()
    assert {e["day"] for e in synced["entries"]} == {today}
    assert len(synced["events"]) == 1 and synced["goals"][0]["progress"] == 60


def test_assistant_rejects_future_days():
    from app.actions import ActionError, execute

    with pytest.raises(ActionError):
        execute(Database(":memory:"), "log_day", {"day": "2999-01-01", "moodLevel": 1})
    with pytest.raises(ActionError):
        execute(Database(":memory:"), "log_day", {"day": "2026-01-01"})
