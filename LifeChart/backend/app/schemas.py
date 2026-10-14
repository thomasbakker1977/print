"""Wire format shared with the iOS app.

Field names are camelCase so they map 1:1 onto the Swift Codable structs.
`updatedAt` is epoch milliseconds; the newest write wins during sync.
"""

from typing import Literal

from pydantic import BaseModel, Field

DATE_PATTERN = r"^\d{4}-\d{2}-\d{2}$"


# Upper bound for timestamps (year 2100) so bogus values cannot pin a record forever.
MAX_TIMESTAMP_MS = 4_102_444_800_000
TEXT = 8000
MAX_RECORDS = 5000


class Dose(BaseModel):
    medicationId: str = Field(max_length=64)
    amount: float = Field(ge=0, le=100_000)


class SyncRecord(BaseModel):
    updatedAt: int = Field(ge=0, le=MAX_TIMESTAMP_MS)
    deleted: bool = False


class DayEntry(SyncRecord):
    day: str = Field(pattern=DATE_PATTERN)
    moodLevel: int | None = Field(default=None, ge=-4, le=4)
    moodRating: float | None = Field(default=None, ge=0, le=100)
    mixed: bool = False
    moodSwitches: int = Field(default=0, ge=0, le=50)
    sleepHours: float | None = Field(default=None, ge=0, le=24)
    anxiety: int = Field(default=0, ge=0, le=3)
    irritability: int = Field(default=0, ge=0, le=3)
    menstruating: bool = False
    weight: float | None = Field(default=None, ge=0, le=1000)
    notes: str = Field(default="", max_length=TEXT)
    doses: list[Dose] = Field(default=[], max_length=50)

    @property
    def key(self) -> str:
        return self.day


class Medication(SyncRecord):
    id: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=200)
    unit: str = Field(default="mg", max_length=20)
    defaultDose: float = Field(default=0, ge=0, le=100_000)
    active: bool = True
    colorIndex: int = 0

    @property
    def key(self) -> str:
        return self.id


class LifeEvent(SyncRecord):
    id: str = Field(min_length=1, max_length=64)
    date: str = Field(pattern=DATE_PATTERN)
    title: str = Field(min_length=1, max_length=200)
    impact: int = Field(default=0, ge=-4, le=4)
    details: str = Field(default="", max_length=TEXT)

    @property
    def key(self) -> str:
        return self.id


class Flashcard(SyncRecord):
    """A Schema Therapy flashcard to read when a familiar pattern is triggered."""

    id: str = Field(min_length=1, max_length=64)
    title: str = Field(min_length=1, max_length=200)
    trigger: str = Field(default="", max_length=TEXT)
    schema_: str = Field(default="", alias="schema", max_length=TEXT)
    reality: str = Field(default="", max_length=TEXT)
    action: str = Field(default="", max_length=TEXT)
    createdAt: int = Field(default=0, ge=0, le=MAX_TIMESTAMP_MS)

    model_config = {"populate_by_name": True, "serialize_by_alias": True}

    @property
    def key(self) -> str:
        return self.id


class WearableDay(SyncRecord):
    """Daily metrics pulled from Garmin Connect by the server (read-only for clients)."""

    day: str = Field(pattern=DATE_PATTERN)
    source: str = "garmin"
    sleepHours: float | None = None
    sleepScore: int | None = None
    restingHeartRate: int | None = None
    hrv: int | None = None
    hrvStatus: str | None = None
    stressAvg: int | None = None
    bodyBatteryHigh: int | None = None
    bodyBatteryLow: int | None = None
    steps: int | None = None

    @property
    def key(self) -> str:
        return self.day


class Goal(SyncRecord):
    id: str = Field(min_length=1, max_length=64)
    title: str = Field(min_length=1, max_length=200)
    details: str = Field(default="", max_length=TEXT)
    area: str = Field(default="", max_length=100)
    targetDate: str | None = Field(default=None, pattern=DATE_PATTERN)
    status: Literal["active", "achieved", "paused", "dropped"] = "active"
    progress: int = Field(default=0, ge=0, le=100)
    createdAt: int = Field(default=0, ge=0, le=MAX_TIMESTAMP_MS)

    @property
    def key(self) -> str:
        return self.id


