import time

import pytest

from bff.auth import AuthError, Principal, validate_claims

ISSUER = "https://login.microsoftonline.com/tid/v2.0"
AUD = "api://bff"
ADMIN_GID = "group-admins"


def _claims(**over):
    base = {
        "iss": ISSUER,
        "aud": AUD,
        "exp": int(time.time()) + 600,
        "oid": "user-123",
        "name": "Ada Admin",
        "groups": [ADMIN_GID],
    }
    base.update(over)
    return base


def test_valid_admin_token_yields_admin_principal():
    p = validate_claims(_claims(), issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID)
    assert isinstance(p, Principal)
    assert p.oid == "user-123"
    assert p.name == "Ada Admin"
    assert p.is_admin is True


def test_valid_non_admin_token_is_not_admin():
    p = validate_claims(
        _claims(groups=["some-other-group"]),
        issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID,
    )
    assert p.is_admin is False


def test_missing_groups_claim_is_not_admin():
    c = _claims()
    del c["groups"]
    p = validate_claims(c, issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID)
    assert p.is_admin is False


def test_wrong_audience_rejected():
    with pytest.raises(AuthError):
        validate_claims(_claims(aud="api://other"), issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID)


def test_wrong_issuer_rejected():
    with pytest.raises(AuthError):
        validate_claims(
            _claims(iss="https://evil/v2.0"),
            issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID,
        )


def test_expired_token_rejected():
    with pytest.raises(AuthError):
        validate_claims(
            _claims(exp=int(time.time()) - 10),
            issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID,
        )


def test_bare_audience_accepted():
    bare = AUD.removeprefix("api://")
    p = validate_claims(_claims(aud=bare), issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID)
    assert p.oid == "user-123"


def test_aud_as_list_accepted():
    p = validate_claims(
        _claims(aud=[AUD, "00000003-0000-0000-c000-000000000002"]),
        issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID,
    )
    assert p.oid == "user-123"


def test_missing_exp_rejected():
    c = _claims()
    del c["exp"]
    with pytest.raises(AuthError):
        validate_claims(c, issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID)
