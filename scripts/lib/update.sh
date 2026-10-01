#!/usr/bin/env bash

_UPDATE_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_UPDATE_SH_DIR/i18n.sh" ]; then
  source "$_UPDATE_SH_DIR/i18n.sh"
else
  # update.sh is what's supposed to restore a missing i18n.sh — its own
  # messages must still print (degraded to the raw key) if that hasn't
  # happened yet.
  ubs_msg() { printf '%s' "$1"; }
fi

# Universal Build Script의 제한된 런타임 번들을 안전하게 갱신한다.
# 원격 manifest는 서명 검증(아래 UBS_UPDATE_MANIFEST_PUBLIC_KEY)으로 무결성을
# 보장한다 — manifest와 payload가 같은 HTTPS 호스트에서 오므로, 서명이 없으면
# 그 호스트/레포 자체가 침해됐을 때 위조된 manifest+payload 조합이 체크섬 검증을
# 그대로 통과할 수 있었다. 서명 개인키는 이 레포에 없고 로컬(릴리스 담당자
# 머신)에만 있다 — scripts/sign-update-manifest.sh 로 릴리스마다 수동 서명한다.

UBS_UPDATE_DEFAULT_BASE_URL="https://raw.githubusercontent.com/Retired-Projects/UBS-ubs/main"
UBS_UPDATE_RELEASE_ROOT="https://raw.githubusercontent.com/Retired-Projects/UBS-ubs"

# scripts/sign-update-manifest.sh 로 서명할 때 쓰는 개인키와 짝을 이루는 공개키.
# 이 상수는 install.sh에도 동일하게 박혀 있다 — 둘 중 하나만 바꾸면 안 되고,
# CI(validate.yml)가 두 값이 같은지 검사한다.
UBS_UPDATE_MANIFEST_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEoeoaD2VIKDVRGJODMYQiXrlyi2uJ
CDpp7AANizXjfMqv3cvuAoiI7CSH02h0TNH4aL9+xyqsdb9P6rN1XYp5Tw==
-----END PUBLIC KEY-----'

# manifest에 대한 ECDSA(P-256/SHA-256) 서명을 검증한다. LibreSSL(macOS 기본
# /usr/bin/openssl)과 OpenSSL 양쪽에서 동작하는 가장 오래되고 넓게 지원되는
# 방식(dgst -sign/-verify)을 쓴다 — Ed25519는 최신 OpenSSL의 pkeyutl -rawin이
# 필요해 LibreSSL에서 동작하지 않는다.
ubs_update_verify_manifest_signature() {
  local manifest="$1" signature="$2" pubkey_file
  command -v openssl >/dev/null 2>&1 || {
    echo "$(ubs_msg UPDATE_OPENSSL_REQUIRED)" >&2
    return 1
  }
  pubkey_file="$(mktemp "${TMPDIR:-/tmp}/ubs-update-pubkey.XXXXXX")" || return 1
  printf '%s\n' "$UBS_UPDATE_MANIFEST_PUBLIC_KEY" > "$pubkey_file"
  if ! openssl dgst -sha256 -verify "$pubkey_file" -signature "$signature" "$manifest" >/dev/null 2>&1; then
    rm -f "$pubkey_file"
    echo "$(ubs_msg UPDATE_SIGNATURE_INVALID)" >&2
    return 1
  fi
  rm -f "$pubkey_file"
}

ubs_update_allowed_path() {
  case "$1" in
    VERSION|build.sh|install.sh|scripts/ubs.py|scripts/ubs_mcp.py|scripts/bootstrap-update.sh|scripts/build-rust-helper.sh|\
    native/ubs-helper/Cargo.toml|native/ubs-helper/Cargo.lock|native/ubs-helper/src/main.rs|\
    scripts/FLUTTER_VERSION|scripts/TAURI_VERSION|\
    scripts/build-flutter.sh|scripts/build-tauri.sh|scripts/build-tauri-macos.sh|scripts/build-gradle.sh|\
    scripts/build-node.sh|scripts/lib/detect.sh|scripts/lib/audit.sh|\
    scripts/lib/node-package-manager.sh|scripts/lib/update.sh|\
    scripts/lib/i18n.sh|scripts/lib/i18n_messages.sh|\
    scripts/i18n.py|scripts/i18n_messages.py|\
    skills/universal-build/SKILL.md|skills/universal-build/agents/openai.yaml|\
    skills/universal-build/references/optimization.md|templates/flutter/ExportOptions.plist|\
    templates/flutter/ExportOptions-macos.plist) return 0 ;;
    *) return 1 ;;
  esac
}

