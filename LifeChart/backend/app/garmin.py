"""Pulls daily health metrics from Garmin Connect into the life chart.

Uses the unofficial `garminconnect` library with the user's own account.
Login tokens are cached in the data volume, so the password is only needed
for the first login (run `python -m app.garmin_login` once if your account
uses two-factor authentication).
"""

import asyncio
import json
import logging
import threading
import time
from collections.abc import Callable
from datetime import date, timedelta
from typing import Any

from .db import Database, now_ms
from .schemas import WearableDay

log = logging.getLogger("lifechart.garmin")

BACKFILL_DAYS = 30
REFRESH_DAYS = 3


def _int(value: Any) -> int | None:
    try:
        return int(round(float(value))) if value is not None else None
    except (TypeError, ValueError):
        return None


def _dig(data: Any, *path: str) -> Any:
    for key in path:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


def parse_day(day: str, stats: Any, sleep: Any, hrv: Any) -> dict:
    """Map Garmin's API payloads onto the WearableDay fields."""
    sleep_seconds = _dig(sleep, "dailySleepDTO", "sleepTimeSeconds")
    record = WearableDay(
        day=day,
        updatedAt=0,
        sleepHours=round(sleep_seconds / 3600, 1) if sleep_seconds else None,
        sleepScore=_int(_dig(sleep, "dailySleepDTO", "sleepScores", "overall", "value")),
        restingHeartRate=_int(_dig(stats, "restingHeartRate")),
        hrv=_int(_dig(hrv, "hrvSummary", "lastNightAvg")),
        hrvStatus=_dig(hrv, "hrvSummary", "status"),
        stressAvg=_int(_dig(stats, "averageStressLevel")),
        bodyBatteryHigh=_int(_dig(stats, "bodyBatteryHighestValue")),
        bodyBatteryLow=_int(_dig(stats, "bodyBatteryLowestValue")),
        steps=_int(_dig(stats, "totalSteps")),
    )
    data = record.model_dump()
    # Garmin reports -1/-2 for "no stress data"; drop those.
    if data["stressAvg"] is not None and data["stressAvg"] < 0:
        data["stressAvg"] = None
    return data


def _has_data(record: dict) -> bool:
    ignored = {"day", "source", "updatedAt", "deleted"}
    return any(v is not None for k, v in record.items() if k not in ignored)


class GarminSync:
    def __init__(
        self,
        db: Database,
        email: str | None,
        password: str | None,
        tokenstore: str,
        client_factory: Callable[..., Any] | None = None,
    ):
        self._db = db
        self._email = email
        self._password = password
        self._tokenstore = tokenstore
        self._client_factory = client_factory
        self._api = None
        self._lock = threading.Lock()
        self._retry_after = 0.0
        self._failures = 0
        self.last_sync: int | None = None
        self.last_error: str | None = None

    @property
    def enabled(self) -> bool:
        return self._client_factory is not None

    def status(self) -> dict:
        return {
            "enabled": self.enabled,
            "lastSync": self.last_sync,
            "lastError": self.last_error,
        }

    def _login(self):
        if self._api is None:
            api = self._client_factory(self._email, self._password)
            api.login(self._tokenstore)
            self._api = api
        return self._api

    def sync(self, today: date | None = None) -> int:
        """Fetch recent days; returns the number of days that changed. Blocking.

        Concurrent calls return immediately, and repeated failures back off so
        a wrong password does not lock the Garmin account.
        """
        if time.monotonic() < self._retry_after:
            return 0
        if not self._lock.acquire(blocking=False):
            return 0
        try:
            return self._sync(today or date.today())
        finally:
            self._lock.release()

    def _sync(self, today: date) -> int:
        try:
            api = self._login()
            backfill = not self._db.live_records("wearables")
            days = BACKFILL_DAYS if backfill else REFRESH_DAYS
            changed = []
            for offset in range(days):
                day = (today - timedelta(days=offset)).isoformat()
                record = parse_day(
                    day,
                    api.get_stats(day),
                    api.get_sleep_data(day),
                    api.get_hrv_data(day),
                )
                if not _has_data(record):
                    continue
                existing = self._db.get_record("wearables", day)
                if existing is not None:
                    comparable = {**existing, "updatedAt": 0}
                    if json.dumps(comparable, sort_keys=True) == json.dumps(record, sort_keys=True):
                        continue
                record["updatedAt"] = now_ms()
                changed.append((day, record["updatedAt"], False, record))
            self._db.apply_changes("wearables", changed)
            self.last_sync = now_ms()
            self.last_error = None
            self._failures = 0
            return len(changed)
        except Exception as error:  # network, auth or API changes on Garmin's side
            self._api = None
            self._failures += 1
            self._retry_after = time.monotonic() + min(3600 * 6, 300 * 2 ** self._failures)
            self.last_error = f"Garmin sync failed ({type(error).__name__}); see server logs"
            log.warning("Garmin sync failed: %s: %s", type(error).__name__, error)
            return 0


async def run_periodically(garmin: GarminSync, interval_minutes: int) -> None:
    while True:
        changed = await asyncio.to_thread(garmin.sync)
        log.info("Garmin sync: %d day(s) updated", changed)
        await asyncio.sleep(interval_minutes * 60)
