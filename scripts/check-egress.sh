#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-egress.sh — AC-9's "no network egress" and the submission profile's
# `[network] egress = "none"`, made checkable rather than asserted.
#
# The claim these files make is unusually strong for a browser artifact: the
# script talks to nothing. Two places can break it, and both are static:
#
#   * the userscript header — `@connect`, `@resource`, `@require`, and the
#     `GM_xmlhttpRequest` / `GM_download` grants that exist to cross origins;
#   * the body — `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`,
#     `sendBeacon`, `import()` of a URL, and dynamic script/img beacons.
#
# This is a REGEX gate, not a parser, and it says so rather than pretending: it
# strips comments before scanning, so a commented-out `fetch` is not a finding,
# but a string literal containing the word is. That is the fail-closed direction
# — a false positive costs an argument, a false negative costs the claim. The
# behavioural proof is the run sheet's "network panel must show no request"
# (docs/acceptance/RUN-SHEET.adoc, AC-9); this is the cheap gate that runs first.
#
# Usage:
#   check-egress.sh [--quiet] FILE...
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = every file is egress-free by this gate
#   1 = at least one finding (the file and line are named)
#   2 = setup error: no file given, or a file does not exist
set -euo pipefail

QUIET=0
if [ "${1:-}" = "--quiet" ]; then QUIET=1; shift; fi

if [ "$#" -eq 0 ]; then
    echo "check-egress: no files given (usage: check-egress.sh [--quiet] FILE...)" >&2
    exit 2
fi

for f in "$@"; do
    [ -f "$f" ] || { echo "check-egress: no such file: $f" >&2; exit 2; }
done

findings=0
checked=0

# strip_comments — drop // line comments and /* */ blocks, keeping line numbers
# stable so a finding can be pointed at. Not a tokenizer: it does not understand
# strings, so a URL inside a comment is dropped (correct) and a URL inside a
# string is kept (also correct, if noisy).
strip_comments() {
    awk '
        { line[NR] = $0 }
        END {
            inblock = 0
            for (i = 1; i <= NR; i++) {
                s = line[i]; out = ""
                j = 1
                while (j <= length(s)) {
                    two = substr(s, j, 2)
                    if (inblock) {
                        if (two == "*/") { inblock = 0; j += 2 } else { j += 1 }
                    } else if (two == "/*") {
                        inblock = 1; j += 2
                    } else if (two == "//") {
                        break
                    } else {
                        out = out substr(s, j, 1); j += 1
                    }
                }
                print i "\t" out
            }
        }
    ' "$1"
}

# Header directives. A directive only counts INSIDE the metadata block
# (`// ==UserScript==` … `// ==/UserScript==`); outside it, `// @connect` is a
# comment about a directive — the self-test's control case — and firing on it
# would make the gate unarguable in exactly the conversation it exists for.
header_findings() {
    local f="$1"
    awk '
        /^[[:space:]]*\/\/[[:space:]]*==UserScript==/ { inblock = 1; next }
        /^[[:space:]]*\/\/[[:space:]]*==\/UserScript==/ { inblock = 0; next }
        inblock && /^[[:space:]]*\/\/[[:space:]]*@(connect|resource|require)([[:space:]]|$)/ { print NR "\t" $0 }
        inblock && /^[[:space:]]*\/\/[[:space:]]*@grant[[:space:]]+(GM_xmlhttpRequest|GM_download)([[:space:]]|$)/ { print NR "\t" $0 }
    ' "$f"
}

# Body primitives, on comment-stripped text.
body_findings() {
    local f="$1"
    strip_comments "$f" | grep -E '(fetch[[:space:]]*\(|new[[:space:]]+XMLHttpRequest|XMLHttpRequest[[:space:]]*\(|new[[:space:]]+WebSocket|new[[:space:]]+EventSource|sendBeacon[[:space:]]*\(|import[[:space:]]*\([[:space:]]*["'"'"'`]https?:|["'"'"']https?://[^"'"'"']*["'"'"'][[:space:]]*\)[[:space:]]*\.[[:space:]]*(src|href))' || true
}

for f in "$@"; do
    checked=$((checked + 1))
    hits="$(printf '%s\n%s\n' "$(header_findings "$f")" "$(body_findings "$f")" | grep -v '^$' || true)"
    if [ -n "$hits" ]; then
        findings=$((findings + $(printf '%s\n' "$hits" | wc -l)))
        echo "NOT EGRESS-FREE $f" >&2
        printf '%s\n' "$hits" | while IFS= read -r hit; do
            printf '  %s\n' "$hit" >&2
        done
    fi
done

if [ "$findings" -gt 0 ]; then
    echo "check-egress: $findings finding(s) in $checked file(s); egress is not none" >&2
    echo "check-egress: the submission profile says [network] egress=\"none\"; either the" >&2
    echo "               declaration or the code has to change" >&2
    exit 1
fi

[ "$QUIET" -eq 1 ] || echo "check-egress: $checked file(s) checked, no network surface found"
exit 0
