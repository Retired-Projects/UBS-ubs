#!/usr/bin/env bash

# Transactional Universal Build Script installer.
# The Bash surface stays curl-friendly; Python owns staging, verification,
# no-follow path checks, atomic replacement, and rollback.
set -euo pipefail

# Standalone installer (curl | bash) — no other repo files exist yet, so this
# can't source scripts/lib/i18n.sh. Language detection/messages are embedded
# inline here and again below in the Python heredoc.
_ubs_install_lang() {
  local raw="${UBS_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
  local code="${raw%%.*}"
  code="${code%%_*}"
  code="$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]')"
  case "$code" in
    ko|en|ja|zh) echo "$code"; return ;;
  esac
  # Env said nothing usable (unset, or the C/POSIX default a non-login-shell
  # launch inherits) — ask macOS what language this machine is in.
  if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v defaults >/dev/null 2>&1; then
    code="$(defaults read -g AppleLocale 2>/dev/null)" || code=""
    code="${code%%.*}"
    code="${code%%_*}"
    code="$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]')"
    case "$code" in
      ko|en|ja|zh) echo "$code"; return ;;
    esac
  fi
  echo en
}

command -v python3 >/dev/null 2>&1 || {
  case "$(_ubs_install_lang)" in
    ko) echo "ERROR: Universal Build Script 설치기는 Python 3.9 이상이 필요합니다." >&2 ;;
    ja) echo "ERROR: Universal Build Script インストーラーには Python 3.9 以上が必要です。" >&2 ;;
    zh) echo "错误：Universal Build Script 安装程序需要 Python 3.9 或更高版本。" >&2 ;;
    *) echo "ERROR: Universal Build Script installer requires Python 3.9+." >&2 ;;
  esac
  exit 1
}

exec python3 - "$@" <<'PY'
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tempfile
import time
from typing import Dict, FrozenSet, List, Optional, Tuple
from urllib.parse import urljoin
from urllib.request import Request, urlopen


# Standalone installer — can't import scripts/i18n.py (doesn't exist locally
# yet), so language detection/messages are embedded here too.
def _detect_lang() -> str:
    raw = (
        os.environ.get("UBS_LANG")
        or os.environ.get("LC_ALL")
        or os.environ.get("LC_MESSAGES")
        or os.environ.get("LANG")
        or ""
    )
    code = raw.split(".")[0].split("_")[0].lower()
    if code in ("ko", "en", "ja", "zh"):
        return code
    # Env said nothing usable (unset, or the C/POSIX default a non-login-shell
    # launch inherits) — ask macOS what language this machine is in.
    if sys.platform == "darwin":
        try:
            completed = subprocess.run(
                ["defaults", "read", "-g", "AppleLocale"],
                capture_output=True,
                text=True,
                timeout=2,
                check=True,
            )
        except (OSError, subprocess.SubprocessError):
            return "en"
        code = completed.stdout.strip().split(".")[0].split("_")[0].lower()
        if code in ("ko", "en", "ja", "zh"):
            return code
    return "en"


_LANG = _detect_lang()

