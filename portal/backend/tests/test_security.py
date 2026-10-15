import pytest
from fastapi import HTTPException

from app.security import (
    hash_password,
    verify_password,
    create_access_token,
    decode_token,
)


def test_hash_and_verify_password():
    h = hash_password("s3cret")
    assert h != "s3cret"
    assert verify_password("s3cret", h) is True
    assert verify_password("wrong", h) is False


def test_token_roundtrip():
    token = create_access_token("user@example.com")
    assert decode_token(token) == "user@example.com"


def test_decode_invalid_token_raises():
    with pytest.raises(HTTPException):
        decode_token("not-a-token")
