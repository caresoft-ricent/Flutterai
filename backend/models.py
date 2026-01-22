from __future__ import annotations

from sqlalchemy import Column, DateTime, Integer, String, Text
from sqlalchemy.sql import func

from database import Base


class Project(Base):
    """项目维度。"""

    __tablename__ = "projects"

    id = Column(Integer, primary_key=True)
    name = Column(String, unique=True, index=True)
    address = Column(String, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())


class Location(Base):
    """部位（位置）维度。

    设计目标：
    - 兼容前端现有的 regionCode/regionText
    - 为后续“几栋几层/哪个区域/哪个房间”的统计打基础
    """

    __tablename__ = "locations"

    id = Column(Integer, primary_key=True)
    project_id = Column(Integer, index=True)

    # Flutter 现有字段
    region_code = Column(String, index=True)  # 允许为空/virtual:
    region_text = Column(String, index=True)  # 例如："1栋6层"

    # 结构化拆解（允许为空，便于后续聚合/趋势分析）
    building_no = Column(String, index=True, nullable=True)  # "1栋"
    floor_no = Column(Integer, index=True, nullable=True)  # 6
    zone = Column(String, index=True, nullable=True)  # "核心筒"/"A户" 等

    extra_json = Column(Text, nullable=True)  # 预留：JSON 字符串
    created_at = Column(DateTime(timezone=True), server_default=func.now())


class WbsNode(Base):
    """分部分项（WBS/本体）节点。

    - level: division | subdivision | item | indicator
    - code: 兼容库里的 id_code（例如 A001 / Pxxxx / Q-123 等）
    """

    __tablename__ = "wbs_nodes"

    id = Column(Integer, primary_key=True)
    project_id = Column(Integer, index=True)

    level = Column(String, index=True)
    name = Column(String, index=True)
    code = Column(String, index=True, nullable=True)

    parent_id = Column(Integer, index=True, nullable=True)
    extra_json = Column(Text, nullable=True)

    created_at = Column(DateTime(timezone=True), server_default=func.now())


class AcceptanceRecord(Base):
    """工序验收记录（逐条主控项）。

    直接兼容 Flutter 现有离线缓存字段，后端只做“持久化 + 维度补全”。
    """

    __tablename__ = "acceptance_records"

    id = Column(Integer, primary_key=True)
    project_id = Column(Integer, index=True)

    # location 维度
    location_id = Column(Integer, index=True, nullable=True)
    region_code = Column(String, index=True)
    region_text = Column(String, index=True)
    building_no = Column(String, index=True, nullable=True)
    floor_no = Column(Integer, index=True, nullable=True)
    zone = Column(String, index=True, nullable=True)

    # WBS 维度（可选：前端先传 name，后续再做字典化/归一化）
    division = Column(String, index=True, nullable=True)  # 分部
    subdivision = Column(String, index=True, nullable=True)  # 子分部
    item = Column(String, index=True, nullable=True)  # 分项（库）
    item_code = Column(String, index=True, nullable=True)
    indicator = Column(String, index=True, nullable=True)  # 指标（target）
    indicator_code = Column(String, index=True, nullable=True)

    result = Column(String, index=True)  # qualified/unqualified/pending
    photo_path = Column(String, nullable=True)
    remark = Column(Text, nullable=True)
    ai_json = Column(Text, nullable=True)  # 预留：在线识别结构化结果

    client_created_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    source = Column(String, index=True, nullable=True)  # flutter/android/ios/web
    client_record_id = Column(String, index=True, nullable=True)  # 预留：前端 UUID


class IssueReport(Base):
    """日常巡检：问题上报/问题台账。

    对齐 issue_report_screen 的核心字段：部位 + 分部分项 + 责任单位/责任人。
    """

    __tablename__ = "issue_reports"

    id = Column(Integer, primary_key=True)
    project_id = Column(Integer, index=True)

    # location 维度
    location_id = Column(Integer, index=True, nullable=True)
    region_code = Column(String, index=True, nullable=True)
    region_text = Column(String, index=True, nullable=True)
    building_no = Column(String, index=True, nullable=True)
    floor_no = Column(Integer, index=True, nullable=True)
    zone = Column(String, index=True, nullable=True)

    # WBS 维度
    division = Column(String, index=True, nullable=True)
    subdivision = Column(String, index=True, nullable=True)
    item = Column(String, index=True, nullable=True)
    indicator = Column(String, index=True, nullable=True)
    library_id = Column(String, index=True, nullable=True)  # 缺陷库/条目 id（如 Q-123）

    description = Column(Text)
    severity = Column(String, index=True, nullable=True)  # 一般/严重
    deadline_days = Column(Integer, nullable=True)

    responsible_unit = Column(String, index=True, nullable=True)
    responsible_person = Column(String, index=True, nullable=True)

    status = Column(String, index=True, default="open")  # open/closed
    photo_path = Column(String, nullable=True)
    ai_json = Column(Text, nullable=True)

    client_created_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    source = Column(String, index=True, nullable=True)
    client_record_id = Column(String, index=True, nullable=True)


class RectificationAction(Base):
    """整改闭环动作/记录。

    用一张表同时承载：
    - 巡检问题（issue_reports）的整改/复验/关闭
    - 工序验收（acceptance_records）的整改/复验

    设计为事件流（timeline），避免频繁改动主表字段。
    """

    __tablename__ = "rectification_actions"

    id = Column(Integer, primary_key=True)
    project_id = Column(Integer, index=True)

    target_type = Column(String, index=True)  # issue | acceptance
    target_id = Column(Integer, index=True)

    action_type = Column(String, index=True)  # rectify | verify | close | comment
    content = Column(Text, nullable=True)
    photo_urls = Column(Text, nullable=True)  # JSON array

    actor_role = Column(String, index=True, nullable=True)  # responsible | supervisor
    actor_name = Column(String, index=True, nullable=True)

    created_at = Column(DateTime(timezone=True), server_default=func.now())
