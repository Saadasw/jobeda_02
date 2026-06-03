"""
Common models shared across modules.
Pagination, audit mixins, and standard response wrappers.
"""
from datetime import datetime
from typing import Any, Generic, List, Optional, TypeVar
from pydantic import BaseModel, Field

T = TypeVar("T")


class PaginationParams(BaseModel):
    """Query parameters for paginated endpoints."""
    page: int = Field(default=1, ge=1, description="Page number (1-indexed)")
    limit: int = Field(default=50, ge=1, le=200, description="Items per page")

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.limit


class PaginatedResponse(BaseModel, Generic[T]):
    """Standard wrapper for paginated list responses."""
    data: List[T]
    page: int
    limit: int
    total: int
    total_pages: int


class MessageResponse(BaseModel):
    """Generic message response."""
    message: str
    data: Optional[Any] = None