ubs_update_allowed_installer_path() {
  case "$1" in
    .env.example|.env.macos.example) return 0 ;;
    *) return 1 ;;
  esac
}

ubs_update_required_paths() {
  cat <<'EOF'
VERSION
build.sh
install.sh
scripts/ubs.py
scripts/ubs_mcp.py
scripts/bootstrap-update.sh
scripts/build-rust-helper.sh
native/ubs-helper/Cargo.toml
native/ubs-helper/Cargo.lock
native/ubs-helper/src/main.rs
scripts/FLUTTER_VERSION
scripts/TAURI_VERSION
scripts/build-flutter.sh
scripts/build-tauri.sh
scripts/build-tauri-macos.sh
scripts/build-gradle.sh
scripts/build-node.sh
scripts/lib/detect.sh
scripts/lib/audit.sh
scripts/lib/node-package-manager.sh
scripts/lib/update.sh
scripts/lib/i18n.sh
scripts/lib/i18n_messages.sh
scripts/i18n.py
scripts/i18n_messages.py
skills/universal-build/SKILL.md
skills/universal-build/agents/openai.yaml
skills/universal-build/references/optimization.md
templates/flutter/ExportOptions.plist
templates/flutter/ExportOptions-macos.plist
EOF
}

ubs_update_installer_paths() {
  cat <<'EOF'
.env.example
.env.macos.example
EOF
}

ubs_update_prune_backups() {
  local root="$1" days="$2" json="${3:-false}" backups
  local count=0 backup_path
  backups="$root/.ubs/backups"
  printf '%s' "$days" | grep -Eqs '^[0-9]+$' || { echo "$(ubs_msg UPDATE_RETENTION_DAYS_INVALID "$days")" >&2; return 2; }
  if [ -L "$root/.ubs" ] || [ -L "$backups" ]; then
    echo "$(ubs_msg UPDATE_BACKUP_SYMLINK_SKIP "$backups")" >&2
    return 1
  fi
  if [ -d "$backups" ]; then
    while IFS= read -r backup_path; do
      [ -n "$backup_path" ] || continue
      rm -rf "$backup_path"
      count=$((count + 1))
    done < <(find "$backups" -mindepth 1 -maxdepth 1 -type d -mtime "+$days" -print)
  fi
  if [ "$json" = true ]; then
    printf '{"ok":true,"mode":"prune-backups","retention_days":%s,"deleted":%s}\n' "$days" "$count"
  else
    echo "$(ubs_msg UPDATE_BACKUP_PRUNED "$days" "$count")"
  fi
}

ubs_update_sha256() {
  if [ -n "${UBS_RUST_HELPER:-}" ] && [ -x "$UBS_RUST_HELPER" ]; then
    "$UBS_RUST_HELPER" sha256 "$1"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "$(ubs_msg UPDATE_SHA256_TOOL_REQUIRED)" >&2
    return 1
  fi
}

ubs_update_fetch() {
  local url="$1" output="$2"
  curl -fsSL --retry 2 --connect-timeout 5 --max-time 30 "$url" -o "$output"
}

ubs_update_semver_compare() {
  awk -v left="$1" -v right="$2" 'BEGIN {
    split(left, a, "."); split(right, b, ".")
    for (i = 1; i <= 3; i++) {
      if ((a[i] + 0) > (b[i] + 0)) { print 1; exit }
      if ((a[i] + 0) < (b[i] + 0)) { print -1; exit }
    }
    print 0
  }'
}

ubs_update_cleanup() {
  if [ -n "${UBS_UPDATE_CLEANUP_TEMP:-}" ]; then
    rm -rf "$UBS_UPDATE_CLEANUP_TEMP" || true
  fi
  if [ -n "${UBS_UPDATE_CLEANUP_LOCK:-}" ]; then
    rmdir "$UBS_UPDATE_CLEANUP_LOCK" 2>/dev/null || true
  fi
}

