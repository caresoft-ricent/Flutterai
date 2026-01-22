from __future__ import annotations

import json
import os
import re
import uuid
import concurrent.futures
from datetime import datetime, timedelta
from typing import Optional
from urllib.parse import urlparse

import uvicorn
from fastapi import Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.encoders import jsonable_encoder
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv
from pydantic import BaseModel, Field
from pydantic.config import ConfigDict
from sqlalchemy import case, func
from sqlalchemy.orm import Session

import models
from database import engine, get_db
from utils.region_parse import parse_region_text


models.Base.metadata.create_all(bind=engine)

load_dotenv()


def _load_local_config() -> dict:
    path = os.path.join(os.path.dirname(__file__), "config.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


_local_cfg = _load_local_config()

_llm_executor = concurrent.futures.ThreadPoolExecutor(max_workers=4)

app = FastAPI(
    title="FlutterAI Backend",
    description="Local backend for Flutter acceptance/inspection data storage",
    version="0.1.0",
)

_uploads_dir = os.path.join(os.path.dirname(__file__), "uploads")
os.makedirs(_uploads_dir, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=_uploads_dir), name="uploads")

# Flutter 本地调试常见来源：
# - iOS Simulator: http://localhost
# - Android Emulator: http://10.0.2.2
# 这里先放开，后续做权限/域名收敛。
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _parse_building_floor(region_text: str) -> tuple[Optional[str], Optional[int]]:
    parsed = parse_region_text(region_text or "")
    return parsed.building_no, parsed.floor_no


def _parse_zone(region_text: str) -> Optional[str]:
    parsed = parse_region_text(region_text or "")
    return parsed.zone


def _normalize_severity_key(sev: Optional[str]) -> str:
    s = (sev or "").strip().lower()
    if not s:
        return "unknown"
    if s in {"严重", "重大", "high", "severe", "critical", "a", "一级"}:
        return "severe"
    if s in {"一般", "普通", "medium", "normal", "b", "二级"}:
        return "normal"
    return s


def _median(values: list[float]) -> Optional[float]:
    xs = [float(x) for x in values if x is not None]
    if not xs:
        return None
    xs.sort()
    n = len(xs)
    mid = n // 2
    if n % 2 == 1:
        return xs[mid]
    return (xs[mid - 1] + xs[mid]) / 2.0


def _safe_days_between(start: Optional[datetime], end: Optional[datetime]) -> Optional[float]:
    if start is None or end is None:
        return None
    try:
        delta = end - start
        return float(delta.total_seconds() / 86400.0)
    except Exception:
        return None


def _uploads_path_from_ref(ref: Optional[str]) -> Optional[str]:
    """Extract a stable relative uploads path from a URL/path.

    We store photos as relative paths like `/uploads/<name>` so network/IP changes
    won't break existing records.
    """

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


def _normalize_upload_ref(ref: Optional[str]) -> Optional[str]:
    p = _uploads_path_from_ref(ref)
    return p if p else ((ref or "").strip() or None)


def _backfill_region_fields(db: Session, *, project_id: int, limit: int = 200) -> dict:
    """Best-effort backfill for building_no/floor_no/zone based on region_text.

    This is intentionally lightweight and safe:
    - only fills missing fields
    - capped by `limit` per table
    """

    limit = int(limit or 0)
    if limit <= 0:
        return {"updated_acceptance": 0, "updated_issues": 0}

    updated_acceptance = 0
    a_rows = (
        db.query(models.AcceptanceRecord)
        .filter(models.AcceptanceRecord.project_id == project_id)
        .filter(
            (models.AcceptanceRecord.building_no.is_(None))
            | (models.AcceptanceRecord.floor_no.is_(None))
            | (models.AcceptanceRecord.zone.is_(None))
        )
        .order_by(models.AcceptanceRecord.created_at.desc())
        .limit(limit)
        .all()
    )
    for r in a_rows:
        parsed = parse_region_text(r.region_text or "")
        changed = False
        if r.building_no is None and parsed.building_no is not None:
            r.building_no = parsed.building_no
            changed = True
        if r.floor_no is None and parsed.floor_no is not None:
            r.floor_no = parsed.floor_no
            changed = True
        if r.zone is None and parsed.zone is not None:
            r.zone = parsed.zone
            changed = True
        if changed:
            updated_acceptance += 1

    updated_issues = 0
    i_rows = (
        db.query(models.IssueReport)
        .filter(models.IssueReport.project_id == project_id)
        .filter(
            (models.IssueReport.building_no.is_(None))
            | (models.IssueReport.floor_no.is_(None))
            | (models.IssueReport.zone.is_(None))
        )
        .order_by(models.IssueReport.created_at.desc())
        .limit(limit)
        .all()
    )
    for r in i_rows:
        parsed = parse_region_text(r.region_text or "")
        changed = False
        if r.building_no is None and parsed.building_no is not None:
            r.building_no = parsed.building_no
            changed = True
        if r.floor_no is None and parsed.floor_no is not None:
            r.floor_no = parsed.floor_no
            changed = True
        if r.zone is None and parsed.zone is not None:
            r.zone = parsed.zone
            changed = True
        if changed:
            updated_issues += 1

    if updated_acceptance or updated_issues:
        db.commit()

    return {"updated_acceptance": updated_acceptance, "updated_issues": updated_issues}


def _ensure_project(db: Session, name: str) -> models.Project:
    n = name.strip()
    if not n:
        raise HTTPException(status_code=400, detail="project_name is empty")
    p = db.query(models.Project).filter(models.Project.name == n).first()
    if p is not None:
        return p
    p = models.Project(name=n)
    db.add(p)
    db.commit()
    db.refresh(p)
    return p


class ProjectIn(BaseModel):
    name: str
    address: Optional[str] = None


class ProjectOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    address: Optional[str] = None
    created_at: datetime


class AcceptanceRecordIn(BaseModel):
    project_id: Optional[int] = None
    project_name: Optional[str] = None
    region_code: str = ""
    region_text: str = ""

    division: Optional[str] = None
    subdivision: Optional[str] = None
    item: Optional[str] = None
    item_code: Optional[str] = None
    indicator: Optional[str] = None
    indicator_code: Optional[str] = None

    result: str = Field(description="qualified | unqualified | pending")
    photo_path: Optional[str] = None
    remark: Optional[str] = None
    ai_json: Optional[str] = None

    client_created_at: Optional[datetime] = None
    source: Optional[str] = None
    client_record_id: Optional[str] = None


class AcceptanceRecordOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    project_id: int
    region_code: str
    region_text: str
    building_no: Optional[str] = None
    floor_no: Optional[int] = None
    zone: Optional[str] = None

    division: Optional[str] = None
    subdivision: Optional[str] = None
    item: Optional[str] = None
    item_code: Optional[str] = None
    indicator: Optional[str] = None
    indicator_code: Optional[str] = None

    result: str
    photo_path: Optional[str] = None
    remark: Optional[str] = None
    ai_json: Optional[str] = None

    client_created_at: Optional[datetime] = None
    created_at: datetime

    source: Optional[str] = None
    client_record_id: Optional[str] = None


class IssueReportIn(BaseModel):
    project_id: Optional[int] = None
    project_name: Optional[str] = None
    region_code: Optional[str] = None
    region_text: Optional[str] = None

    division: Optional[str] = None
    subdivision: Optional[str] = None
    item: Optional[str] = None
    indicator: Optional[str] = None
    library_id: Optional[str] = None

    description: str
    severity: Optional[str] = None
    deadline_days: Optional[int] = None

    responsible_unit: Optional[str] = None
    responsible_person: Optional[str] = None

    status: str = "open"
    photo_path: Optional[str] = None
    ai_json: Optional[str] = None
    client_created_at: Optional[datetime] = None
    source: Optional[str] = None
    client_record_id: Optional[str] = None


class IssueReportOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    project_id: int

    region_code: Optional[str] = None
    region_text: Optional[str] = None
    building_no: Optional[str] = None
    floor_no: Optional[int] = None
    zone: Optional[str] = None

    division: Optional[str] = None
    subdivision: Optional[str] = None
    item: Optional[str] = None
    indicator: Optional[str] = None
    library_id: Optional[str] = None

    description: str
    severity: Optional[str] = None
    deadline_days: Optional[int] = None

    responsible_unit: Optional[str] = None
    responsible_person: Optional[str] = None

    status: str
    photo_path: Optional[str] = None
    ai_json: Optional[str] = None

    client_created_at: Optional[datetime] = None
    created_at: datetime

    source: Optional[str] = None
    client_record_id: Optional[str] = None


class RectificationActionIn(BaseModel):
    action_type: str = Field(description="rectify | verify | close | comment")
    content: Optional[str] = None
    photo_urls: list[str] = []
    actor_role: Optional[str] = None
    actor_name: Optional[str] = None


class RectificationActionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    project_id: int
    target_type: str
    target_id: int
    action_type: str
    content: Optional[str] = None
    photo_urls: Optional[str] = None
    actor_role: Optional[str] = None
    actor_name: Optional[str] = None
    created_at: datetime


class AcceptanceVerifyIn(BaseModel):
    result: str = Field(description="qualified | unqualified | pending")
    remark: Optional[str] = None
    photo_urls: list[str] = []
    actor_role: Optional[str] = None
    actor_name: Optional[str] = None


class DashboardSummaryOut(BaseModel):
    acceptance_total: int = 0
    acceptance_qualified: int = 0
    acceptance_unqualified: int = 0
    acceptance_pending: int = 0

    issues_total: int = 0
    issues_open: int = 0
    issues_closed: int = 0

    issues_by_severity: dict[str, int] = {}
    top_responsible_units: list[dict] = []

    recent_unqualified_acceptance: list[dict] = []
    recent_open_issues: list[dict] = []


def _is_focus_query(q: str) -> bool:
    s = (q or "").strip()
    if not s:
        return False
    keys = [
        "关注",
        "关注点",
        "重点",
        "风险",
        "预警",
        "本周",
        "下周",
        "下一步",
        "要盯",
        "需要盯",
        "驾驶舱",
        "focus",
    ]
    return any(k in s for k in keys)


