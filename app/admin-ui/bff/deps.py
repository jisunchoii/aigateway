"""FastAPI auth dependencies: verify the Entra access token's signature against the tenant
JWKS, then apply pure claim validation. require_admin enforces the admin group (403)."""
from typing import Callable

import jwt
from jwt.exceptions import PyJWKClientError
from fastapi import Depends, Header, HTTPException

from bff.auth import AuthError, Principal, validate_claims
from bff.config import Settings


class TokenVerifier:
    """Verifies RS256 signature + claims. key_resolver(kid) -> public key (injectable for tests)."""

    def __init__(self, *, issuer: str, audience: str, admin_group: str,
                 key_resolver: Callable[[str], object]):
        self._issuer = issuer
        self._audience = audience
        self._admin_group = admin_group
        self._key_resolver = key_resolver

    def verify(self, token: str) -> Principal:
        header = jwt.get_unverified_header(token)
        key = self._key_resolver(header.get("kid", ""))
        # PyJWT checks signature + exp; accept both aud forms (validate_claims re-checks).
        claims = jwt.decode(
            token, key, algorithms=["RS256"],
            audience=[self._audience, self._audience.removeprefix("api://")],
            issuer=self._issuer,
            options={"verify_aud": True},
        )
        return validate_claims(
            claims, issuer=self._issuer, audience=self._audience,
            admin_group=self._admin_group,
        )


def _jwks_resolver(jwks_uri: str) -> Callable[[str], object]:
    client = jwt.PyJWKClient(jwks_uri)
    return lambda kid: client.get_signing_key(kid).key


def build_verifier(settings: Settings) -> TokenVerifier:
    return TokenVerifier(
        issuer=settings.issuer,
        audience=settings.bff_api_audience,
        admin_group=settings.admin_group_object_id,
        key_resolver=_jwks_resolver(settings.jwks_uri),
    )


# Wired in main.py via dependency_overrides-friendly accessors.
def get_verifier() -> TokenVerifier:  # pragma: no cover - overridden in app startup
    raise RuntimeError("verifier not configured")


def current_principal(
    authorization: str = Header(default=""),
    verifier: TokenVerifier = Depends(get_verifier),
) -> Principal:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return verifier.verify(token)
    except AuthError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except PyJWKClientError:
        # JWKS endpoint unreachable/unparseable is a transient infra failure, not a bad token.
        raise HTTPException(status_code=503, detail="unable to validate token")
    except Exception:
        raise HTTPException(status_code=401, detail="invalid token")


def require_admin(principal: Principal = Depends(current_principal)) -> Principal:
    if not principal.is_admin:
        raise HTTPException(status_code=403, detail="admin group membership required")
    return principal