ubs_update_safe_destination() {
  local root="$1" relative="$2" current component old_ifs
  ubs_update_allowed_path "$relative" || return 1
  if [ -n "${UBS_RUST_HELPER:-}" ] && [ -x "$UBS_RUST_HELPER" ]; then
    "$UBS_RUST_HELPER" validate-relative "$relative" || return 1
  fi
  case "$relative" in /*|*../*|../*|*/..) return 1 ;; esac

  current="$root"
  old_ifs="$IFS"
  IFS='/'
  for component in $relative; do
    current="$current/$component"
    if [ -L "$current" ]; then
      IFS="$old_ifs"
      echo "$(ubs_msg UPDATE_PATH_SYMLINK_SKIP "$relative")" >&2
      return 1
    fi
  done
  IFS="$old_ifs"
}

ubs_update_restore() {
  local root="$1" backup="$2"
  shift 2
  local relative destination restore_tmp
  for relative in "$@"; do
    destination="$root/$relative"
    if [ -e "$backup/$relative" ]; then
      mkdir -p "$(dirname "$destination")" || { echo "$(ubs_msg UPDATE_RESTORE_DIR_FAILED "$relative")" >&2; continue; }
      restore_tmp="$(mktemp "$destination.ubs-restore.XXXXXX")" || {
        echo "$(ubs_msg UPDATE_RESTORE_TEMP_FAILED "$relative")" >&2
        continue
      }
      if ! cp -p "$backup/$relative" "$restore_tmp" || ! mv -f "$restore_tmp" "$destination"; then
        echo "$(ubs_msg UPDATE_RESTORE_FAILED "$relative")" >&2
        rm -f "$restore_tmp" || true
      fi
    else
      rm -f "$destination" || echo "$(ubs_msg UPDATE_NEW_FILE_REMOVE_FAILED "$relative")" >&2
    fi
  done
}

