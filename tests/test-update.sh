#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
REMOTE="$FIXTURE/remote"
TARGET="$FIXTURE/target"
trap 'rm -rf "$FIXTURE"' EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mkdir -p "$REMOTE/scripts" "$TARGET"
cp "$REPO_DIR/scripts/update-manifest.txt" "$REMOTE/scripts/update-manifest.txt"
cp "$REPO_DIR/scripts/update-manifest.txt.sig" "$REMOTE/scripts/update-manifest.txt.sig"

while IFS=' ' read -r kind hash relative extra; do
  [ "$kind" = "file" ] || continue
  mkdir -p "$REMOTE/$(dirname "$relative")" "$TARGET/$(dirname "$relative")"
  cp "$REPO_DIR/$relative" "$REMOTE/$relative"
  cp "$REPO_DIR/$relative" "$TARGET/$relative"
done < "$REPO_DIR/scripts/update-manifest.txt"

if [ "${UBS_TEST_LEGACY_RUST_HELPER:-false}" = true ]; then
  mkdir -p "$TARGET/.ubs/bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '  sha256) python3 -c '\''import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())'\'' "$2" ;;' \
    '  validate-relative) exit 0 ;;' \
    '  *) exit 2 ;;' \
    'esac' > "$TARGET/.ubs/bin/ubs-helper"
  chmod +x "$TARGET/.ubs/bin/ubs-helper"
  UBS_RUST_HELPER="$TARGET/.ubs/bin/ubs-helper"
  export UBS_RUST_HELPER
fi

printf '\n# local drift\n' >> "$TARGET/scripts/build-node.sh"
DRIFT_HASH="$(sha256_file "$TARGET/scripts/build-node.sh")"

CHECK_OUTPUT="$(UBS_LANG=ko UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check)"
printf '%s\n' "$CHECK_OUTPUT" | grep -Fq 'scripts/build-node.sh' || {
  echo "update --check가 주입한 드리프트(scripts/build-node.sh)를 감지하지 못했습니다." >&2
  printf '%s\n' "$CHECK_OUTPUT" >&2
  exit 1
}
[ "$(sha256_file "$TARGET/scripts/build-node.sh")" = "$DRIFT_HASH" ] || {
  echo "update --check가 로컬 파일을 변경했습니다." >&2
  exit 1
}

DRY_OUTPUT="$(UBS_LANG=ko UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --dry-run)"
printf '%s\n' "$DRY_OUTPUT" | grep -Fq 'dry-run이므로' || {
  echo "update --dry-run 결과가 명확하지 않습니다." >&2
  exit 1
}
[ "$(sha256_file "$TARGET/scripts/build-node.sh")" = "$DRIFT_HASH" ] || {
  echo "update --dry-run이 로컬 파일을 변경했습니다." >&2
  exit 1
}

if [ "${UBS_TEST_LEGACY_RUST_HELPER:-false}" = true ]; then
  printf '\n// force native helper rebuild\n' >> "$TARGET/native/ubs-helper/src/main.rs"
fi

UPDATE_OUTPUT="$(UBS_LANG=ko UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update)"
cmp "$TARGET/scripts/build-node.sh" "$REMOTE/scripts/build-node.sh" || {
  echo "업데이트 파일이 원격 검증본과 다릅니다." >&2
  exit 1
}
if [ "${UBS_TEST_LEGACY_RUST_HELPER:-false}" = true ]; then
  "$TARGET/.ubs/bin/ubs-helper" verify-manifest \
    "$REMOTE/scripts/update-manifest.txt" "$TARGET" native/ubs-helper/src/main.rs || {
    echo "업데이트 후 Rust helper 자동 재빌드가 실행되지 않았습니다." >&2
    exit 1
  }
fi
BACKUP_DIR="$(printf '%s\n' "$UPDATE_OUTPUT" | sed -n 's/^백업 위치: //p')"
[ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/scripts/build-node.sh" ] || {
  echo "업데이트 백업을 찾을 수 없습니다." >&2
  exit 1
}
grep -Fq '# local drift' "$BACKUP_DIR/scripts/build-node.sh" || {
  echo "백업에 업데이트 전 파일이 보존되지 않았습니다." >&2
  exit 1
}

# 감지 모듈이 사라져도 update 명령은 독립적으로 실행되어 복구해야 한다.
rm -f "$TARGET/scripts/lib/detect.sh"
MISSING_CHECK="$(UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check)"
printf '%s\n' "$MISSING_CHECK" | grep -Fq 'scripts/lib/detect.sh' || {
  echo "update가 누락된 감지 모듈을 찾지 못했습니다." >&2
  exit 1
}
UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update >/dev/null
cmp "$TARGET/scripts/lib/detect.sh" "$REMOTE/scripts/lib/detect.sh" || {
  echo "update가 누락된 감지 모듈을 복구하지 못했습니다." >&2
  exit 1
}

