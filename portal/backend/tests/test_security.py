import pytest
from fastapi import HTTPException

import jwt

from app.config import get_settings
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


def test_decode_token_missing_sub_raises_401():
    s = get_settings()
    token = jwt.encode({"exp": 9999999999}, s.jwt_secret_key, algorithm=s.jwt_algorithm)
    with pytest.raises(HTTPException) as exc_info:
        decode_token(token)
    assert exc_info.value.status_code == 401
