import hashlib
import os
from pathlib import Path
from typing import List, Tuple

from app.utils.db import get_db_connection
from app.utils.logger import get_logger

logger = get_logger(__name__)


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _migrations_dir() -> Path:
    return Path(__file__).resolve().parents[2] / "migrations"


def _migration_files() -> List[Path]:
    migrations_dir = _migrations_dir()
    if not migrations_dir.is_dir():
        return []
    return sorted(path for path in migrations_dir.glob("v*.sql") if path.is_file())


def _checksum(sql: str) -> str:
    return hashlib.sha256(sql.encode("utf-8")).hexdigest()


def _ensure_table(cur) -> None:
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS qd_schema_migrations (
            id SERIAL PRIMARY KEY,
            filename VARCHAR(255) NOT NULL UNIQUE,
            checksum VARCHAR(64) NOT NULL,
            applied_at TIMESTAMP NOT NULL DEFAULT NOW()
        )
        """
    )


def _applied(cur) -> dict:
    cur.execute("SELECT filename, checksum FROM qd_schema_migrations")
    return {row["filename"]: row["checksum"] for row in cur.fetchall()}


def run_pending_migrations() -> Tuple[int, int]:
    if not _env_bool("RUN_DB_MIGRATIONS", True):
        logger.info("Database migrations are disabled via RUN_DB_MIGRATIONS")
        return 0, 0

    files = _migration_files()
    if not files:
        return 0, 0

    applied_count = 0
    with get_db_connection() as db:
        cur = db.cursor()
        _ensure_table(cur)
        existing = _applied(cur)

        for path in files:
            sql = path.read_text(encoding="utf-8")
            digest = _checksum(sql)
            previous = existing.get(path.name)

            if previous == digest:
                continue
            if previous and previous != digest:
                raise RuntimeError(f"Migration checksum changed after apply: {path.name}")

            logger.info(f"Applying database migration: {path.name}")
            cur.execute(sql)
            cur.execute(
                "INSERT INTO qd_schema_migrations (filename, checksum) VALUES (?, ?)",
                (path.name, digest),
            )
            applied_count += 1

        db.commit()
        cur.close()

    if applied_count:
        logger.info(f"Applied {applied_count}/{len(files)} database migrations")
    else:
        logger.info(f"Database migrations up to date ({len(files)} files)")
    return applied_count, len(files)
