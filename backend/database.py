import os
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker

# 使用统一的 SQLite 数据库（仓库根目录 flutterai.db）
# 可用环境变量覆盖：APP_DB_PATH=/ABS/PATH/flutterai.db
_default_db_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "flutterai.db"))
_db_path = (os.getenv("APP_DB_PATH") or "").strip() or _default_db_path
SQLALCHEMY_DATABASE_URL = f"sqlite:///{_db_path}"

# check_same_thread=False 是 SQLite 在多线程环境下的特殊配置
engine = create_engine(
    SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False}
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()

# 依赖项：获取数据库会话
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
