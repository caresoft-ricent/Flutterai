#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────
# 发布 iOS IPA 到 TestFlight
#
# 用法:
#   ./scripts/publish_ios_testflight.sh
#
# 需要设置环境变量（或在此脚本中填入）:
#   API_KEY_ID      - App Store Connect API Key ID
#   API_ISSUER_ID   - App Store Connect Issuer ID
#
# API Key 文件应位于 ~/.private_keys/AuthKey_<API_KEY_ID>.p8
# Issuer ID 获取: App Store Connect → 用户和访问 → 集成 → 密钥
# ────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

API_KEY_ID="${API_KEY_ID:-6FH2LLS242}"
API_ISSUER_ID="${API_ISSUER_ID:-69a6de91-32f7-47e3-e053-5b8c7c11a4d1}"
IPA_DIR="build/ios/ipa"

# 检查 Issuer ID
if [[ -z "$API_ISSUER_ID" ]]; then
  echo "❌ 请设置 API_ISSUER_ID 环境变量"
  echo ""
  echo "获取方式: App Store Connect → 用户和访问 → 集成 → App Store Connect API → 密钥"
  echo "页面顶部会显示 Issuer ID (UUID 格式)"
  echo ""
  echo "示例:"
  echo "  API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ./scripts/publish_ios_testflight.sh"
  exit 1
fi

# 检查 API Key 文件
KEY_PATH="$HOME/.private_keys/AuthKey_${API_KEY_ID}.p8"
if [[ ! -f "$KEY_PATH" ]]; then
  echo "❌ 未找到 API Key 文件: $KEY_PATH"
  exit 1
fi

# 构建 IPA
echo "📦 构建 iOS Release IPA..."
flutter build ipa --release

# 查找 IPA
IPA_FILE=$(find "$IPA_DIR" -name "*.ipa" -type f | head -1)
if [[ -z "$IPA_FILE" ]]; then
  echo "❌ 未找到 IPA 文件: $IPA_DIR"
  exit 1
fi
echo "✅ IPA 构建成功: $IPA_FILE ($(du -h "$IPA_FILE" | cut -f1))"

# 验证 IPA
echo "🔍 验证 IPA..."
xcrun altool --validate-app --type ios \
  -f "$IPA_FILE" \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID"

echo "✅ IPA 验证通过"

# 上传到 TestFlight
echo "🚀 上传到 TestFlight..."
xcrun altool --upload-app --type ios \
  -f "$IPA_FILE" \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID"

echo ""
echo "✅ 上传成功！IPA 已提交到 App Store Connect。"
echo "   打开 App Store Connect → TestFlight 查看处理状态。"
echo "   通常需要 10-30 分钟处理后才能在 TestFlight 中使用。"



