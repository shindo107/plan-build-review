#!/usr/bin/env bash
#
# generate-repo-map.sh — build a compact index of a repo's source files.
#
# Writes .claude/repo-map.md at the current git repo root with:
#   - SHA freshness header
#   - Per-directory sections
#   - Per-file leading comment + exported signatures
#
# Idempotent: same source state produces the same output.
# Deps: git, grep, awk, sed. No language toolchains required.
#
# Known limitation: `leading_comment` captures the file-leading comment only
# when the comment is the first non-shebang, non-blank token in the file. Files
# that start with imports or package declarations above their JSDoc/docstring
# will be summarized without that comment. The signature list is unaffected.
#
# Usage:
#   cd <repo-root>
#   bash /path/to/generate-repo-map.sh
#
# See references/repo-map.md for format + freshness policy.

set -euo pipefail

# Locate repo root — refuse to run outside a git repo.
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "generate-repo-map: not inside a git repository" >&2
  exit 1
fi

cd "$REPO_ROOT"

HEAD_SHA="$(git rev-parse HEAD)"
OUT_DIR=".claude"
OUT_FILE="$OUT_DIR/repo-map.md"

mkdir -p "$OUT_DIR"

# Source extensions we understand. Adding one here + a case branch below is the full cost of support.
# IMPORTANT: this list must stay in sync with the freshness-check extension list in
# references/repo-map.md and SKILL.md's Phase 3 preamble. Drift → silent stale maps.
EXTS=(ts tsx js jsx mjs cjs py go rs java rb)

# List tracked source files using git ls-files, filtered in-script. We filter with a single
# grep rather than passing pathspecs to `git ls-files` because pathspec-magic handling varies
# across git versions, causing silent incompleteness on older git.
list_sources() {
  local alternation
  alternation="$(IFS='|'; echo "${EXTS[*]}")"
  git ls-files 2>/dev/null | grep -E "\.(${alternation})\$" | LC_ALL=C sort
}

# Extract the file-leading comment/docstring (first contiguous comment block at top of file).
# Supports: // line comments, /* ... */, # line comments, """ / ''' python docstrings.
leading_comment() {
  local f="$1"
  awk '
    BEGIN { in_block=0; in_doc=0; captured=0 }
    NR==1 && /^#!/ { next }            # skip shebang
    /^[[:space:]]*$/ {
      if (captured==0 && NR<=3) next   # skip blank lines before comment
      else exit
    }
    /^[[:space:]]*\/\// {
      print; captured=1; next
    }
    /^[[:space:]]*\/\*/ {
      in_block=1; print; captured=1
      if (/\*\//) { in_block=0 }
      next
    }
    in_block==1 {
      print
      if (/\*\//) { in_block=0 }
      next
    }
    /^[[:space:]]*#/ {
      print; captured=1; next
    }
    /^[[:space:]]*"""/ || /^[[:space:]]*'"'"''"'"''"'"'/ {
      in_doc=1; print; captured=1
      # If the triple-quote opens and closes on same line, stop.
      if (gsub(/"""/,"&")>=2 || gsub(/'"'"''"'"''"'"'/,"&")>=2) { in_doc=0; exit }
      next
    }
    in_doc==1 {
      print
      if (/"""/ || /'"'"''"'"''"'"'/) { in_doc=0; exit }
      next
    }
    { exit }
  ' "$f" 2>/dev/null | head -c 800
}

# Extract exported signatures for a given language. Output format: "<line>\t<signature>"
# Heuristics are deliberately shallow — they favor false negatives over false positives.
extract_signatures() {
  local f="$1"
  case "$f" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
      grep -nE '^[[:space:]]*export[[:space:]]+(async[[:space:]]+)?(function|class|interface|type|const|let|var|enum|default)[[:space:]]' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):[[:space:]]*/\1\t/' \
        | head -n 40
      ;;
    *.py)
      grep -nE '^(def|class|async def)[[:space:]]+[A-Za-z_]' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):[[:space:]]*/\1\t/' \
        | head -n 40
      ;;
    *.go)
      grep -nE '^func[[:space:]]+(\([^)]*\)[[:space:]]+)?[A-Z][A-Za-z0-9_]*\(' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):[[:space:]]*/\1\t/' \
        | head -n 40
      grep -nE '^type[[:space:]]+[A-Z][A-Za-z0-9_]*[[:space:]]' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):[[:space:]]*/\1\t/' \
        | head -n 20
      ;;
    *.rs)
      grep -nE '^pub[[:space:]]+(fn|struct|enum|trait|type|const|static|mod)[[:space:]]' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):[[:space:]]*/\1\t/' \
        | head -n 40
      ;;
    *.java)
      grep -nE '^[[:space:]]*(public|protected)[[:space:]]+(static[[:space:]]+)?(final[[:space:]]+)?(class|interface|enum|[A-Za-z_<>,[:space:]]+[[:space:]]+[a-zA-Z_][A-Za-z0-9_]*\()' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):[[:space:]]*/\1\t/' \
        | head -n 40
      ;;
    *.rb)
      grep -nE '^[[:space:]]*(def|class|module)[[:space:]]+[A-Za-z_]' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):[[:space:]]*/\1\t/' \
        | head -n 40
      ;;
  esac
}

# Generate the map.
{
  printf '<!-- repo-map head: %s -->\n\n' "$HEAD_SHA"
  printf '# Repo map\n\n'
  printf 'Generated at HEAD `%s`. Regenerate with `scripts/generate-repo-map.sh` after source changes.\n\n' "$HEAD_SHA"

  CURRENT_DIR=""
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && continue

    # Top-level directory for grouping. Files at repo root go under "(root)".
    dir="${file%%/*}"
    if [[ "$dir" == "$file" ]]; then
      dir="(root)"
    fi

    if [[ "$dir" != "$CURRENT_DIR" ]]; then
      printf '## %s/\n\n' "$dir"
      CURRENT_DIR="$dir"
    fi

    printf '### %s\n\n' "$file"

    # Leading comment (trimmed).
    comment="$(leading_comment "$file" | sed -E 's/^[[:space:]]*(\/\/|#|\*|"""|'"'"''"'"''"'"')[[:space:]]?//; s/\*\/[[:space:]]*$//' | awk 'NF>0' | head -n 4)"
    if [[ -n "$comment" ]]; then
      printf '%s\n\n' "$comment"
    fi

    # Signatures.
    sig_count=0
    while IFS=$'\t' read -r lineno sig; do
      [[ -z "$lineno" ]] && continue
      # Trim trailing body like ` { ... ` to keep the signature compact.
      sig_trimmed="$(printf '%s' "$sig" | sed -E 's/\{.*$//; s/[[:space:]]+$//')"
      printf -- '- `%s` — L%s\n' "$sig_trimmed" "$lineno"
      sig_count=$((sig_count + 1))
    done < <(extract_signatures "$file")

    if [[ $sig_count -eq 0 ]]; then
      printf -- '- _(no exported signatures detected)_\n'
    fi

    printf '\n'
  done < <(list_sources)
} > "$OUT_FILE"

echo "wrote $OUT_FILE (HEAD $HEAD_SHA)"
