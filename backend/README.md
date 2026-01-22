# FlutterAI Backend（本地数据后端）

目标：先把 Flutter 的「工序验收 / 日常巡检」数据落到本地 SQLite，形成可扩展的基础数据层，为后续 Palantir 式问答（汇总、趋势、追溯、对比）做准备。

## 运行

在项目根目录执行：

- 安装依赖：`python3 -m pip install -r backend/requirements.txt`
- 初始化演示数据：`python3 backend/seed.py`
- 启动后端：`python3 backend/main.py`

服务默认监听：`http://127.0.0.1:8000`

## 真机测试（推荐：先用本机 MacBookPro 作为后端）

不需要先部署到服务器。只要手机与 Mac 在同一 Wi-Fi/局域网，就可以让真机直接访问你 Mac 上启动的后端。

### 1) 启动后端（Mac）

在项目根目录：

- 安装依赖：`python3 -m pip install -r backend/requirements.txt`
- 启动：`python3 backend/main.py`

后端会监听 `0.0.0.0:8000`（局域网可访问）。

获取 Mac 的局域网 IP（任选其一）：

- `ipconfig getifaddr en0`（Wi-Fi 常见）
- `ifconfig | grep "inet "`

然后用手机浏览器访问：`http://<你的Mac局域网IP>:8000/v1/health`，看到 `{"status":"ok"}` 就说明通了。

如果访问不到：检查 macOS 防火墙是否拦截 Python 监听端口、以及手机/电脑是否在同一个网络。

### 2) 让 Flutter 真机指向你的 Mac 后端

本项目 Flutter 通过 `--dart-define` 读后端地址：

- `BACKEND_BASE_URL`：默认 `http://127.0.0.1:8000`
- `PROJECT_NAME`：默认 `演示项目`

iOS 真机（示例）：

`flutter run --dart-define=BACKEND_BASE_URL=http://<你的Mac局域网IP>:8000 --dart-define=PROJECT_NAME=演示项目`

Android 真机（示例）：

`flutter run --dart-define=BACKEND_BASE_URL=http://<你的Mac局域网IP>:8000 --dart-define=PROJECT_NAME=演示项目`

备注：Android 侧如果使用 http 明文，通常需要允许 cleartext（本仓库已在 `android/app/src/main/AndroidManifest.xml` 开启，后续上线建议切换 HTTPS 并收敛）。

## 部署到服务器（需要多人/异地联调时再做）

当你需要让多台手机在不同网络访问同一个后端时，再把后端部署到一台服务器（VPS/云主机）。最小可用步骤如下：

1) 服务器安装 Python 3.11+（建议 3.11/3.12），并拉取本仓库代码
2) 创建虚拟环境并安装依赖：

`python3 -m venv .venv && source .venv/bin/activate && pip install -r backend/requirements.txt`

3) 启动服务（开发/临时联调）：

`python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000`

4) 打开服务器安全组/防火墙端口（8000 或你改的端口）
5) Flutter 侧将 `BACKEND_BASE_URL` 改为：`http://<服务器公网IP>:8000`

生产建议：用 Nginx 做反向代理 + HTTPS（否则 iOS/Android 可能因为安全策略阻断明文 HTTP）。

## 数据模型（面向未来扩展）

当前后端采用“本体化维度”建模：

- **Location（部位）**：兼容 `regionCode/regionText`，并预留 `building_no/floor_no/zone` 用于聚合与趋势。
- **WBS（分部分项）**：用 `division/subdivision/item/indicator` 承载分部/子分部/分项/指标。
- **责任维度**：`responsible_unit/responsible_person`。

后续要实现“最近一层花了多长时间”等，需要在 Location/WBS 的基础上补充 **进度事件（progress events）** 或 **工序开始/完成时间**；现阶段先把验收/巡检先存起来。

## API（v1）

### 0) 照片上传（用于跨设备查看）