def _focus_answer_from_pack(pack: dict) -> str:
    """Generate a fixed-structure Chinese answer strictly from Focus Pack."""

    meta = pack.get("meta", {}) if isinstance(pack, dict) else {}
    window = meta.get("window", {}) if isinstance(meta, dict) else {}
    days = window.get("time_range_days")
    start = window.get("start")
    end = window.get("end")

    m = pack.get("metrics", {}) if isinstance(pack, dict) else {}
    closure = pack.get("closure", {}) if isinstance(pack, dict) else {}
    dq = pack.get("data_quality", {}) if isinstance(pack, dict) else {}
    top_focus = pack.get("top_focus", []) if isinstance(pack, dict) else []

    lines: list[str] = []
    lines.append(f"【时间窗】近{days}天（{start} ~ {end}）")

    lines.append("【总体结论】")
    lines.append(
        "- 未闭环巡检："
        f"{int(m.get('issues_open', 0))} 条（严重 {int(m.get('issues_open_severe', 0))}，逾期 {int(m.get('issues_open_overdue', 0))}）"
    )
    lines.append(
        "- 验收分项："
        f"不合格 {int(m.get('acceptance_unqualified_items', 0))}，甩项 {int(m.get('acceptance_pending_items', 0))}"
    )

    lines.append("【Top关注点（确定性生成）】")
    if isinstance(top_focus, list) and top_focus:
        for idx, it in enumerate(top_focus[:5], start=1):
            if not isinstance(it, dict):
                continue
            title = it.get("title") or ""
            score = it.get("risk_score")
            evidence = it.get("evidence") or {}
            lines.append(f"{idx}) {title}（风险评分 {score}）")
            if isinstance(evidence, dict):
                ev_parts = []
                if "issues_open" in evidence:
                    ev_parts.append(f"open={int(evidence.get('issues_open', 0))}")
                if "issues_open_severe" in evidence:
                    ev_parts.append(f"severe={int(evidence.get('issues_open_severe', 0))}")
                if "issues_open_overdue" in evidence:
                    ev_parts.append(f"overdue={int(evidence.get('issues_open_overdue', 0))}")
                if "acceptance_unqualified_items" in evidence:
                    ev_parts.append(f"unqItems={int(evidence.get('acceptance_unqualified_items', 0))}")
                if "acceptance_pending_items" in evidence:
                    ev_parts.append(f"penItems={int(evidence.get('acceptance_pending_items', 0))}")
                if ev_parts:
                    lines.append("   - 证据：" + "，".join(ev_parts))
    else:
        lines.append("- 当前时间窗内没有足够的数据生成关注点。")

    lines.append("【闭环指标】")
    lines.append(
        "- 巡检关闭："
        f"{int(closure.get('issue_close_count', 0))} 次，平均 {closure.get('issue_close_days_avg')} 天，中位数 {closure.get('issue_close_days_median')} 天"
    )
    lines.append(
        "- 验收复验："
        f"{int(closure.get('acceptance_verify_count', 0))} 次，平均 {closure.get('acceptance_verify_days_avg')} 天，中位数 {closure.get('acceptance_verify_days_median')} 天"
    )

    lines.append("【数据质量（会影响统计与AI结论）】")
    lines.append(
        "- 未解析部位："
        f"验收 {int(dq.get('acceptance_missing_building', 0))} 条，巡检 {int(dq.get('issues_missing_building', 0))} 条"
    )
    lines.append(
        "- 缺失闭环动作："
        f"已关闭巡检但无 close 动作 {int(dq.get('issues_closed_missing_close_action', 0))} 条；验收非甩项但无 verify 动作 {int(dq.get('acceptance_missing_verify_action', 0))} 条"
    )

    lines.append("【下一步动作（只基于 Focus Pack 字段）】")
    lines.append("- 先盯风险评分最高的楼栋/范围，优先清理：严重 + 逾期 + 不合格分项。")
    lines.append("- 对未解析部位的记录补齐‘1栋6层/区域’格式，避免落在‘未解析’影响分楼栋统计。")
    lines.append("- 复验/关闭请走整改闭环动作流（verify/close），否则闭环时长无法统计。")

    return "\n".join(lines)


def _dashboard_focus_pack(
    db: Session,
    *,
    project_id: int,
    time_range_days: int = 14,
    building: Optional[str] = None,
    do_backfill: bool = True,
    backfill_limit: int = 200,
) -> dict:
    days = int(time_range_days or 0)
    if days <= 0:
        days = 14

    now = datetime.utcnow()
    start_dt = now - timedelta(days=days)
    start_s = start_dt.strftime("%Y-%m-%d")
    end_s = now.strftime("%Y-%m-%d")

    backfill = _backfill_region_fields(db, project_id=project_id, limit=backfill_limit) if do_backfill else None

    # Acceptance items within window
    item_key = func.coalesce(
        models.AcceptanceRecord.item_code,
        models.AcceptanceRecord.item,
        models.AcceptanceRecord.indicator_code,
        models.AcceptanceRecord.indicator,
    )
    a_q = (
        db.query(
            models.AcceptanceRecord.building_no,
            item_key.label("item_key"),
            func.max(case((models.AcceptanceRecord.result == "unqualified", 1), else_=0)).label("has_unq"),
            func.max(case((models.AcceptanceRecord.result == "pending", 1), else_=0)).label("has_pen"),
        )
        .filter(models.AcceptanceRecord.project_id == project_id)
        .filter(models.AcceptanceRecord.created_at >= start_dt)
    )
    if building:
        a_q = a_q.filter(models.AcceptanceRecord.building_no == building)
    a_rows = a_q.group_by(models.AcceptanceRecord.building_no, item_key).all()

    a_items_total = 0
    a_items_unq = 0
    a_items_pen = 0
    by_building: dict[str, dict] = {}
    for b, _k, has_unq, has_pen in a_rows:
        bkey = (b or "").strip() or "未解析"
        d = by_building.setdefault(
            bkey,
            {
                "building": bkey,
                "acceptance_unqualified_items": 0,
                "acceptance_pending_items": 0,
                "issues_open": 0,
                "issues_open_severe": 0,
                "issues_open_overdue": 0,
                "risk_score": 0,
            },
        )
        a_items_total += 1
        if int(has_unq or 0) > 0:
            a_items_unq += 1
            d["acceptance_unqualified_items"] += 1
        elif int(has_pen or 0) > 0:
            a_items_pen += 1
            d["acceptance_pending_items"] += 1

    # Current open issues (snapshot) grouped by building
    open_rows = (
        db.query(models.IssueReport.id, models.IssueReport.building_no, models.IssueReport.created_at, models.IssueReport.deadline_days, models.IssueReport.severity)
        .filter(models.IssueReport.project_id == project_id)
        .filter(models.IssueReport.status == "open")
        .order_by(models.IssueReport.created_at.desc())
        .limit(5000)
        .all()
    )
    issues_open = 0
    issues_open_severe = 0
    issues_open_overdue = 0
    for _id, b, created_at, deadline_days, severity in open_rows:
        bkey = (b or "").strip() or "未解析"
        if building and bkey != building:
            continue
        d = by_building.setdefault(
            bkey,
            {
                "building": bkey,
                "acceptance_unqualified_items": 0,
                "acceptance_pending_items": 0,
                "issues_open": 0,
                "issues_open_severe": 0,
                "issues_open_overdue": 0,
                "risk_score": 0,
            },
        )
        issues_open += 1
        d["issues_open"] += 1
        if _normalize_severity_key(severity) == "severe":
            issues_open_severe += 1
            d["issues_open_severe"] += 1
        try:
            dd = int(deadline_days) if deadline_days is not None else None
        except Exception:
            dd = None
        if dd is not None and created_at is not None:
            age = _safe_days_between(created_at, now)
            if age is not None and age > float(dd):
                issues_open_overdue += 1
                d["issues_open_overdue"] += 1

    # Closure metrics within window
    issue_close_actions = (
        db.query(models.RectificationAction.target_id, func.min(models.RectificationAction.created_at))
        .filter(models.RectificationAction.project_id == project_id)
        .filter(models.RectificationAction.target_type == "issue")
        .filter(models.RectificationAction.action_type == "close")
        .filter(models.RectificationAction.created_at >= start_dt)
        .group_by(models.RectificationAction.target_id)
        .all()
    )
    close_days: list[float] = []
    for target_id, close_at in issue_close_actions:
        issue = db.query(models.IssueReport).filter(models.IssueReport.id == int(target_id)).first()
        if issue is None:
            continue
        if building and ((issue.building_no or "").strip() or "未解析") != building:
            continue
        d = _safe_days_between(issue.created_at, close_at)
        if d is not None and d >= 0:
            close_days.append(d)

    verify_actions = (
        db.query(models.RectificationAction.target_id, func.min(models.RectificationAction.created_at))
        .filter(models.RectificationAction.project_id == project_id)
        .filter(models.RectificationAction.target_type == "acceptance")
        .filter(models.RectificationAction.action_type == "verify")
        .filter(models.RectificationAction.created_at >= start_dt)
        .group_by(models.RectificationAction.target_id)
        .all()
    )
    verify_days: list[float] = []
    for target_id, verify_at in verify_actions:
        rec = db.query(models.AcceptanceRecord).filter(models.AcceptanceRecord.id == int(target_id)).first()
        if rec is None:
            continue
        if building and ((rec.building_no or "").strip() or "未解析") != building:
            continue
        d = _safe_days_between(rec.created_at, verify_at)
        if d is not None and d >= 0:
            verify_days.append(d)

    closure = {
        "issue_close_count": int(len(close_days)),
        "issue_close_days_avg": round(sum(close_days) / len(close_days), 2) if close_days else None,
        "issue_close_days_median": round(_median(close_days), 2) if close_days else None,
        "acceptance_verify_count": int(len(verify_days)),
        "acceptance_verify_days_avg": round(sum(verify_days) / len(verify_days), 2) if verify_days else None,
        "acceptance_verify_days_median": round(_median(verify_days), 2) if verify_days else None,
    }

    # Data quality indicators
    dq = {
        "acceptance_missing_building": int(
            db.query(func.count(models.AcceptanceRecord.id))
            .filter(models.AcceptanceRecord.project_id == project_id)
            .filter(models.AcceptanceRecord.building_no.is_(None))
            .scalar()
            or 0
        ),
        "issues_missing_building": int(
            db.query(func.count(models.IssueReport.id))
            .filter(models.IssueReport.project_id == project_id)
            .filter(models.IssueReport.building_no.is_(None))
            .scalar()
            or 0
        ),
        "issues_closed_missing_close_action": 0,
        "acceptance_missing_verify_action": 0,
    }

    # Closed issues without close action
    closed_ids = (
        db.query(models.IssueReport.id)
        .filter(models.IssueReport.project_id == project_id)
        .filter(models.IssueReport.status == "closed")
        .order_by(models.IssueReport.created_at.desc())
        .limit(5000)
        .all()
    )
    closed_id_list = [int(x[0]) for x in closed_ids]
    if closed_id_list:
        has_close = set(
            int(x[0])
            for x in db.query(models.RectificationAction.target_id)
            .filter(models.RectificationAction.project_id == project_id)
            .filter(models.RectificationAction.target_type == "issue")
            .filter(models.RectificationAction.action_type == "close")
            .filter(models.RectificationAction.target_id.in_(closed_id_list))
            .all()
        )
        dq["issues_closed_missing_close_action"] = int(len([x for x in closed_id_list if x not in has_close]))

    # Acceptance records (non-pending) without verify action (best-effort)
    acc_ids = (
        db.query(models.AcceptanceRecord.id)
        .filter(models.AcceptanceRecord.project_id == project_id)
        .filter(models.AcceptanceRecord.result.in_(["qualified", "unqualified"]))
        .order_by(models.AcceptanceRecord.created_at.desc())
        .limit(5000)
        .all()
    )
    acc_id_list = [int(x[0]) for x in acc_ids]
    if acc_id_list:
        has_verify = set(
            int(x[0])
            for x in db.query(models.RectificationAction.target_id)
            .filter(models.RectificationAction.project_id == project_id)
            .filter(models.RectificationAction.target_type == "acceptance")
            .filter(models.RectificationAction.action_type == "verify")
            .filter(models.RectificationAction.target_id.in_(acc_id_list))
            .all()
        )
        dq["acceptance_missing_verify_action"] = int(len([x for x in acc_id_list if x not in has_verify]))

    # Compute risk score per building
    def _risk_score(d: dict) -> int:
        open_n = int(d.get("issues_open", 0))
        severe_n = int(d.get("issues_open_severe", 0))
        overdue_n = int(d.get("issues_open_overdue", 0))
        unq_items = int(d.get("acceptance_unqualified_items", 0))
        pen_items = int(d.get("acceptance_pending_items", 0))
        dq_pen = 10 if str(d.get("building")) == "未解析" else 0
        score = (
            severe_n * 12
            + open_n * 4
            + overdue_n * 8
            + unq_items * 6
            + pen_items * 2
            + dq_pen
        )
        return int(max(0, min(100, score)))

    for d in by_building.values():
        d["risk_score"] = _risk_score(d)

    by_building_list = sorted(by_building.values(), key=lambda x: int(x.get("risk_score", 0)), reverse=True)

    # Top focus (deterministic)
    top_focus: list[dict] = []
    for d in by_building_list:
        if int(d.get("risk_score", 0)) <= 0:
            continue
        bname = d.get("building")
        title = f"{bname} 优先闭环风险" if bname else "优先闭环风险"
        top_focus.append(
            {
                "title": title,
                "building": bname,
                "risk_score": int(d.get("risk_score", 0)),
                "evidence": {
                    "issues_open": int(d.get("issues_open", 0)),
                    "issues_open_severe": int(d.get("issues_open_severe", 0)),
                    "issues_open_overdue": int(d.get("issues_open_overdue", 0)),
                    "acceptance_unqualified_items": int(d.get("acceptance_unqualified_items", 0)),
                    "acceptance_pending_items": int(d.get("acceptance_pending_items", 0)),
                },
            }
        )
        if len(top_focus) >= 5:
            break

    pack = {
        "meta": {
            "project_id": project_id,
            "generated_at": now.isoformat(),
            "window": {"time_range_days": days, "start": start_s, "end": end_s},
            "backfill": backfill,
            "scope": {"building": building} if building else {},
        },
        "metrics": {
            "acceptance_unqualified_items": int(a_items_unq),
            "acceptance_pending_items": int(a_items_pen),
            "issues_open": int(issues_open),
            "issues_open_severe": int(issues_open_severe),
            "issues_open_overdue": int(issues_open_overdue),
        },
        "closure": closure,
        "data_quality": dq,
        "by_building": by_building_list,
        "top_focus": top_focus,
    }
    return pack


