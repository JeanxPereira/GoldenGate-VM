#!/usr/bin/env bash
# GPU progress scoreboard from a reims-vgpu host log (runs in WSL).
#
#   tools/gpu-score.sh [log]              # default /tmp/reims-vgpu-fail.log
#   tools/gpu-score.sh <baseline> <new>   # two runs + delta (new - baseline)
#
# Sections (all counters print 0 when the log never mentions them):
#   draws        draws_ok / draws_fail summed over exec_indirect* lines, ok ratio,
#                rt_resolves sum, rt_transient lines, passes dropped
#                (linux_clear_store reason=draws_skipped_after_engine_refusal)
#   translation  linux_m2v_async done ... ok by stage, vs failures
#                (reason=m2v_*translate* on async_done / m2v_reason= on draws),
#                spirv_dump_fail, distinct failing pipes
#   declines     every " reason=<slug>" (not the "_reason=" inside detail=):
#                total, distinct slugs, top 15 by max(A,B)
#   resources    rt_resolve by reason+object_type, texture_resolve_missing by
#                descriptor type, mapper_desc_fail, present_unbacked/restaled,
#                scanout_paint_mapping
# No deps beyond grep/awk/sort.
set -u
A=${1:-/tmp/reims-vgpu-fail.log}; B=${2:-}
for f in "$A" ${B:+"$B"}; do [ -r "$f" ] || { echo "gpu-score: cannot read $f" >&2; exit 1; }; done

# One pass per log -> "key<TAB>value" lines.
collect() {
  awk '
  function num(k,   m) { return match($0, "(^| )" k "=[0-9]+") ? substr($0, RSTART + (RSTART > 1) + length(k) + 1, RLENGTH - (RSTART > 1) - length(k) - 1) + 0 : 0 }
  function val(k,   m) { return match($0, "(^| )" k "=[^ ]+") ? substr($0, RSTART + (RSTART > 1) + length(k) + 1, RLENGTH - (RSTART > 1) - length(k) - 1) : "" }
  /exec_indirect[0-9]* ch=/ { c["draws.ok"] += num("draws_ok"); c["draws.fail"] += num("draws_fail"); c["draws.rt_resolves"] += num("rt_resolves"); c["draws.exec_lines"]++ }
  / rt_transient task=/ { c["draws.rt_transient"]++ }
  /reason=draws_skipped_after_engine_refusal/ { c["draws.passes_dropped"]++ }
  /linux_m2v_async done pipe=.* ok / { c["xl.ok"]++; c["xl.ok." tolower(val("stage"))]++ }
  /linux_m2v_async_done reason=m2v_[a-z_]*translate/ { c["xl.fail"]++; p = val("pipe"); if (p != "") fp[p] = 1 }
  /m2v_reason=m2v_[a-z_]*translate/ { c["xl.fail_at_draw"]++; p = val("pipeline_ref"); if (p != "") fp[p] = 1 }
  /spirv_dump_fail / { c["xl.spirv_dump_fail"]++; p = val("pipe"); if (p != "") fp[p] = 1 }
  {
    s = $0
    while (match(s, /(^| )reason=[A-Za-z0-9_]+/)) {
      t = substr(s, RSTART, RLENGTH); sub(/^ ?reason=/, "", t)
      c["slug." t]++; c["dec.total"]++
      s = substr(s, RSTART + RLENGTH)
    }
  }
  /(^| )rt_resolve reason=/ { c["res.rt_resolve." val("reason") ".ot" val("object_type")]++ }
  /reason=draw_prepare_texture_resolve_missing/ {
    if (match($0, /detail=type=[0-9]+/)) c["res.texmiss.type" substr($0, RSTART + 12, RLENGTH - 12)]++
    else c["res.texmiss.other"]++
  }
  /refused_by=draw_prepare_texture_resolve_missing/ { c["res.texmiss.pass_dropped"]++ }
  /mapper_desc_fail/ { c["res.mapper_desc_fail"]++ }
  /present_unbacked/ { c["res.present_unbacked"]++ }
  /restaled/ { c["res.restaled"]++ }
  /scanout_paint_mapping/ { c["res.scanout_paint_mapping"]++ }
  END {
    n = 0; for (p in fp) n++; c["xl.fail_pipes"] = n
    for (k in c) printf "%s\t%d\n", k, c[k]
  }' "$1"
}

