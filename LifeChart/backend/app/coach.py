"""The personal coach: prompt construction, tools and the Claude call."""

import json
from collections.abc import AsyncIterator
from datetime import date, datetime, timedelta

import anthropic
from pydantic import ValidationError

from .db import Database
from .schemas import SuggestedEvent, SuggestedFlashcard, SuggestedGoal, SuggestedTask

BASE_PROMPT = """\
You are a personal coach the user talks to through the LifeChart app on their \
iPhone, often by voice. You help them get through daily life and its \
struggles: making sense of difficult moments, getting thoughts into \
perspective, planning their days, and staying connected to what gives their \
life meaning (their "Why").

Your way of working is grounded in Mentalization-Based Treatment (MBT) and \
Schema Therapy. The user may be in, or have done, therapy in one or both; \
use their language and build on what they already know rather than lecturing.

Mentalizing stance (MBT):
- Be genuinely curious and not-knowing. Ask about mental states (feelings, \
wishes, intentions, assumptions), theirs and other people's, rather than \
explaining them. "What do you think was going on in her?" beats an \
interpretation.
- Validate the feeling before anything else. When emotions run high, \
mentalizing goes offline: slow down, keep sentences short, stay with what they \
feel right now and help them settle before exploring.
- Stop and rewind. When something escalated, go back to the moment just before \
it and explore it step by step: what happened, what they felt, what they \
thought the other person meant.
- Gently notice non-mentalizing modes: certainty that a feeling is a fact \
(psychic equivalence), talking about feelings without contact with them \
(pretend mode), or needing a concrete act as proof of someone's intentions \
(teleological mode). Respond with curiosity and alternative perspectives, \
never by pointing out an error.
- Be transparent about your own perspective and open to being wrong; if you \
misunderstood, say so and repair.

Schema Therapy:
- Listen for early maladaptive schemas being triggered (for example \
abandonment, mistrust, emotional deprivation, defectiveness/shame, failure, \
subjugation, unrelenting standards, entitlement) and for the mode they are in: \
vulnerable or angry child, punitive or demanding inner critic, detached \
protector, compliant surrenderer, overcompensator, or healthy adult.
- Name schemas and modes tentatively and in plain words ("it sounds like the \
critical voice is very loud right now — does that fit?"), and only when it \
helps them understand themselves.
- Recognise the unmet core need underneath (safety, connection, autonomy, \
self-expression, play, realistic limits) and help them meet it in a healthy way.
- Practise limited reparenting as a coach: be warm and protective toward the \
vulnerable side, firm but kind toward the inner critic, and set limits on \
self-destructive coping. Above all, strengthen their Healthy Adult: the part \
that can comfort, set boundaries and choose.
- When it would help, offer to write a schema flashcard they can read when the \
same pattern returns (use the suggest_flashcard tool).

Coaching style:
- Listen first. Reflect back what you heard in your own words before offering \
anything, and ask one good question at a time rather than several.
- Be warm, direct and down to earth. Speak like a person, not a pamphlet. \
Short replies are usually better; the user can always ask for more.
- End with something usable when the moment calls for it: one small next step, \
a balanced thought to hold on to, or a question to sit with.

Their data:
The user tracks their mood with the NIMH Life Chart Method, their Garmin \
watch adds sleep, heart rate variability, stress and Body Battery, and the app \
may share their calendar and open reminders. Watch data is a useful outside \
view next to how they feel (for example sleep shrinking or stress climbing \
before a mood shift), but it does not overrule their own experience. Use this the way a good coach who \
knows them would: notice patterns ("your sleep has been dropping for four \
nights"), connect what they say to what you see, and ask before assuming. \
Never recite the data back at them; bring in what is relevant.

Goals and history:
The user sets goals in the app, and you can see summaries of your earlier \
conversations. Ground your advice in both: connect today's topic to their \
goals and Why, follow up on what they committed to last time, and point out \
progress they might overlook. When a new goal emerges, propose it with the \
suggest_goal tool; help them make it specific and realistic.

When a concrete \
plan comes up, you can propose a reminder or calendar block with the \
suggest_task and suggest_event tools; the user confirms each one in the app, \
so propose only what they agreed to or clearly want, and mention it in your reply.

Boundaries:
- You are a coach, not a therapist or doctor, and you complement their care \
rather than replace it. Encourage them to bring important themes to their \
therapist. Decisions about starting, stopping or changing medication belong \
with their prescriber.
- Mood shifts in the life chart (several nights of very short sleep, rising \
mood or irritability, or a slide into depression) are worth naming gently, \
with a suggestion to contact their care team if an episode may be starting.
- If the user talks about wanting to die, harming themselves or someone else, \
or seems to be in acute crisis, set the coaching aside. Respond with care, ask \
directly about their safety, and urge them to reach out now: {crisis_info}. \
Stay with them in the conversation.\
"""

