# FlutterAI Backend (Java 17 + Spring Boot 3)

这是对 `backend/` 里 Python（FastAPI + SQLAlchemy + SQLite）后端的 **Java 参考重写**，用于团队对照实现与后续演进。

## 目标

- 路由路径与字段命名尽量保持一致（`/v1/...` + JSON `snake_case`）
- 使用本地 SQLite（默认 `./flutterai.db`）
- 支持上传图片并通过 `/uploads/...` 访问

## 运行

前置：JDK 17+。

本项目已内置 Maven Wrapper（`./mvnw`），无需系统安装 Maven。

- 启动（推荐，确保相对路径正确）：
  - `cd backend-java`
  - `./mvnw spring-boot:run`

- 一键构建并在 8000 端口启动：
  - `cd backend-java`
  - `chmod +x ./run_8000.sh && ./run_8000.sh`

- 停止（8000 端口）：
  - `cd backend-java`
  - `chmod +x ./stop_8000.sh && ./stop_8000.sh`

默认监听：`http://127.0.0.1:8000`

## 配置

见 [src/main/resources/application.yml](src/main/resources/application.yml)

- SQLite DB / uploads / config.json 默认会自动在以下两种相对路径里探测（便于从不同工作目录启动）：
  - `backend/...`（从仓库根目录启动）
  - `../backend/...`（从 backend-java/ 目录启动）

默认所有运行时都统一使用仓库根目录的 `flutterai.db`（与 Python/Flutter 共用）。

如需强制指定 DB 路径（推荐用于部署/脚本）：
- `APP_DB_PATH=/ABS/PATH/flutterai.db`

说明：
- 如果你从别的目录启动 jar，请用环境变量覆盖：
  - `APP_DB_PATH=/ABS/PATH/flutterai.db`
  - `APP_UPLOADS_DIR=/ABS/PATH/backend/uploads`
  - `APP_AI_LOCAL_CONFIG_PATH=/ABS/PATH/backend/config.json`

## API 对照

已实现（与 Python 版本对齐）：

- `GET  /v1/health`
- `GET  /v1/projects`
- `POST /v1/projects/ensure`
- `POST /v1/uploads/photo`（multipart，字段名 `file`，返回 `{url, path}`）

- `POST /v1/acceptance-records`
- `GET  /v1/acceptance-records`
- `GET  /v1/acceptance-records/{recordId}`
- `GET  /v1/acceptance-records/{recordId}/actions`
- `POST /v1/acceptance-records/{recordId}/actions`
- `POST /v1/acceptance-records/{recordId}/verify`

- `POST /v1/issue-reports`
- `GET  /v1/issue-reports`
- `GET  /v1/issue-reports/{issueId}`
- `GET  /v1/issue-reports/{issueId}/actions`
- `POST /v1/issue-reports/{issueId}/actions`
- `POST /v1/issue-reports/{issueId}/close`

- `GET /v1/dashboard/summary`

参考/占位：

- `GET /v1/dashboard/focus`：Java 版已实现近似 focus pack（可继续按 Python 细节微调）
- `GET /v1/ai/status`：诊断配置与是否启用 LLM
- `POST /v1/ai/chat`：规则意图路由为主；当启用时会尝试调用豆包 Ark `/chat/completions` 做润色/建议，失败自动回退规则答案；支持请求体字段 `ai_enabled`（布尔）用于移动端演示时按请求开/关

## 结构说明

- `com.flutterai.backend.domain`：JPA Entity（表结构对齐 SQLAlchemy models）
- `com.flutterai.backend.repo`：Spring Data JPA Repository
- `com.flutterai.backend.service`：业务逻辑（upsert、verify、close、dashboard 汇总等）
- `com.flutterai.backend.api`：Controller + 统一异常处理
- `com.flutterai.backend.util`：`RegionParser` / `UploadRefNormalizer`（对齐 Python 逻辑）
