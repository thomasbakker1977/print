"""Tools the assistant executes directly on the user's data.

These cover things the user asks for in so many words ("log my mood as -1",
"I slept six hours"). Each write gets a fresh timestamp so it syncs to the
phone like any other edit.
"""

import uuid
from datetime import date

from pydantic import BaseModel, Field, ValidationError

from .db import Database, now_ms
from .schemas import DATE_PATTERN, DayEntry, Goal, LifeEvent

ACTION_TOOLS = [
    {
        "name": "log_day",
        "description": (
            "Record what the user tells you about a day in their life chart: mood level, "
            "sleep, anxiety, irritability, mixed state or a note. Only use it when the user "
            "asks you to log something or clearly states it for their chart. Fields left "
            "null are not changed; a note is appended to the day's notes."
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
    date: str = Field(pattern=DATE_PATTERN)
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


def _log_day(db: Database, args: LogDay) -> str:
    if date.fromisoformat(args.day) > date.today():
        raise ActionError("Cannot log a day in the future.")
    existing = db.get_record("entries", args.day) or {"day": args.day}
    entry = DayEntry.model_validate({**existing, "updatedAt": now_ms(), "deleted": False})
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
    db.apply_changes("entries", [(entry.day, entry.updatedAt, False, entry.model_dump())])
    return f"Logged {', '.join(changes)} for {args.day}"


def _log_life_event(db: Database, args: LogLifeEvent) -> str:
    event = LifeEvent(id=str(uuid.uuid4()), updatedAt=now_ms(), **args.model_dump())
    db.apply_changes("events", [(event.id, event.updatedAt, False, event.model_dump())])
    return f"Added life event '{args.title}' on {args.date}"


def _update_goal(db: Database, args: UpdateGoal) -> str:
    existing = db.get_record("goals", args.goalId)
    if existing is None or existing.get("deleted"):
        raise ActionError("No goal with that id.")
    goal = Goal.model_validate({**existing, "updatedAt": now_ms()})
    if args.progress is not None:
        goal.progress = args.progress
    if args.status is not None:
        goal.status = args.status
    db.apply_changes("goals", [(goal.id, goal.updatedAt, False, goal.model_dump())])
    return f"Updated goal '{goal.title}': {goal.progress}% {goal.status}"