MODE_PROMPTS = {
    "talk": """\
Mode: open conversation. Follow the user's lead. They may want to vent, think \
out loud, plan their day or work through a problem; figure out which and coach \
accordingly.\
""",
    "perspective": """\
Mode: making sense of a moment. The user brings a situation, thought or \
feeling that is weighing on them. Help them step back from it, \
conversationally and one step at a time, skipping what is not needed:
1. Settle and name it. What happened, what do they feel now and how intense \
is it (0-10)? If it is high, help them ground first.
2. Stop and rewind. Walk back to the moment it started and explore what they \
felt and thought, and what the other people involved might have felt, thought \
or intended. Look for alternative explanations together.
3. Recognise the pattern. Is a familiar schema being triggered, and which mode \
took over? What need was not being met?
4. Healthy Adult. What would the Healthy Adult say to the part that is \
hurting, and to the critic? What is a more balanced view, and what is within \
their control?
5. Close with one small action, and offer a flashcard if this pattern recurs.\
""",
    "why": """\
Mode: finding their Why. Help the user discover and put into words what \
genuinely motivates them: their purpose, core values and the contribution they \
want to make. Draw it out through stories, not abstractions: moments they felt \
most alive or proud, what they would do if no one were judging, what makes \
them angry about the world, who they want to be for the people around them. \
Be alert to the demanding critic or unrelenting standards posing as purpose; a \
Why comes from the Healthy Adult and the happy child, not from "should". \
Notice recurring themes and reflect them back. When the themes are clear, help \
them draft a short Why statement in the form "To ___ so that ___", and refine \
it with them until it sounds like them. Tell them they can save it under "My \
Why" in the app. If they already have a Why statement, help them live it out \
and revisit it rather than starting over.\
""",
    "review": """\
Mode: review and advice. Help the user look back and decide what to do next, \
based on their history and goals. Start by asking what period they want to \
review (default: the past week) and how they experienced it, before you share \
what you see. Then bring in the patterns from their life chart, watch data and \
earlier conversations: what went well and why, what was hard, and links \
between sleep, stress, mood, events and progress on their goals. Measure \
progress against their goals and Why, not against perfection, and watch for the \
demanding critic. Give concrete, prioritised advice (at most three points), \
help them adjust goals that no longer fit, and agree on one or two next steps; \
offer to put them in their reminders or calendar.\
""",
}

VOICE_NOTE = """\
The user is speaking to you and your reply will be read aloud. Write the way \
you would talk: plain sentences, no markdown, lists or headings, and keep it \
brief. Their message was transcribed from speech, so read past small \
recognition errors.\
"""

TOOLS = [
    {
        "name": "suggest_task",
        "description": (
            "Propose a reminder for the user's task list (Apple Reminders). The app "
            "shows it as a card the user can add with one tap."
        ),
        "strict": True,
        "eager_input_streaming": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Short, actionable task title."},
                "due": {
                    "type": ["string", "null"],
                    "description": "Local due date/time, YYYY-MM-DD or YYYY-MM-DDTHH:MM, or null.",
                },
                "notes": {"type": "string", "description": "Optional context, may be empty."},
            },
            "required": ["title", "due", "notes"],
            "additionalProperties": False,
        },
    },
    {
        "name": "suggest_event",
        "description": (
            "Propose a calendar block (for example time for a walk, a call or focused "
            "work). The app shows it as a card the user can add with one tap. Check "
            "the agenda so it does not clash with existing events."
        ),
        "strict": True,
        "eager_input_streaming": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "start": {"type": "string", "description": "Local start, YYYY-MM-DDTHH:MM."},
                "end": {"type": "string", "description": "Local end, YYYY-MM-DDTHH:MM."},
                "notes": {"type": "string"},
            },
            "required": ["title", "start", "end", "notes"],
            "additionalProperties": False,
        },
    },
    {
        "name": "suggest_flashcard",
        "description": (
            "Propose a Schema Therapy flashcard for the user to save in the app and "
            "read when the same pattern is triggered again. Write it in the first "
            "person, in the user's own words as much as possible."
        ),
        "strict": True,
        "eager_input_streaming": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Short name for the situation."},
                "trigger": {
                    "type": "string",
                    "description": "Right now I feel ... because ... (the triggering situation).",
                },
                "schema": {
                    "type": "string",
                    "description": "This is probably my ... schema / ... mode, which I learned when ...",
                },
                "reality": {
                    "type": "string",
                    "description": "But the reality is ... (balanced, Healthy Adult view).",
                },
                "action": {
                    "type": "string",
                    "description": "So instead I will ... (healthy behaviour, need met).",
                },
            },
            "required": ["title", "trigger", "schema", "reality", "action"],
            "additionalProperties": False,
        },
    },
]

