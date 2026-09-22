#!/usr/bin/env bash
set -euo pipefail

git=${CHAIN_REPO_HOOK_GIT:-git}
name=$1
shift

# --git-path resolves through core.hooksPath and would point back here; --git-common-dir does not.
common_dir=$("$git" rev-parse --git-common-dir 2>/dev/null) || exit 0
hook="$common_dir/hooks/$name"

[ -x "$hook" ] || exit 0

exec "$hook" "$@"