class ChatIn(BaseModel):
    query: Optional[str] = None
    project_name: Optional[str] = None
    messages: Optional[list[dict]] = None


class ChatPlan(BaseModel):
    """A lightweight, LLM-produced plan for intent-driven responses.

    Keep it permissive to avoid 422 on model drift.
    """

    intent: str = ""
    scope: dict = Field(default_factory=dict)  # building/floor/responsible_unit/time_range_days
    dimensions: list[str] = Field(default_factory=list)
    style: str = "analysis"  # analysis|summary|list
    top_n: int = 5


class ChatOut(BaseModel):
    answer: str
    facts: dict
    meta: dict = Field(default_factory=dict)


@app.post("/v1/uploads/photo")
async def upload_photo(request: Request, file: UploadFile = File(...)):
    # Save uploaded images and return an absolute URL for cross-device preview.
    ext = os.path.splitext(file.filename or "")[1].lower().strip()
    if ext not in {".jpg", ".jpeg", ".png", ".webp", ".heic"}:
        # Allow unknown extensions by defaulting to .jpg
        ext = ext or ".jpg"

    name = f"{uuid.uuid4().hex}{ext}"
    dst = os.path.join(_uploads_dir, name)

    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="empty file")

    with open(dst, "wb") as f:
        f.write(content)

    path = f"/uploads/{name}"
    # request.base_url ends with '/'
    url = f"{request.base_url}uploads/{name}"
    return {"url": url, "path": path}


def _get_env(*names: str) -> Optional[str]:
    for n in names:
        v = os.getenv(n)
        if v is not None and v.strip():
            return v.strip()
    return None


def _get_cfg(path: str) -> Optional[str]:
    cur = _local_cfg
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    if cur is None:
        return None
    s = str(cur).strip()
    return s or None


_ark_client = None


@app.get("/v1/ai/status")
def ai_status():
    """Expose runtime AI configuration for diagnostics.

    Use this to confirm whether Doubao(ARK) is configured and whether chat endpoints
    are expected to call the model.
    """

    api_key = _get_env("ARK_API_KEY", "DOUBAO_API_KEY") or _get_cfg("doubao.api_key")
    model = (
        _get_env("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID")
        or _get_cfg("doubao.model")
        or _get_cfg("doubao.endpoint_id")
    )
    base_url = _get_env("ARK_BASE_URL", "DOUBAO_BASE_URL") or _get_cfg("doubao.base_url")
    client = _get_ark_client()

    return {
        "llm": {
            "provider": "doubao",
            "configured": bool(api_key and model),
            "has_api_key": bool(api_key),
            "has_model": bool(model),
            "has_client": bool(client is not None),
            "model": model or "",
            "base_url": base_url or "",
            "note": "configured=true 表示已检测到 API Key + model/endpoint；是否实际计费取决于调用链和后端日志/meta.llm.used。",
        }
    }


def _get_ark_client():
    global _ark_client
    if _ark_client is not None:
        return _ark_client

    api_key = _get_env("ARK_API_KEY", "DOUBAO_API_KEY") or _get_cfg("doubao.api_key")
    if not api_key:
        return None

    try:
        from volcenginesdkarkruntime import Ark

        base_url = (
            _get_env("ARK_BASE_URL", "DOUBAO_BASE_URL")
            or _get_cfg("doubao.base_url")
        )
        # Ark has a sensible default base_url; only override when provided.
        _ark_client = Ark(api_key=api_key, base_url=base_url) if base_url else Ark(api_key=api_key)
        return _ark_client
    except Exception:
        return None


def _doubao_chat_answer(*, query: str, facts: dict, messages: Optional[list[dict]] = None) -> Optional[str]:
    client = _get_ark_client()
    model = (
        _get_env("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID")
        or _get_cfg("doubao.model")
        or _get_cfg("doubao.endpoint_id")
    )
    if client is None or not model:
        return None

    def _facts_view_for_llm(q: str, f: dict) -> dict:
        """Create a human-labeled view of facts for LLM.

        Key goal: avoid leaking raw API field names while keeping evidence traceable.
        """

        a_total = int(f.get("acceptance_total", 0) or 0)
        a_ok = int(f.get("acceptance_qualified", 0) or 0)
        a_unq = int(f.get("acceptance_unqualified", 0) or 0)
        a_pen = int(f.get("acceptance_pending", 0) or 0)

        i_total = int(f.get("issues_total", 0) or 0)
        i_open = int(f.get("issues_open", 0) or 0)
        i_closed = int(f.get("issues_closed", 0) or 0)

        issues_by_sev = f.get("issues_by_severity", {}) if isinstance(f.get("issues_by_severity"), dict) else {}
        top_units = f.get("top_responsible_units", []) if isinstance(f.get("top_responsible_units"), list) else []
        by_building = f.get("by_building", []) if isinstance(f.get("by_building"), list) else []

        severe = 0
        try:
            severe = int(issues_by_sev.get("严重", 0) or issues_by_sev.get("severe", 0) or 0)
        except Exception:
            severe = 0

        evidence: list[str] = []
        evidence.append(f"验收分项：共{a_total}，合格{a_ok}，不合格{a_unq}，甩项{a_pen}。")
        evidence.append(f"巡检问题：共{i_total}，未闭环{i_open}，已闭环{i_closed}，严重{severe}。")
        if top_units:
            head = top_units[0] if isinstance(top_units[0], dict) else None
            if head:
                u = (str(head.get("responsible_unit", "")) or "").strip() or "未填写"
                c = int(head.get("count", 0) or 0)
                evidence.append(f"责任单位未闭环最多：{u}（{c}条）。")

        building_lines: list[str] = []
        for b in by_building[:8]:
            if not isinstance(b, dict):
                continue
            bn = (str(b.get("building", "")) or "").strip() or "未解析"
            building_lines.append(
                f"{bn}：验收{int(b.get('acceptance_total', 0) or 0)}（不合格{int(b.get('acceptance_unqualified', 0) or 0)}，合格{int(b.get('acceptance_qualified', 0) or 0)}，甩项{int(b.get('acceptance_pending', 0) or 0)}）；"
                f"巡检{int(b.get('issues_total', 0) or 0)}（未闭环{int(b.get('issues_open', 0) or 0)}）"
            )

        scope = f.get("scope") if isinstance(f.get("scope"), dict) else {}
        scope_txt = ""
        if scope:
            parts = []
            if (scope.get("building") or "").strip():
                parts.append(str(scope.get("building")).strip())
            if scope.get("floor") is not None:
                parts.append(f"{scope.get('floor')}层")
            if (scope.get("responsible_unit") or "").strip():
                parts.append(f"责任单位：{str(scope.get('responsible_unit')).strip()}")
            scope_txt = "，".join(parts)

        return {
            "问题": q,
            "范围": scope_txt,
            "核心证据": evidence,
            "按楼栋进展": building_lines,
            "提示": [
                "证据必须来自‘核心证据/按楼栋进展’的原句，不要输出内部字段名或英文key。",
                "如果用户问‘项目进展/各栋/楼栋’，优先用‘按楼栋进展’回答。",
            ],
        }

    system_prompt = (
        "你是项目质量数据助手。\n"
        "只允许基于给定的 facts_view 回答，禁止编造数字。\n"
        "强约束：总字数 <= 200；最多 6 行；不输出英文字段名（例如 acceptance_total 这类）。\n"
        "输出格式固定（每行以短句为主）：\n"
        "结论：1-2句\n"
        "证据：2-3句（必须原样复制 facts_view.核心证据 或 facts_view.按楼栋进展 的句子）\n"
        "下一步：1-2句（可执行）\n"
        "证据不足就写：‘证据不足：缺少XXX’，不要猜。"
    )

    # Provide a labeled view to the model to avoid leaking raw API keys.
    try:
        fv = _facts_view_for_llm(query, jsonable_encoder(facts))
        facts_json = json.dumps(fv, ensure_ascii=False)
    except Exception:
        fv = _facts_view_for_llm(query, facts)
        facts_json = json.dumps(fv, ensure_ascii=False, default=str)
    user_prompt = f"facts_view(JSON)：{facts_json}"

    def _normalize_role(r: str) -> str:
        rr = (r or "").strip().lower()
        if rr in {"assistant", "ai"}:
            return "assistant"
        return "user"

    chat_messages = [{"role": "system", "content": system_prompt}]
    # Provide facts once, then rely on conversation history + current question.
    chat_messages.append({"role": "system", "content": f"facts_view(JSON)：{facts_json}"})

    if isinstance(messages, list):
        for m in messages[-12:]:
            if not isinstance(m, dict):
                continue
            role = _normalize_role(str(m.get("role", "user")))
            content = str(m.get("content", "")).strip()
            if not content:
                continue
            chat_messages.append({"role": role, "content": content})

    chat_messages.append({"role": "user", "content": user_prompt})

    try:
        try:
            resp = client.chat.completions.create(
                model=model,
                messages=chat_messages,
                temperature=0.2,
                max_tokens=512,
            )
        except TypeError:
            # Some SDK versions may not accept max_tokens; retry without it.
            resp = client.chat.completions.create(
                model=model,
                messages=chat_messages,
                temperature=0.2,
            )
        if resp and getattr(resp, "choices", None):
            msg = resp.choices[0].message
            content = (msg.content or "").strip() if msg else ""
            return content or None
    except Exception:
        return None

    return None