- `POST /v1/uploads/photo`（multipart form-data，字段名：`file`）
- 上传后图片可通过 `GET /uploads/<filename>` 访问

后端会返回：`{ "url": "http://<host>:8000/uploads/<filename>" }`

Flutter 侧会把这个 `url` 写入 `photo_path`，这样记录表详情可以直接预览（不再依赖手机本地路径）。

### 1) 工序验收（逐条主控项记录）

- `POST /v1/acceptance-records`
- `GET  /v1/acceptance-records?project_id=1&limit=100`

**请求字段（与 Flutter 映射建议）**

- `region_code`：Flutter `AcceptanceRecord.regionCode`
- `region_text`：Flutter `AcceptanceRecord.regionText`（如“1栋6层”）
- `item_code`：Flutter `LibraryItem.idCode`
- `item`：Flutter `LibraryItem.name`
- `indicator_code`：Flutter `TargetItem.idCode`
- `indicator`：Flutter `TargetItem.name`
- `result`：建议映射为字符串：`qualified` / `unqualified` / `pending`
- `photo_path`：Flutter `AcceptanceRecord.photoPath`
- `remark`：Flutter `AcceptanceRecord.remark`
- `division/subdivision`：来自验收页的级联选择（分部/子分部）

### 2) 日常巡检（问题上报/问题台账）

- `POST /v1/issue-reports`
- `GET  /v1/issue-reports?project_id=1&limit=100&status=open&responsible_unit=项目部`

**请求字段（与 Flutter 映射建议）**

- `region_text`：来自巡检页“部位”选择/输入（如“1栋3层/核心筒”）
- `division/subdivision/item/indicator`：巡检页选择的分部/子分部/分项/指标
- `library_id`：缺陷库条目 id（如 `Q-123`），可选
- `description`：问题描述（必填）
- `severity`：一般/严重
- `deadline_days`：整改期限（天）
- `responsible_unit`：责任单位
- `responsible_person`：责任人
- `photo_path`：拍照路径或服务器 URL（可选；建议使用上传后返回的 URL）

### 3) 健康检查

- `GET /v1/health` -> `{ "status": "ok" }`

## 下一步（不做权限，先跑通闭环）

1. Flutter 侧新增一个 `BackendApiService`，把本地保存动作同时 `POST` 到后端（先不做重试队列也行）。
2. 接入豆包（ARK）：后端实现 `/v1/ai/chat`：先做 SQL 聚合，再把“可核验数据”喂给模型生成回答。

## 豆包（ARK）配置

后端的 `POST /v1/ai/chat` 会：

1) 先调用 `/v1/dashboard/summary` 的同等逻辑聚合出 `facts`（真实数据）；
2) **若配置了豆包**，则用豆包生成自然语言回答，并把 `facts` 原样返回（便于追溯/核验）；
3) 若未配置或调用失败，则回退到规则回答（仍返回真实 `facts`）。

推荐使用配置文件（本地开发最省事）：

1) 复制示例配置：

`cp backend/config.example.json backend/config.json`

2) 编辑 `backend/config.json`，填入你的：

- `doubao.api_key`
- `doubao.model`（Endpoint/Model ID，例如 `ep-xxxx`）

然后启动后端：

`python3 backend/main.py`

说明：`backend/config.json` 已加入 `.gitignore`，不会被提交。

也支持环境变量（适合部署环境，优先级更高；任选其一命名即可）：

- `ARK_API_KEY` 或 `DOUBAO_API_KEY`：必填（开启豆包）
- `ARK_MODEL` 或 `DOUBAO_MODEL`：必填（Endpoint/Model ID）
- `ARK_BASE_URL` 或 `DOUBAO_BASE_URL`：可选（不填用 SDK 默认）

示例（Mac 终端临时运行）：

`export ARK_API_KEY=xxxx && export ARK_MODEL=ep-xxxx && python3 backend/main.py`