_MESSAGES: Dict[str, Dict[str, str]] = {
    "OPENSSL_REQUIRED": {
        "ko": "manifest 서명 검증에는 openssl이 필요합니다.",
        "en": "manifest signature verification requires openssl.",
        "ja": "manifest 署名検証には openssl が必要です。",
        "zh": "manifest 签名验证需要 openssl。",
    },
    "SIGNATURE_INVALID": {
        "ko": "manifest 서명 검증 실패 — 다운로드 채널이 침해됐을 수 있습니다.",
        "en": "manifest signature verification failed — the download channel may be compromised.",
        "ja": "manifest の署名検証に失敗しました — ダウンロード経路が侵害されている可能性があります。",
        "zh": "manifest 签名验证失败 —— 下载渠道可能已被攻破。",
    },
    "FILE_SOURCE_TEST_ONLY": {
        "ko": "file:// 설치 소스는 명시적 테스트 모드에서만 허용됩니다.",
        "en": "file:// install source is allowed only in explicit test mode.",
        "ja": "file:// インストールソースは明示的なテストモードでのみ許可されます。",
        "zh": "仅在显式测试模式下才允许使用 file:// 安装源。",
    },
    "SOURCE_REQUIRES_HTTPS": {
        "ko": "설치 소스는 HTTPS만 허용됩니다: {url}",
        "en": "install source must use HTTPS: {url}",
        "ja": "インストールソースは HTTPS のみ許可されます: {url}",
        "zh": "安装源必须使用 HTTPS：{url}",
    },
    "DOWNLOAD_FAILED": {
        "ko": "다운로드 실패: {relative}: {error}",
        "en": "download failed: {relative}: {error}",
        "ja": "ダウンロードに失敗しました: {relative}: {error}",
        "zh": "下载失败：{relative}：{error}",
    },
    "MANIFEST_LINE_INVALID": {
        "ko": "잘못된 manifest 줄입니다: {number}",
        "en": "invalid manifest line {number}",
        "ja": "無効な manifest 行です: {number}",
        "zh": "无效的 manifest 行：{number}",
    },
    "MANIFEST_SHA256_INVALID": {
        "ko": "manifest {number}번째 줄의 SHA-256 값이 잘못됐습니다.",
        "en": "invalid SHA-256 on manifest line {number}",
        "ja": "manifest {number} 行目の SHA-256 が無効です。",
        "zh": "manifest 第 {number} 行的 SHA-256 无效。",
    },
    "MANIFEST_DUP_PATH": {
        "ko": "manifest에 중복된 경로입니다: {relative}",
        "en": "duplicate manifest path: {relative}",
        "ja": "manifest に重複したパスがあります: {relative}",
        "zh": "manifest 中存在重复路径：{relative}",
    },
    "VERSION_MISMATCH": {
        "ko": "설치기/manifest 버전이 일치하지 않습니다: {installer} != {manifest}",
        "en": "installer/manifest version mismatch: {installer} != {manifest}",
        "ja": "インストーラーと manifest のバージョンが一致しません: {installer} != {manifest}",
        "zh": "安装程序与 manifest 版本不匹配：{installer} != {manifest}",
    },
    "MANIFEST_SET_MISMATCH": {
        "ko": "관리 대상 manifest 구성이 다릅니다: missing={missing} extra={extra}",
        "en": "managed manifest mismatch: missing={missing} extra={extra}",
        "ja": "管理対象 manifest の構成が一致しません: missing={missing} extra={extra}",
        "zh": "受管理的 manifest 内容不匹配：missing={missing} extra={extra}",
    },
    "UNSAFE_PATH": {
        "ko": "안전하지 않은 설치 경로입니다: {relative}",
        "en": "unsafe install path: {relative}",
        "ja": "安全でないインストールパスです: {relative}",
        "zh": "不安全的安装路径：{relative}",
    },
    "SYMLINK_PATH_REFUSED": {
        "ko": "심볼릭 링크 설치 경로는 거부합니다: {relative}",
        "en": "refusing symbolic-link install path: {relative}",
        "ja": "シンボリックリンクのインストールパスは拒否されます: {relative}",
        "zh": "拒绝符号链接安装路径：{relative}",
    },
    "DEST_NOT_FILE": {
        "ko": "설치 대상이 파일이 아닙니다: {relative}",
        "en": "install destination is not a file: {relative}",
        "ja": "インストール先がファイルではありません: {relative}",
        "zh": "安装目标不是文件：{relative}",
    },
    "SHA256_MISMATCH": {
        "ko": "SHA-256 불일치: {relative}",
        "en": "SHA-256 mismatch: {relative}",
        "ja": "SHA-256 が一致しません: {relative}",
        "zh": "SHA-256 不匹配: {relative}",
    },
    "INSTALLED": {
        "ko": "설치됨: {relative}",
        "en": "installed: {relative}",
        "ja": "インストール済み: {relative}",
        "zh": "已安装：{relative}",
    },
    "INSTALLER_HEADER": {
        "ko": "Universal Build Script {version} 트랜잭션 설치기 ({kind})",
        "en": "Universal Build Script {version} transactional installer ({kind})",
        "ja": "Universal Build Script {version} トランザクション型インストーラー ({kind})",
        "zh": "Universal Build Script {version} 事务性安装程序（{kind}）",
    },
    "SOURCE_LABEL": {
        "ko": "소스: {url}",
        "en": "source: {url}",
        "ja": "ソース: {url}",
        "zh": "来源：{url}",
    },
    "PRESERVED": {
        "ko": "보존됨: {relative} (교체하려면 UBS_FORCE=true 설정)",
        "en": "preserved: {relative} (set UBS_FORCE=true to replace)",
        "ja": "保持されました: {relative}(置き換えるには UBS_FORCE=true を設定)",
        "zh": "已保留：{relative}（如需替换请设置 UBS_FORCE=true）",
    },
    "INSTALL_COMPLETE": {
        "ko": "설치 완료",
        "en": "installation complete",
        "ja": "インストール完了",
        "zh": "安装完成",
    },
    "HINT_DETECT": {
        "ko": "감지: ./build.sh detect",
        "en": "detect: ./build.sh detect",
        "ja": "検出: ./build.sh detect",
        "zh": "检测：./build.sh detect",
    },
    "HINT_BUILD": {
        "ko": "빌드:  ./build.sh",
        "en": "build:  ./build.sh",
        "ja": "ビルド: ./build.sh",
        "zh": "构建：./build.sh",
    },
    "INSTALL_FAILED": {
        "ko": "설치 실패: {error}",
        "en": "installation failed: {error}",
        "ja": "インストールに失敗しました: {error}",
        "zh": "安装失败：{error}",
    },
}


