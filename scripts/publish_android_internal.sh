#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APK_PATH="${APK_PATH:-build/app/outputs/flutter-apk/app-release.apk}"
MINIO_TARGET_APK="${MINIO_TARGET_APK:-ricent-minio/beaver-ai/android/ricent.apk}"
MINIO_TARGET_CHECK_JSON="${MINIO_TARGET_CHECK_JSON:-ricent-minio/beaver-ai/check.json}"
CHECK_JSON_PATH="${CHECK_JSON_PATH:-check.json}"
CDN_PURGE_URL="${CDN_PURGE_URL:-http://manager.ricent.com/api/v4/tencent/cdn-cache/beaver-ai}"
PUBSPEC_PATH="${PUBSPEC_PATH:-pubspec.yaml}"

# Optional: release notes to put into check.json.data.update
RELEASE_NOTES="${RELEASE_NOTES:-}"

# Optional: override offline ASR/VAD model download URLs via Dart defines.
# Example:
#   ASR_MODEL_URL=https://app.ricent.com/beaver-ai/models/asr.tar.bz2 \
#   VAD_MODEL_URL=https://app.ricent.com/beaver-ai/models/silero_vad.onnx \
#   ./scripts/publish_android_internal.sh
DART_DEFINES=()
if [[ -n "${ASR_MODEL_URL:-}" ]]; then
  DART_DEFINES+=("--dart-define=ASR_MODEL_URL=${ASR_MODEL_URL}")
fi
if [[ -n "${VAD_MODEL_URL:-}" ]]; then
  DART_DEFINES+=("--dart-define=VAD_MODEL_URL=${VAD_MODEL_URL}")
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter 未安装或不在 PATH 中" >&2
  exit 1
fi
if ! command -v mc >/dev/null 2>&1; then
  echo "mc (MinIO client) 未安装或不在 PATH 中" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl 未安装或不在 PATH 中" >&2
  exit 1
fi

if (( ${#DART_DEFINES[@]} > 0 )); then
  flutter build apk --release "${DART_DEFINES[@]}"
else
  flutter build apk --release
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "未找到 APK: $APK_PATH" >&2
  exit 1
fi
if [[ ! -f "$CHECK_JSON_PATH" ]]; then
  echo "未找到 check.json: $CHECK_JSON_PATH" >&2
  exit 1
fi

if [[ ! -f "$PUBSPEC_PATH" ]]; then
  echo "未找到 pubspec.yaml: $PUBSPEC_PATH" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 未安装或不在 PATH 中（用于生成 check.json）" >&2
  exit 1
fi

GENERATED_CHECK_JSON=""
tmp_dir=""
cleanup_tmp() {
  if [[ -n "${tmp_dir}" && -d "${tmp_dir}" ]]; then
    rm -rf "${tmp_dir}" || true
  fi
}
trap cleanup_tmp EXIT

tmp_dir="$(mktemp -d)"
GENERATED_CHECK_JSON="${tmp_dir}/check.json"

python3 - "$CHECK_JSON_PATH" "$PUBSPEC_PATH" "$APK_PATH" "$RELEASE_NOTES" >"$GENERATED_CHECK_JSON" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime

check_path, pubspec_path, apk_path, release_notes = sys.argv[1:5]

with open(check_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

version_raw = ''
with open(pubspec_path, 'r', encoding='utf-8') as f:
    for line in f:
        m = re.match(r'^version:\s*([^\s#]+)', line.strip())
        if m:
            version_raw = m.group(1)
            break

app_version = version_raw
build_number = ''
if '+' in version_raw:
    app_version, build_number = version_raw.split('+', 1)

apk_size = None
apk_sha256 = None
try:
    st = os.stat(apk_path)
    apk_size = st.st_size
    h = hashlib.sha256()
    with open(apk_path, 'rb') as af:
        for chunk in iter(lambda: af.read(1024 * 1024), b''):
            h.update(chunk)
    apk_sha256 = h.hexdigest()
except Exception:
    pass

root = data if isinstance(data, dict) else {}
payload = root.get('data')
if not isinstance(payload, dict):
    payload = {}
    root['data'] = payload

payload['version'] = app_version or payload.get('version', '')
payload['buildNumber'] = build_number or payload.get('buildNumber', '')

ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
note = (release_notes or '').strip()
payload['update'] = note if note else f'build {ts}'

if apk_size is not None:
    payload['apkSize'] = apk_size
if apk_sha256 is not None:
    payload['apkSha256'] = apk_sha256

json.dump(root, sys.stdout, ensure_ascii=False, indent=4)
sys.stdout.write('\n')
PY

mc cp "$APK_PATH" "$MINIO_TARGET_APK"
mc cp "$GENERATED_CHECK_JSON" "$MINIO_TARGET_CHECK_JSON"

curl -X DELETE "$CDN_PURGE_URL"

echo "OK: 已发布到内测环境，并已触发 CDN 刷新"