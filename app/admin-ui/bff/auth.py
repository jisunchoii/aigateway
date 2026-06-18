"""Entra ID access-token validation and admin gating.

`validate_claims` is pure (no network): given an already-decoded claims dict, it enforces
issuer/audience/expiry and derives admin status from the groups claim. The signature check and
JWKS fetch live in the FastAPI dependency (deps.py) which decodes the token then calls this.
"""
import time
from dataclasses import dataclass


class AuthError(Exception):
    """Token failed validation (401)."""


@dataclass(frozen=True)
class Principal:
    oid: str
    name: str
    is_admin: bool


def validate_claims(claims: dict, *, issuer: str, audience: str, admin_group: str) -> Principal:
    if claims.get("iss") != issuer:
        raise AuthError("issuer mismatch")
    # aud may be the app id URI or the bare client id depending on token version, and per
    # RFC 7519 may be a single string OR a list (Entra issues multi-audience tokens). Accept
    # the configured audience in either form, in either shape.
    aud = claims.get("aud")
    aud_values = aud if isinstance(aud, list) else [aud]
    if audience not in aud_values and audience.removeprefix("api://") not in aud_values:
        raise AuthError("audience mismatch")
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)) or exp < time.time():
        raise AuthError("token expired")
    oid = claims.get("oid") or claims.get("sub")
    if not oid:
        raise AuthError("no subject")
    # NOTE: Entra omits 'groups' for users in >150 groups ("overage"); is_admin will be False
    # (fail-closed). See entra_team_claim caveat in infra/variables.tf.
    groups = claims.get("groups") or []
    return Principal(
        oid=oid,
        name=claims.get("name", oid),
        is_admin=admin_group in groups,
    )