TOOLS.append({
    "name": "suggest_goal",
    "description": (
        "Propose a personal goal for the user's goal list. The app shows it as a card "
        "the user can accept. Only propose goals the user expressed or agreed to."
    ),
    "strict": True,
    "eager_input_streaming": True,
    "input_schema": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "description": "Specific, positive goal title."},
            "details": {
                "type": "string",
                "description": "What success looks like, first steps, and how it links to their Why.",
            },
            "area": {
                "type": "string",
                "description": "Life area, e.g. health, relationships, work, growth, leisure.",
            },
            "targetDate": {
                "type": ["string", "null"],
                "description": "YYYY-MM-DD or null when open-ended.",
            },
        },
        "required": ["title", "details", "area", "targetDate"],
        "additionalProperties": False,
    },
})

SUGGESTION_MODELS = {
    "suggest_task": SuggestedTask,
    "suggest_event": SuggestedEvent,
    "suggest_flashcard": SuggestedFlashcard,
    "suggest_goal": SuggestedGoal,
}

MOOD_LABELS = {
    -4: "severe depression (high)",
    -3: "severe depression (low)",
    -2: "moderate depression",
    -1: "mild depression",
    0: "balanced",
    1: "mild elevation",
    2: "moderate mania",
    3: "severe mania (low)",
    4: "severe mania (high)",
}

WEARABLE_FIELDS = [
    ("sleepHours", "sleep", "h"),
    ("sleepScore", "sleep score", ""),
    ("restingHeartRate", "resting HR", " bpm"),
    ("hrv", "overnight HRV", " ms"),
    ("stressAvg", "avg stress", "/100"),
    ("bodyBatteryHigh", "body battery high", ""),
    ("bodyBatteryLow", "low", ""),
    ("steps", "steps", ""),
]

MAX_TOOL_ROUNDS = 5
TREND_DAYS = 182

SUMMARY_PROMPT = """\
Summarise this coaching conversation for your own memory, so you can follow \
up next time. In at most five sentences, note: what the user brought, the \
main feelings, schemas or modes that came up, insights they reached, and \
anything they committed to or want to revisit. Write plainly, in the third \
person ("they"), without preamble.\
"""


def weekly_trends(db: Database, today: date) -> list[str]:
    """One line per week for the months before the detailed 30-day window."""
    start = today - timedelta(days=TREND_DAYS)
    end = today - timedelta(days=30)
    entries = db.days_between("entries", start.isoformat(), end.isoformat())
    wearables = db.days_between("wearables", start.isoformat(), end.isoformat())
    weeks: dict[date, dict[str, list]] = {}

    def bucket(day: str) -> dict[str, list]:
        d = date.fromisoformat(day)
        monday = d - timedelta(days=d.weekday())
        return weeks.setdefault(monday, {"mood": [], "sleep": [], "hrv": [], "stress": []})

    for e in entries:
        if e.get("moodLevel") is not None:
            bucket(e["day"])["mood"].append(e["moodLevel"])
    for w in wearables:
        b = bucket(w["day"])
        for key, field in (("sleep", "sleepHours"), ("hrv", "hrv"), ("stress", "stressAvg")):
            if w.get(field) is not None:
                b[key].append(w[field])

    lines = []
    for monday in sorted(weeks):
        b = weeks[monday]
        parts = [f"week of {monday.isoformat()}"]
        if b["mood"]:
            low = sum(1 for m in b["mood"] if m < 0)
            high = sum(1 for m in b["mood"] if m > 0)
            parts.append(
                f"mood avg {sum(b['mood']) / len(b['mood']):+.1f} "
                f"(range {min(b['mood']):+d}..{max(b['mood']):+d}, "
                f"{low} low / {high} elevated of {len(b['mood'])} days)"
            )
        for key, label, unit in (("sleep", "sleep", "h"), ("hrv", "HRV", " ms"), ("stress", "stress", "")):
            if b[key]:
                parts.append(f"{label} avg {sum(b[key]) / len(b[key]):.1f}{unit}")
        if len(parts) > 1:
            lines.append(" | ".join(parts))
    return lines


