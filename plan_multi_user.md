# Multi-User Architecture Plan

> **Goal:** Enable multiple users per tenant (madrasa), with custom authentication fully independent of Supabase Auth.
>
> **Auth strategy:** bcrypt for password hashing + PyJWT for token generation — zero dependency on Supabase Auth.
>
> **Depends on:** `plan_multi_tenant.md` — tenant_id must exist before users can be assigned to tenants.

---

## Current State

- Auth is a placeholder — `/me` returns a static message
- No JWT validation on any endpoint
- No user table in the database
- No password hashing
- All endpoints are publicly accessible (no authentication required)
- `created_by` / `updated_by` fields exist on tables but are never populated
- Supabase is used only as a PostgreSQL database (not for auth)

---

## Auth Stack (Platform-Independent)

| Concern | Solution | Library |
|---------|----------|---------|
| Password hashing | bcrypt (adaptive, salt built-in) | `bcrypt` |
| Token generation | JWT (JSON Web Tokens) | `PyJWT` |
| Token validation | Decode + verify signature | `PyJWT` |
| Secret management | `.env` file | `python-dotenv` |
| Middleware | FastAPI dependency injection | built-in |

### Why NOT Supabase Auth?

- **Portability:** Can switch from Supabase to raw PostgreSQL, Neon, PlanetScale, etc.
- **Control:** Full control over password policies, token expiry, session management
- **Simplicity:** No need to learn Supabase Auth API, custom claims, `app_metadata` patterns
- **Cost:** No dependence on Supabase's auth tier limits

### New Dependencies

```
# Add to requirements.txt
bcrypt
PyJWT
```

---

## User-Tenant Relationship

```
Tenant (Madrasa)
├── User: Owner (1 per tenant, created at registration)
├── User: Admin (invited by owner)
├── User: Accountant (invited by owner/admin)
├── User: Teacher (invited by owner/admin)
└── User: Viewer (invited by anyone with invite permission)
```

A user belongs to **exactly one tenant**. The `tenant_id` is stored in the `users` table.

> [!NOTE]
> If multi-tenant-per-user is needed later (e.g., a consultant managing 3 madrasas), a `user_tenants` junction table can be added. For now, 1 user = 1 tenant.

---

## Schema Changes

### New Table: `users`

Our own users table — completely independent of Supabase `auth.users`:

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    full_name TEXT NOT NULL,
    phone TEXT,
    role TEXT NOT NULL DEFAULT 'viewer'
        CHECK (role IN ('owner', 'admin', 'accountant', 'teacher', 'viewer')),
    is_active BOOLEAN DEFAULT TRUE,
    last_login TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP NULL
);

CREATE INDEX idx_users_tenant ON users(tenant_id);
CREATE INDEX idx_users_email ON users(email);
```

### New Table: `invitations`

```sql
CREATE TABLE invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    email TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'viewer'
        CHECK (role IN ('admin', 'accountant', 'teacher', 'viewer')),
    invited_by UUID NOT NULL REFERENCES users(id),
    token TEXT NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(32), 'hex'),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
    expires_at TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    accepted_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_invitations_tenant ON invitations(tenant_id);
CREATE INDEX idx_invitations_token ON invitations(token);
```

### Optional: `refresh_tokens` table

For secure token refresh without re-authentication:

```sql
CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,               -- bcrypt hash of the refresh token
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    revoked_at TIMESTAMP
);

CREATE INDEX idx_refresh_tokens_user ON refresh_tokens(user_id);
```

---

## JWT Structure

Our custom JWT payload:

```json
{
    "sub": "user-uuid",
    "tenant_id": "tenant-uuid",
    "role": "owner",
    "email": "admin@jobeda.com",
    "name": "Abdul Karim",
    "iat": 1735600000,
    "exp": 1735686400
}
```

### Token Lifecycle

| Token | Lifetime | Storage | Purpose |
|-------|----------|---------|---------|
| Access token | 24 hours (configurable) | Frontend memory / localStorage | API authorization |
| Refresh token | 30 days | httpOnly cookie or secure storage | Get new access token |

---

## Application Layer Implementation

### 1. Auth Utilities: `services/auth_service.py`

```python
"""
Authentication service — password hashing and JWT management.
Zero dependency on Supabase Auth.
"""
import os
import bcrypt
import jwt
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv

