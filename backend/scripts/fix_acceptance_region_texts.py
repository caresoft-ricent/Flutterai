from __future__ import annotations

import os
import sys

from sqlalchemy.orm import Session


# Allow running from repo root: `python3 backend/scripts/...`
_HERE = os.path.dirname(__file__)
_BACKEND_DIR = os.path.abspath(os.path.join(_HERE, ".."))
if _BACKEND_DIR not in sys.path:
    sys.path.insert(0, _BACKEND_DIR)

import models  # noqa: E402
from database import SessionLocal  # noqa: E402
from utils.region_parse import parse_region_text  # noqa: E402


MAPPINGS = [
    # Requested mapping
    ("测试项目 / 1期 / 1栋", "1栋10层"),
    ("测试项目/1期/1栋", "1栋10层"),
    ("测试项目 / 1期/1栋", "1栋10层"),
    ("测试项目/1期 / 1栋", "1栋10层"),
    ("6层", "1栋6层"),
    ("6 层", "1栋6层"),
    ("1栋", "1栋8层"),
    ("1 栋", "1栋8层"),
]


def _apply_row(r: models.AcceptanceRecord, new_text: str) -> bool:
    if (r.region_text or "") == new_text:
        return False

    r.region_text = new_text

    parsed = parse_region_text(new_text)
    if parsed.building_no:
        r.building_no = parsed.building_no
    if parsed.floor_no is not None:
        r.floor_no = parsed.floor_no
    if parsed.zone:
        r.zone = parsed.zone
    return True


def main() -> None:
    db: Session = SessionLocal()
    try:
        updated = 0
        for old, new in MAPPINGS:
            rows = (
                db.query(models.AcceptanceRecord)
                .filter(models.AcceptanceRecord.region_text == old)
                .all()
            )
            for r in rows:
                if _apply_row(r, new):
                    updated += 1

        if updated:
            db.commit()
        print(f"updated acceptance_records: {updated}")
    finally:
        db.close()


if __name__ == "__main__":
    main()
