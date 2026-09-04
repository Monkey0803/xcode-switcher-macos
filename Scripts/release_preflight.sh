#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
errors=()

required_variables=(
  DEVELOPER_ID_APPLICATION
  NOTARYTOOL_PROFILE
  SU_FEED_URL
  SPARKLE_PUBLIC_KEY
)
for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    errors+=("缺少环境变量 $variable_name。")
  fi
done

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  if [[ "$DEVELOPER_ID_APPLICATION" != "Developer ID Application:"* ]]; then
    errors+=("DEVELOPER_ID_APPLICATION 必须是 Developer ID Application 证书，不能使用 Apple Development 或 Apple Distribution。")
  else
    identity_output="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
    if ! /usr/bin/grep -Fq "\"$DEVELOPER_ID_APPLICATION\"" <<<"$identity_output"; then
      errors+=("钥匙串中不存在签名身份：$DEVELOPER_ID_APPLICATION")
    fi
  fi
fi

if [[ -n "${SU_FEED_URL:-}" && "$SU_FEED_URL" != https://?* ]]; then
  errors+=("SU_FEED_URL 必须是包含主机名的 HTTPS 地址。")
fi

if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  decoded_length=""
  if ! decoded_length="$(printf '%s' "$SPARKLE_PUBLIC_KEY" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"; then
    errors+=("SPARKLE_PUBLIC_KEY 不是有效的 Base64。")
  elif [[ "$decoded_length" != "32" ]]; then
    errors+=("SPARKLE_PUBLIC_KEY 解码后必须为 32 字节的 Ed25519 公钥。")
  fi
fi

if ! /usr/bin/xcrun --find notarytool >/dev/null 2>&1; then
  errors+=("当前 Xcode 工具链缺少 notarytool。")
fi

generate_appcast="$project_dir/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$generate_appcast" ]]; then
  errors+=("找不到 Sparkle generate_appcast；请先执行 ./build_app.sh。")
fi

if (( ${#errors[@]} > 0 )); then
  printf '发布预检失败：\n' >&2
  for message in "${errors[@]}"; do
    printf -- '- %s\n' "$message" >&2
  done
  exit 2
fi

if [[ "${SKIP_NOTARY_AUTH_CHECK:-0}" != "1" ]]; then
  if ! /usr/bin/xcrun notarytool history \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --output-format json >/dev/null; then
    printf '发布预检失败：Notary Keychain Profile 无效或无法连接 Apple 服务：%s\n' "$NOTARYTOOL_PROFILE" >&2
    exit 2
  fi
fi

printf '发布预检通过：Developer ID、Sparkle 配置和 Notary 凭据均可用。\n'