load_dotenv()

JWT_SECRET = os.environ.get("JWT_SECRET", "change-me-in-production")
JWT_ALGORITHM = os.environ.get("JWT_ALGORITHM", "HS256")
JWT_EXPIRY_HOURS = int(os.environ.get("JWT_EXPIRY_HOURS", "24"))


# ─── Password Hashing ────────────────────────────────────────────────

def hash_password(plain_password: str) -> str:
    """Hash a password using bcrypt."""
    salt = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(plain_password.encode("utf-8"), salt).decode("utf-8")


def verify_password(plain_password: str, hashed: str) -> bool:
    """Verify a password against its bcrypt hash."""
    return bcrypt.checkpw(
        plain_password.encode("utf-8"),
        hashed.encode("utf-8"),
    )


# ─── JWT Token Management ────────────────────────────────────────────

def create_access_token(user_id: str, tenant_id: str, role: str,
                        email: str, name: str) -> str:
    """Create a signed JWT access token."""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "tenant_id": tenant_id,
        "role": role,
        "email": email,
        "name": name,
        "iat": now,
        "exp": now + timedelta(hours=JWT_EXPIRY_HOURS),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_token(token: str) -> dict:
    """
    Decode and validate a JWT token.
    Raises jwt.ExpiredSignatureError if expired.
    Raises jwt.InvalidTokenError if invalid.
    """
    return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
```

### 2. Auth Dependency: `dependencies/auth.py`

```python
"""
FastAPI authentication dependency.
Extracts and validates JWT from the Authorization header.
"""
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import jwt

from services.auth_service import decode_token

security = HTTPBearer()


class CurrentUser:
    """Authenticated user context — available in all route handlers."""
    def __init__(self, user_id: str, tenant_id: str, role: str,
                 email: str, name: str):
        self.user_id = user_id
        self.tenant_id = tenant_id
        self.role = role
        self.email = email
        self.name = name


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> CurrentUser:
    """
    Validates the JWT and returns the current user context.
    Raises 401 if token is invalid or expired.
    """
    token = credentials.credentials
    try:
        payload = decode_token(token)
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token has expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")

    return CurrentUser(
        user_id=payload["sub"],
        tenant_id=payload["tenant_id"],
        role=payload["role"],
        email=payload.get("email", ""),
        name=payload.get("name", ""),
    )
```

### 3. Auth Routes: `routes/auth.py` (complete rewrite)

| Method | Endpoint | Auth Required | Description |
|--------|----------|---------------|-------------|
| `POST` | `/auth/register` | ❌ | Register new madrasa + owner account |
| `POST` | `/auth/login` | ❌ | Login → returns access token |
| `POST` | `/auth/refresh` | ❌ | Refresh access token (with refresh token) |
| `POST` | `/auth/logout` | ✅ | Revoke refresh token |
| `POST` | `/auth/change-password` | ✅ | Change own password |
| `GET` | `/auth/me` | ✅ | Current user info + tenant |

#### Registration Flow

```
POST /auth/register
{
    "email": "admin@jobeda.com",
    "password": "SecurePass123!",
    "full_name": "Abdul Karim",
    "phone": "01711111111",
    "madrasa_name": "Jobeda Hafizia Madrasa",
    "madrasa_slug": "jobeda"
}

→ Backend:
1. Validate email is not taken
2. Validate slug is not taken
3. Create tenant record
4. Hash password with bcrypt
5. Create user record (role: "owner")
6. Seed default chart of accounts for the tenant
7. Seed default fee types for the tenant
8. Generate JWT
9. Return { user, tenant, access_token }
```

#### Login Flow

```
POST /auth/login
{
    "email": "admin@jobeda.com",
    "password": "SecurePass123!"
}