def _call_with_timeout(fn, *, timeout_s: float, default=None):
    fut = _llm_executor.submit(fn)
    try:
        return fut.result(timeout=float(timeout_s)), {"timed_out": False}
    except concurrent.futures.TimeoutError:
        return default, {"timed_out": True}
    except Exception as e:
        return default, {"timed_out": False, "error": (str(e) or "error")[:200]}


def _extract_basic_scope(query: str) -> dict:
    s = (query or "").replace(" ", "")
    out: dict = {}
    m_b = re.search(r"(\d+)(?:栋|楼|#)", s)
    if m_b:
        out["building"] = f"{m_b.group(1)}栋"
    m_f = re.search(r"(\d+)(?:层|楼)", s)
    if m_f:
        try:
            out["floor"] = int(m_f.group(1))
        except Exception:
            pass
    return out


def _last_user_utterances(messages: Optional[list[dict]], n: int = 6) -> list[str]:
    out: list[str] = []
    if not isinstance(messages, list):
        return out
    for m in reversed(messages[-(n * 2) :]):
        if not isinstance(m, dict):
            continue
        role = str(m.get("role", "")).strip().lower()
        if role not in {"user", "human"}:
            continue
        content = str(m.get("content", "")).strip()
        if content:
            out.append(content)
        if len(out) >= n:
            break
    return out


def _infer_intent(query: str, messages: Optional[list[dict]] = None) -> str:
    """Infer user intent deterministically.

    Goals:
    - Avoid hard-coded answer templates.
    - Route to the right data query & assembly.
    - Handle follow-ups like “具体什么问题” using conversation context.
    """

    q = (query or "").strip()
    s = q.replace(" ", "")
    if not s:
        return "unknown"

    # 进度类：项目/楼栋/工序/到几层
    if any(k in s for k in ["进度", "进展", "干到", "做到", "到几层", "几层", "楼层进度", "工序"]):
        # Avoid misrouting generic "几层" in other contexts.
        if any(k in s for k in ["问题", "缺陷", "巡检"]):
            pass
        else:
            return "progress"

    # Follow-up like "1栋呢" / "那1栋" should inherit previous intent.
    if re.fullmatch(r"(?:那|这个|再看下)?\s*\d+\s*(?:栋|楼|#)\s*(?:呢|怎么样|情况)?", s):
        last = "".join(_last_user_utterances(messages, n=6))
        if any(k in last for k in ["进度", "进展", "工序", "到几层", "楼栋"]):
            return "progress"
        if any(k in last for k in ["哪类问题", "问题多", "具体什么问题", "巡检", "缺陷"]):
            return "issues_detail"

    # 问题多/哪类问题：偏向巡检问题分类
    if any(k in s for k in ["哪类", "哪个类型", "类型", "问题多", "最多", "top", "排行"]):
        if any(k in s for k in ["问题", "缺陷", "巡检"]):
            return "issues_top"

    # 具体问题明细：需要列表/具体是什么
    if any(k in s for k in ["具体", "明细", "分别", "列出", "都有什么", "哪些问题", "什么问题"]):
        if any(k in s for k in ["问题", "缺陷", "巡检"]):
            return "issues_detail"
        # Follow-up: “具体什么问题” after discussing issues.
        last = "".join(_last_user_utterances(messages, n=4))
        if any(k in last for k in ["问题", "缺陷", "巡检", "未闭环"]):
            return "issues_detail"

    # 仅问数量：可以走现有汇总
    return "unknown"


def _category_key_for_issue(r: models.IssueReport) -> str:
    # Prefer human-readable names; avoid showing codes (e.g. Q-123).
    parts = [
        (r.indicator or "").strip(),
        (r.item or "").strip(),
        (r.subdivision or "").strip(),
        (r.division or "").strip(),
    ]
    for p in parts:
        if p and not _looks_like_code(p):
            return p
    # If nothing readable, do not leak library_id; fallback to a generic bucket.
    return "其他问题"


def _looks_like_code(s: str) -> bool:
    t = (s or "").strip()
    if not t:
        return False
    # Typical patterns: A001, P0231, Q-101, A001001, etc.
    if re.fullmatch(r"[A-Za-z]{1,4}-?\d{2,8}", t):
        return True
    if re.fullmatch(r"[A-Za-z]{1,4}\d{3,8}", t):
        return True
    if re.fullmatch(r"[A-Za-z]{1,4}\d{2,8}\d{3,8}", t):
        return True
    # Pure alnum/hyphen/underscore and short: likely an internal code.
    if re.fullmatch(r"[A-Za-z0-9_-]{2,16}", t) and not re.search(r"[\u4e00-\u9fff]", t):
        return True
    return False


def _short_text(s: Optional[str], max_len: int = 28) -> str:
    t = (s or "").strip().replace("\n", " ")
    if len(t) <= max_len:
        return t
    return t[: max(0, max_len - 1)] + "…"


def _progress_by_building_and_process(
    db: Session,
    *,
    project_id: int,
    building: Optional[str] = None,
    top_n_process: int = 6,
    building_limit: int = 10,
) -> list[dict]:
    """Return progress as: building -> process -> max floor reached.

    Process key uses item_code/item/indicator_code/indicator.
    Floor is derived from parsed floor_no.
    """

    top_n_process = int(top_n_process or 0) or 6
    building_limit = int(building_limit or 0) or 10

    # Prefer human-readable names; do NOT prioritize codes.
    process_key = func.coalesce(
        models.AcceptanceRecord.item,
        models.AcceptanceRecord.indicator,
        models.AcceptanceRecord.subdivision,
        models.AcceptanceRecord.division,
        models.AcceptanceRecord.item_code,
        models.AcceptanceRecord.indicator_code,
    )

    q = (
        db.query(
            models.AcceptanceRecord.building_no.label("building"),
            process_key.label("process"),
            func.max(models.AcceptanceRecord.floor_no).label("max_floor"),
            func.count(models.AcceptanceRecord.id).label("record_count"),
            func.max(case((models.AcceptanceRecord.result == "unqualified", 1), else_=0)).label("has_unq"),
            func.max(case((models.AcceptanceRecord.result == "pending", 1), else_=0)).label("has_pen"),
        )
        .filter(models.AcceptanceRecord.project_id == project_id)
        .filter(models.AcceptanceRecord.floor_no.isnot(None))
    )
    if building:
        q = q.filter(models.AcceptanceRecord.building_no == building)
    rows = q.group_by(models.AcceptanceRecord.building_no, process_key).all()

    by_b: dict[str, list[dict]] = {}
    for b, p, max_floor, cnt, has_unq, has_pen in rows:
        bn = (b or "").strip() or "未解析"
        proc = (p or "").strip() or "未命名工序"
        # Hide pure codes in UI; keep grouping but show a friendly placeholder.
        if _looks_like_code(proc):
            proc = "工序（未命名）"
        try:
            mf = int(max_floor or 0)
        except Exception:
            mf = 0
        if mf <= 0:
            continue
        status = "合格"
        if int(has_unq or 0) > 0:
            status = "含不合格"
        elif int(has_pen or 0) > 0:
            status = "含甩项"

        by_b.setdefault(bn, []).append(
            {
                "process": proc,
                "max_floor": mf,
                "record_count": int(cnt or 0),
                "status": status,
            }
        )

    def _b_sort_key(bn: str):
        m = re.search(r"(\d+)", bn)
        return (0, int(m.group(1))) if m else (1, bn)

    out: list[dict] = []
    for bn in sorted(by_b.keys(), key=_b_sort_key)[:building_limit]:
        items = by_b[bn]
        items.sort(key=lambda x: (int(x.get("max_floor", 0)), int(x.get("record_count", 0))), reverse=True)
        out.append({"building": bn, "processes": items[:top_n_process]})
    return out


def _top_issue_categories(
    db: Session,
    *,
    project_id: int,
    building: Optional[str] = None,
    floor: Optional[int] = None,
    responsible_unit: Optional[str] = None,
    top_n: int = 5,
    sample_per_cat: int = 2,
) -> list[dict]:
    top_n = int(top_n or 0) or 5
    sample_per_cat = int(sample_per_cat or 0) or 2

    q = db.query(models.IssueReport).filter(models.IssueReport.project_id == project_id)
    if building:
        q = q.filter(models.IssueReport.building_no == building)
    if floor is not None:
        q = q.filter(models.IssueReport.floor_no == int(floor))
    if responsible_unit:
        q = q.filter(models.IssueReport.responsible_unit == responsible_unit)

    rows = q.order_by(models.IssueReport.created_at.desc()).limit(5000).all()
    buckets: dict[str, dict] = {}
    for r in rows:
        key = _category_key_for_issue(r)
        b = buckets.setdefault(
            key,
            {
                "category": key,
                "total": 0,
                "open": 0,
                "severe": 0,
                "samples": [],
            },
        )
        b["total"] += 1
        if (r.status or "").strip().lower() == "open":
            b["open"] += 1
        if _normalize_severity_key(r.severity) == "severe":
            b["severe"] += 1

        if len(b["samples"]) < sample_per_cat:
            loc = (r.region_text or "").strip() or (r.building_no or "").strip() or "-"
            b["samples"].append(
                {
                    "where": loc,
                    "desc": _short_text(r.description, 26),
                    "status": (r.status or "").strip() or "open",
                    "severity": (r.severity or "").strip() or "-",
                }
            )

    cats = list(buckets.values())
    cats.sort(key=lambda x: (int(x.get("open", 0)), int(x.get("total", 0)), int(x.get("severe", 0))), reverse=True)
    return cats[:top_n]


