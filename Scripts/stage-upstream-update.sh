#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REMOTE="upstream"
UPSTREAM_BRANCH="main"
BRANCH_NAME=""
WORKTREE=""
FETCH=1
RUN_AUDIT=1
AUDIT_ARGS=()

usage() {
    cat <<'USAGE'
Usage: Scripts/stage-upstream-update.sh [options]

Creates an isolated Git worktree for a W3C NuValidator upstream update, merges
the selected upstream ref into that worktree, and runs the Swift port audit.
The current checkout is left untouched.

Options:
  --remote <name>           Remote to fetch/merge. Default: upstream.
  --branch <name>           Remote branch to merge. Default: main.
  --branch-name <name>      Local branch name for the worktree.
                            Default: upstream-update/<UTC timestamp>.
  --worktree <path>         Worktree path.
                            Default: .build/upstream-worktrees/<branch-name>.
  --no-fetch                Do not fetch before creating the worktree.
  --no-audit                Create/merge the worktree but skip audit execution.
  --filter <text>           Pass a parity filter to the audit script.
  --no-strict               Do not use vnu-parity --strict in the audit.
  --help                    Show this help.

Typical use:
  git remote add upstream https://github.com/validator/validator.git   # once
  Scripts/stage-upstream-update.sh

If the merge conflicts, resolve and commit in the printed worktree, then run:
  Scripts/audit-upstream-update.sh --base <base-rev> --head HEAD
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)
            REMOTE="${2:?missing value for --remote}"
            shift 2
            ;;
        --branch)
            UPSTREAM_BRANCH="${2:?missing value for --branch}"
            shift 2
            ;;
        --branch-name)
            BRANCH_NAME="${2:?missing value for --branch-name}"
            shift 2
            ;;
        --worktree)
            WORKTREE="${2:?missing value for --worktree}"
            shift 2
            ;;
        --no-fetch)
            FETCH=0
            shift
            ;;
        --no-audit)
            RUN_AUDIT=0
            shift
            ;;
        --filter)
            AUDIT_ARGS+=(--filter "${2:?missing value for --filter}")
            shift 2
            ;;
        --no-strict)
            AUDIT_ARGS+=(--no-strict)
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "stage-upstream-update: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

cd "$ROOT"

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    cat >&2 <<EOF
stage-upstream-update: remote '$REMOTE' is not configured.

Add it with:
  git remote add $REMOTE https://github.com/validator/validator.git
EOF
    exit 2
fi

BASE="$(git rev-parse --verify HEAD)"
TIMESTAMP="$(date -u '+%Y%m%d-%H%M%S')"
if [[ -z "$BRANCH_NAME" ]]; then
    BRANCH_NAME="upstream-update/$TIMESTAMP"
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    echo "stage-upstream-update: branch '$BRANCH_NAME' already exists." >&2
    exit 2
fi

BRANCH_PATH_NAME="${BRANCH_NAME//\//-}"
if [[ -z "$WORKTREE" ]]; then
    WORKTREE="$ROOT/.build/upstream-worktrees/$BRANCH_PATH_NAME"
elif [[ "$WORKTREE" != /* ]]; then
    WORKTREE="$ROOT/$WORKTREE"
fi
if [[ -e "$WORKTREE" ]]; then
    echo "stage-upstream-update: worktree path already exists: $WORKTREE" >&2
    exit 2
fi

if [[ "$FETCH" -eq 1 ]]; then
    git fetch "$REMOTE" "$UPSTREAM_BRANCH"
fi

UPSTREAM_REF="$REMOTE/$UPSTREAM_BRANCH"
git rev-parse --verify "$UPSTREAM_REF^{commit}" >/dev/null

mkdir -p "$(dirname "$WORKTREE")"
git worktree add -b "$BRANCH_NAME" "$WORKTREE" "$BASE"

set +e
git -C "$WORKTREE" merge --no-edit "$UPSTREAM_REF"
MERGE_STATUS=$?
set -e

if [[ "$MERGE_STATUS" -ne 0 ]]; then
    cat <<EOF
Upstream merge stopped with conflicts.

Worktree: $WORKTREE
Branch:   $BRANCH_NAME
Base:     $BASE
Upstream: $UPSTREAM_REF

Resolve conflicts in the worktree, commit the merge, then run:
  cd "$WORKTREE"
  Scripts/audit-upstream-update.sh --base "$BASE" --head HEAD
EOF
    exit "$MERGE_STATUS"
fi

if [[ "$RUN_AUDIT" -eq 1 ]]; then
    git -C "$WORKTREE" status --short
    (
        cd "$WORKTREE"
        Scripts/audit-upstream-update.sh \
            --base "$BASE" \
            --head HEAD \
            --report ".build/upstream-update-audit.md" \
            "${AUDIT_ARGS[@]}"
    )
fi

cat <<EOF
Staged upstream update.

Worktree: $WORKTREE
Branch:   $BRANCH_NAME
Base:     $BASE
Upstream: $UPSTREAM_REF
Report:   $WORKTREE/.build/upstream-update-audit.md
EOF
