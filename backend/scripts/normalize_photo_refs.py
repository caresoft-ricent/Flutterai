import json
import os
import sys
from urllib.parse import urlparse


def _uploads_path_from_ref(ref: str) -> str | None:
    s = (ref or "").strip()
    if not s:
        return None
    if s.startswith("/uploads/"):
        return s
    if s.startswith("uploads/"):
        return f"/{s}"
    if s.startswith("http://") or s.startswith("https://"):
        try:
            p = urlparse(s).path
        except Exception:
            return None
        if (p or "").startswith("/uploads/"):
            return p
    return None


def _normalize_upload_ref(ref: str | None) -> str | None:
    if ref is None:
        return None
    p = _uploads_path_from_ref(ref)
    if p:
        return p
    s = ref.strip()
    return s or None


def main() -> int:
    here = os.path.dirname(__file__)
    backend_dir = os.path.abspath(os.path.join(here, ".."))
    repo_root = os.path.abspath(os.path.join(backend_dir, ".."))
    sys.path.insert(0, backend_dir)
    sys.path.insert(0, repo_root)

    # Local imports after path setup
    import models  # type: ignore
    from database import SessionLocal  # type: ignore

    db = SessionLocal()

    updated_acceptance = 0
    updated_issues = 0
    updated_actions = 0

    try:
        for r in db.query(models.AcceptanceRecord).all():
            before = r.photo_path
            after = _normalize_upload_ref(before)
            if after != before:
                r.photo_path = after
                updated_acceptance += 1

        for r in db.query(models.IssueReport).all():
            before = r.photo_path
            after = _normalize_upload_ref(before)
            if after != before:
                r.photo_path = after
                updated_issues += 1

        for a in db.query(models.RectificationAction).all():
            raw = a.photo_urls
            if raw is None or str(raw).strip() == "":
                continue
            try:
                data = json.loads(raw)
            except Exception:
                continue
            if not isinstance(data, list):
                continue
            normalized = []
            changed = False
            for x in data:
                s = str(x).strip()
                if not s:
                    continue
                n = _normalize_upload_ref(s)
                if n != s:
                    changed = True
                normalized.append(n or s)
            if changed:
                a.photo_urls = json.dumps(normalized, ensure_ascii=False)
                updated_actions += 1

        db.commit()

        print(
            json.dumps(
                {
                    "updated_acceptance": updated_acceptance,
                    "updated_issues": updated_issues,
                    "updated_actions": updated_actions,
                },
                ensure_ascii=False,
            )
        )
        return 0
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())
