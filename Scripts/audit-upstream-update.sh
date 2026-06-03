#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE=""
HEAD_REV="HEAD"
REPORT=".build/upstream-update-audit.md"
RUN_PARITY=1
UPDATE_BASELINE=0
PARITY_STRICT=1
PARITY_FILTER=""
FETCH_REMOTE=""

usage() {
    cat <<'USAGE'
Usage: Scripts/audit-upstream-update.sh [options]

Audits a local upstream update for the Swift NuValidator port. The script
compares two Git revisions, classifies changed upstream source materials,
runs the Swift parity harness, and writes a Markdown report.

Options:
  --base <rev>             Revision before the upstream update.
                           Default: HEAD~1 if it exists, otherwise HEAD.
  --head <rev>             Revision after the upstream update. Default: HEAD.
  --report <path>          Markdown report path. Default: .build/upstream-update-audit.md
  --filter <text>          Pass a parity filter to vnu-parity.
  --update-baseline        Refresh resources/NuValidator/parity-baseline.json.
  --no-parity              Skip parity execution.
  --no-strict              Do not use vnu-parity --strict.
  --fetch <remote>         Fetch a remote before auditing. Example: --fetch upstream
  --help                   Show this help.

Typical workflow:
  git remote add upstream https://github.com/validator/validator.git   # once
  git fetch upstream
  git merge upstream/main                                             # or cherry-pick
  Scripts/audit-upstream-update.sh --base <pre-merge-rev> --head HEAD
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)
            BASE="${2:?missing value for --base}"
            shift 2
            ;;
        --head)
            HEAD_REV="${2:?missing value for --head}"
            shift 2
            ;;
        --report)
            REPORT="${2:?missing value for --report}"
            shift 2
            ;;
        --filter)
            PARITY_FILTER="${2:?missing value for --filter}"
            shift 2
            ;;
        --update-baseline)
            UPDATE_BASELINE=1
            shift
            ;;
        --no-parity)
            RUN_PARITY=0
            shift
            ;;
        --no-strict)
            PARITY_STRICT=0
            shift
            ;;
        --fetch)
            FETCH_REMOTE="${2:?missing value for --fetch}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "audit-upstream-update: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -n "$FETCH_REMOTE" ]]; then
    git fetch "$FETCH_REMOTE"
fi

if [[ -z "$BASE" ]]; then
    if git rev-parse --verify -q "${HEAD_REV}~1" >/dev/null; then
        BASE="${HEAD_REV}~1"
    else
        BASE="$HEAD_REV"
    fi
fi

git rev-parse --verify "$BASE" >/dev/null
git rev-parse --verify "$HEAD_REV" >/dev/null

mkdir -p "$(dirname "$REPORT")"

CHANGES_FILE="$(mktemp "${TMPDIR:-/tmp}/vnu-upstream-changes.XXXXXX")"
PARITY_FILE="$(mktemp "${TMPDIR:-/tmp}/vnu-upstream-parity.XXXXXX")"
trap 'rm -f "$CHANGES_FILE" "$PARITY_FILE"' EXIT

git diff --name-status "$BASE" "$HEAD_REV" > "$CHANGES_FILE"

changed_matching() {
    local pattern="$1"
    awk '{ print $2 }' "$CHANGES_FILE" | grep -E "$pattern" || true
}

count_matching() {
    local pattern="$1"
    changed_matching "$pattern" | wc -l | tr -d ' '
}

write_list() {
    local title="$1"
    local pattern="$2"
    local limit="${3:-80}"
    local files
    files="$(changed_matching "$pattern" | head -n "$limit")"
    if [[ -z "$files" ]]; then
        return
    fi
    {
        echo
        echo "### $title"
        echo
        while IFS= read -r file; do
            [[ -n "$file" ]] && echo "- \`$file\`"
        done <<< "$files"
        local total
        total="$(count_matching "$pattern")"
        if [[ "$total" -gt "$limit" ]]; then
            echo "- ... $((total - limit)) more"
        fi
    } >> "$REPORT"
}

SCHEMA_PATTERN='^(schema/|resources/).*\.(rnc|rng|sch)$|^resources/presets\.txt$'
LOCAL_ENTITY_PATTERN='^src/nu/validator/localentities/'
TEST_PATTERN='^tests/|^e2e/|^resources/NuValidator/parity-baseline\.json$'
MESSAGE_PATTERN='^tests/messages\.json$'
JAVA_CHECKER_PATTERN='^src/nu/validator/(checker|validation|htmlparser|xml|servlet|messages|io|client)/.*\.java$'
DOC_PATTERN='^(docs/|README\.md|CONTRIBUTING\.md|IMPORTANT\.md)'
SWIFT_PATTERN='^(Sources/|NuValidator\.xcodeproj|NuValidator\.xctestplan|Scripts/|resources/NuValidator/)'

SCHEMA_COUNT="$(count_matching "$SCHEMA_PATTERN")"
LOCAL_ENTITY_COUNT="$(count_matching "$LOCAL_ENTITY_PATTERN")"
TEST_COUNT="$(count_matching "$TEST_PATTERN")"
MESSAGE_COUNT="$(count_matching "$MESSAGE_PATTERN")"
JAVA_CHECKER_COUNT="$(count_matching "$JAVA_CHECKER_PATTERN")"
DOC_COUNT="$(count_matching "$DOC_PATTERN")"
SWIFT_COUNT="$(count_matching "$SWIFT_PATTERN")"
TOTAL_COUNT="$(wc -l < "$CHANGES_FILE" | tr -d ' ')"
DIRTY_STATUS="$(git status --short)"

