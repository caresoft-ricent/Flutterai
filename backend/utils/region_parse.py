from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class ParsedRegion:
    building_no: Optional[str] = None
    floor_no: Optional[int] = None
    zone: Optional[str] = None


_CN_NUM = {
    "零": 0,
    "一": 1,
    "二": 2,
    "两": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
    "十": 10,
}


def _cn_to_int(s: str) -> Optional[int]:
    t = (s or "").strip()
    if not t:
        return None
    if t.isdigit():
        try:
            return int(t)
        except Exception:
            return None

    # Very small chinese numerals like: 十, 十一, 二十, 二十三
    if any(ch not in _CN_NUM for ch in t):
        return None

    if t == "十":
        return 10
    if t.startswith("十"):
        # 十一 = 10 + 1
        return 10 + _CN_NUM.get(t[1:], 0)
    if "十" in t:
        a, b = t.split("十", 1)
        tens = _CN_NUM.get(a, 0) * 10
        ones = _CN_NUM.get(b, 0) if b else 0
        return tens + ones

    return _CN_NUM.get(t)


def parse_region_text(region_text: str) -> ParsedRegion:
    """Parse user-entered region text into building/floor/zone.

    Supported examples:
    - "1栋10层"
    - "2# / 3层 / 304"
    - "3栋 / 6层 / 核心筒"

    Notes:
    - Returns best-effort; never raises.
    - building_no is normalized to "{n}栋" when numeric is detected.
    """

    raw = (region_text or "").strip()
    if not raw:
        return ParsedRegion()

    s = raw.replace(" ", "")

    # Building: 2#, 2栋, 2楼
    m_b = re.search(r"([\d一二三四五六七八九十两]+)(?:栋|楼|#)", s)
    building_no = None
    if m_b:
        bi = _cn_to_int(m_b.group(1))
        if bi is not None:
            building_no = f"{bi}栋"

    # Floor: 3层/3楼
    m_f = re.search(r"([\d一二三四五六七八九十两]+)(?:层|楼)", s)
    floor_no = None
    if m_f:
        fi = _cn_to_int(m_f.group(1))
        if fi is not None:
            floor_no = fi

    # Zone: last part after '/'
    zone = None
    if "/" in raw:
        parts = [p.strip() for p in raw.split("/") if p.strip()]
        if len(parts) >= 2:
            zone = parts[-1]
    else:
        # Try room number after floor (e.g., 2#3层304)
        m_room = re.search(r"(?:层|楼)([A-Za-z0-9]{2,}|[\d]{2,})$", s)
        if m_room:
            zone = m_room.group(1)

    return ParsedRegion(building_no=building_no, floor_no=floor_no, zone=zone)
