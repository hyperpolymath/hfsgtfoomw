#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check_egress_test.sh — Silence and Firing controls for scripts/check-egress.sh.
#
# Silence: the surface the product is allowed to have must pass. Firing: one
# fixture per finding family, so a clean run means the gate looked. Each firing
# case is paired with a control that proves the gate is not firing on the word
# alone (a comment that mentions fetch, a header that mentions @connect in prose).
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
gate="$repo/scripts/check-egress.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  PASS: %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL: %s\n' "$1" >&2; }
run()  { local f="$1"; set +e; out="$(bash "$gate" --quiet "$f" 2>&1)"; rc=$?; set -e; }

expect() { # expect RC LABEL FILE
    local want="$1" label="$2" file="$3" rc out
    set +e
    out="$(bash "$gate" --quiet "$file" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq "$want" ]; then ok "$label (exit $rc)"
    else bad "$label — wanted exit $want, got $rc: $out"; fi
}

# ── Silence: the shape the product is allowed to have ────────────────────────
cat > "$work/clean.user.js" <<'JS'
// ==UserScript==
// @name        hfsgtfoomw
// @namespace   https://github.com/hyperpolymath/hfsgtfoomw
// @version     0.1.0
// @description Keeps a floating window out of the way
// @license     MPL-2.0
// @match       *://*/*
// @noframes
// @grant       GM_getValue
// @grant       GM_setValue
// @grant       GM_registerMenuCommand
// @grant       GM_addStyle
// ==/UserScript==
"use strict";
const FLOAT = "hfsgtfoomw-float";
function remember(key, value) { GM_setValue(key, value); }
function recall(key) { return GM_getValue(key, null); }
GM_registerMenuCommand("Toggle the float", () => {
  const el = document.getElementById(FLOAT);
  if (el) { el.remove(); remember("visible", false); } else { remember("visible", true); }
});
GM_addStyle("#" + FLOAT + "{position:fixed;right:16px;bottom:16px}");
JS
expect 0 "silence: grants, styles and storage only" "$work/clean.user.js"

# ── Firing: one per finding family ──────────────────────────────────────────
mk() { printf '%s\n' "$2" > "$work/$1"; }

mk "connect.user.js" '// ==UserScript==
// @name x
// @connect api.example.com
// ==/UserScript=='
expect 1 "firing: @connect" "$work/connect.user.js"

mk "resource.user.js" '// ==UserScript==
// @resource css https://example.com/x.css
// ==/UserScript=='
expect 1 "firing: @resource" "$work/resource.user.js"

mk "require.user.js" '// ==UserScript==
// @require https://example.com/lib.js
// ==/UserScript=='
expect 1 "firing: @require" "$work/require.user.js"

mk "grant.user.js" '// ==UserScript==
// @grant GM_xmlhttpRequest
// ==/UserScript=='
expect 1 "firing: GM_xmlhttpRequest grant" "$work/grant.user.js"

mk "fetch.user.js" 'const r = await fetch("/api/state");'
expect 1 "firing: fetch" "$work/fetch.user.js"

mk "xhr.user.js" 'const x = new XMLHttpRequest(); x.open("GET", "/x");'
expect 1 "firing: XMLHttpRequest" "$work/xhr.user.js"

mk "ws.user.js" 'const s = new WebSocket("wss://example.com/feed");'
expect 1 "firing: WebSocket" "$work/ws.user.js"

mk "beacon.user.js" 'navigator.sendBeacon("/log", "x");'
expect 1 "firing: sendBeacon" "$work/beacon.user.js"

mk "es.user.js" 'const e = new EventSource("/stream");'
expect 1 "firing: EventSource" "$work/es.user.js"

mk "dynamic-import.user.js" 'const m = await import("https://example.com/mod.js");'
expect 1 "firing: dynamic import of a URL" "$work/dynamic-import.user.js"

# ── The control that keeps the gate honest ──────────────────────────────────
# A comment that says fetch, and a header comment that explains @connect, must
# both be silent: the gate strips comments, so it is firing on code, not words.
mk "commented.user.js" '// ==UserScript==
// @name x
// @license MPL-2.0
// ==/UserScript==
// Never call fetch() here: this script has no network surface.
// @connect is deliberately absent (see docs/TECHNICAL-CONFORMANCE.adoc, AC-9).
/*
   fetch, XMLHttpRequest and WebSocket are all forbidden by AC-9.
*/
const label = "no network";'
expect 0 "control: the words in comments are not findings" "$work/commented.user.js"

# ── Setup contract: exit 2 is never a pass ──────────────────────────────────
set +e
bash "$gate" --quiet >/dev/null 2>&1; rc_nofiles=$?
bash "$gate" --quiet "$work/nope.user.js" >/dev/null 2>&1; rc_missing=$?
set -e
[ "$rc_nofiles" -eq 2 ] && ok "setup: no files exits 2" || bad "setup: no files exited $rc_nofiles, want 2"
[ "$rc_missing" -eq 2 ] && ok "setup: missing file exits 2" || bad "setup: missing file exited $rc_missing, want 2"

echo
if [ "$fail" -gt 0 ]; then
    echo "check-egress self-test: $pass passed, $fail failed" >&2
    exit 1
fi
echo "check-egress self-test: $pass passed, 0 failed"