def t(key: str, **kwargs) -> str:
    table = _MESSAGES.get(key, {})
    template = table.get(_LANG) or table.get("en") or key
    return template.format(**kwargs) if kwargs else template


# scripts/sign-update-manifest.sh 로 서명할 때 쓰는 개인키와 짝을 이루는 공개키.
# scripts/lib/update.sh 에도 동일하게 박혀 있다 — 둘 중 하나만 바꾸면 안 되고,
# CI(validate.yml)가 두 값이 같은지 검사한다. manifest와 payload가 같은 HTTPS
# 호스트에서 오므로, 서명이 없으면 그 호스트/레포 자체가 침해됐을 때 위조된
# manifest+payload 조합이 체크섬 검증을 그대로 통과할 수 있었다.
MANIFEST_PUBLIC_KEY_PEM = """-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEoeoaD2VIKDVRGJODMYQiXrlyi2uJ
CDpp7AANizXjfMqv3cvuAoiI7CSH02h0TNH4aL9+xyqsdb9P6rN1XYp5Tw==
-----END PUBLIC KEY-----
"""

VERSION = "3.11.2"
REPOSITORY = "https://raw.githubusercontent.com/Retired-Projects/UBS-ubs"
RELEASE_REF = os.environ.get("UBS_INSTALL_REF", f"v{VERSION}")
BASE_URL = os.environ.get("UBS_INSTALL_BASE_URL", f"{REPOSITORY}/{RELEASE_REF}").rstrip("/") + "/"
ALLOW_FILE = os.environ.get("UBS_INSTALL_ALLOW_FILE", "false") == "true"
FORCE = os.environ.get("UBS_FORCE", "false") == "true"
MANAGE_GITIGNORE = os.environ.get("UBS_MANAGE_GITIGNORE", "true") == "true"
ROOT = Path.cwd().resolve()

MANAGED = (
    "VERSION", "build.sh", "install.sh", "scripts/ubs.py", "scripts/ubs_mcp.py",
    "scripts/bootstrap-update.sh", "scripts/build-rust-helper.sh",
    "native/ubs-helper/Cargo.toml", "native/ubs-helper/Cargo.lock",
    "native/ubs-helper/src/main.rs", "scripts/FLUTTER_VERSION",
    "scripts/TAURI_VERSION", "scripts/build-flutter.sh",
    "scripts/build-tauri.sh", "scripts/build-tauri-macos.sh",
    "scripts/build-gradle.sh", "scripts/build-node.sh",
    "scripts/lib/detect.sh", "scripts/lib/audit.sh",
    "scripts/lib/node-package-manager.sh", "scripts/lib/update.sh",
    "scripts/lib/i18n.sh", "scripts/lib/i18n_messages.sh",
    "scripts/i18n.py", "scripts/i18n_messages.py",
    "skills/universal-build/SKILL.md", "skills/universal-build/agents/openai.yaml",
    "skills/universal-build/references/optimization.md",
    "templates/flutter/ExportOptions.plist",
    "templates/flutter/ExportOptions-macos.plist",
)