def _doubao_extract_plan(*, query: str, messages: Optional[list[dict]] = None) -> Optional[dict]:
    """Ask Doubao to output a strict JSON plan for intent/scoping.

    If model is unavailable or output is invalid, return None.
    """
    client = _get_ark_client()
    model = (
        _get_env("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID")
        or _get_cfg("doubao.model")
        or _get_cfg("doubao.endpoint_id")
    )
    if client is None or not model:
        return None

    system_prompt = (
        "你是一个‘意图解析器’，负责把用户的问题转换为可执行的分析计划(JSON)。"
        "只输出 JSON，不要输出任何额外文字。"
        "JSON 结构：{"
        "intent: string, "
        "scope: {building?: string, floor?: number, responsible_unit?: string, time_range_days?: number}, "
        "dimensions: string[], style: 'analysis'|'summary'|'list', top_n: number}。"
        "规则："
        "- 仅当用户问题包含：关注/关注点/重点/风险/预警/下一步/focus/驾驶舱 时，intent 才能为 'focus'；否则不要输出 focus。"
        "- 如果用户问‘1栋进展/1栋6层…’，scope.building/floor 必须填；"
        "- 如果用户问‘责任单位…’，scope.responsible_unit 或 dimensions 包含 'responsible_unit'；"
        "- 如果用户提到‘本周/近7天/近两周/近30天’，尽量给出 scope.time_range_days（7/14/30 等）；"
        "- 如果用户未限定范围，scope 为空；"
        "- style 默认 'analysis'；top_n 默认 5。"
    )

    # Provide only last turns to help disambiguate follow-ups like “解释一下”.
    convo: list[dict] = []
    if isinstance(messages, list):
        for m in messages[-8:]:
            if not isinstance(m, dict):
                continue
            role = str(m.get("role", "")).strip().lower()
            if role not in {"user", "assistant"}:
                continue
            content = str(m.get("content", "")).strip()
            if not content:
                continue
            convo.append({"role": role, "content": content})

    user_prompt = (
        "根据用户输入生成分析计划(JSON)。\n"
        f"用户问题：{query}\n"
        f"上下文（可选）：{json.dumps(convo, ensure_ascii=False)}"
    )

    try:
        resp = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.0,
        )
        if not resp or not getattr(resp, "choices", None):
            return None
        msg = resp.choices[0].message
        content = (msg.content or "").strip() if msg else ""
        if not content:
            return None
        # Some models may wrap with ```json
        content = re.sub(r"^```(?:json)?\s*", "", content, flags=re.I).strip()
        content = re.sub(r"\s*```$", "", content).strip()
        data = json.loads(content)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _acceptance_item_counts(
    db: Session,
    *,
    project_id: int,
    building: Optional[str] = None,
    floor: Optional[int] = None,
) -> dict[str, int]:
    """Item-level acceptance counts within optional scope.

    Each item is classified by worst result.
    """
    item_key = func.coalesce(
        models.AcceptanceRecord.item_code,
        models.AcceptanceRecord.item,
        models.AcceptanceRecord.indicator_code,
        models.AcceptanceRecord.indicator,
    )
    q = (
        db.query(
            item_key.label("item_key"),
            func.max(case((models.AcceptanceRecord.result == "unqualified", 1), else_=0)).label("has_unq"),
            func.max(case((models.AcceptanceRecord.result == "pending", 1), else_=0)).label("has_pen"),
        )
        .filter(models.AcceptanceRecord.project_id == project_id)
    )
    if building:
        q = q.filter(models.AcceptanceRecord.building_no == building)
    if floor is not None:
        q = q.filter(models.AcceptanceRecord.floor_no == floor)
    rows = q.group_by(item_key).all()

    out = {"qualified": 0, "unqualified": 0, "pending": 0}
    for _k, has_unq, has_pen in rows:
        if int(has_unq or 0) > 0:
            out["unqualified"] += 1
        elif int(has_pen or 0) > 0:
            out["pending"] += 1
        else:
            out["qualified"] += 1
    return out


def _issue_counts(
    db: Session,
    *,
    project_id: int,
    building: Optional[str] = None,
    floor: Optional[int] = None,
    responsible_unit: Optional[str] = None,
) -> dict[str, int]:
    q = db.query(models.IssueReport.status, func.count(models.IssueReport.id)).filter(
        models.IssueReport.project_id == project_id
    )
    if building:
        q = q.filter(models.IssueReport.building_no == building)
    if floor is not None:
        q = q.filter(models.IssueReport.floor_no == floor)
    if responsible_unit:
        q = q.filter(models.IssueReport.responsible_unit == responsible_unit)
    rows = q.group_by(models.IssueReport.status).all()
    m = {str(k): int(v) for k, v in rows}
    return {
        "total": sum(m.values()),
        "open": int(m.get("open", 0)),
        "closed": int(m.get("closed", 0)),
    }


def _by_floor_facts(db: Session, project_id: int, building: str) -> list[dict]:
    """Progress breakdown by floor within a building."""
    # Acceptance by floor (item-level)
    item_key = func.coalesce(
        models.AcceptanceRecord.item_code,
        models.AcceptanceRecord.item,
        models.AcceptanceRecord.indicator_code,
        models.AcceptanceRecord.indicator,
    )
    a_rows = (
        db.query(
            models.AcceptanceRecord.floor_no,
            item_key.label("item_key"),
            func.max(case((models.AcceptanceRecord.result == "unqualified", 1), else_=0)).label("has_unq"),
            func.max(case((models.AcceptanceRecord.result == "pending", 1), else_=0)).label("has_pen"),
        )
        .filter(models.AcceptanceRecord.project_id == project_id)
        .filter(models.AcceptanceRecord.building_no == building)
        .group_by(models.AcceptanceRecord.floor_no, item_key)
        .all()
    )
    by_f: dict[int, dict] = {}
    for floor_no, _k, has_unq, has_pen in a_rows:
        fkey = int(floor_no or 0)
        d = by_f.setdefault(
            fkey,
            {
                "floor": fkey,
                "acceptance_total": 0,
                "acceptance_qualified": 0,
                "acceptance_unqualified": 0,
                "acceptance_pending": 0,
                "issues_total": 0,
                "issues_open": 0,
                "issues_closed": 0,
            },
        )
        d["acceptance_total"] += 1
        if int(has_unq or 0) > 0:
            d["acceptance_unqualified"] += 1
        elif int(has_pen or 0) > 0:
            d["acceptance_pending"] += 1
        else:
            d["acceptance_qualified"] += 1

    i_rows = (
        db.query(
            models.IssueReport.floor_no,
            models.IssueReport.status,
            func.count(models.IssueReport.id),
        )
        .filter(models.IssueReport.project_id == project_id)
        .filter(models.IssueReport.building_no == building)
        .group_by(models.IssueReport.floor_no, models.IssueReport.status)
        .all()
    )
    for floor_no, status, cnt in i_rows:
        fkey = int(floor_no or 0)
        d = by_f.setdefault(
            fkey,
            {
                "floor": fkey,
                "acceptance_total": 0,
                "acceptance_qualified": 0,
                "acceptance_unqualified": 0,
                "acceptance_pending": 0,
                "issues_total": 0,
                "issues_open": 0,
                "issues_closed": 0,
            },
        )
        d["issues_total"] += int(cnt)
        sk = str(status or "").strip().lower()
        if sk == "open":
            d["issues_open"] += int(cnt)
        elif sk == "closed":
            d["issues_closed"] += int(cnt)

    return [by_f[k] for k in sorted(by_f.keys()) if k != 0]


def _facts_for_plan(
    db: Session,
    *,
    project_id: int,
    plan: ChatPlan,
    limit: int,
) -> dict:
    scope = plan.scope or {}
    building = (scope.get("building") or "").strip() or None
    floor = scope.get("floor")
    try:
        floor = int(floor) if floor is not None else None
    except Exception:
        floor = None
    responsible_unit = (scope.get("responsible_unit") or "").strip() or None

    # Always include a minimal project-level summary for context, but when scoped,
    # also add scope_* facts and scoped breakdowns.
    base = dashboard_summary(project_id=project_id, project_name=None, limit=limit, db=db)
    base["by_building"] = _building_progress_facts(db, project_id)

    if not building and floor is None and not responsible_unit:
        return base

    # Scoped acceptance/issue counts
    a = _acceptance_item_counts(db, project_id=project_id, building=building, floor=floor)
    i = _issue_counts(
        db,
        project_id=project_id,
        building=building,
        floor=floor,
        responsible_unit=responsible_unit,
    )

    base["scope"] = {
        "building": building,
        "floor": floor,
        "responsible_unit": responsible_unit,
    }
    base["scope_acceptance"] = {
        "acceptance_total": int(sum(a.values())),
        "acceptance_qualified": int(a.get("qualified", 0)),
        "acceptance_unqualified": int(a.get("unqualified", 0)),
        "acceptance_pending": int(a.get("pending", 0)),
        "definition": "验收分项口径：按 item/item_code 去重并按最差结果归类（不合格>甩项>合格）",
    }
    base["scope_issues"] = {
        "issues_total": int(i.get("total", 0)),
        "issues_open": int(i.get("open", 0)),
        "issues_closed": int(i.get("closed", 0)),
    }

    if building:
        base["by_floor"] = _by_floor_facts(db, project_id, building)

    return base