ubs_run_update() {
  local root="$1" check_only="$2" dry_run="$3"
  local base_url payload_base_url manifest_url temp_dir manifest manifest_sig remote_version="" seen=""
  local kind value relative extra expected actual local_version changed_count=0
  local required timestamp backup_dir destination install_tmp mode version_order lock_dir i changed_file helper_dir root_helper_dir
  local rust_batch=false rust_source_changed=false
  local -a paths hashes changed_paths installed_paths

  command -v curl >/dev/null 2>&1 || { echo "$(ubs_msg UPDATE_CURL_REQUIRED)" >&2; return 1; }

  base_url="${UBS_UPDATE_BASE_URL:-$UBS_UPDATE_DEFAULT_BASE_URL}"
  base_url="${base_url%/}"
  case "$base_url" in
    https://*) ;;
    file://*)
      [ "${UBS_UPDATE_ALLOW_FILE:-false}" = "true" ] || {
        echo "$(ubs_msg UPDATE_FILE_SCHEME_TEST_ONLY)" >&2
        return 1
      }
      ;;
    *) echo "$(ubs_msg UPDATE_URL_HTTPS_REQUIRED "$base_url")" >&2; return 1 ;;
  esac

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ubs-update.XXXXXX")" || return 1
  manifest="$temp_dir/update-manifest.txt"
  manifest_url="$base_url/scripts/update-manifest.txt"
  if ! ubs_update_fetch "$manifest_url" "$manifest"; then
    echo "$(ubs_msg UPDATE_MANIFEST_FETCH_FAILED "$manifest_url")" >&2
    rm -rf "$temp_dir"
    return 1
  fi
  manifest_sig="$temp_dir/update-manifest.txt.sig"
  if ! ubs_update_fetch "$manifest_url.sig" "$manifest_sig"; then
    echo "$(ubs_msg UPDATE_MANIFEST_SIG_FETCH_FAILED "$manifest_url.sig")" >&2
    rm -rf "$temp_dir"
    return 1
  fi
  if ! ubs_update_verify_manifest_signature "$manifest" "$manifest_sig"; then
    rm -rf "$temp_dir"
    return 1
  fi

  while IFS=' ' read -r kind value relative extra; do
    [ -z "$kind" ] && continue
    case "$kind" in
      \#*) continue ;;
      version)
        if [ -n "$remote_version" ] || [ -z "$value" ] || [ -n "$relative" ]; then
          echo "$(ubs_msg UPDATE_VERSION_ENTRY_INVALID)" >&2
          rm -rf "$temp_dir"
          return 1
        fi
        remote_version="$value"
        ;;
      file)
        if ! printf '%s' "$value" | grep -Eqs '^[0-9a-f]{64}$' || \
           [ -z "$relative" ] || [ -n "$extra" ] || \
           ! ubs_update_allowed_path "$relative"; then
          echo "$(ubs_msg UPDATE_MANIFEST_ENTRY_INVALID "$relative")" >&2
          rm -rf "$temp_dir"
          return 1
        fi
        case " $seen " in
          *" $relative "*)
            echo "$(ubs_msg UPDATE_MANIFEST_PATH_DUPLICATE "$relative")" >&2
            rm -rf "$temp_dir"
            return 1
            ;;
        esac
        seen="$seen $relative"
        paths+=("$relative")
        hashes+=("$value")
        ;;
      installer-file)
        if ! printf '%s' "$value" | grep -Eqs '^[0-9a-f]{64}$' || \
           [ -z "$relative" ] || [ -n "$extra" ] || \
           ! ubs_update_allowed_installer_path "$relative"; then
          echo "$(ubs_msg UPDATE_MANIFEST_ENTRY_INVALID "$relative")" >&2
          rm -rf "$temp_dir"
          return 1
        fi
        case " $seen " in
          *" $relative "*)
            echo "$(ubs_msg UPDATE_MANIFEST_PATH_DUPLICATE "$relative")" >&2
            rm -rf "$temp_dir"
            return 1
            ;;
        esac
        seen="$seen $relative"
        ;;
      *)
        echo "$(ubs_msg UPDATE_MANIFEST_ENTRY_UNKNOWN "$kind")" >&2
        rm -rf "$temp_dir"
        return 1
        ;;
    esac
  done < "$manifest"

  if ! printf '%s' "$remote_version" | grep -Eqs '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$(ubs_msg UPDATE_MANIFEST_VERSION_FORMAT "$remote_version")" >&2
    rm -rf "$temp_dir"
    return 1
  fi
  payload_base_url="$base_url"
  if [ "$base_url" = "$UBS_UPDATE_DEFAULT_BASE_URL" ] && \
     [ "${UBS_UPDATE_USE_RELEASE_TAGS:-true}" = true ]; then
    payload_base_url="$UBS_UPDATE_RELEASE_ROOT/v$remote_version"
  fi
  while IFS= read -r required; do
    case " $seen " in
      *" $required "*) ;;
      *) echo "$(ubs_msg UPDATE_MANIFEST_REQUIRED_PATH_MISSING "$required")" >&2; rm -rf "$temp_dir"; return 1 ;;
    esac
  done < <(ubs_update_required_paths)

  local_version="unknown"
  [ -f "$root/VERSION" ] && local_version="$(tr -d '[:space:]' < "$root/VERSION")"
  if printf '%s' "$local_version" | grep -Eqs '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    version_order="$(ubs_update_semver_compare "$remote_version" "$local_version")"
    if [ "$version_order" = "-1" ] && [ "${UBS_UPDATE_ALLOW_DOWNGRADE:-false}" != "true" ]; then
      echo "$(ubs_msg UPDATE_DOWNGRADE_BLOCKED "$local_version" "$remote_version")" >&2
      echo "$(ubs_msg UPDATE_DOWNGRADE_HINT)" >&2
      rm -rf "$temp_dir"
      return 1
    fi
  fi

  for ((i = 0; i < ${#paths[@]}; i++)); do
    relative="${paths[$i]}"
    if ! ubs_update_safe_destination "$root" "$relative"; then
      rm -rf "$temp_dir"
      return 1
    fi
  done

  if [ -n "${UBS_RUST_HELPER:-}" ] && [ -x "$UBS_RUST_HELPER" ]; then
    changed_file="$temp_dir/changed-paths.txt"
    if "$UBS_RUST_HELPER" changed-manifest "$manifest" "$root" > "$changed_file" 2>/dev/null; then
      rust_batch=true
      while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        case " ${paths[*]} " in
          *" $relative "*) ;;
          *) echo "$(ubs_msg UPDATE_RUST_HELPER_PATH_OUTSIDE "$relative")" >&2; rm -rf "$temp_dir"; return 1 ;;
        esac
        case " ${changed_paths[*]} " in
          *" $relative "*) echo "$(ubs_msg UPDATE_RUST_HELPER_PATH_DUPLICATE "$relative")" >&2; rm -rf "$temp_dir"; return 1 ;;
        esac
        changed_paths+=("$relative")
        changed_count=$((changed_count + 1))
      done < "$changed_file"
    else
      echo "$(ubs_msg UPDATE_RUST_HELPER_BATCH_UNSUPPORTED)" >&2
    fi
  fi

  if [ "$rust_batch" != true ]; then
    for ((i = 0; i < ${#paths[@]}; i++)); do
      relative="${paths[$i]}"
      expected="${hashes[$i]}"
      actual=""
      [ -f "$root/$relative" ] && actual="$(ubs_update_sha256 "$root/$relative")"
      if [ "$actual" != "$expected" ]; then
        changed_paths+=("$relative")
        changed_count=$((changed_count + 1))
      fi
    done
  fi

  echo "$(ubs_msg UPDATE_VERSION_STATUS "$local_version" "$remote_version")"
  if [ "$changed_count" -eq 0 ]; then
    echo "$(ubs_msg UPDATE_UP_TO_DATE)"
    rm -rf "$temp_dir"
    return 0
  fi

  echo "$(ubs_msg UPDATE_CHANGED_COUNT "$changed_count")"
  printf '  - %s\n' "${changed_paths[@]}"
  if [ "$check_only" = true ]; then
    echo "$(ubs_msg UPDATE_CHECK_ONLY_DONE)"
    rm -rf "$temp_dir"
    return 0
  fi
  if [ "$dry_run" = true ]; then
    echo "$(ubs_msg UPDATE_DRY_RUN_SKIPPED)"
    rm -rf "$temp_dir"
    return 0
  fi

  if [ -L "$root/.ubs" ] || [ -L "$root/.ubs/backups" ]; then
    echo "$(ubs_msg UPDATE_BACKUP_ROOT_SYMLINK_BLOCK "$root/.ubs")" >&2
    rm -rf "$temp_dir"
    return 1
  fi
  mkdir -p "$root/.ubs" || { echo "$(ubs_msg UPDATE_STATE_DIR_FAILED)" >&2; rm -rf "$temp_dir"; return 1; }
  lock_dir="$root/.ubs/update.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "$(ubs_msg UPDATE_LOCK_HELD "$lock_dir")" >&2
    rm -rf "$temp_dir"
    return 1
  fi
  UBS_UPDATE_CLEANUP_TEMP="$temp_dir"
  UBS_UPDATE_CLEANUP_LOCK="$lock_dir"
  trap ubs_update_cleanup EXIT

  for ((i = 0; i < ${#paths[@]}; i++)); do
    relative="${paths[$i]}"
    expected="${hashes[$i]}"
    case " ${changed_paths[*]} " in *" $relative "*) ;; *) continue ;; esac
    if ! mkdir -p "$temp_dir/stage/$(dirname "$relative")"; then
      echo "$(ubs_msg UPDATE_STAGE_DIR_FAILED "$relative")" >&2
      rm -rf "$temp_dir"
      return 1
    fi
    if ! ubs_update_fetch "$payload_base_url/$relative" "$temp_dir/stage/$relative"; then
      echo "$(ubs_msg UPDATE_FILE_DOWNLOAD_FAILED "$relative")" >&2
      rm -rf "$temp_dir"
      return 1
    fi
    if [ "$rust_batch" != true ]; then
      actual="$(ubs_update_sha256 "$temp_dir/stage/$relative")" || { rm -rf "$temp_dir"; return 1; }
      if [ "$actual" != "$expected" ]; then
        echo "$(ubs_msg UPDATE_SHA256_MISMATCH "$relative")" >&2
        rm -rf "$temp_dir"
        return 1
      fi
    fi
  done
  if [ "$rust_batch" = true ] && \
     ! "$UBS_RUST_HELPER" verify-manifest "$manifest" "$temp_dir/stage" "${changed_paths[@]}"; then
    echo "$(ubs_msg UPDATE_RUST_BATCH_VERIFY_FAILED)" >&2
    rm -rf "$temp_dir"
    return 1
  fi

  timestamp="$(date '+%Y%m%d-%H%M%S')-$$"
  backup_dir="$root/.ubs/backups/$timestamp"
  if ! mkdir -p "$backup_dir"; then
    echo "$(ubs_msg UPDATE_BACKUP_DIR_FAILED "$backup_dir")" >&2
    rm -rf "$temp_dir"
    return 1
  fi
  for relative in "${changed_paths[@]}"; do
    if ! ubs_update_safe_destination "$root" "$relative"; then
      echo "$(ubs_msg UPDATE_BACKUP_PRECHECK_FAILED "$relative")" >&2
      rm -rf "$temp_dir"
      return 1
    fi
    if [ -e "$root/$relative" ]; then
      if ! mkdir -p "$backup_dir/$(dirname "$relative")" || \
         ! cp -p "$root/$relative" "$backup_dir/$relative"; then
        echo "$(ubs_msg UPDATE_BACKUP_FAILED "$relative")" >&2
        rm -rf "$temp_dir"
        return 1
      fi
    fi
  done

  for relative in "${changed_paths[@]}"; do
    if ! ubs_update_safe_destination "$root" "$relative"; then
      echo "$(ubs_msg UPDATE_REPLACE_PRECHECK_FAILED "$relative")" >&2
      ubs_update_restore "$root" "$backup_dir" "${installed_paths[@]}"
      rm -rf "$temp_dir"
      return 1
    fi
    destination="$root/$relative"
    if ! mkdir -p "$(dirname "$destination")"; then
      echo "$(ubs_msg UPDATE_DEST_DIR_FAILED "$relative")" >&2
      ubs_update_restore "$root" "$backup_dir" "${installed_paths[@]}"
      rm -rf "$temp_dir"
      return 1
    fi
    install_tmp="$(mktemp "$destination.ubs-new.XXXXXX")" || {
      echo "$(ubs_msg UPDATE_REPLACE_TEMP_FAILED "$relative")" >&2
      ubs_update_restore "$root" "$backup_dir" "${installed_paths[@]}"
      rm -rf "$temp_dir"
      return 1
    }
    if ! cp "$temp_dir/stage/$relative" "$install_tmp"; then
      echo "$(ubs_msg UPDATE_REPLACE_PREP_FAILED "$relative")" >&2
      ubs_update_restore "$root" "$backup_dir" "${installed_paths[@]}"
      rm -rf "$temp_dir"
      return 1
    fi
    case "$relative" in
      *.sh|scripts/ubs.py|scripts/ubs_mcp.py) mode=755 ;;
      *) mode=644 ;;
    esac
    if ! chmod "$mode" "$install_tmp"; then
      echo "$(ubs_msg UPDATE_PERMISSION_FAILED "$relative")" >&2
      rm -f "$install_tmp"
      ubs_update_restore "$root" "$backup_dir" "${installed_paths[@]}"
      rm -rf "$temp_dir"
      return 1
    fi
    if ! mv -f "$install_tmp" "$destination"; then
      echo "$(ubs_msg UPDATE_REPLACE_FAILED "$relative")" >&2
      ubs_update_restore "$root" "$backup_dir" "${installed_paths[@]}"
      rm -f "$install_tmp"
      rm -rf "$temp_dir"
      return 1
    fi
    installed_paths+=("$relative")
    case "$relative" in
      native/ubs-helper/*|scripts/build-rust-helper.sh) rust_source_changed=true ;;
    esac
  done

  helper_dir=""
  root_helper_dir=""
  [ -z "${UBS_RUST_HELPER:-}" ] || helper_dir="$(cd "$(dirname "$UBS_RUST_HELPER")" 2>/dev/null && pwd -P || true)"
  [ ! -d "$root/.ubs/bin" ] || root_helper_dir="$(cd "$root/.ubs/bin" && pwd -P)"
  if [ "$rust_source_changed" = true ] && \
     [ -n "$helper_dir" ] && [ "$helper_dir" = "$root_helper_dir" ]; then
    if command -v cargo >/dev/null 2>&1; then
      if ! bash "$root/scripts/build-rust-helper.sh"; then
        echo "$(ubs_msg UPDATE_RUST_REBUILD_FAILED)" >&2
      fi
    else
      echo "$(ubs_msg UPDATE_RUST_REBUILD_NO_CARGO)" >&2
    fi
  fi

  ubs_update_cleanup
  UBS_UPDATE_CLEANUP_TEMP=""
  UBS_UPDATE_CLEANUP_LOCK=""
  trap - EXIT
  echo "$(ubs_msg UPDATE_COMPLETE "$remote_version")"
  echo "$(ubs_msg UPDATE_BACKUP_LOCATION "$backup_dir")"
}