# Signed by the release manifest and consumed only during first install. The
# runtime updater must not overwrite an application's existing env templates.
INSTALLER_FILES = (".env.example", ".env.macos.example")

IGNORE_BLOCK = """# BEGIN Universal Build Script
.ubs/
.env
.env.*
!.env.example
!.env.*.example
signing/
*.p12
*.p8
*.pem
*.key
*.cer
*.mobileprovision
*.provisionprofile
*.entitlements
*.jks
*.keystore
key.properties
local.properties
GoogleService-Info.plist
google-services.json
# END Universal Build Script
"""


def fetch(relative: str) -> bytes:
    if BASE_URL.startswith("file://") and not ALLOW_FILE:
        raise RuntimeError(t("FILE_SOURCE_TEST_ONLY"))
    if not (BASE_URL.startswith("https://") or BASE_URL.startswith("file://")):
        raise RuntimeError(t("SOURCE_REQUIRES_HTTPS", url=BASE_URL))
    url = urljoin(BASE_URL, relative)
    last_error: Optional[Exception] = None
    for attempt in range(3):
        try:
            request = Request(url, headers={"User-Agent": f"universal-build-script/{VERSION}"})
            with urlopen(request, timeout=30) as response:
                return response.read()
        except Exception as error:
            last_error = error
            if attempt < 2:
                time.sleep(0.25 * (attempt + 1))
    raise RuntimeError(t("DOWNLOAD_FAILED", relative=relative, error=last_error))


def verify_manifest_signature(manifest: bytes, signature: bytes) -> None:
    # LibreSSL(macOS 기본 /usr/bin/openssl)과 OpenSSL 양쪽에서 동작하는 가장
    # 오래되고 넓게 지원되는 방식(dgst -sign/-verify, ECDSA P-256/SHA-256)을
    # 쓴다 — Ed25519는 최신 OpenSSL의 pkeyutl -rawin이 필요해 LibreSSL에서
    # 동작하지 않는다.
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError(t("OPENSSL_REQUIRED"))
    with tempfile.TemporaryDirectory(prefix="ubs-install-verify-") as tmp:
        tmp_path = Path(tmp)
        pubkey_file = tmp_path / "pubkey.pem"
        manifest_file = tmp_path / "manifest.txt"
        signature_file = tmp_path / "manifest.sig"
        pubkey_file.write_text(MANIFEST_PUBLIC_KEY_PEM, encoding="utf-8")
        manifest_file.write_bytes(manifest)
        signature_file.write_bytes(signature)
        result = subprocess.run(
            [openssl, "dgst", "-sha256", "-verify", str(pubkey_file),
             "-signature", str(signature_file), str(manifest_file)],
            capture_output=True,
        )
        if result.returncode != 0:
            raise RuntimeError(t("SIGNATURE_INVALID"))


def parse_manifest(data: bytes) -> Dict[str, str]:
    version = ""
    entries: Dict[str, str] = {}
    for number, raw in enumerate(data.decode("utf-8").splitlines(), 1):
        fields = raw.split()
        if not fields or fields[0].startswith("#"):
            continue
        if fields[0] == "version" and len(fields) == 2:
            version = fields[1]
            continue
        if len(fields) != 3 or fields[0] not in {"file", "installer-file"}:
            raise RuntimeError(t("MANIFEST_LINE_INVALID", number=number))
        digest, relative = fields[1:]
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise RuntimeError(t("MANIFEST_SHA256_INVALID", number=number))
        if relative in entries:
            raise RuntimeError(t("MANIFEST_DUP_PATH", relative=relative))
        entries[relative] = digest
    if version != VERSION:
        raise RuntimeError(t("VERSION_MISMATCH", installer=VERSION, manifest=version))
    expected = set(MANAGED) | set(INSTALLER_FILES)
    if set(entries) != expected:
        missing = sorted(expected - set(entries))
        extra = sorted(set(entries) - expected)
        raise RuntimeError(t("MANIFEST_SET_MISMATCH", missing=missing, extra=extra))
    return entries


def safe_relative(relative: str) -> PurePosixPath:
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise RuntimeError(t("UNSAFE_PATH", relative=relative))
    return path


def destination_for(relative: str) -> Path:
    path = safe_relative(relative)
    current = ROOT
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            raise RuntimeError(t("SYMLINK_PATH_REFUSED", relative=relative))
    return current