→ Backend:
1. Find user by email
2. Verify password with bcrypt
3. Check user.is_active
4. Check tenant.is_active
5. Update last_login timestamp
6. Generate JWT (contains user_id, tenant_id, role)
7. Return { user, access_token, refresh_token }
```

#### Token Refresh Flow

```
POST /auth/refresh
{
    "refresh_token": "..."
}

→ Backend:
1. Find refresh_token record (not expired, not revoked)
2. Verify token hash
3. Load user from DB (check still active)
4. Generate new access_token
5. Optionally rotate refresh_token
6. Return { access_token }
```

### 4. User Management Routes: `routes/users.py`

| Method | Endpoint | Auth | Role Required | Description |
|--------|----------|------|---------------|-------------|
| `POST` | `/users/invite` | ✅ | owner, admin | Invite user to the tenant |
| `GET` | `/users` | ✅ | owner, admin | List users in tenant |
| `GET` | `/users/{id}` | ✅ | owner, admin, self | Get user profile |
| `PUT` | `/users/{id}` | ✅ | owner, admin, self | Update user profile |
| `DELETE` | `/users/{id}` | ✅ | owner, admin | Deactivate user |
| `PUT` | `/users/{id}/role` | ✅ | owner | Change user's role |
| `POST` | `/auth/accept-invite` | ❌ | — | Accept invitation + create account |
| `GET` | `/invitations` | ✅ | owner, admin | List pending invitations |
| `DELETE` | `/invitations/{id}` | ✅ | owner, admin | Revoke invitation |

#### Invitation Flow

```
1. POST /users/invite { email: "teacher@gmail.com", role: "teacher" }
   → Creates invitation with token (valid 7 days)
   → Sends email with link (or returns token for manual sharing)

2. POST /auth/accept-invite { token: "...", password: "...", full_name: "..." }
   → Validates token
   → Creates user (tenant_id + role from invitation)
   → Marks invitation as accepted
   → Returns { user, access_token }
```

### 5. Inject Auth into Every Existing Route

```python
# BEFORE (no auth — public access):
@router.get("")
def list_students():
    resp = supabase.table("students").select("*").eq("is_deleted", False).execute()
    return resp.data

# AFTER (auth required + tenant-scoped):
@router.get("")
def list_students(user: CurrentUser = Depends(get_current_user)):
    resp = (
        supabase.table("students")
        .select("*")
        .eq("tenant_id", user.tenant_id)     # ← tenant isolation
        .eq("is_deleted", False)
        .execute()
    )
    return resp.data
```

### 6. Populate Audit Fields

```python
# On create:
data["created_by"] = user.user_id

# On update:
data["updated_by"] = user.user_id
data["updated_at"] = datetime.utcnow().isoformat()
```

---

## Models

### `models/user.py`

```python
from pydantic import BaseModel, Field, EmailStr
from typing import Optional

class RegisterRequest(BaseModel):
    email: str
    password: str = Field(min_length=8)
    full_name: str
    phone: Optional[str] = None
    madrasa_name: str
    madrasa_slug: str = Field(pattern=r"^[a-z0-9-]+$")

class LoginRequest(BaseModel):
    email: str
    password: str

class LoginResponse(BaseModel):
    user_id: str
    email: str
    full_name: str
    role: str
    tenant_id: str
    tenant_name: str
    access_token: str
    refresh_token: Optional[str] = None

class UserProfileResponse(BaseModel):
    id: str
    email: str
    full_name: str
    phone: Optional[str] = None
    role: str
    is_active: bool
    last_login: Optional[str] = None
    created_at: Optional[str] = None

class InviteRequest(BaseModel):
    email: str
    role: str = Field(pattern=r"^(admin|accountant|teacher|viewer)$")

class AcceptInviteRequest(BaseModel):
    token: str
    password: str = Field(min_length=8)
    full_name: str
    phone: Optional[str] = None

class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str = Field(min_length=8)
```

### `models/tenant.py`

```python
from pydantic import BaseModel
from typing import Optional

