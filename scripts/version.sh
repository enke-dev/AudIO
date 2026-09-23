#!/usr/bin/env bash
# Next semantic version from Conventional Commits (Angular style) since the last v* tag.
#   scripts/version.sh [NOTES_FILE]
# Prints the next version (e.g. 0.3.1) – nothing if there are no new commits – and writes
# markdown release notes to NOTES_FILE if given. The first release is always 0.0.1.
#   type!: … / BREAKING CHANGE  → major    feat: … → minor    anything else → patch
# Plain bash 3.2 (macOS default) + git, no other dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

notes_file="${1:-}"
last_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
range="${last_tag:+$last_tag..}HEAD"

# One record per commit: hash <US> subject <US> body <RS>
log="$(git log --no-merges --format='%h%x1f%s%x1f%b%x1e' "$range")"
[ -n "$log" ] || exit 0

bump=patch
breaking="" features="" fixes="" other=""
pattern='^([a-z]+)(\([^)]*\))?(!)?: (.+)$'

while IFS=$'\x1f' read -r -d $'\x1e' hash subject body; do
    hash="${hash//$'\n'/}"
    if [[ $subject =~ $pattern ]]; then
        type="${BASH_REMATCH[1]}" scope="${BASH_REMATCH[2]}" bang="${BASH_REMATCH[3]}" text="${BASH_REMATCH[4]}"
    else
        type="" scope="" bang="" text="$subject"
    fi
    scope="${scope:+**${scope:1:${#scope}-2}:** }"
    line="- $scope$text ($hash)"$'\n'

    if [ -n "$bang" ] || [[ $body == *"BREAKING CHANGE"* ]]; then
        bump=major
        breaking+="$line"
    elif [ "$type" = feat ]; then
        [ "$bump" = major ] || bump=minor
        features+="$line"
    elif [ "$type" = fix ]; then
        fixes+="$line"
    else
        other+="$line"
    fi
done <<< "$log"

if [ -z "$last_tag" ]; then
    version="0.0.1"
else
    IFS=. read -r major minor patch <<< "${last_tag#v}"
    case "$bump" in
        major) version="$((major + 1)).0.0" ;;
        minor) version="$major.$((minor + 1)).0" ;;
        *) version="$major.$minor.$((patch + 1))" ;;
    esac
fi

if [ -n "$notes_file" ]; then
    mkdir -p "$(dirname "$notes_file")"
    {
        [ -z "$breaking" ] || printf '## ⚠️ Breaking changes\n\n%s\n' "$breaking"
        [ -z "$features" ] || printf '## Features\n\n%s\n' "$features"
        [ -z "$fixes" ] || printf '## Bug fixes\n\n%s\n' "$fixes"
        [ -z "$other" ] || printf '## Other changes\n\n%s\n' "$other"
    } > "$notes_file"
fi

echo "$version"
