from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy.orm import Session

import models
from database import SessionLocal, engine


def main() -> None:
    models.Base.metadata.create_all(bind=engine)

    db: Session = SessionLocal()
    try:
        # Project
        project = db.query(models.Project).filter(models.Project.name == "演示项目").first()
        if project is None:
            project = models.Project(name="演示项目", address="本地")
            db.add(project)
            db.commit()
            db.refresh(project)

        now = datetime.now()

        # Acceptance records (模拟几条)
        db.add_all(
            [
                models.AcceptanceRecord(
                    project_id=project.id,
                    region_code="virtual:1栋3层",
                    region_text="1栋3层",
                    building_no="1栋",
                    floor_no=3,
                    division="主体结构",
                    subdivision="钢筋工程",
                    item="钢筋验收",
                    item_code="A001",
                    indicator="保护层厚度",
                    indicator_code="T001",
                    result="qualified",
                    remark="现场抽检合格",
                    client_created_at=now - timedelta(days=2),
                    source="seed",
                ),
                models.AcceptanceRecord(
                    project_id=project.id,
                    region_code="virtual:1栋3层",
                    region_text="1栋3层",
                    building_no="1栋",
                    floor_no=3,
                    division="主体结构",
                    subdivision="模板工程",
                    item="模板验收",
                    item_code="A002",
                    indicator="模板加固",
                    indicator_code="T002",
                    result="unqualified",
                    remark="局部加固不足",
                    client_created_at=now - timedelta(days=1),
                    source="seed",
                ),
            ]
        )

        # Issue reports (模拟几条)
        db.add_all(
            [
                models.IssueReport(
                    project_id=project.id,
                    region_text="1栋3层/核心筒",
                    building_no="1栋",
                    floor_no=3,
                    zone="核心筒",
                    division="主体结构",
                    subdivision="模板工程",
                    item="模板支撑",
                    indicator="立杆间距",
                    library_id="Q-101",
                    description="模板支撑立杆间距偏大，存在安全风险。",
                    severity="严重",
                    deadline_days=3,
                    responsible_unit="项目部",
                    responsible_person="木易",
                    status="open",
                    client_created_at=now - timedelta(days=1),
                    source="seed",
                ),
            ]
        )

        db.commit()
        print("seed ok")
    finally:
        db.close()


if __name__ == "__main__":
    main()
