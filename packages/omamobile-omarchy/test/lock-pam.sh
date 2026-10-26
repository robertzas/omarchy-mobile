#!/bin/bash
# SPDX-License-Identifier: MIT
# lib/lock-pam against scratch roots: Omarchy's stanza when its
# omarchy-apply-lock is there, the built-in copy when not, an existing file
# and the fingerprint file never touched. OMARCHY_PKG_ROOT (an extracted
# omarchy package) adds a check against the real omarchy-apply-lock.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
tool=$PWD/lib/lock-pam

# Omarchy's script, in the shape omarchy-apply-lock has (4.0.6)
r=$t/omarchy; mkdir -p "$r/usr/bin" "$r/etc/pam.d"
cat >"$r/usr/bin/omarchy-apply-lock" <<'SH'
#!/bin/bash
as_root tee /etc/pam.d/omarchy-lock-password >/dev/null <<'EOF'
#%PAM-1.0
auth       required                    pam_unix.so try_first_pass nullok  # from omarchy
account    include                     system-local-login
EOF
as_root tee /etc/pam.d/omarchy-lock-fingerprint >/dev/null <<'EOF'
#%PAM-1.0
auth       required                    pam_fprintd.so
EOF
SH
echo fingerprint-from-omamobile >"$r/etc/pam.d/omarchy-lock-fingerprint"
"$tool" --root "$r" >/dev/null || fail "lock-pam runs"
f=$r/etc/pam.d/omarchy-lock-password
[[ $(head -1 "$f") == '#%PAM-1.0' ]] && grep -c '# from omarchy' "$f" >/dev/null || fail "Omarchy's stanza is written"
grep -c pam_fprintd "$f" >/dev/null && fail "only the password stanza is taken"
[[ $(stat -c %a "$f") == 644 ]] || fail "the file is world-readable, as Omarchy writes it"
[[ $(cat "$r/etc/pam.d/omarchy-lock-fingerprint") == fingerprint-from-omamobile ]] || fail "the fingerprint file is left alone"
pass "writes Omarchy's password stanza and nothing else"

echo 'auth required pam_hand_made.so' >"$f"
"$tool" --root "$r" >/dev/null || fail "lock-pam runs again"
[[ $(cat "$f") == 'auth required pam_hand_made.so' ]] || fail "an existing file is kept"
pass "an existing file is left as it is"

r=$t/bare; mkdir -p "$r"
"$tool" --root "$r" | grep -c 'built-in copy' >/dev/null || fail "the fallback is reported"
grep -c '^account    include                     system-local-login$' "$r/etc/pam.d/omarchy-lock-password" >/dev/null \
  && grep -c 'pam_faillock.so preauth' "$r/etc/pam.d/omarchy-lock-password" >/dev/null || fail "the built-in stanza is written"
[[ ! -e $r/etc/pam.d/omarchy-lock-fingerprint ]] || fail "no fingerprint file is made"
pass "without Omarchy's script, the built-in copy"

r=$t/odd; mkdir -p "$r/usr/bin"
printf '#!/bin/bash\ntee /etc/pam.d/omarchy-lock-password <<'"'"'EOF'"'"'\nnot pam\nEOF\n' >"$r/usr/bin/omarchy-apply-lock"
"$tool" --root "$r" >/dev/null
grep -c pam_unix.so "$r/etc/pam.d/omarchy-lock-password" >/dev/null || fail "a stanza that isn't PAM falls back"
pass "a stanza that doesn't look like PAM is not taken"

if [[ -n ${OMARCHY_PKG_ROOT:-} ]]; then
  r=$t/real; mkdir -p "$r/usr/bin"
  cp "$OMARCHY_PKG_ROOT/usr/bin/omarchy-apply-lock" "$r/usr/bin/"
  "$tool" --root "$r" | grep -c "Omarchy's omarchy-apply-lock" >/dev/null || fail "the real omarchy-apply-lock is read"
  # The built-in copy is the one Omarchy ships: keep them in step
  diff <(sed -n "/<<'EOF'/,/^EOF/p" "$tool" | sed '1d;$d') "$r/etc/pam.d/omarchy-lock-password" >/dev/null \
    || fail "the built-in copy matches the real omarchy-apply-lock"
  pass "the real omarchy-apply-lock: its stanza, and the built-in copy matches it"
fi
