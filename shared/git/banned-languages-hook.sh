#!/usr/bin/env bash
# banned languages hook: reject files this repository does not want written at all.
set -euo pipefail

git=${BANNED_LANGUAGES_GIT:-git}
banned=('*.js' '*.cjs' '*.mjs' '*.py')

case $(printf '%s' "${BANNED_LANGUAGES:-}" | tr '[:upper:]' '[:lower:]') in
off | 0 | no | skip) exit 0 ;;
esac

if "$git" rev-parse --verify --quiet HEAD >/dev/null; then
    base=HEAD
else
    base=$("$git" hash-object -t tree /dev/null)
fi

mapfile -d '' -t files < <(
    "$git" diff --cached -z --name-only --diff-filter=ACR "$base" -- "${banned[@]}"
)

[ ${#files[@]} -eq 0 ] && exit 0

{
    printf '\nThis commit introduces files in a banned language:\n\n'
    printf '  %s\n' "${files[@]}"
    printf '\nUse Nix, Lua, shell or Perl instead, or unstage them.\n'
} >&2

exit 1