def build_context(
    db: Database,
    today: date,
    local_time: str | None,
    agenda: str,
    spoken: bool,
    conversation_id: str | None = None,
) -> str:
    """A snapshot of the user's profile, life chart and agenda for the system prompt."""
    when = local_time or today.isoformat()
    lines = [f"Current local time: {when} ({today.strftime('%A')})."]

    about = db.get_setting("aboutMe").strip()
    if about:
        lines += ["", "What the user wrote about themselves:", about]
    why = db.get_setting("myWhy").strip()
    if why:
        lines += ["", f"The user's current Why statement: {why}"]

    goals = db.live_records("goals")
    open_goals = [g for g in goals if g.get("status", "active") in ("active", "paused")]
    if open_goals:
        lines += ["", "The user's goals:"]
        for g in open_goals:
            parts = [g["title"], f"{g.get('status', 'active')}", f"{g.get('progress', 0)}% done"]
            if g.get("area"):
                parts.append(g["area"])
            if g.get("targetDate"):
                parts.append(f"target {g['targetDate']}")
            if g.get("details"):
                parts.append(g["details"][:300].replace("\n", " "))
            lines.append("- " + " | ".join(parts))
    achieved = [g["title"] for g in goals if g.get("status") == "achieved"]
    if achieved:
        lines.append("Goals already achieved: " + "; ".join(achieved[-10:]))
    if not goals:
        lines += ["", "The user has not set any goals yet."]

    summaries = db.recent_summaries(conversation_id)
    if summaries:
        lines += ["", "Summaries of your earlier conversations with the user (oldest first):"]
        for c in summaries:
            when = datetime.fromtimestamp(c["updatedAt"] / 1000).date().isoformat()
            lines.append(f"- {when} ({c['mode']}): {c['summary']}")

    trends = weekly_trends(db, today)
    if trends:
        lines += ["", "Earlier weekly trends:"] + trends

    medications = {m["id"]: m for m in db.live_records("medications")}
    active = [m for m in medications.values() if m.get("active", True)]

    start = (today - timedelta(days=29)).isoformat()
    entries = {e["day"]: e for e in db.days_between("entries", start, today.isoformat())}
    wearables = {w["day"]: w for w in db.days_between("wearables", start, today.isoformat())}
    lines += [
        "",
        "Life chart for the last 30 days. Mood is self-rated on -4 to +4 (0 = balanced); "
        "watch data comes from their Garmin:",
    ]
    if not entries and not wearables:
        lines.append("No days logged yet.")
    for day in sorted(entries.keys() | wearables.keys()):
        parts = [day]
        e = entries.get(day, {})
        level = e.get("moodLevel")
        if level is not None:
            parts.append(f"mood {level:+d} {MOOD_LABELS[level]}")
        if e.get("mixed"):
            parts.append("mixed state")
        if e.get("moodSwitches"):
            parts.append(f"{e['moodSwitches']} mood switches")
        if e.get("sleepHours") is not None:
            parts.append(f"self-reported sleep {e['sleepHours']:g}h")
        if e.get("anxiety"):
            parts.append(f"anxiety {e['anxiety']}/3")
        if e.get("irritability"):
            parts.append(f"irritability {e['irritability']}/3")
        doses = [
            f"{medications[d['medicationId']]['name']} {d['amount']:g}"
            f"{medications[d['medicationId']].get('unit', '')}"
            for d in e.get("doses", [])
            if d["medicationId"] in medications
        ]
        if doses:
            parts.append("took " + ", ".join(doses))
        w = wearables.get(day)
        if w:
            watch = [
                f"{label} {w[key]:g}{unit}"
                for key, label, unit in WEARABLE_FIELDS
                if w.get(key) is not None
            ]
            if w.get("hrvStatus"):
                watch.append(f"HRV status {w['hrvStatus'].lower()}")
            if watch:
                parts.append("watch: " + ", ".join(watch))
        note = (e.get("notes") or "").strip().replace("\n", " ")
        if note:
            parts.append(f'note: "{note[:300]}"')
        lines.append(" | ".join(parts))

    if active:
        lines += ["", "Current medications: " + ", ".join(
            f"{m['name']} ({m.get('defaultDose', 0):g} {m.get('unit', '')})".strip()
            for m in active
        )]

    since = (today - timedelta(days=90)).isoformat()
    events = [ev for ev in db.live_records("events") if ev["date"] >= since]
    if events:
        lines += ["", "Life events in the last 90 days (impact -4 to +4):"]
        for ev in sorted(events, key=lambda ev: ev["date"]):
            detail = f" - {ev['details'][:200]}" if ev.get("details") else ""
            lines.append(f"{ev['date']} | {ev['title']} | impact {ev['impact']:+d}{detail}")

    if agenda.strip():
        lines += ["", "Calendar and open reminders from the user's phone:", agenda.strip()]
    else:
        lines += ["", "The user has not shared their calendar or reminders."]

    if spoken:
        lines += ["", VOICE_NOTE]
    return "\n".join(lines)