def _building_progress_facts(db: Session, project_id: int) -> list[dict]:
    # Acceptance by building (item-level): each item is classified by worst result.
    item_key = func.coalesce(
        models.AcceptanceRecord.item_code,
        models.AcceptanceRecord.item,
        models.AcceptanceRecord.indicator_code,
        models.AcceptanceRecord.indicator,
    )
    a_rows = (
        db.query(
            models.AcceptanceRecord.building_no,
            item_key.label("item_key"),
            func.max(case((models.AcceptanceRecord.result == "unqualified", 1), else_=0)).label("has_unq"),
            func.max(case((models.AcceptanceRecord.result == "pending", 1), else_=0)).label("has_pen"),
        )
        .filter(models.AcceptanceRecord.project_id == project_id)
        .group_by(models.AcceptanceRecord.building_no, item_key)
        .all()
    )

    by_b: dict[str, dict] = {}
    for b, _k, has_unq, has_pen in a_rows:
        bkey = (b or "").strip() or "未解析"
        d = by_b.setdefault(
            bkey,
            {
                "building": bkey,
                "acceptance_total": 0,
                "acceptance_qualified": 0,
                "acceptance_unqualified": 0,
                "acceptance_pending": 0,
                "issues_total": 0,
                "issues_open": 0,
                "issues_closed": 0,
            },
        )
        d["acceptance_total"] += 1
        if int(has_unq or 0) > 0:
            d["acceptance_unqualified"] += 1
        elif int(has_pen or 0) > 0:
            d["acceptance_pending"] += 1
        else:
            d["acceptance_qualified"] += 1

    # Issues by building & status
    i_rows = (
        db.query(
            models.IssueReport.building_no,
            models.IssueReport.status,
            func.count(models.IssueReport.id),
        )
        .filter(models.IssueReport.project_id == project_id)
        .group_by(models.IssueReport.building_no, models.IssueReport.status)
        .all()
    )
    for b, s, c in i_rows:
        bkey = (b or "").strip() or "未解析"
        d = by_b.setdefault(
            bkey,
            {
                "building": bkey,
                "acceptance_total": 0,
                "acceptance_qualified": 0,
                "acceptance_unqualified": 0,
                "acceptance_pending": 0,
                "issues_total": 0,
                "issues_open": 0,
                "issues_closed": 0,
            },
        )
        d["issues_total"] += int(c)
        sk = str(s or "").strip().lower()
        if sk == "open":
            d["issues_open"] += int(c)
        elif sk == "closed":
            d["issues_closed"] += int(c)

    def _sort_key(x: dict):
        m = re.search(r"(\d+)", x.get("building", ""))
        return (0, int(m.group(1))) if m else (1, x.get("building", ""))

    return sorted(by_b.values(), key=_sort_key)


@app.get("/v1/health")
def health():
    return {"status": "ok"}


@app.get("/v1/projects")
def list_projects(db: Session = Depends(get_db)):
    rows = db.query(models.Project).order_by(models.Project.created_at.desc()).limit(200).all()
    return [ProjectOut.model_validate(r).model_dump() for r in rows]


@app.post("/v1/projects/ensure")
def ensure_project(payload: ProjectIn, db: Session = Depends(get_db)):
    p = _ensure_project(db, payload.name)
    if payload.address and payload.address.strip():
        addr = payload.address.strip()
        if (p.address or "").strip() != addr:
            p.address = addr
            db.commit()
    return {"id": p.id, "name": p.name}