def atomic_write(destination: Path, data: bytes, mode: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination_for(destination.relative_to(ROOT).as_posix())
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.ubs-install-", dir=destination.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        destination_for(destination.relative_to(ROOT).as_posix())
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def detect_kinds() -> FrozenSet[str]:
    kinds = set()
    if (ROOT / "src-tauri" / "tauri.conf.json").is_file():
        kinds.add("tauri")
    pubspec = ROOT / "pubspec.yaml"
    if pubspec.is_file() and re.search(
        r"sdk:\s*flutter|^\s*flutter:", pubspec.read_text(encoding="utf-8", errors="replace"), re.MULTILINE,
    ):
        kinds.add("flutter")
    if any((ROOT / name).is_file() for name in ("gradlew", "settings.gradle", "settings.gradle.kts")):
        kinds.add("gradle")
    package = ROOT / "package.json"
    if package.is_file() and re.search(r'"build"\s*:', package.read_text(encoding="utf-8", errors="replace")):
        kinds.add("node")
    return frozenset(kinds)


# Files every install needs regardless of detected project kind(s).
COMMON_FILES: FrozenSet[str] = frozenset({
    "VERSION", "build.sh", "install.sh", "scripts/ubs.py", "scripts/ubs_mcp.py",
    "scripts/bootstrap-update.sh", "scripts/lib/detect.sh", "scripts/lib/audit.sh",
    "scripts/lib/node-package-manager.sh", "scripts/lib/update.sh",
    "scripts/lib/i18n.sh", "scripts/lib/i18n_messages.sh",
    "scripts/i18n.py", "scripts/i18n_messages.py",
    "skills/universal-build/SKILL.md", "skills/universal-build/agents/openai.yaml",
    "skills/universal-build/references/optimization.md",
})

# Adapter-specific files, fetched only when the matching kind is detected.
KIND_FILES: Dict[str, FrozenSet[str]] = {
    "flutter": frozenset({
        "scripts/FLUTTER_VERSION", "scripts/build-flutter.sh",
        "templates/flutter/ExportOptions.plist",
        "templates/flutter/ExportOptions-macos.plist",
    }),
    "tauri": frozenset({
        "scripts/build-rust-helper.sh", "native/ubs-helper/Cargo.toml",
        "native/ubs-helper/Cargo.lock", "native/ubs-helper/src/main.rs",
        "scripts/TAURI_VERSION", "scripts/build-tauri.sh",
        "scripts/build-tauri-macos.sh",
    }),
    "gradle": frozenset({"scripts/build-gradle.sh"}),
    "node": frozenset({"scripts/build-node.sh"}),
}


def managed_selection(kinds: FrozenSet[str]) -> Tuple[str, ...]:
    # No kind detected (bare workspace / ambiguous monorepo root): stay safe
    # and install every adapter rather than guessing which ones are needed.
    if not kinds:
        return MANAGED
    selected = set(COMMON_FILES)
    for kind in kinds:
        selected |= KIND_FILES[kind]
    return tuple(relative for relative in MANAGED if relative in selected)


def add_change(
    changes: Dict[str, Tuple[bytes, int]], relative: str, data: bytes,
    mode: int = 0o644, preserve: bool = False,
) -> None:
    destination = destination_for(relative)
    if preserve and destination.exists():
        return
    changes[relative] = (data, mode)


def apply_transaction(changes: Dict[str, Tuple[bytes, int]]) -> None:
    backups: Dict[str, Optional[Tuple[bytes, int]]] = {}
    applied: List[str] = []
    for relative in changes:
        destination = destination_for(relative)
        if destination.exists():
            if not destination.is_file():
                raise RuntimeError(t("DEST_NOT_FILE", relative=relative))
            backups[relative] = (destination.read_bytes(), stat.S_IMODE(destination.stat().st_mode))
        else:
            backups[relative] = None
    try:
        for relative, (data, mode) in changes.items():
            atomic_write(destination_for(relative), data, mode)
            applied.append(relative)
            print(t("INSTALLED", relative=relative))
    except Exception:
        for relative in reversed(applied):
            destination = destination_for(relative)
            backup = backups[relative]
            if backup is None:
                if destination.exists():
                    destination.unlink()
            else:
                atomic_write(destination, backup[0], backup[1])
        raise


def main() -> None:
    kinds = detect_kinds()
    selected = managed_selection(kinds)
    installer_selection = tuple(
        relative for relative, kind in (
            (".env.example", "flutter"), (".env.macos.example", "tauri"),
        )
        if kind in kinds
    )
    kind_label = "+".join(sorted(kinds)) if kinds else "workspace"
    print(t("INSTALLER_HEADER", version=VERSION, kind=kind_label))
    print(t("SOURCE_LABEL", url=BASE_URL))

    key_fingerprint = hashlib.sha256(MANIFEST_PUBLIC_KEY_PEM.encode("utf-8")).hexdigest()
    print(f"manifest public key fingerprint (SHA-256): {key_fingerprint}")
    print("compare this against the value published in README.md before trusting this install")

    manifest_bytes = fetch("scripts/update-manifest.txt")
    verify_manifest_signature(manifest_bytes, fetch("scripts/update-manifest.txt.sig"))
    manifest = parse_manifest(manifest_bytes)

    def fetch_verified(relative: str) -> Tuple[str, bytes]:
        data = fetch(relative)
        actual = hashlib.sha256(data).hexdigest()
        if actual != manifest[relative]:
            raise RuntimeError(t("SHA256_MISMATCH", relative=relative))
        return relative, data

    staged: Dict[str, bytes] = {}
    payloads = (*selected, *installer_selection)
    with ThreadPoolExecutor(max_workers=min(8, len(payloads))) as executor:
        futures = [executor.submit(fetch_verified, relative) for relative in payloads]
        for future in as_completed(futures):
            relative, data = future.result()
            staged[relative] = data

    changes: Dict[str, Tuple[bytes, int]] = {}
    for relative in selected:
        destination = destination_for(relative)
        if destination.is_file() and not FORCE:
            print(t("PRESERVED", relative=relative))
            continue
        mode = 0o755 if relative.endswith(".sh") or relative in {
            "scripts/ubs.py", "scripts/ubs_mcp.py",
        } else 0o644
        add_change(changes, relative, staged[relative], mode)

    if MANAGE_GITIGNORE:
        gitignore = destination_for(".gitignore")
        existing = gitignore.read_text(encoding="utf-8") if gitignore.is_file() else ""
        pattern = re.compile(
            r"(?ms)^# BEGIN Universal Build Script\n.*?^# END Universal Build Script\n?"
        )
        if pattern.search(existing):
            updated = pattern.sub(IGNORE_BLOCK, existing)
        else:
            updated = existing.rstrip() + ("\n\n" if existing.strip() else "") + IGNORE_BLOCK
        if updated != existing:
            add_change(changes, ".gitignore", updated.encode(), 0o644)

    if "flutter" in kinds:
        env_example = staged[".env.example"]
        add_change(changes, ".env.example", env_example, preserve=True)
        if not (ROOT / ".env").exists() and not (ROOT / ".env.prod").exists():
            add_change(changes, ".env", env_example, 0o600)
        if (ROOT / "ios").is_dir():
            add_change(
                changes, "ios/ExportOptions.plist",
                staged["templates/flutter/ExportOptions.plist"], preserve=True,
            )
        if (ROOT / "macos").is_dir():
            add_change(
                changes, "macos/ExportOptions.plist",
                staged["templates/flutter/ExportOptions-macos.plist"], preserve=True,
            )
    if "tauri" in kinds:
        env_example = staged[".env.macos.example"]
        add_change(changes, ".env.macos.example", env_example, preserve=True)
        if not (ROOT / ".env.macos").exists():
            add_change(changes, ".env.macos", env_example, 0o600)

    apply_transaction(changes)
    if "tauri" in kinds:
        signing = destination_for("signing/.keep").parent
        signing.mkdir(parents=True, exist_ok=True)

    if "tauri" in kinds and os.environ.get("UBS_BUILD_RUST_HELPER", "false") == "true":
        import subprocess
        subprocess.run(["bash", "scripts/build-rust-helper.sh"], check=True)

    print(t("INSTALL_COMPLETE"))
    print(t("HINT_DETECT"))
    print(t("HINT_BUILD"))


try:
    main()
except Exception as error:
    print(t("INSTALL_FAILED", error=error), file=__import__("sys").stderr)
    raise SystemExit(1)
PY
