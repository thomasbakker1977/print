"""One-time interactive Garmin Connect login (handles two-factor codes).

    docker compose run --rm lifechart python -m app.garmin_login

Stores login tokens in the data volume; the server reuses them afterwards.
"""

import getpass
import os

from garminconnect import Garmin


def main() -> None:
    tokenstore = os.environ.get("GARMIN_TOKENSTORE", "/data/garmin-tokens")
    email = os.environ.get("GARMIN_EMAIL") or input("Garmin email: ")
    password = os.environ.get("GARMIN_PASSWORD") or getpass.getpass("Garmin password: ")
    api = Garmin(email, password, prompt_mfa=lambda: input("Garmin two-factor code: "))
    api.login(tokenstore)
    print(f"Logged in as {api.get_full_name()}; tokens saved to {tokenstore}")


if __name__ == "__main__":
    main()
