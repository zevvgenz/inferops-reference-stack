"""init: create items table

Idempotent via Alembic's version table (alembic_version) — this migration
runs exactly once regardless of how many times the migration Job is
re-triggered across installs and upgrades; re-running `alembic upgrade head`
against an already-migrated database is a no-op.

Revision ID: 0001
Revises:
Create Date: 2026-08-06
"""

from __future__ import annotations

import sqlalchemy as sa

from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "items",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("name", sa.String(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("items")
