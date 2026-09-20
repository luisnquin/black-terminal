#!/usr/bin/env bash
# deadnix hook: lint the .nix content staged for this commit, not the worktree.
set -euo pipefail

git=${DEADNIX_HOOK_GIT:-git}
deadnix=${DEADNIX_HOOK_DEADNIX:-deadnix}

command -v "$deadnix" >/dev/null 2>&1 || exit 0

if "$git" rev-parse --verify --quiet HEAD >/dev/null; then
    base=HEAD
else
    base=$("$git" hash-object -t tree /dev/null)
fi

mapfile -d '' -t files < <(
    "$git" diff --cached -z --name-only --diff-filter=ACMR "$base" -- '*.nix'
)

[ ${#files[@]} -eq 0 ] && exit 0

staged=$(mktemp -d)
trap 'rm -rf "$staged"' EXIT

for file in "${files[@]}"; do
    mkdir -p "$staged/$(dirname "$file")"
    "$git" show ":$file" >"$staged/$file"
done

cd "$staged"

if "$deadnix" --hidden --fail -- "${files[@]}"; then
    exit 0
fi

cat >&2 <<EOF

Dead code in the staged content above. Fix it, or drop it from this commit.

  deadnix --edit <file>   remove it in the worktree, then restage
EOF

exit 1
