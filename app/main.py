"""Trivial FastAPI service: proves the stack's wiring works, nothing more.

Three endpoints only, deliberately kept minimal:
- GET  /healthz  — liveness: process is up. Always 200, never touches
  Postgres/Redis. Must stay cheap and dependency-free — a liveness probe
  that can fail because a downstream is briefly unavailable causes
  Kubernetes to restart a perfectly healthy process, which is the opposite
  of what liveness is for.
- GET  /readyz   — readiness: can this pod actually serve traffic? Checks
  that the `items` table exists (the migration Job has run) and that
  Postgres/Redis are reachable. Returns 503 until both are true. This is
  what gates the app Deployment behind the post-install/post-upgrade
  migration Job — see docs/decisions.md "Migration ordering" and the
  Deployment's readinessProbe.
- GET  /items    — list items (reads DB, populates Redis cache)
- POST /items    — create an item (writes DB, invalidates Redis cache)
"""

from __future__ import annotations

import json

from fastapi import Depends, FastAPI, Response
from pydantic import BaseModel
from sqlalchemy import Column, Integer, String, inspect, select
from sqlalchemy.orm import Session

from db import Base, engine, get_db, get_redis

app = FastAPI(title="reference-stack-app")

ITEMS_CACHE_KEY = "items:all"
CACHE_TTL_SECONDS = 30


class Item(Base):
    __tablename__ = "items"

    id = Column(Integer, primary_key=True)
    name = Column(String, nullable=False)


class ItemIn(BaseModel):
    name: str


class ItemOut(BaseModel):
    id: int
    name: str

    model_config = {"from_attributes": True}


@app.get("/healthz")
def healthz() -> dict:
    # Liveness only: no DB/Redis calls. See module docstring.
    return {"status": "ok"}


@app.get("/readyz")
def readyz(response: Response) -> dict:
    try:
        if not inspect(engine).has_table("items"):
            response.status_code = 503
            return {"status": "not-ready", "reason": "schema not migrated"}
        get_redis().ping()
    except Exception as exc:  # noqa: BLE001 — readiness probe: any failure means not-ready
        response.status_code = 503
        return {"status": "not-ready", "reason": str(exc)}
    return {"status": "ready"}


@app.get("/items", response_model=list[ItemOut])
def list_items(db: Session = Depends(get_db)) -> list[ItemOut]:
    cache = get_redis()
    cached = cache.get(ITEMS_CACHE_KEY)
    if cached is not None:
        return [ItemOut(**row) for row in json.loads(cached)]

    items = db.execute(select(Item)).scalars().all()
    result = [ItemOut.model_validate(item) for item in items]

    cache.set(
        ITEMS_CACHE_KEY,
        json.dumps([item.model_dump() for item in result]),
        ex=CACHE_TTL_SECONDS,
    )
    return result


@app.post("/items", response_model=ItemOut, status_code=201)
def create_item(item: ItemIn, db: Session = Depends(get_db)) -> ItemOut:
    row = Item(name=item.name)
    db.add(row)
    db.commit()
    db.refresh(row)

    # Invalidate rather than update in place — correctness over cache-hit
    # optimization, appropriate for a stack whose only job is to prove the
    # write-then-read path works.
    get_redis().delete(ITEMS_CACHE_KEY)

    return ItemOut.model_validate(row)
