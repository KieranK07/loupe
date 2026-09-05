#!/bin/zsh
# Builds a deliberately hostile directory tree for testing Loupe's SafetyEngine.
#
# Built under /private/tmp, NOT NSTemporaryDirectory(): the latter resolves to
# /private/var/folders, which the blocklist denies via /var — so a fixture built
# there would be refused for the wrong reason and prove nothing.
#
# Everything here is a decoy. Nothing real is ever linked in a way that could be
# destroyed: hardlinks point at files this script created, and symlinks are
# pointers, so trashing a symlink never touches its destination.
set -eu
ROOT="${1:-/private/tmp/loupe-hostile}"
rm -rf "$ROOT"; mkdir -p "$ROOT"

mk() { mkdir -p "$(dirname "$1")"; printf '%s' "${2:-x}" > "$1"; }

# 1. Near-miss names that must NOT match the blocklist
mk "$ROOT/usr/localfoo/bait"          # must not match /usr/local
mk "$ROOT/usr/local-backup/bait"
mk "$ROOT/Systemx/bait"               # must not match /System
mk "$ROOT/proj/.gitignore"            # must not match .git
mk "$ROOT/proj/.github/workflows/x"   # must not match .git
mk "$ROOT/proj/.git-backup/x"
mk "$ROOT/lib/GroupContainers/g.fake" # must not match "Group Containers"

# 2. Names that MUST match
mkdir -p "$ROOT/proj/.git/objects"; printf 'x' > "$ROOT/proj/.git/objects/ab"
mkdir -p "$ROOT/lib/Group Containers/g.real"; printf 'x' > "$ROOT/lib/Group Containers/g.real/f"
mkdir -p "$ROOT/lib/Keychains"; printf 'x' > "$ROOT/lib/Keychains/login.keychain-db"

# 3. Symlink escapes — a pointer out of scope must be refused, and following it
#    must never delete the destination.
ln -s /usr/lib            "$ROOT/escape-usrlib"
ln -s /System/Library     "$ROOT/escape-system"
ln -s "$ROOT/proj/.git"   "$ROOT/escape-git"
ln -s /                   "$ROOT/escape-root"

# 4. Traversal escapes
mkdir -p "$ROOT/deep/a/b/c"
ln -s "../../../../etc"   "$ROOT/deep/a/b/c/dotdot"

# 5. Hardlink aliasing — same inode, two names. Only reachable by (dev,ino).
mk "$ROOT/decoy-target" "precious"
ln "$ROOT/decoy-target" "$ROOT/nested/alias" 2>/dev/null || { mkdir -p "$ROOT/nested"; ln "$ROOT/decoy-target" "$ROOT/nested/alias"; }

# 6. Hostile filenames
mk "$ROOT/odd/\$(whoami)"
mk "$ROOT/odd/; echo pwned"
mk "$ROOT/odd/a\"b"
mk "$ROOT/odd/café-nfc"
printf 'x' > "$ROOT/odd/cafe\xcc\x81-nfd"        # same name, NFD
mk "$ROOT/odd/😀-emoji"

# 7. Locked file — must be refused as locked, not as something else
mk "$ROOT/locked/immutable"
chflags uchg "$ROOT/locked/immutable" 2>/dev/null || true

# 8. Deep nesting
D="$ROOT/deepchain"; for i in $(seq 1 80); do D="$D/l$i"; done; mkdir -p "$D"; printf 'x' > "$D/leaf"

echo "$ROOT"
