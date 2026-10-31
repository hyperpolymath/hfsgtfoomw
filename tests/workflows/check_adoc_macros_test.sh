#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Controls for scripts/check-adoc-macros.sh.
#
# Every case that must fail is a PLANTED positive. A gate that has only ever
# returned 0 is indistinguishable from a gate wired to nothing - this estate has
# shipped that bug twice (a check written but never wired, and a check that
# shelled out to a tool whose failure level defaulted to FATAL). So: each defect
# class is staged, asserted to fail with the defect named at file:line, then
# removed and asserted to pass.
#
# The exemptions matter just as much: a broken macro shown inside a listing block
# or behind a comment is a lesson, not a defect, and verbatim third-party text
# must be exemptable line by line. Those cases are staged too, because a gate
# with no false-positive story gets switched off the first time it is wrong.
set -euo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-adoc-macros.sh"
[ -f "$CHECKER" ] || { echo "FAIL: checker not found at $CHECKER" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
REPO="$FIXTURE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

OUT=""
RC=0
run() {
    set +e
    OUT="$(bash "$CHECKER" "$@" 2>&1)"
    RC=$?
    set -e
}

clear_subjects() {
    find "$REPO" -maxdepth 1 -type f \( -name '*.adoc' -o -name '*.md' -o -name '*.allow' \) -delete
    git -C "$REPO" rm -q --cached -r . >/dev/null 2>&1 || true
}

stage() {           # stage NAME CONTENT
    printf '%s\n' "$2" > "$REPO/$1"
    git -C "$REPO" add "$1"
}

expect_pass() {     # expect_pass DESCRIPTION [ARGS...]
    local desc="$1"; shift
    run "$@"
    if [ "$RC" -ne 0 ]; then
        echo "FAIL: $desc — expected exit 0, got $RC" >&2
        printf '%s\n' "$OUT" >&2
        exit 1
    fi
    printf '%s' "$OUT" | grep -q '^PASS:' || {
        echo "FAIL: $desc — exit 0 but no PASS line" >&2
        printf '%s\n' "$OUT" >&2
        exit 1
    }
}

expect_fail() {     # expect_fail DESCRIPTION NEEDLE [ARGS...]
    local desc="$1" needle="$2"; shift 2
    run "$@"
    if [ "$RC" -ne 1 ]; then
        echo "FAIL: $desc — expected exit 1, got $RC" >&2
        printf '%s\n' "$OUT" >&2
        exit 1
    fi
    printf '%s' "$OUT" | grep -qF "$needle" || {
        echo "FAIL: $desc — output did not name '$needle'" >&2
        printf '%s\n' "$OUT" >&2
        exit 1
    }
}

# ── 1. The clean case must pass, or every failure below proves nothing ────────
clear_subjects
stage clean.adoc '= A real document

image:https://img.shields.io/badge/Code-MPL--2.0-blue.svg[Code licence: MPL-2.0,link="https://opensource.org/licenses/MPL-2.0"]

See link:https://example.org[the example] or link:mailto:a@example.org[a@example.org].

[source,bash]
----
image:not(this is fine, it is not a macro)
----'
expect_pass "valid badge, link and mailto are accepted" "$REPO"

# ── 2. The defect this gate was written for: an EMPTY image target ───────────
# Parses cleanly; Asciidoctor renders the whole line as literal text.
clear_subjects
stage broken-image.adoc '= A document whose badge lost its target

image:[Code licence: MPL-2.0,link="https://opensource.org/licenses/MPL-2.0"]'
expect_fail "empty image target is rejected" "broken-image.adoc:3" "$REPO"
clear_subjects
stage broken-image.adoc '= Same defect, block form

image::[alt text]'
expect_fail "empty block image target is rejected" "empty-image-target" "$REPO"

# ── 3. Markdown links: valid Markdown, literal punctuation in AsciiDoc ───────
clear_subjects
stage broken-md.adoc '= A Markdown document wearing an .adoc extension

Please read the [contributing guide](https://example.org/contributing).'
expect_fail "Markdown link is rejected" "markdown-link" "$REPO"
clear_subjects
stage broken-md.adoc '= Markdown image

![alt text](https://example.org/x.png)'
expect_fail "Markdown image is rejected (it carries a Markdown link)" "markdown-link" "$REPO"

# ── 4. Empty link and xref targets ──────────────────────────────────────────
clear_subjects
stage broken-link.adoc '= Shared

link:[the words]'
expect_fail "empty link target is rejected" "empty-link-target" "$REPO"
clear_subjects
stage broken-xref.adoc '= Shared

xref:[somewhere]'
expect_fail "empty xref target is rejected" "empty-link-target" "$REPO"

# ── 5. Exemptions: a deliberate demonstration is not a defect ───────────────
clear_subjects
stage teaching.adoc '= How not to write a badge

----
image:[Code licence: MPL-2.0,link="https://opensource.org/licenses/MPL-2.0"]
----

.....
[text](https://example.org)
.....

////
[text](https://example.org)
////

// image:[broken] and [text](https://example.org) behind a line comment'
expect_pass "listing, literal, comment blocks and line comments are exempt" "$REPO"

# ── 6. Scope: this gate reads .adoc only ────────────────────────────────────
clear_subjects
stage notes.md 'Please read the [guide](https://example.org).'
expect_pass "Markdown in a .md file is out of scope" "$REPO"

# ── 7. The allowlist (third-party text this project must not edit) ──────────
clear_subjects
stage vendor.adoc '= Verbatim upstream text

image:[Code licence: MPL-2.0,link="https://opensource.org/licenses/MPL-2.0"]'
printf '%s\n' '# whole file' 'vendor.adoc' > "$REPO/whole.allow"
expect_pass "whole-file allowlist entry is honoured" --allow "$REPO/whole.allow" "$REPO"

printf '%s\n' '# single line' 'vendor.adoc:3' > "$REPO/line.allow"
expect_pass "single-line allowlist entry is honoured" --allow "$REPO/line.allow" "$REPO"

printf '%s\n' 'vendor.adoc:99' > "$REPO/wrong-line.allow"
expect_fail "a line exemption does not exempt the file" "vendor.adoc:3" --allow "$REPO/wrong-line.allow" "$REPO"

# ── 8. Fail closed on a bad invocation ─────────────────────────────────────
run "$FIXTURE/does-not-exist"
[ "$RC" -eq 2 ] || { echo "FAIL: missing repository path should exit 2, got $RC" >&2; exit 1; }
run --allow "$FIXTURE/no.allow" "$REPO"
[ "$RC" -eq 2 ] || { echo "FAIL: unreadable allowlist should exit 2, got $RC" >&2; exit 1; }
run --nonsense "$REPO"
[ "$RC" -eq 2 ] || { echo "FAIL: unknown option should exit 2, got $RC" >&2; exit 1; }

# ── 9. An empty subject list is a PASS, not a failure (stripped mint) ───────
clear_subjects
expect_pass "no tracked .adoc is a pass" "$REPO"

echo "PASS: check-adoc-macros controls (4 defect classes, 4 exemptions, allowlist, fail-closed)"