class SyncRequest(BaseModel):
    cursor: int = Field(default=0, ge=0)
    entries: list[DayEntry] = Field(default=[], max_length=MAX_RECORDS)
    medications: list[Medication] = Field(default=[], max_length=MAX_RECORDS)
    events: list[LifeEvent] = Field(default=[], max_length=MAX_RECORDS)
    flashcards: list[Flashcard] = Field(default=[], max_length=MAX_RECORDS)
    goals: list[Goal] = Field(default=[], max_length=MAX_RECORDS)


class SyncResponse(BaseModel):
    cursor: int
    entries: list[DayEntry]
    medications: list[Medication]
    events: list[LifeEvent]
    flashcards: list[Flashcard]
    goals: list[Goal]
    wearables: list[WearableDay]


PROFILE_FIELDS = ("name", "aboutMe", "careHistory", "warningSigns", "crisisPlan", "myWhy", "coachStyle")


class Profile(BaseModel):
    """What the user tells the coach about themselves. Stored only on their server."""

    name: str = Field(default="", max_length=100)
    aboutMe: str = Field(default="", max_length=8000)
    # Diagnoses, treatments and care so far, in their own words.
    careHistory: str = Field(default="", max_length=20000)
    # Relapse prevention plan (signaleringsplan): early warning signs and agreed actions.
    warningSigns: str = Field(default="", max_length=20000)
    # Who to contact in a crisis and what helps.
    crisisPlan: str = Field(default="", max_length=8000)
    myWhy: str = Field(default="", max_length=4000)
    # How the user wants their coach to come across (e.g. a personality profile they like).
    coachStyle: str = Field(default="", max_length=8000)


CoachMode = Literal["talk", "perspective", "why", "review", "reflect", "assistant"]


class ImageAttachment(BaseModel):
    """A photo the user chose to share with the coach. Used for one reply, never stored."""

    mediaType: Literal["image/jpeg", "image/png"]
    # Base64, at most ~3 MB decoded; the app downsizes photos before sending.
    data: str = Field(min_length=1, max_length=4_000_000)


class ChatRequest(BaseModel):
    conversationId: str | None = None
    message: str = Field(min_length=1, max_length=20000)
    mode: CoachMode = "talk"
    spoken: bool = False
    # The phone's local time, e.g. "2026-10-14T21:30:00+02:00".
    localTime: str | None = Field(default=None, max_length=64)
    # Upcoming calendar events and open reminders, summarised on the phone.
    agenda: str = Field(default="", max_length=20000)
    assistantName: str = Field(default="Jarvis", min_length=1, max_length=40)
    images: list[ImageAttachment] = Field(default=[], max_length=4)


class SuggestedTask(BaseModel):
    kind: Literal["task"] = "task"
    title: str = Field(min_length=1, max_length=200)
    due: str | None = Field(default=None, max_length=32)
    notes: str = Field(default="", max_length=2000)


class SuggestedEvent(BaseModel):
    kind: Literal["event"] = "event"
    title: str = Field(min_length=1, max_length=200)
    start: str = Field(min_length=10, max_length=32)
    end: str = Field(min_length=10, max_length=32)
    notes: str = Field(default="", max_length=2000)


class SuggestedFlashcard(BaseModel):
    kind: Literal["flashcard"] = "flashcard"
    title: str = Field(min_length=1, max_length=200)
    trigger: str = Field(max_length=2000)
    schema_: str = Field(max_length=2000, alias="schema")
    reality: str = Field(max_length=2000)
    action: str = Field(max_length=2000)

    model_config = {"populate_by_name": True, "serialize_by_alias": True}


class SuggestedGoal(BaseModel):
    kind: Literal["goal"] = "goal"
    title: str = Field(min_length=1, max_length=200)
    details: str = Field(default="", max_length=2000)
    area: str = Field(default="", max_length=100)
    targetDate: str | None = Field(default=None, pattern=DATE_PATTERN)


Suggestion = SuggestedTask | SuggestedEvent | SuggestedFlashcard | SuggestedGoal


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str
    createdAt: int
    suggestions: list[Suggestion] = []


class Conversation(BaseModel):
    id: str
    title: str
    mode: CoachMode
    createdAt: int
    updatedAt: int


class ConversationDetail(Conversation):
    messages: list[ChatMessage]
