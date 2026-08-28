from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.core.config import settings

DATABASE_URL = settings.database_url
if DATABASE_URL.startswith("postgresql+asyncpg"):
    try:
        import asyncpg  # noqa: F401
    except ImportError:
        DATABASE_URL = "sqlite+aiosqlite:///./health_rule_engine.db"
elif DATABASE_URL.startswith("postgresql"):
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://")

if "sqlite" in DATABASE_URL:
    engine = create_async_engine(DATABASE_URL, echo=settings.debug)
else:
    engine = create_async_engine(DATABASE_URL, echo=settings.debug, pool_size=10, max_overflow=20)

async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_session() -> AsyncSession:
    async with async_session() as session:
        yield session
