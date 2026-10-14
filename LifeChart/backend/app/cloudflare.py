"""Verifies that requests came through Cloudflare Access.

When CF_ACCESS_TEAM_DOMAIN and CF_ACCESS_AUD are set, every API request must
carry a valid `Cf-Access-Jwt-Assertion` header signed by your Cloudflare
Zero Trust team. Combined with a Cloudflare Tunnel (no published ports), the
API is only reachable through Cloudflare.
"""

import jwt
from jwt import PyJWKClient


class AccessVerifier:
    def __init__(self, team_domain: str, audience: str):
        team_domain = team_domain.removeprefix("https://").rstrip("/")
        self._issuer = f"https://{team_domain}"
        self._audience = audience
        self._keys = PyJWKClient(f"{self._issuer}/cdn-cgi/access/certs", cache_keys=True)

    def verify(self, token: str | None) -> bool:
        if not token:
            return False
        try:
            key = self._keys.get_signing_key_from_jwt(token)
            jwt.decode(
                token,
                key.key,
                algorithms=["RS256"],
                audience=self._audience,
                issuer=self._issuer,
            )
            return True
        except jwt.PyJWTError:
            return False