# Python 코어가 사라져도 얇은 Bash bootstrap이 update를 실행해 복구해야 한다.
rm -f "$TARGET/scripts/ubs.py" "$TARGET/scripts/ubs_mcp.py"
CORE_MISSING_CHECK="$(UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check)"
printf '%s\n' "$CORE_MISSING_CHECK" | grep -Fq 'scripts/ubs.py' || {
  echo "bootstrap update가 누락된 Python 코어를 찾지 못했습니다." >&2
  exit 1
}
printf '%s\n' "$CORE_MISSING_CHECK" | grep -Fq 'scripts/ubs_mcp.py' || {
  echo "bootstrap update가 누락된 MCP 서버를 찾지 못했습니다." >&2
  exit 1
}
CORE_MISSING_JSON="$(UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check --json)"
printf '%s' "$CORE_MISSING_JSON" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["schema_version"] == 1
assert "scripts/ubs.py" in result["changed_paths"]
assert "scripts/ubs_mcp.py" in result["changed_paths"]
'
UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update >/dev/null
cmp "$TARGET/scripts/ubs.py" "$REMOTE/scripts/ubs.py" || {
  echo "bootstrap update가 Python 코어를 복구하지 못했습니다." >&2
  exit 1
}
cmp "$TARGET/scripts/ubs_mcp.py" "$REMOTE/scripts/ubs_mcp.py"
[ -x "$TARGET/scripts/ubs.py" ]
[ -x "$TARGET/scripts/ubs_mcp.py" ]

UPDATE_JSON="$(UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check --json)"
printf '%s' "$UPDATE_JSON" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["schema_version"] == 1
assert result["ok"] is True
assert result["mode"] == "check"
assert result["status"] == 0
assert result["local_version"] == "3.11.2"
assert result["remote_version"] == "3.11.2"
assert result["changed_paths"] == []
assert result["backup_path"] is None
assert isinstance(result["output"], list)
'

# manifest 서명이 없거나 다른 키로 만들어졌으면(=매니페스트/payload가 서로 다른
# 채널에서 왔거나 채널 자체가 침해됐을 가능성) 체크섬이 다 맞아도 거부해야 한다.
rm -f "$REMOTE/scripts/update-manifest.txt.sig"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "서명 파일 없는 manifest를 허용했습니다." >&2
  exit 1
fi

openssl ecparam -name prime256v1 -genkey -noout -out "$FIXTURE/wrong-signing-key.pem"
openssl dgst -sha256 -sign "$FIXTURE/wrong-signing-key.pem" \
  -out "$REMOTE/scripts/update-manifest.txt.sig" "$REMOTE/scripts/update-manifest.txt"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "다른 키로 만든 서명을 허용했습니다." >&2
  exit 1
fi
cp "$REPO_DIR/scripts/update-manifest.txt.sig" "$REMOTE/scripts/update-manifest.txt.sig"

mkdir -p "$TARGET/.ubs/backups/old-test"
touch -t 202001010000 "$TARGET/.ubs/backups/old-test"
PRUNE_JSON="$(bash "$TARGET/build.sh" update --prune-backups 30 --json)"
printf '%s' "$PRUNE_JSON" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result == {"ok": True, "mode": "prune-backups", "retention_days": 30, "deleted": 1}
'
[ ! -e "$TARGET/.ubs/backups/old-test" ] || { echo "오래된 백업이 정리되지 않았습니다." >&2; exit 1; }

# 두 파일 중 두 번째 교체가 실패하면 첫 번째 파일도 업데이트 전 상태로 복원해야 한다.
printf '\n# rollback build drift\n' >> "$TARGET/build.sh"
printf '\n# rollback node drift\n' >> "$TARGET/scripts/build-node.sh"
ROLLBACK_BUILD_HASH="$(sha256_file "$TARGET/build.sh")"
ROLLBACK_NODE_HASH="$(sha256_file "$TARGET/scripts/build-node.sh")"
mkdir -p "$FIXTURE/fail-bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'last=""' 'for value in "$@"; do last="$value"; done' \
  'case "$last" in */scripts/build-node.sh) exit 9 ;; esac' \
  'exec /bin/mv "$@"' > "$FIXTURE/fail-bin/mv"
chmod +x "$FIXTURE/fail-bin/mv"
if PATH="$FIXTURE/fail-bin:$PATH" UBS_UPDATE_BASE_URL="file://$REMOTE" \
  UBS_UPDATE_ALLOW_FILE=true bash "$TARGET/build.sh" update >/dev/null 2>&1; then
  echo "교체 실패를 구성한 업데이트가 성공했습니다." >&2
  exit 1
