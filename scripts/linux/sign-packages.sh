#!/usr/bin/env bash
# v0.4.3 L5：包 PGP 签名 + 校验（deb `_gpgorigin` / rpm addsign）。
# 用法：
#   sign-packages.sh sign-deb <file.deb>   # 追加 _gpgorigin（分离签名成员）
#   sign-packages.sh sign-rpm <file.rpm>   # rpmsign --addsign
#   sign-packages.sh verify-deb <file.deb>
#   sign-packages.sh verify-rpm <file.rpm>
# 密钥：ZILT_GPG_KEY_ID（gpg keyring 中已有该 key；CI 注入经 ZILT_GPG_KEY 导入；
# 非默认 keyring 经 GNUPGHOME 透传——脚本自动映射为 rpm 的 _gpg_path 宏）。
# rpm 校验前置：gpg --armor --export <key> | rpm --import（rpm -K 需要公钥入库）。
#
# deb 追加面说明：GNU `ar r` 会规范化改写全部既有成员头（uid/mode/填充），
# 破坏「签名覆盖原始字节」的前提 → 这里按 ar 头格式（name[16] mtime[12]
# uid[6] gid[6] mode[8] size[10] `\x60\x0a`）纯字节追加，前缀零改动。
set -eu
KEY="${ZILT_GPG_KEY_ID:-}"
[ -n "$KEY" ] || { echo "set ZILT_GPG_KEY_ID" >&2; exit 2; }

# rpm 的 keyring 路径宏：GNUPGHOME 环境存在时显式下发
RPM_HOME_DEFINES=()
if [ -n "${GNUPGHOME:-}" ]; then
  RPM_HOME_DEFINES+=(--define "_gpg_path $GNUPGHOME" --define "__gpg /usr/bin/gpg")
fi

CMD="$1"; shift
case "$CMD" in
  sign-deb)
    DEB="$1"
    TMP=$(mktemp -d)
    gpg --batch --yes --detach-sign --output "$TMP/_gpgorigin" "$DEB"
    SIZE=$(stat -c%s "$TMP/_gpgorigin")
    {
      printf '_gpgorigin/     '                 # name[16]
      printf '%-12s' '0'                        # mtime[12]
      printf '%-6s' '0'                         # uid[6]
      printf '%-6s' '0'                         # gid[6]
      printf '%-8s' '100644'                    # mode[8]
      printf '%-10d' "$SIZE"                    # size[10]
      printf '\140\012'                         # magic "`\n"
      cat "$TMP/_gpgorigin"
      [ $((SIZE % 2)) -eq 1 ] && printf '\n'
    } >> "$DEB"
    rm -rf "$TMP"
    echo "[sign-deb] _gpgorigin appended -> $DEB"
    ;;
  verify-deb)
    DEB="$1"
    TMP=$(mktemp -d)
    OFFSET=$(python3 -c "
import sys
data = open(sys.argv[1], 'rb').read()
idx = data.find(b'_gpgorigin/')
sys.exit(1) if idx < 0 else print(idx)
" "$DEB") || { echo "_gpgorigin member not found" >&2; exit 5; }
    head -c "$OFFSET" "$DEB" > "$TMP/orig"
    ar p "$DEB" _gpgorigin > "$TMP/sig"
    gpg --verify "$TMP/sig" "$TMP/orig"
    rm -rf "$TMP"
    echo "[verify-deb] OK"
    ;;
  sign-rpm)
    RPM="$1"
    command -v rpmsign >/dev/null 2>&1 || { echo "rpmsign missing (apt install rpm-sign)" >&2; exit 4; }
    rpmsign --addsign --define "_gpg_name $KEY" "${RPM_HOME_DEFINES[@]}" "$RPM"
    echo "[sign-rpm] signed -> $RPM"
    ;;
  verify-rpm)
    RPM="$1"
    rpm -K "$RPM"
    ;;
  *)
    echo "usage: $0 sign-deb|sign-rpm|verify-deb|verify-rpm <file>" >&2
    exit 2
    ;;
esac