@app.post("/v1/acceptance-records")
def create_acceptance_record(payload: AcceptanceRecordIn, db: Session = Depends(get_db)):
    if payload.project_id is not None:
        project_id = payload.project_id
    elif payload.project_name and payload.project_name.strip():
        project_id = _ensure_project(db, payload.project_name).id
    else:
        project_id = _ensure_project(db, "默认项目").id

    building_no, floor_no = _parse_building_floor(payload.region_text)
    zone = _parse_zone(payload.region_text)

    normalized_photo_path = _normalize_upload_ref(payload.photo_path)

    if payload.client_record_id and payload.client_record_id.strip():
        key = payload.client_record_id.strip()
        existing = (
            db.query(models.AcceptanceRecord)
            .filter(models.AcceptanceRecord.project_id == project_id)
            .filter(models.AcceptanceRecord.client_record_id == key)
            .first()
        )
        if existing is not None:
            existing.region_code = payload.region_code
            existing.region_text = payload.region_text
            existing.building_no = building_no
            existing.floor_no = floor_no
            existing.zone = zone
            existing.division = payload.division
            existing.subdivision = payload.subdivision
            existing.item = payload.item
            existing.item_code = payload.item_code
            existing.indicator = payload.indicator
            existing.indicator_code = payload.indicator_code
            existing.result = payload.result
            existing.photo_path = normalized_photo_path
            existing.remark = payload.remark
            existing.ai_json = payload.ai_json
            existing.client_created_at = payload.client_created_at
            existing.source = payload.source
            db.commit()
            return {"id": existing.id}

    row = models.AcceptanceRecord(
        project_id=project_id,
        region_code=payload.region_code,
        region_text=payload.region_text,
        building_no=building_no,
        floor_no=floor_no,
        zone=zone,
        division=payload.division,
        subdivision=payload.subdivision,
        item=payload.item,
        item_code=payload.item_code,
        indicator=payload.indicator,
        indicator_code=payload.indicator_code,
        result=payload.result,
        photo_path=normalized_photo_path,
        remark=payload.remark,
        ai_json=payload.ai_json,
        client_created_at=payload.client_created_at,
        source=payload.source,
        client_record_id=payload.client_record_id,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return {"id": row.id}


@app.get("/v1/acceptance-records")
def list_acceptance_records(
    project_id: int = 1,
    project_name: Optional[str] = None,
    limit: int = 100,
    db: Session = Depends(get_db),
):
    if project_name and project_name.strip():
        project_id = _ensure_project(db, project_name.strip()).id
    rows = (
        db.query(models.AcceptanceRecord)
        .filter(models.AcceptanceRecord.project_id == project_id)
        .order_by(models.AcceptanceRecord.created_at.desc())
        .limit(limit)
        .all()
    )
    return [AcceptanceRecordOut.model_validate(r).model_dump() for r in rows]


@app.get("/v1/acceptance-records/{record_id}")
def get_acceptance_record(record_id: int, db: Session = Depends(get_db)):
    r = db.query(models.AcceptanceRecord).filter(models.AcceptanceRecord.id == record_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="acceptance record not found")
    return AcceptanceRecordOut.model_validate(r).model_dump()


def _add_action(
    db: Session,
    *,
    project_id: int,
    target_type: str,
    target_id: int,
    payload: RectificationActionIn,
) -> models.RectificationAction:
    ttype = (target_type or "").strip().lower()
    if ttype not in {"issue", "acceptance"}:
        raise HTTPException(status_code=400, detail="invalid target_type")

    at = (payload.action_type or "").strip().lower()
    if at not in {"rectify", "verify", "close", "comment"}:
        raise HTTPException(status_code=400, detail="invalid action_type")

    content = (payload.content or "").strip() or None
    photos = [str(x).strip() for x in (payload.photo_urls or []) if str(x).strip()]
    photos = [p for p in (_normalize_upload_ref(x) for x in photos) if p]

    row = models.RectificationAction(
        project_id=project_id,
        target_type=ttype,
        target_id=int(target_id),
        action_type=at,
        content=content,
        photo_urls=json.dumps(photos, ensure_ascii=False) if photos else None,
        actor_role=(payload.actor_role or "").strip() or None,
        actor_name=(payload.actor_name or "").strip() or None,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


@app.get("/v1/acceptance-records/{record_id}/actions")
def list_acceptance_actions(record_id: int, db: Session = Depends(get_db)):
    r = db.query(models.AcceptanceRecord).filter(models.AcceptanceRecord.id == record_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="acceptance record not found")
    rows = (
        db.query(models.RectificationAction)
        .filter(models.RectificationAction.target_type == "acceptance")
        .filter(models.RectificationAction.target_id == record_id)
        .order_by(models.RectificationAction.created_at.asc())
        .limit(200)
        .all()
    )
    return [RectificationActionOut.model_validate(x).model_dump() for x in rows]


@app.post("/v1/acceptance-records/{record_id}/actions")
def add_acceptance_action(record_id: int, payload: RectificationActionIn, db: Session = Depends(get_db)):
    r = db.query(models.AcceptanceRecord).filter(models.AcceptanceRecord.id == record_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="acceptance record not found")
    row = _add_action(
        db,
        project_id=r.project_id,
        target_type="acceptance",
        target_id=record_id,
        payload=payload,
    )
    return {"id": row.id}


@app.post("/v1/acceptance-records/{record_id}/verify")
def verify_acceptance_record(record_id: int, payload: AcceptanceVerifyIn, db: Session = Depends(get_db)):
    r = db.query(models.AcceptanceRecord).filter(models.AcceptanceRecord.id == record_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="acceptance record not found")

    next_result = (payload.result or "").strip().lower()
    if next_result not in {"qualified", "unqualified", "pending"}:
        raise HTTPException(status_code=400, detail="invalid result")

    # Update record
    r.result = next_result
    if payload.remark is not None:
        r.remark = payload.remark
    db.commit()

    # Add verify action for audit trail
    _add_action(
        db,
        project_id=r.project_id,
        target_type="acceptance",
        target_id=record_id,
        payload=RectificationActionIn(
            action_type="verify",
            content=(payload.remark or "").strip() or f"复验结果：{next_result}",
            photo_urls=payload.photo_urls,
            actor_role=payload.actor_role,
            actor_name=payload.actor_name,
        ),
    )
    return {"id": r.id, "result": r.result}


@app.post("/v1/issue-reports")
def create_issue_report(payload: IssueReportIn, db: Session = Depends(get_db)):
    if payload.project_id is not None:
        project_id = payload.project_id
    elif payload.project_name and payload.project_name.strip():
        project_id = _ensure_project(db, payload.project_name).id
    else:
        project_id = _ensure_project(db, "默认项目").id

    region_text = payload.region_text or ""
    building_no, floor_no = _parse_building_floor(region_text)
    zone = _parse_zone(region_text)

    normalized_photo_path = _normalize_upload_ref(payload.photo_path)

    if payload.client_record_id and payload.client_record_id.strip():
        key = payload.client_record_id.strip()
        existing = (
            db.query(models.IssueReport)
            .filter(models.IssueReport.project_id == project_id)
            .filter(models.IssueReport.client_record_id == key)
            .first()
        )
        if existing is not None:
            existing.region_code = payload.region_code
            existing.region_text = payload.region_text
            existing.building_no = building_no
            existing.floor_no = floor_no
            existing.zone = zone
            existing.division = payload.division
            existing.subdivision = payload.subdivision
            existing.item = payload.item
            existing.indicator = payload.indicator
            existing.library_id = payload.library_id
            existing.description = payload.description
            existing.severity = payload.severity
            existing.deadline_days = payload.deadline_days
            existing.responsible_unit = payload.responsible_unit
            existing.responsible_person = payload.responsible_person
            existing.status = payload.status
            existing.photo_path = normalized_photo_path
            existing.ai_json = payload.ai_json
            existing.client_created_at = payload.client_created_at
            existing.source = payload.source
            db.commit()
            return {"id": existing.id}

    row = models.IssueReport(
        project_id=project_id,
        region_code=payload.region_code,
        region_text=payload.region_text,
        building_no=building_no,
        floor_no=floor_no,
        zone=zone,
        division=payload.division,
        subdivision=payload.subdivision,
        item=payload.item,
        indicator=payload.indicator,
        library_id=payload.library_id,
        description=payload.description,
        severity=payload.severity,
        deadline_days=payload.deadline_days,
        responsible_unit=payload.responsible_unit,
        responsible_person=payload.responsible_person,
        status=payload.status,
        photo_path=normalized_photo_path,
        ai_json=payload.ai_json,
        client_created_at=payload.client_created_at,
        source=payload.source,
        client_record_id=payload.client_record_id,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return {"id": row.id}


@app.get("/v1/issue-reports")
def list_issue_reports(
    project_id: int = 1,
    project_name: Optional[str] = None,
    limit: int = 100,
    status: Optional[str] = None,
    responsible_unit: Optional[str] = None,
    db: Session = Depends(get_db),
):
    if project_name and project_name.strip():
        project_id = _ensure_project(db, project_name.strip()).id
    q = db.query(models.IssueReport).filter(models.IssueReport.project_id == project_id)
    if status:
        q = q.filter(models.IssueReport.status == status)
    if responsible_unit:
        q = q.filter(models.IssueReport.responsible_unit == responsible_unit)
    rows = q.order_by(models.IssueReport.created_at.desc()).limit(limit).all()
    return [IssueReportOut.model_validate(r).model_dump() for r in rows]


@app.get("/v1/issue-reports/{issue_id}")
def get_issue_report(issue_id: int, db: Session = Depends(get_db)):
    r = db.query(models.IssueReport).filter(models.IssueReport.id == issue_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="issue report not found")
    return IssueReportOut.model_validate(r).model_dump()


@app.get("/v1/issue-reports/{issue_id}/actions")
def list_issue_actions(issue_id: int, db: Session = Depends(get_db)):
    r = db.query(models.IssueReport).filter(models.IssueReport.id == issue_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="issue report not found")
    rows = (
        db.query(models.RectificationAction)
        .filter(models.RectificationAction.target_type == "issue")
        .filter(models.RectificationAction.target_id == issue_id)
        .order_by(models.RectificationAction.created_at.asc())
        .limit(200)
        .all()
    )
    return [RectificationActionOut.model_validate(x).model_dump() for x in rows]


@app.post("/v1/issue-reports/{issue_id}/actions")
def add_issue_action(issue_id: int, payload: RectificationActionIn, db: Session = Depends(get_db)):
    r = db.query(models.IssueReport).filter(models.IssueReport.id == issue_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="issue report not found")
    row = _add_action(
        db,
        project_id=r.project_id,
        target_type="issue",
        target_id=issue_id,
        payload=payload,
    )
    return {"id": row.id}


@app.post("/v1/issue-reports/{issue_id}/close")
def close_issue(issue_id: int, payload: RectificationActionIn, db: Session = Depends(get_db)):
    r = db.query(models.IssueReport).filter(models.IssueReport.id == issue_id).first()
    if r is None:
        raise HTTPException(status_code=404, detail="issue report not found")
    r.status = "closed"
    db.commit()

    # Ensure action type is close
    p = RectificationActionIn(
        action_type="close",
        content=payload.content,
        photo_urls=payload.photo_urls,
        actor_role=payload.actor_role,
        actor_name=payload.actor_name,
    )
    row = _add_action(
        db,
        project_id=r.project_id,
        target_type="issue",
        target_id=issue_id,
        payload=p,
    )
    return {"id": r.id, "status": r.status, "action_id": row.id}


@app.get("/v1/dashboard/summary")
def dashboard_summary(
    project_id: int = 1,
    project_name: Optional[str] = None,
    limit: int = 10,
    db: Session = Depends(get_db),
):
    if project_name and project_name.strip():
        project_id = _ensure_project(db, project_name.strip()).id

    # Acceptance counts (item-level): each item is classified by worst result.
    # Priority: unqualified > pending > qualified.
    item_key = func.coalesce(
        models.AcceptanceRecord.item_code,
        models.AcceptanceRecord.item,
        models.AcceptanceRecord.indicator_code,
        models.AcceptanceRecord.indicator,
    )
    a_rows = (
        db.query(
            item_key.label("item_key"),
            func.max(case((models.AcceptanceRecord.result == "unqualified", 1), else_=0)).label("has_unq"),
            func.max(case((models.AcceptanceRecord.result == "pending", 1), else_=0)).label("has_pen"),
        )
        .filter(models.AcceptanceRecord.project_id == project_id)
        .group_by(item_key)
        .all()
    )
    a_counts = {"qualified": 0, "unqualified": 0, "pending": 0}
    for _k, has_unq, has_pen in a_rows:
        if int(has_unq or 0) > 0:
            a_counts["unqualified"] += 1
        elif int(has_pen or 0) > 0:
            a_counts["pending"] += 1
        else:
            a_counts["qualified"] += 1

    # Issue counts by status
    i_rows = (
        db.query(models.IssueReport.status, func.count(models.IssueReport.id))
        .filter(models.IssueReport.project_id == project_id)
        .group_by(models.IssueReport.status)
        .all()
    )
    i_counts = {str(k): int(v) for k, v in i_rows}

    # Issue counts by severity
    s_rows = (
        db.query(models.IssueReport.severity, func.count(models.IssueReport.id))
        .filter(models.IssueReport.project_id == project_id)
        .group_by(models.IssueReport.severity)
        .all()
    )
    sev_counts: dict[str, int] = {}
    for k, v in s_rows:
        key = (k or "").strip() or "未填写"
        sev_counts[key] = int(v)

    # Top responsible units (open issues)
    u_rows = (
        db.query(models.IssueReport.responsible_unit, func.count(models.IssueReport.id))
        .filter(models.IssueReport.project_id == project_id)
        .filter(models.IssueReport.status == "open")
        .group_by(models.IssueReport.responsible_unit)
        .order_by(func.count(models.IssueReport.id).desc())
        .limit(10)
        .all()
    )
    top_units = [
        {"responsible_unit": (k or "").strip() or "未填写", "count": int(v)}
        for k, v in u_rows
    ]

    recent_unqualified = (
        db.query(models.AcceptanceRecord)
        .filter(models.AcceptanceRecord.project_id == project_id)
        .filter(models.AcceptanceRecord.result == "unqualified")
        .order_by(models.AcceptanceRecord.created_at.desc())
        .limit(limit)
        .all()
    )
    recent_open = (
        db.query(models.IssueReport)
        .filter(models.IssueReport.project_id == project_id)
        .filter(models.IssueReport.status == "open")
        .order_by(models.IssueReport.created_at.desc())
        .limit(limit)
        .all()
    )

    out = DashboardSummaryOut(
        acceptance_total=sum(a_counts.values()),
        acceptance_qualified=a_counts.get("qualified", 0),
        acceptance_unqualified=a_counts.get("unqualified", 0),
        acceptance_pending=a_counts.get("pending", 0),
        issues_total=sum(i_counts.values()),
        issues_open=i_counts.get("open", 0),
        issues_closed=i_counts.get("closed", 0),
        issues_by_severity=sev_counts,
        top_responsible_units=top_units,
        recent_unqualified_acceptance=[
            AcceptanceRecordOut.model_validate(r).model_dump() for r in recent_unqualified
        ],
        recent_open_issues=[IssueReportOut.model_validate(r).model_dump() for r in recent_open],
    )
    return out.model_dump()


@app.get("/v1/dashboard/focus")
def dashboard_focus(
    project_id: int = 1,
    project_name: Optional[str] = None,
    time_range_days: int = 14,
    building: Optional[str] = None,
    do_backfill: bool = True,
    backfill_limit: int = 200,
    db: Session = Depends(get_db),
):
    if project_name and project_name.strip():
        project_id = _ensure_project(db, project_name.strip()).id

    b = (building or "").strip() or None
    pack = _dashboard_focus_pack(
        db,
        project_id=project_id,
        time_range_days=int(time_range_days or 14),
        building=b,
        do_backfill=bool(do_backfill),
        backfill_limit=int(backfill_limit or 200),
    )
    return pack


@app.post("/v1/ai/chat")
def chat_with_data(payload: ChatIn, db: Session = Depends(get_db)):
    q = (payload.query or "").strip()
    if not q and payload.messages:
        try:
            last_user = next(
                (
                    m
                    for m in reversed(payload.messages)
                    if isinstance(m, dict)
                    and str(m.get("role", "")).strip().lower() in {"user", "human"}
                    and str(m.get("content", "")).strip()
                ),
                None,
            )
            if last_user:
                q = str(last_user.get("content", "")).strip()
        except Exception:
            q = q

    if not q:
        raise HTTPException(status_code=400, detail="query is empty")

    project_id = (
        _ensure_project(db, payload.project_name).id
        if payload.project_name and payload.project_name.strip()
        else _ensure_project(db, "默认项目").id
    )

    # Best-effort backfill to ensure building/floor are available for grouping.
    _backfill_region_fields(db, project_id=project_id, limit=200)

    # 0) Deterministic intent inference for tool-like queries.
    intent = _infer_intent(q, payload.messages)
    scope0 = _extract_basic_scope(q)
    b0 = (scope0.get("building") or "").strip() or None
    f0 = scope0.get("floor")
    try:
        f0 = int(f0) if f0 is not None else None
    except Exception:
        f0 = None

    if intent == "progress":
        progress = _progress_by_building_and_process(
            db,
            project_id=project_id,
            building=b0,
            top_n_process=6,
            building_limit=10,
        )

        lines: list[str] = []
        if b0:
            lines.append(f"{b0}工序进度（按已落库验收记录推算）：")
        else:
            lines.append("项目工序进度（每栋：工序→到几层，按已落库验收记录推算）：")

        if not progress:
            lines.append("- 暂无可用的楼栋/楼层数据（请确保部位包含‘1栋6层’且已录入验收）。")
        else:
            for it in progress:
                bn = str(it.get("building", "未解析"))
                ps = it.get("processes", [])
                if not isinstance(ps, list) or not ps:
                    continue
                segs: list[str] = []
                for p in ps:
                    if not isinstance(p, dict):
                        continue
                    proc = str(p.get("process", "工序")).strip() or "工序"
                    mf = int(p.get("max_floor", 0) or 0)
                    status = str(p.get("status", ""))
                    if status and status != "合格":
                        segs.append(f"{proc}到{mf}层（{status}）")
                    else:
                        segs.append(f"{proc}到{mf}层")
                if segs:
                    lines.append(f"- {bn}：" + "；".join(segs))

        lines.append("\n提示：统计口径=同一工序在该楼栋出现过的最高楼层；楼栋/楼层解析依赖部位格式‘1栋6层/区域’。")

        meta: dict = {
            "route": "chat",
            "tool": {"intent": "progress", "scope": scope0},
            "llm": {
                "used": False,
                "provider": "doubao",
                "model": (
                    _get_env("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID")
                    or _get_cfg("doubao.model")
                    or _get_cfg("doubao.endpoint_id")
                    or ""
                ),
            },
        }
        return ChatOut(answer="\n".join(lines), facts={"progress": progress}, meta=meta).model_dump()

    if intent in {"issues_top", "issues_detail"}:
        cats = _top_issue_categories(
            db,
            project_id=project_id,
            building=b0,
            floor=f0,
            responsible_unit=None,
            top_n=5,
            sample_per_cat=3 if intent == "issues_detail" else 1,
        )

        scope_txt = []
        if b0:
            scope_txt.append(b0)
        if f0 is not None:
            scope_txt.append(f"{f0}层")
        scope_s = "，".join(scope_txt)

        lines: list[str] = []
        head = "巡检问题类型排行" if intent == "issues_top" else "巡检问题明细（按类型汇总+示例）"
        lines.append(f"{head}{('（' + scope_s + '）') if scope_s else ''}：")

        if not cats:
            lines.append("- 暂无可统计的问题数据（可能未录入巡检，或楼栋/楼层未解析）。")
        else:
            for idx, c in enumerate(cats, start=1):
                cat = str(c.get("category", "未分类")).strip() or "未分类"
                total = int(c.get("total", 0) or 0)
                open_ = int(c.get("open", 0) or 0)
                sev = int(c.get("severe", 0) or 0)
                line = f"{idx}) {cat}：{total}条（未闭环{open_}，严重{sev}）"
                lines.append(line)
                if intent == "issues_detail":
                    samples = c.get("samples", [])
                    if isinstance(samples, list) and samples:
                        for sm in samples[:3]:
                            if not isinstance(sm, dict):
                                continue
                            where = str(sm.get("where", "-"))
                            desc = str(sm.get("desc", ""))
                            st = str(sm.get("status", ""))
                            sv = str(sm.get("severity", ""))
                            lines.append(f"   - 例：{where}｜{desc}（{st}，{sv}）")

        if intent == "issues_top":
            lines.append("\n你可以继续问：‘具体什么问题？’我会把每类的示例条目列出来。")

        meta: dict = {
            "route": "chat",
            "tool": {"intent": intent, "scope": scope0},
            "llm": {
                "used": False,
                "provider": "doubao",
                "model": (
                    _get_env("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID")
                    or _get_cfg("doubao.model")
                    or _get_cfg("doubao.endpoint_id")
                    or ""
                ),
            },
        }
        return ChatOut(answer="\n".join(lines), facts={"issue_categories": cats}, meta=meta).model_dump()

    # 1) Extract an intent plan (prefer LLM, fallback heuristics)
    def _plan_call():
        return _doubao_extract_plan(query=q, messages=payload.messages)

    raw_plan, plan_call_meta = _call_with_timeout(_plan_call, timeout_s=1.8, default=None)
    plan = None
    if isinstance(raw_plan, dict):
        try:
            plan = ChatPlan.model_validate(raw_plan)
        except Exception:
            plan = None
    if plan is None:
        plan = ChatPlan(
            intent="focus" if _is_focus_query(q) else "fallback",
            scope=_extract_basic_scope(q),
            style="analysis",
        )

    # Guardrail: don't let LLM mis-route everything into focus.
    focus_by_keyword = _is_focus_query(q)
    if not focus_by_keyword and (plan.intent or "").strip().lower() == "focus":
        plan.intent = "fallback"

    # Focus intent: use deterministic Focus Pack + fixed template, no LLM.
    if focus_by_keyword:
        scope = plan.scope or {}
        b = (scope.get("building") or "").strip() or None
        try:
            days = int(scope.get("time_range_days") or 14)
        except Exception:
            days = 14

        focus_pack = _dashboard_focus_pack(
            db,
            project_id=project_id,
            time_range_days=days,
            building=b,
            do_backfill=True,
            backfill_limit=200,
        )
        focus_pack["meta"]["plan"] = plan.model_dump()
        answer = _focus_answer_from_pack(focus_pack)

        meta: dict = {
            "route": "focus",
            "llm": {
                "used": False,
                "provider": "doubao",
                "model": (
                    _get_env("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID")
                    or _get_cfg("doubao.model")
                    or _get_cfg("doubao.endpoint_id")
                    or ""
                ),
            },
        }
        return ChatOut(answer=answer, facts={"focus_pack": focus_pack}, meta=meta).model_dump()

    # 2) Build facts based on plan scope
    facts = _facts_for_plan(db, project_id=project_id, plan=plan, limit=10)
    facts["plan"] = plan.model_dump()

    meta: dict = {
        "route": "chat",
        "llm": {
            "used": False,
            "provider": "doubao",
            "model": (
                _get_env("ARK_MODEL", "DOUBAO_MODEL", "DOUBAO_ENDPOINT_ID")
                or _get_cfg("doubao.model")
                or _get_cfg("doubao.endpoint_id")
                or ""
            ),
        }
    }

    if plan_call_meta.get("timed_out"):
        meta["llm"]["plan_timed_out"] = True

    # Prefer Doubao (ARK) if configured; fall back to rule-based MVP.
    # Hard guard: keep total latency under client receiveTimeout (default 8s).
    def _ans_call():
        return _doubao_chat_answer(query=q, facts=facts, messages=payload.messages)

    llm_answer, ans_call_meta = _call_with_timeout(_ans_call, timeout_s=5.5, default=None)
    if llm_answer:
        meta["llm"]["used"] = True
        return ChatOut(answer=llm_answer, facts=facts, meta=meta).model_dump()

    if ans_call_meta.get("timed_out"):
        meta["llm"]["timed_out"] = True
        meta["llm"]["fallback"] = "local_timeout"
    if ans_call_meta.get("error"):
        meta["llm"]["error"] = ans_call_meta.get("error")
        meta["llm"]["fallback"] = "local_error"

    # Rule-based MVP (replace with Doubao later): answer using real aggregated facts.
    a_unq = int(facts.get("acceptance_unqualified", 0))
    a_ok = int(facts.get("acceptance_qualified", 0))
    a_pen = int(facts.get("acceptance_pending", 0))
    i_open = int(facts.get("issues_open", 0))
    i_total = int(facts.get("issues_total", 0))

    if "不合格" in q and "验收" in q:
        answer = f"当前验收不合格 {a_unq} 条（合格 {a_ok}，甩项 {a_pen}）。"
    elif "巡检" in q and ("多少" in q or "几条" in q or "数量" in q):
        answer = f"当前巡检问题共 {i_total} 条，其中未闭环(open) {i_open} 条。"
    elif "责任单位" in q or "谁" in q:
        top = facts.get("top_responsible_units", [])
        if top:
            head = top[0]
            answer = f"未闭环问题最多的责任单位是 {head.get('responsible_unit')}（{head.get('count')} 条）。"
        else:
            answer = "当前没有可统计的责任单位分布。"
    else:
        by_b = facts.get("by_building", [])
        m_b = re.search(r"(\d+)\s*(?:栋|楼|#)", q.replace(" ", ""))
        target_building = f"{m_b.group(1)}栋" if m_b else None
        if any(k in q for k in ["解释", "怎么理解", "含义"]):
            lines = [
                "说明：我基于本项目已写入的验收/巡检数据进行汇总。",
                "- ‘验收分项’：按分项(item/item_code)去重后统计，并按最差结果归类（不合格>甩项>合格）。",
                "- ‘巡检未闭环’：status=open 的问题数。",
                "- ‘未解析’楼栋：说明该条记录的 region_text/building_no 无法解析到楼栋，建议按‘1栋6层/区域’规范填写。",
            ]
            answer = "\n".join(lines)
        elif any(k in q for k in ["为什么", "原因", "归因", "分析", "风险", "建议", "怎么改", "怎么做"]):
            top = facts.get("top_responsible_units", [])
            recent_bad = facts.get("recent_unqualified_acceptance", [])
            recent_open = facts.get("recent_open_issues", [])
            lines = ["分析与建议（基于现有事实）："]
            if isinstance(top, list) and top:
                head = top[0] if isinstance(top[0], dict) else None
                if head:
                    lines.append(
                        f"- 当前未闭环问题主要集中在责任单位：{head.get('responsible_unit')}（{int(head.get('count', 0))} 条）。"
                    )
            if isinstance(recent_bad, list) and recent_bad:
                r0 = recent_bad[0] if isinstance(recent_bad[0], dict) else None
                if r0:
                    lines.append(
                        f"- 最近一次不合格验收：{r0.get('region_text')} / {r0.get('item')} / {r0.get('indicator')}（备注：{r0.get('remark') or '无'}）。"
                    )
            if isinstance(recent_open, list) and recent_open:
                i0 = recent_open[0] if isinstance(recent_open[0], dict) else None
                if i0:
                    lines.append(
                        f"- 最近一条未闭环巡检：{i0.get('region_text')}（责任单位：{i0.get('responsible_unit') or '未填写'}）。"
                    )
            lines.append("- 建议：优先闭环 open 问题；对不合格分项复查并补充照片/整改记录；统一位置填写以提升楼栋/楼层统计质量。")
            answer = "\n".join(lines)
        elif any(k in q for k in ["进展", "进度", "每栋", "各栋", "楼栋", "几栋"]):
            scoped = []
            if isinstance(by_b, list) and by_b:
                for b in by_b:
                    if not isinstance(b, dict):
                        continue
                    bn = str(b.get("building", "未解析"))
                    if target_building and bn != target_building:
                        continue
                    scoped.append(b)

            if target_building:
                lines = [f"{target_building}进展（基于已落库数据）："]
            else:
                lines = ["项目进展（按楼栋汇总）："]

            if scoped:
                for b in scoped:
                    bn = str(b.get("building", "未解析"))
                    lines.append(
                        f"- {bn}：验收{int(b.get('acceptance_total', 0))}（不合格{int(b.get('acceptance_unqualified', 0))}，合格{int(b.get('acceptance_qualified', 0))}，甩项{int(b.get('acceptance_pending', 0))}）；"
                        f"巡检{int(b.get('issues_total', 0))}（未闭环{int(b.get('issues_open', 0))}）"
                    )
            elif target_building:
                lines.append("- 暂无该楼栋的数据（可能楼栋未解析或尚未录入）。")
            else:
                lines.append("- 暂无可按楼栋汇总的数据（可能还没有写入 building_no）。")

            answer = "\n".join(lines)
        else:
            answer = (
                "我已读取本项目的验收与巡检汇总数据。"
                "你可以更自由地问：‘项目进展如何？’、‘每栋情况总结并解释原因？’、‘为什么巡检未闭环这么多？’、‘给出风险点和整改建议’。"
            )

        if meta.get("llm", {}).get("timed_out"):
            answer = "（大模型连接超时，已切换本地概览）\n" + answer
        elif meta.get("llm", {}).get("fallback") == "local_error":
            answer = "（大模型暂不可用，已切换本地概览）\n" + answer

    return ChatOut(answer=answer, facts=facts, meta=meta).model_dump()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
