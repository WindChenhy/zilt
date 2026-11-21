#!/usr/bin/env bash
# v0.4.3 L5：包签名 + 校验端到端（deb `_gpgorigin` / rpm `rpmsign --addsign`）。
#
# 用法：bash scripts/linux/dev-sign-e2e.sh [--no-build]
#   --no-build  复用 dist/ 里已有的 deb/rpm（不重新打包）
#
# 密钥：默认生成**临时**测试密钥（GNUPGHOME 在临时目录，结束即删）；
#       发布签名传 `ZILT_GPG_KEY_ID` + `GNUPGHOME` 复用真实密钥。
# 退出码：0 PASS / 1 FAIL / 3 SKIP（缺工具或产物）
#
# 断言：
#   1. deb 追加 `_gpgorigin` 后 `gpg --verify` Good signature
#   2. 签名后的 deb 仍被 dpkg-deb 正常解析（ar 前缀零改动）
#   3. rpm --addsign 后在**独立 rpmdb** 导入公钥 → `rpm -K` digests signatures OK
#   4. 反向对照：空 rpmdb 下同文件 `rpm -K` 必须不是 OK（证明校验真的用到了签名）
set -eu
cd "$(dirname "$0")/../.."

NO_BUILD=0
[ "${1:-}" = "--no-build" ] && NO_BUILD=1

for t in gpg dpkg-deb rpm rpm2cpio python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "SIGN_E2E=SKIP reason=missing-$t"; exit 3; }
done
command -v rpmsign >/dev/null 2>&1 || { echo "SIGN_E2E=SKIP reason=missing-rpmsign"; exit 3; }

if [ "$NO_BUILD" = 0 ]; then
  bash scripts/linux/pack-rpm.sh >/dev/null 2>&1 || { echo "SIGN_E2E=FAIL reason=pack"; exit 1; }
fi

# 取最新产物（dist/ 里可能残留历史版本）
DEB=$(ls -t dist/*.deb 2>/dev/null | head -1 || true)
RPM=$(ls -t dist/*.rpm 2>/dev/null | head -1 || true)
[ -n "$DEB" ] && [ -n "$RPM" ] || { echo "SIGN_E2E=SKIP reason=no-artifacts"; exit 3; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; FAIL=1; }

# ---- 0) 产物卫生（v0.4.3 修复的 tar 条目名 UAF 回归哨兵）----
DEB_LIST="$TMP/deb-list.txt"
dpkg-deb -c "$DEB" > "$DEB_LIST" 2>/dev/null || { echo "SIGN_E2E=FAIL reason=deb-unreadable"; exit 1; }
if grep -q '\\[0-7][0-7][0-7]' "$DEB_LIST"; then
  echo "  FAIL deb 含不可打印文件名（tar 头被写到已回收内存？）"
  grep '\\[0-7][0-7][0-7]' "$DEB_LIST" | head -3 | sed 's/^/    /'
  FAIL=1
else
  echo "  PASS deb 条目名可打印"
fi
for want in './usr/bin/zilt-app' '/usr/share/applications/' '/usr/share/icons/hicolor/256x256/apps/'; do
  grep -qF "$want" "$DEB_LIST" || { echo "  FAIL deb missing $want"; FAIL=1; }
done

# ---- 密钥：临时 or 复用 ----
if [ -n "${ZILT_GPG_KEY_ID:-}" ]; then
  KEY="$ZILT_GPG_KEY_ID"
  echo "KEY=reuse:$KEY"
else
  export GNUPGHOME="$TMP/gnupg"
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-gen-key 'Zilt E2E <e2e@zilt.invalid>' rsa2048 sign 0 >"$TMP/keygen.log" 2>&1
  KEY=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
  echo "KEY=ephemeral:$KEY"
fi
[ -n "$KEY" ] || { echo "SIGN_E2E=FAIL reason=no-key"; exit 1; }
export ZILT_GPG_KEY_ID="$KEY"
gpg --armor --export "$KEY" > "$TMP/pub.asc"

# ---- 1/2) deb ----
cp "$DEB" "$TMP/app.deb"
SIG_DEB="$TMP/app.deb"
if bash scripts/linux/sign-packages.sh sign-deb "$SIG_DEB" >/dev/null 2>&1; then
  ok "deb _gpgorigin appended"
else
  bad "deb sign"
fi
if bash scripts/linux/sign-packages.sh verify-deb "$SIG_DEB" >"$TMP/verify-deb.log" 2>&1; then
  ok "deb gpg --verify Good signature"
else
  bad "deb verify"; tail -3 "$TMP/verify-deb.log" | sed 's/^/    /'
fi
if dpkg-deb -I "$SIG_DEB" >"$TMP/deb-info.log" 2>&1 && grep -q 'Package:' "$TMP/deb-info.log"; then
  ok "signed deb still parses (dpkg-deb -I)"
else
  bad "dpkg-deb parse after sign"
fi

# ---- 3/4) rpm ----
cp "$RPM" "$TMP/app.rpm"
SIG_RPM="$TMP/app.rpm"
if bash scripts/linux/sign-packages.sh sign-rpm "$SIG_RPM" >"$TMP/sign-rpm.log" 2>&1; then
  ok "rpm --addsign"
else
  bad "rpm sign"; tail -3 "$TMP/sign-rpm.log" | sed 's/^/    /'
fi
DB="$TMP/rpmdb"
rpm --dbpath "$DB" --initdb >/dev/null 2>&1
rpm --dbpath "$DB" --import "$TMP/pub.asc" >/dev/null 2>&1
if rpm --dbpath "$DB" -K "$SIG_RPM" >"$TMP/rpmk.log" 2>&1 && grep -q 'signatures OK' "$TMP/rpmk.log"; then
  ok "rpm -K digests signatures OK (imported key)"
else
  bad "rpm -K"; cat "$TMP/rpmk.log" | sed 's/^/    /'
fi
EMPTY="$TMP/empty"
rpm --dbpath "$EMPTY" --initdb >/dev/null 2>&1
if rpm --dbpath "$EMPTY" -K "$SIG_RPM" >"$TMP/rpmk-empty.log" 2>&1 && grep -q 'signatures OK' "$TMP/rpmk-empty.log"; then
  bad "negative control: signature verified without key (unexpected)"
else
  ok "negative control: unverified without imported key"
fi
# 未签名原件也必须不是 OK（防止「永远 OK」的假断言）
if rpm --dbpath "$DB" -K "$RPM" >"$TMP/rpmk-orig.log" 2>&1 && grep -q 'signatures OK' "$TMP/rpmk-orig.log"; then
  bad "original rpm reported signed (unexpected)"
else
  ok "control: unsigned original not OK"
fi

echo "SIGNED_COPIES=$(basename "$DEB") + $(basename "$RPM")（签名在临时副本上验证）"
if [ "$FAIL" = 0 ]; then echo "SIGN_E2E=PASS"; exit 0; fi
echo "SIGN_E2E=FAIL"; exit 1
