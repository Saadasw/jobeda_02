"""
Security primitives: password hashing, token hashing, and JWT access tokens.

- Passwords  → bcrypt (matches users.password_hash format `$2b$...`).
- Secret tokens (invitations, refresh tokens, password resets) → stored as
  SHA-256 hex digests. The plaintext is returned to the caller exactly once
  and never persisted (see migration 020).
- Access tokens → short-lived JWTs (HS256).
"""
import hashlib
import os
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional

import bcrypt
import jwt

# ─── Config ──────────────────────────────────────────────────────────────────
JWT_SECRET: str = os.environ.get("JWT_SECRET", "dev-insecure-secret-change-me")
JWT_ALGORITHM: str = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES: int = int(os.environ.get("ACCESS_TOKEN_EXPIRE_MINUTES", "30"))
REFRESH_TOKEN_EXPIRE_DAYS: int = int(os.environ.get("REFRESH_TOKEN_EXPIRE_DAYS", "30"))

# bcrypt only hashes the first 72 bytes of input.
_BCRYPT_MAX_BYTES = 72


# ─── Passwords ───────────────────────────────────────────────────────────────
def hash_password(password: str) -> str:
    """Hash a plaintext password with bcrypt. Returns the `$2b$...` string."""
    pw = password.encode("utf-8")[:_BCRYPT_MAX_BYTES]
    return bcrypt.hashpw(pw, bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    """Constant-time check of a plaintext password against a stored bcrypt hash."""
    try:
        pw = password.encode("utf-8")[:_BCRYPT_MAX_BYTES]
        return bcrypt.checkpw(pw, password_hash.encode("utf-8"))
    except (ValueError, TypeError):
        return False


# ─── Opaque secret tokens (invites / refresh / reset) ────────────────────────
def generate_secret_token(n_bytes: int = 32) -> str:
    """Return a URL-safe random secret. Show to the recipient once; store only its hash."""
    return secrets.token_urlsafe(n_bytes)


def hash_token(token: str) -> str:
    """SHA-256 hex digest used for storing/looking up opaque tokens."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


# ─── JWT access tokens ───────────────────────────────────────────────────────
def create_access_token(
    *,
    user_id: str,
    tenant_id: str,
    role: str,
    expires_minutes: Optional[int] = None,
) -> str:
    """Mint a signed JWT carrying the user id, tenant id, and role name."""
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=expires_minutes if expires_minutes is not None else ACCESS_TOKEN_EXPIRE_MINUTES
    )
    payload = {
        "sub": str(user_id),
        "tenant_id": str(tenant_id),
        "role": role,
        "type": "access",
        "exp": expire,
        "iat": datetime.now(timezone.utc),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_access_token(token: str) -> dict:
    """Decode and verify a JWT. Raises jwt.PyJWTError on failure."""
    return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])


def refresh_token_expiry() -> datetime:
    """Absolute expiry timestamp for a newly issued refresh token."""
    return datetime.now(timezone.utc) + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
