#!/bin/bash

set -euo pipefail

if (( $# > 1 )); then
    echo "Usage: $0 [path-within-worktree]" >&2
    exit 2
fi

start_path=${1:-$PWD}
if ! common_dir=$(git -C "$start_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    echo "Handoff resolution failed: $start_path is not inside a Git worktree" >&2
    exit 1
fi

if [[ $(basename "$common_dir") != '.git' || ! -d "$common_dir" ]]; then
    echo "Handoff resolution failed: the repository has no primary checkout metadata" >&2
    exit 1
fi

main_checkout=$(cd "$(dirname "$common_dir")" && pwd -P)
found_main=false
while IFS= read -r -d '' field; do
    [[ "$field" == worktree\ * ]] || continue
    worktree_path=${field#worktree }
    if [[ -d "$worktree_path" ]]; then
        worktree_path=$(cd "$worktree_path" && pwd -P)
    fi

    if [[ "$worktree_path" == "$main_checkout" ]]; then
        found_main=true
    elif [[ -e "$worktree_path/.claude/handoff.md" || -L "$worktree_path/.claude/handoff.md" ]]; then
        echo "Handoff resolution failed: linked-worktree handoff exists at $worktree_path/.claude/handoff.md" >&2
        exit 1
    fi
done < <(git -C "$start_path" worktree list --porcelain -z)

if [[ "$found_main" != true ]]; then
    echo "Handoff resolution failed: Git metadata does not list the primary checkout" >&2
    exit 1
fi

printf '%s/.claude/handoff.md\n' "$main_checkout"