ta=$(collect "$A"); tb=""; [ -n "$B" ] && tb=$(collect "$B")

{ printf '%s\n' "$ta" | sed 's/^/A\t/'; [ -n "$B" ] && printf '%s\n' "$tb" | sed 's/^/B\t/'; } |
awk -F'\t' -v two="${B:+1}" -v na="$(basename "$A")" -v nb="$(basename "${B:-}")" '
  { v[$1, $2] = $3; seen[$2] = 1 }
  function g(s, k) { return ((s, k) in v) ? v[s, k] : 0 }
  function row(label, a, b) {
    if (two) printf "  %-44s %10s %10s %+10d\n", label, a, b, b - a
    else     printf "  %-44s %10s\n", label, a
  }
  function r(label, k) { row(label, g("A", k), g("B", k)) }
  function ratio(s,   o, f) { o = g(s, "draws.ok"); f = g(s, "draws.fail"); return (o + f) ? sprintf("%.1f%%", 100 * o / (o + f)) : "-" }
  function head(t) { print ""; print t }
  # keys with prefix pre, sorted by max(A,B) desc, at most lim rows
  function ranked(pre, lim, lp,   k, n, i, j, t, key, m) {
    n = 0
    for (k in seen) if (index(k, pre) == 1) { key[++n] = k; m[n] = g("A", k) > g("B", k) ? g("A", k) : g("B", k) }
    for (i = 2; i <= n; i++) for (j = i; j > 1 && (m[j] > m[j-1] || (m[j] == m[j-1] && key[j] < key[j-1])); j--) {
      t = m[j]; m[j] = m[j-1]; m[j-1] = t; t = key[j]; key[j] = key[j-1]; key[j-1] = t }
    if (n == 0) { row("(none)", 0, 0); return 0 }
    for (i = 1; i <= n && i <= lim; i++) r(lp substr(key[i], length(pre) + 1), key[i])
    return n
  }
  END {
    if (two) printf "  %-44s %10s %10s %10s\n", "", "A", "B", "delta"
    printf "  A = %s\n", na; if (two) printf "  B = %s\n", nb
    head("draws")
    r("draws_ok (sum)", "draws.ok"); r("draws_fail (sum)", "draws.fail")
    if (two) printf "  %-44s %10s %10s\n", "ok ratio", ratio("A"), ratio("B"); else printf "  %-44s %10s\n", "ok ratio", ratio("A")
    r("rt_resolves (sum)", "draws.rt_resolves"); r("rt_transient", "draws.rt_transient")
    r("passes dropped (after_engine_refusal)", "draws.passes_dropped")
    head("translation (m2v)")
    r("shaders translated ok", "xl.ok"); r("  vertex", "xl.ok.vertex"); r("  fragment", "xl.ok.fragment"); r("  kernel", "xl.ok.kernel")
    r("translate failures (async)", "xl.fail"); r("translate failures hit at draw", "xl.fail_at_draw")
    r("spirv_dump_fail", "xl.spirv_dump_fail"); r("distinct failing pipes", "xl.fail_pipes")
    head("decline slugs")
    r("reason= total", "dec.total")
    na_ = 0; nb_ = 0; for (k in seen) if (index(k, "slug.") == 1) { if (("A", k) in v) na_++; if (("B", k) in v) nb_++ }
    row("distinct slugs", na_, nb_)
    ranked("slug.", 15, "  ")
    head("resources")
    ranked("res.rt_resolve.", 99, "rt_resolve ")
    ranked("res.texmiss.", 99, "texture_resolve_missing ")
    r("mapper_desc_fail", "res.mapper_desc_fail"); r("present_unbacked", "res.present_unbacked")
    r("restaled", "res.restaled"); r("scanout_paint_mapping", "res.scanout_paint_mapping")
  }'