PARITY_STATUS=0
if [[ "$RUN_PARITY" -eq 1 ]]; then
    PARITY_DERIVED_DATA=".build/parity-xcode"
    xcodebuild -quiet \
        -project NuValidator.xcodeproj \
        -scheme VNUParity \
        -configuration Debug \
        -derivedDataPath "$PARITY_DERIVED_DATA" \
        build
    PARITY_EXECUTABLE="$PARITY_DERIVED_DATA/Build/Products/Debug/vnu-parity"
    PARITY_ARGS=(--allow-regression)
    if [[ "$PARITY_STRICT" -eq 1 ]]; then
        PARITY_ARGS+=(--strict)
    fi
    if [[ -n "$PARITY_FILTER" ]]; then
        PARITY_ARGS+=(--filter "$PARITY_FILTER")
    fi
    if [[ "$UPDATE_BASELINE" -eq 1 ]]; then
        PARITY_ARGS+=(--update-baseline)
    fi
    set +e
    "$PARITY_EXECUTABLE" "${PARITY_ARGS[@]}" > "$PARITY_FILE" 2>&1
    PARITY_STATUS=$?
    set -e
else
    printf 'Parity skipped by --no-parity.\n' > "$PARITY_FILE"
fi

cat > "$REPORT" <<EOF
# Swift NuValidator Upstream Update Audit

- Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
- Repository: \`$ROOT\`
- Base: \`$(git rev-parse --short "$BASE")\` (\`$BASE\`)
- Head: \`$(git rev-parse --short "$HEAD_REV")\` (\`$HEAD_REV\`)
- Changed files: $TOTAL_COUNT
- Working tree dirty: $([[ -n "$DIRTY_STATUS" ]] && echo yes || echo no)

## Change Summary

| Area | Count | Why it matters |
| --- | ---: | --- |
| Relax NG / Schematron / schema presets | $SCHEMA_COUNT | Source material for element, attribute, namespace, SVG, MathML, and some assertion rules. |
| Local entity cache | $LOCAL_ENTITY_COUNT | Packaged copies of external schemas/entities used by upstream schema resolution. |
| Tests and parity expectations | $TEST_COUNT | New or changed fixtures define the observable behavior the Swift port must match. |
| \`tests/messages.json\` | $MESSAGE_COUNT | Primary parity expectation map. Changes usually need immediate parity review. |
| Java checker/pipeline code | $JAVA_CHECKER_COUNT | Algorithmic behavior that usually cannot be refreshed as data. |
| Swift port / app files | $SWIFT_COUNT | Local implementation or packaging changes in this fork. |
| Documentation | $DOC_COUNT | API semantics or release-process notes may have changed. |

## Parity

- Command: \`${PARITY_EXECUTABLE:-vnu-parity} $(printf '%q ' "${PARITY_ARGS[@]:-}")\`
- Exit status: $PARITY_STATUS

\`\`\`text
$(cat "$PARITY_FILE")
\`\`\`

## Recommended Triage

1. If schemas changed, inspect schema diffs first and update generated Swift/resource tables when available. Until then, map schema changes to the nearest Swift vocabulary tables and content-model checks.
2. If \`tests/messages.json\` or fixtures changed, run focused parity filters for those paths before running the full corpus.
3. If Java checker code changed, inspect the changed classes and decide whether the change is algorithmic, message wording, or vocabulary data.
4. Refresh \`resources/NuValidator/parity-baseline.json\` only after the Swift implementation matches the intended new behavior.
5. Run full parity, Xcode tests, and \`Scripts/build-macos-app.sh\` before shipping a refreshed macOS app.
EOF

write_list "Schema And Preset Changes" "$SCHEMA_PATTERN"
write_list "Local Entity Cache Changes" "$LOCAL_ENTITY_PATTERN"
write_list "Parity Fixture And Test Changes" "$TEST_PATTERN"
write_list "Java Checker And Pipeline Changes" "$JAVA_CHECKER_PATTERN"
write_list "Swift Port Changes" "$SWIFT_PATTERN"
write_list "Documentation Changes" "$DOC_PATTERN"

cat >> "$REPORT" <<'EOF'

## Useful Follow-Up Commands

```sh
xcodebuild -project NuValidator.xcodeproj -scheme VNUParity -configuration Debug -derivedDataPath .build/parity-xcode build
.build/parity-xcode/Build/Products/Debug/vnu-parity --strict --allow-regression
.build/parity-xcode/Build/Products/Debug/vnu-parity --update-baseline --allow-regression
xcodebuild -project NuValidator.xcodeproj -scheme NuValidator -destination 'platform=macOS' test
Scripts/build-macos-app.sh
```

## Notes On Schema Data

Relax NG and Schematron files are upstream source material, not runtime tables
for the Swift port today. The intended maintenance path is to use these files
as inputs for generated, typed Swift resources where practical, while keeping
algorithmic checks in Swift code with parity tests around them.
EOF

echo "Wrote $REPORT"
if [[ "$PARITY_STATUS" -ne 0 ]]; then
    echo "Parity reported issues. See $REPORT." >&2
    exit "$PARITY_STATUS"
fi