class TenantResponse(BaseModel):
    id: str
    name: str
    slug: str
    address: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    logo_url: Optional[str] = None
    is_active: bool
    created_at: Optional[str] = None

class TenantUpdate(BaseModel):
    name: Optional[str] = None
    address: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    logo_url: Optional[str] = None
```

---

## New Files

| File | Purpose |
|------|---------|
| `services/auth_service.py` | Password hashing (bcrypt) + JWT creation/validation (PyJWT) |
| `dependencies/__init__.py` | Package init |
| `dependencies/auth.py` | `get_current_user` FastAPI dependency |
| `models/user.py` | Registration, login, profile, invitation models |
| `models/tenant.py` | Tenant Pydantic models |
| `routes/auth.py` | Complete rewrite — register, login, refresh, password |
| `routes/users.py` | User management + invitations |
| `routes/tenants.py` | Tenant info endpoints |
| `services/onboarding.py` | Tenant creation + default data seeding |
| `helpers/tenant.py` | Tenant-scoped query helpers |

---

## Migration: `012_users_invitations.sql`

```sql
-- 1. Create users table (our own, NOT Supabase auth.users)
-- 2. Create invitations table
-- 3. Create refresh_tokens table
-- 4. Create indexes
```

---

## Security Considerations

| Concern | Mitigation |
|---------|------------|
| Password storage | bcrypt with 12 rounds (adaptive, salted) |
| Token theft | Short-lived access tokens (24h) + refresh tokens (30d) |
| Brute force | Rate limiting on login endpoint (FastAPI middleware) |
| SQL injection | Supabase client uses parameterized queries |
| Cross-tenant access | Every query scoped by `tenant_id` from JWT |
| Role escalation | Role stored in DB, verified on each request |
| Token forgery | JWT signed with server-side secret (HS256) |
| Refresh token reuse | Tokens are hashed in DB, revocable, single-use (rotated) |

---

## Password Policy

Enforced at the application layer:

```python
def validate_password(password: str) -> None:
    if len(password) < 8:
        raise ValueError("Password must be at least 8 characters")
    if not any(c.isupper() for c in password):
        raise ValueError("Password must contain at least one uppercase letter")
    if not any(c.isdigit() for c in password):
        raise ValueError("Password must contain at least one number")
```

---

## Execution Order

> ⚠️ Must be done AFTER multi-tenant schema changes are in place.

```
1. Add bcrypt + PyJWT to requirements.txt
2. Create users + invitations + refresh_tokens tables (migration)
3. Create services/auth_service.py (hash, verify, JWT)
4. Create dependencies/auth.py (get_current_user)
5. Rewrite routes/auth.py (register, login, refresh, change-password)
6. Create routes/users.py (invite, list, update, deactivate)
7. Create services/onboarding.py (tenant seeding)
8. Update ALL existing routes to require auth (Depends(get_current_user))
9. Populate audit fields (created_by, updated_by)
10. Test: register → login → JWT → access protected endpoint → verify tenant isolation
```

---

## Open Questions

> [!IMPORTANT]
> **Q1: Email sending** — How should invitation emails be sent? Options: (a) return the token/link in the API response for manual sharing, (b) integrate with an email service (Resend, SendGrid, SES). Recommendation: start with (a), add email later.

> [!IMPORTANT]
> **Q2: Password reset** — Without Supabase Auth's built-in reset flow, we need to build our own. This requires an email service. Same answer as Q1 — defer email integration, add a "reset by admin" endpoint for now.

> [!WARNING]
> **Q3: Token storage on frontend** — Where should the frontend store tokens? `localStorage` (convenient but XSS vulnerable) vs `httpOnly cookies` (more secure). This is a frontend decision but affects API design (cookie-based auth needs CSRF protection).

> [!IMPORTANT]
> **Q4: Rate limiting** — Should we add rate limiting on auth endpoints? Recommendation: Yes, use `slowapi` or a simple in-memory counter. 5 login attempts per minute per IP.