fi
[ "$(sha256_file "$TARGET/build.sh")" = "$ROLLBACK_BUILD_HASH" ] || {
  echo "부분 실패 후 build.sh가 원래 상태로 복원되지 않았습니다." >&2
  exit 1
}
[ "$(sha256_file "$TARGET/scripts/build-node.sh")" = "$ROLLBACK_NODE_HASH" ] || {
  echo "부분 실패 후 build-node.sh 상태가 바뀌었습니다." >&2
  exit 1
}

# 원격 버전이 더 낮으면 명시적 허용 없이 적용하지 않아야 한다.
sed 's/^version .*/version 2.0.0/' "$REPO_DIR/scripts/update-manifest.txt" \
  > "$REMOTE/scripts/update-manifest.txt"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "다운그레이드 manifest를 허용했습니다." >&2
  exit 1
fi
cp "$REPO_DIR/scripts/update-manifest.txt" "$REMOTE/scripts/update-manifest.txt"

# manifest와 실제 다운로드 파일의 해시가 다르면 백업·교체 전에 중단해야 한다.
printf '\n# tampered remote\n' >> "$REMOTE/scripts/build-node.sh"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update >/dev/null 2>&1; then
  echo "SHA-256이 다른 원격 파일을 허용했습니다." >&2
  exit 1
fi
[ "$(sha256_file "$TARGET/build.sh")" = "$ROLLBACK_BUILD_HASH" ] || {
  echo "해시 검증 실패 전에 로컬 파일이 변경됐습니다." >&2
  exit 1
}
cp "$REPO_DIR/scripts/build-node.sh" "$REMOTE/scripts/build-node.sh"

# 필수 파일 누락과 중복 항목도 manifest 전체를 거부해야 한다.
grep -v ' scripts/build-node.sh$' "$REPO_DIR/scripts/update-manifest.txt" \
  > "$REMOTE/scripts/update-manifest.txt"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "필수 경로가 누락된 manifest를 허용했습니다." >&2
  exit 1
fi
cp "$REPO_DIR/scripts/update-manifest.txt" "$REMOTE/scripts/update-manifest.txt"
grep ' scripts/build-node.sh$' "$REPO_DIR/scripts/update-manifest.txt" \
  >> "$REMOTE/scripts/update-manifest.txt"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "중복 경로가 있는 manifest를 허용했습니다." >&2
  exit 1
fi
cp "$REPO_DIR/scripts/update-manifest.txt" "$REMOTE/scripts/update-manifest.txt"

# 동시 실행 잠금이 있으면 두 번째 실제 업데이트를 거부해야 한다.
mkdir -p "$TARGET/.ubs/update.lock"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update >/dev/null 2>&1; then
  echo "동시에 두 업데이트를 허용했습니다." >&2
  exit 1
fi
rmdir "$TARGET/.ubs/update.lock"

# manifest가 허용 목록 밖으로 쓰려 하면 다운로드 전에 중단해야 한다.
printf '%s\n' 'version 9.9.9' \
  'file 0000000000000000000000000000000000000000000000000000000000000000 ../escape' \
  > "$REMOTE/scripts/update-manifest.txt"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "악성 manifest 상대 경로를 허용했습니다." >&2
  exit 1
fi
[ ! -e "$FIXTURE/escape" ] || { echo "허용 경로 밖 파일이 생성됐습니다." >&2; exit 1; }

# 관리 경로 또는 부모가 심볼릭 링크면 외부 파일을 건드리지 않아야 한다.
cp "$REPO_DIR/scripts/update-manifest.txt" "$REMOTE/scripts/update-manifest.txt"
printf '%s\n' 'outside' > "$FIXTURE/outside"
rm -f "$TARGET/scripts/build-node.sh"
ln -s "$FIXTURE/outside" "$TARGET/scripts/build-node.sh"
if UBS_UPDATE_BASE_URL="file://$REMOTE" UBS_UPDATE_ALLOW_FILE=true \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "심볼릭 링크 관리 경로를 허용했습니다." >&2
  exit 1
fi
grep -Fqx 'outside' "$FIXTURE/outside" || { echo "심볼릭 링크 외부 파일이 변경됐습니다." >&2; exit 1; }

if UBS_UPDATE_BASE_URL="http://example.invalid" \
  bash "$TARGET/build.sh" update --check >/dev/null 2>&1; then
  echo "HTTPS가 아닌 업데이트 URL을 허용했습니다." >&2
  exit 1
fi

echo "업데이트 테스트 통과"
