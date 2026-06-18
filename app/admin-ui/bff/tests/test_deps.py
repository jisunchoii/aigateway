import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from bff.auth import Principal
from bff.deps import TokenVerifier

ISSUER = "https://login.microsoftonline.com/tid/v2.0"
AUD = "api://bff"
ADMIN_GID = "group-admins"


@pytest.fixture
def keypair():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key


def _make_token(key, **over):
    claims = {
        "iss": ISSUER, "aud": AUD, "exp": int(time.time()) + 600,
        "oid": "u1", "name": "Ada", "groups": [ADMIN_GID],
    }
    claims.update(over)
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test-kid"})


def _verifier(key):
    # Inject the public key directly instead of fetching JWKS over the network.
    pub = key.public_key()
    return TokenVerifier(
        issuer=ISSUER, audience=AUD, admin_group=ADMIN_GID,
        key_resolver=lambda kid: pub,
    )


def test_verifier_accepts_valid_signed_token(keypair):
    v = _verifier(keypair)
    p = v.verify(_make_token(keypair))
    assert isinstance(p, Principal)
    assert p.is_admin is True


def test_verifier_rejects_tampered_token(keypair):
    v = _verifier(keypair)
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    bad = _make_token(other)  # signed by the wrong key
    with pytest.raises(jwt.exceptions.InvalidSignatureError):
        v.verify(bad)
