"""Tools the assistant executes directly on the user's data.

These cover things the user asks for in so many words ("log my mood as -1",
"I slept six hours"). Each write gets a fresh timestamp so it syncs to the
phone like any other edit.
"""

import uuid
from datetime import date, timedelta

from pydantic import BaseModel, Field, ValidationError

from .db import Database, now_ms
from .schemas import DATE_PATTERN, DayEntry, Goal, LifeEvent

# The assistant may only write recent days; older history is edited in the app.
LOG_WINDOW_DAYS = 7

ACTION_TOOLS = [
    {
        "name": "log_day",
        "description": (
            "Record what the user tells you about a day in their life chart: mood level, "
            "sleep, anxiety, irritability, mixed state or a note. Only use it when the user "
            "asks you to log something or clearly states it for their chart. Fields left "
            "null are not changed; a note is appended to the day's notes. Only today and "
            "the previous 7 days can be logged."
        ),
        "strict": True,
        "eager_input_streaming": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "day": {"type": "string", "description": "YYYY-MM-DD; today unless the user says otherwise."},
                "moodLevel": {
                    "type": ["integer", "null"],
                    "description": "NIMH Life Chart level -4..+4 (0 balanced, negative depressed, positive elevated).",
                },
                "sleepHours": {"type": ["number", "null"]},
                "anxiety": {"type": ["integer", "null"], "description": "0 none .. 3 severe."},
                "irritability": {"type": ["integer", "null"], "description": "0 none .. 3 severe."},
                "mixed": {"type": ["boolean", "null"]},
                "note": {"type": ["string", "null"], "description": "Text to add to the day's notes."},
            },
            "required": ["day", "moodLevel", "sleepHours", "anxiety", "irritability", "mixed", "note"],
            "additionalProperties": False,
        },
    },
    {
        "name": "log_life_event",
        "description": "Add a life event (something that happened that may affect mood) to the life chart.",
        "strict": True,
        "eager_input_streaming": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "date": {"type": "string", "description": "YYYY-MM-DD"},
                "title": {"type": "string"},
                "impact": {"type": "integer", "description": "-4 very negative .. +4 very positive."},
                "details": {"type": "string"},
            },
            "required": ["date", "title", "impact", "details"],
            "additionalProperties": False,
        },
    },
    {
        "name": "update_goal",
        "description": (
            "Update progress or status of one of the user's existing goals, identified by "
            "the goal id shown in the context. Only when the user asks for it."
        ),
        "strict": True,
        "eager_input_streaming": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "goalId": {"type": "string"},
                "progress": {"type": ["integer", "null"], "description": "0..100"},
                "status": {
                    "type": ["string", "null"],
                    "description": "active, paused, achieved or dropped; null to keep.",
                },
            },
            "required": ["goalId", "progress", "status"],
            "additionalProperties": False,
        },
    },
]


class LogDay(BaseModel):
    day: str = Field(pattern=DATE_PATTERN)
    moodLevel: int | None = Field(default=None, ge=-4, le=4)
    sleepHours: float | None = Field(default=None, ge=0, le=24)
    anxiety: int | None = Field(default=None, ge=0, le=3)
    irritability: int | None = Field(default=None, ge=0, le=3)
    mixed: bool | None = None
    note: str | None = Field(default=None, max_length=4000)


class LogLifeEvent(BaseModel):
    date: str = Field(pattern=DATE_PATTERN, max_length=10)
    title: str = Field(min_length=1, max_length=200)
    impact: int = Field(ge=-4, le=4)
    details: str = Field(default="", max_length=2000)


class UpdateGoal(BaseModel):
    goalId: str
    progress: int | None = Field(default=None, ge=0, le=100)
    status: str | None = Field(default=None, pattern="^(active|paused|achieved|dropped)$")


class ActionError(Exception):
    pass


def execute(db: Database, name: str, tool_input: dict) -> str:
    """Runs an action tool and returns a short human-readable summary."""
    try:
        if name == "log_day":
            return _log_day(db, LogDay.model_validate(tool_input))
        if name == "log_life_event":
            return _log_life_event(db, LogLifeEvent.model_validate(tool_input))
        if name == "update_goal":
            return _update_goal(db, UpdateGoal.model_validate(tool_input))
    except ValidationError as error:
        raise ActionError(f"Invalid input: {error}") from error
    raise ActionError(f"Unknown tool {name}")


def _timestamp(existing: dict | None) -> int:
    """Newer than both the clock and the stored record, so the write always wins."""
    return max(now_ms(), (existing or {}).get("updatedAt", 0) + 1)


def _save(db: Database, kind: str, key: str, updated_at: int, data: dict) -> None:
    if db.apply_changes(kind, [(key, updated_at, False, data)]) == 0:
        raise ActionError("The change could not be saved.")


def _log_day(db: Database, args: LogDay) -> str:
    day = date.fromisoformat(args.day)
    today = date.today()
    if day > today:
        raise ActionError("Cannot log a day in the future.")
    if day < today - timedelta(days=LOG_WINDOW_DAYS):
        raise ActionError("Only the last 7 days can be logged by voice; edit older days in the app.")
    existing = db.get_record("entries", args.day)
    base = existing if existing and not existing.get("deleted") else {"day": args.day}
    entry = DayEntry.model_validate({**base, "updatedAt": _timestamp(existing), "deleted": False})
    changes = []
    for field in ("moodLevel", "sleepHours", "anxiety", "irritability", "mixed"):
        value = getattr(args, field)
        if value is not None:
            setattr(entry, field, value)
            changes.append(f"{field} {value}")
    if args.note:
        entry.notes = f"{entry.notes}\n{args.note}".strip() if entry.notes else args.note
        changes.append("note")
    if not changes:
        raise ActionError("Nothing to log.")
    _save(db, "entries", entry.day, entry.updatedAt, entry.model_dump())
    return f"Logged {', '.join(changes)} for {args.day}"


def _log_life_event(db: Database, args: LogLifeEvent) -> str:
    event = LifeEvent(id=str(uuid.uuid4()), updatedAt=now_ms(), **args.model_dump())
    _save(db, "events", event.id, event.updatedAt, event.model_dump())
    return f"Added life event '{args.title}' on {args.date}"


def _update_goal(db: Database, args: UpdateGoal) -> str:
    existing = db.get_record("goals", args.goalId)
    if existing is None or existing.get("deleted"):
        raise ActionError("No goal with that id.")
    goal = Goal.model_validate({**existing, "updatedAt": _timestamp(existing)})
    if args.progress is not None:
        goal.progress = args.progress
    if args.status is not None:
        goal.status = args.status
    _save(db, "goals", goal.id, goal.updatedAt, goal.model_dump())
    return f"Updated goal '{goal.title}': {goal.progress}% {goal.status}"
