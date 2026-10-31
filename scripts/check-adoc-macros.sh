#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-adoc-macros.sh - the blind spot of the AsciiDoc render gate.
#
# scripts/check-adoc-renders.sh proves every tracked .adoc *parses*. Text that
# is not a macro at all parses perfectly, which is why these defects survived it:
#
#   * image:[alt,link="https://..."] - an EMPTY image target. Asciidoctor emits
#     the whole line as a literal paragraph, so a badge silently becomes source
#     code on the page. Found in README.adoc on main (PR #2 dropped the target).
#   * [text](https://...) - a Markdown link. AsciiDoc renders the brackets
#     literally, so the reader sees punctuation instead of a link. Found in
#     CODE_OF_CONDUCT.adoc, a Markdown document renamed to .adoc.
#
# Neither is a parse error, so neither is visible to a stderr comparison. This
# gate reads the shape of the macros instead.
#
# Usage: check-adoc-macros.sh [--allow FILE] [REPO_ROOT]
#
# The allowlist is for verbatim third-party text this project must not edit (the
# estate's "third-party untouchable" rule). One entry per line:
#   <path>            the whole file is exempt
#   <path>:<line>     only that line is exempt
#   # ...             comment; blank lines ignored
#
# Exit codes, matching its sibling check-adoc-renders.sh:
#   0  no findings
#   1  at least one finding (every finding is listed)
#   2  the check could not run (bad path, unreadable allowlist)
set -euo pipefail

ALLOW=""
REPO_ROOT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow)
            [ "$#" -ge 2 ] || { echo "ERROR: --allow requires a file argument" >&2; exit 2; }
            ALLOW="$2"; shift 2 ;;
        --allow=*)
            ALLOW="${1#--allow=}"; shift ;;
        -h|--help)
            sed -n '6,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)
            echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        *)
            [ -z "$REPO_ROOT" ] || { echo "ERROR: more than one repository path given" >&2; exit 2; }
            REPO_ROOT="$1"; shift ;;
    esac
done
REPO_ROOT="${REPO_ROOT:-.}"

[ -d "$REPO_ROOT" ] || { echo "ERROR: repository path does not exist: $REPO_ROOT" >&2; exit 2; }
if [ -n "$ALLOW" ] && [ ! -r "$ALLOW" ]; then
    echo "ERROR: allowlist is not readable: $ALLOW" >&2
    exit 2
fi

# Subject list read NUL-delimited so a path containing a space cannot split.
FILES=()
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
        FILES+=("$REPO_ROOT/$f")
    done < <(git -C "$REPO_ROOT" ls-files -z -- '*.adoc' 2>/dev/null || true)
else
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(find "$REPO_ROOT" -type f -name '*.adoc' \
        -not -path '*/.git/*' -not -path '*/node_modules/*' -print0 2>/dev/null || true)
fi

# An empty subject list is a PASS, not a failure: a stripped mint may
# legitimately carry no .adoc yet (same contract as check-adoc-renders.sh).
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "PASS: no tracked .adoc (nothing to check)"
    exit 0
fi

# Allowlist, split into whole-file exemptions and single-line exemptions.
ALLOW_FILES=()
ALLOW_LINES=()
if [ -n "$ALLOW" ]; then
    while IFS= read -r raw; do
        entry="${raw%%#*}"
        entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$entry" ] || continue
        case "$entry" in
            *:*) ALLOW_LINES+=("$entry") ;;
            *)   ALLOW_FILES+=("$entry") ;;
        esac
    done < "$ALLOW"
fi

is_allowed_file() {
    local rel="$1" e
    for e in ${ALLOW_FILES[@]+"${ALLOW_FILES[@]}"}; do
        if [ "$e" = "$rel" ]; then return 0; fi
    done
    return 1
}

is_allowed_line() {
    local key="$1" e
    for e in ${ALLOW_LINES[@]+"${ALLOW_LINES[@]}"}; do
        if [ "$e" = "$key" ]; then return 0; fi
    done
    return 1
}

FINDINGS=""
COUNT=0
FILES_HIT=0

# A delimited block is 4+ repetitions of one character: ---- listing, ....
# literal, ++++ passthrough, //// comment, ==== example, **** sidebar, ____
# quote. Content inside one is literal, so a document may legitimately *show* a
# broken macro there - that is a lesson, not a defect.
BLOCK_DELIM_RE='^(-{4,}|\.{4,}|\+{4,}|/{4,}|={4,}|\*{4,}|_{4,})$'

for f in "${FILES[@]}"; do
    rel="${f#"$REPO_ROOT"/}"
    if is_allowed_file "$rel"; then continue; fi

    hit=0
    lineno=0
    BLOCK=""
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))

        if [[ "$line" =~ $BLOCK_DELIM_RE ]]; then
            if [ -z "$BLOCK" ]; then
                BLOCK="$line"
            else
                BLOCK=""
            fi
            continue
        fi

        if [ -n "$BLOCK" ]; then continue; fi

        # A line comment renders nothing, so a defect inside one is not a defect.
        if [[ "$line" =~ ^[[:space:]]*// ]]; then continue; fi

        if is_allowed_line "$rel:$lineno"; then continue; fi

        finding=""
        if [[ "$line" =~ image:\[ || "$line" =~ image::\[ ]]; then
            finding='empty-image-target: "image:[" has no target, so the line is literal text; use image:URL[alt]'
        elif [[ "$line" =~ link:\[ || "$line" =~ link::\[ || "$line" =~ xref:\[ ]]; then
            finding='empty-link-target: "link:[text]" has no target, so the line is literal text; use link:URL[text]'
        elif [[ "$line" =~ \]\( ]]; then
            finding='markdown-link: "[text](url)" is Markdown and renders literally; use link:URL[text]'
        fi

        if [ -n "$finding" ]; then
            COUNT=$((COUNT + 1))
            hit=1
            line_trimmed="$(printf '%s' "$line" | cut -c1-100)"
            FINDINGS="${FINDINGS}  ${rel}:${lineno}: ${finding}"$'\n'
            FINDINGS="${FINDINGS}      ${line_trimmed}"$'\n'
        fi
    done < "$f"

    if [ "$hit" -eq 1 ]; then FILES_HIT=$((FILES_HIT + 1)); fi
done

if [ "$COUNT" -eq 0 ]; then
    echo "PASS: ${#FILES[@]} tracked .adoc file(s) carry no broken macros or Markdown links"
    exit 0
fi

echo "FAIL: ${COUNT} finding(s) in ${FILES_HIT} of ${#FILES[@]} tracked .adoc file(s):" >&2
printf '%s' "$FINDINGS" >&2
echo >&2
echo "These lines parse cleanly, which is why check-adoc-renders.sh is blind to them." >&2
echo "Repair them:" >&2
echo '  * a badge:     image:https://img.shields.io/badge/NAME-VALUE-COLOUR[Alt text,link="URL"]' >&2
echo '  * a hyperlink: link:https://example.org[the words to show]' >&2
echo '  * an email:    link:mailto:someone@example.org[someone@example.org]' >&2
echo "  * to SHOW a broken form deliberately, put it in a ---- listing block or" >&2
echo "    behind a // comment; verbatim third-party text goes in the allowlist:" >&2
echo "    scripts/check-adoc-macros.sh --allow .adoc-macros-allow ." >&2
exit 1
