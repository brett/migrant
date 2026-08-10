#!/usr/bin/env bash
# Reformats Markdown files: prose wrap, table alignment, and ordered-list
# numbering (see .mdformat.toml for options). Code fences and `---` breaks
# are left untouched.
#
# Usage:
#   tools/mdformat.sh              # reformat every *.md file in the repo
#   tools/mdformat.sh <file...>    # reformat specific files
set -euo pipefail

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mapfile -t files < <(find "$repo_root" -iname "*.md" -not -path "$repo_root/.git/*")
fi

exec uvx --with mdformat-gfm --with mdformat-tables --with mdformat-simple-breaks \
  mdformat "${files[@]}"