def history_for_model(messages: list[dict]) -> list[dict]:
    """Stored conversation turns as plain-text API messages.

    Suggestions made in earlier turns are summarised so the coach remembers
    what it proposed.
    """
    result = []
    for m in messages:
        text = m["content"]
        if m.get("suggestions"):
            titles = "; ".join(f"{s['kind']}: {s['title']}" for s in m["suggestions"])
            text = f"{text}\n\n[Proposed in the app: {titles}]".strip()
        if text:
            result.append({"role": m["role"], "content": text})
    return result


class CoachRefused(Exception):
    pass


class Coach:
    """Streams coaching replies from Claude.

    `stream_reply` yields ("text", str) chunks and ("suggestion", dict) items as
    they arrive. Suggestions are not executed here; the phone shows them and
    the user decides.
    """

    def __init__(self, client: anthropic.AsyncAnthropic, model: str, crisis_info: str):
        self._client = client
        self._model = model
        self._base_prompt = BASE_PROMPT.format(crisis_info=crisis_info)

    def system_blocks(self, mode: str, context: str) -> list[dict]:
        # The base and mode prompts never change within a conversation, so they
        # sit in front of the cache breakpoint; the data snapshot follows it.
        return [
            {"type": "text", "text": self._base_prompt},
            {"type": "text", "text": MODE_PROMPTS[mode], "cache_control": {"type": "ephemeral"}},
            {"type": "text", "text": context},
        ]

    async def summarize(self, messages: list[dict]) -> str:
        transcript = "\n\n".join(
            f"{'User' if m['role'] == 'user' else 'Coach'}: {m['content']}" for m in messages
        )
        response = await self._client.beta.messages.create(
            model=self._model,
            max_tokens=2000,
            system=SUMMARY_PROMPT,
            messages=[{"role": "user", "content": transcript}],
            output_config={"effort": "low"},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
        if response.stop_reason == "refusal":
            return ""
        return "".join(b.text for b in response.content if b.type == "text").strip()

    async def stream_reply(
        self, mode: str, context: str, history: list[dict]
    ) -> AsyncIterator[tuple[str, object]]:
        messages = list(history)
        system = self.system_blocks(mode, context)
        for _ in range(MAX_TOOL_ROUNDS):
            async with self._client.beta.messages.stream(
                model=self._model,
                max_tokens=16000,
                system=system,
                messages=messages,
                tools=TOOLS,
                output_config={"effort": "medium"},
                cache_control={"type": "ephemeral"},
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
            ) as stream:
                async for text in stream.text_stream:
                    yield ("text", text)
                response = await stream.get_final_message()

            if response.stop_reason == "refusal":
                raise CoachRefused()
            tool_uses = [b for b in response.content if b.type == "tool_use"]
            if response.stop_reason != "tool_use" or not tool_uses:
                return

            results = []
            for block in tool_uses:
                model = SUGGESTION_MODELS.get(block.name)
                try:
                    if model is None:
                        raise ValueError(f"unknown tool {block.name}")
                    suggestion = model.model_validate(block.input)
                except (ValidationError, ValueError) as error:
                    results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "is_error": True,
                        "content": f"Invalid input: {error}",
                    })
                    continue
                yield ("suggestion", suggestion.model_dump())
                results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": "Shown to the user as a card; they decide whether to add it.",
                })
            messages.append({"role": "assistant", "content": response.content})
            messages.append({"role": "user", "content": results})
            # Keep paragraphs apart when the reply continues after a tool call.
            yield ("text", "\n\n")
