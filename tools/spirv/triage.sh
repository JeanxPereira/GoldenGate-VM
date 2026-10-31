#!/usr/bin/env bash
# Offline triage of a REIMS_VGPU_SPIRV_DUMP directory (runs in WSL).
#
#   tools/spirv/triage.sh <dump-dir> [--log /tmp/reims-vgpu-fail.log] [--out <dir>] [-j N]
#
# For every *.spv in <dump-dir>: spirv-val (target env $TARGET_ENV, default
# vulkan1.2 — the one reims' own gate uses) and spirv-dis into <out>
# (default <dump-dir>/triage/), then a summary:
#   - invalid modules, with the validator's first complaint
#   - capabilities / extensions / ext-inst imports beyond a plain Vulkan shader
#   - widest vector, matrices, vectors of 8/16/64-bit components
#   - Int8/Int16/Int64/Float16/Float64 use
#   - OpTypeArray lengths, and Function/Private/Workgroup variables by bytes
#     (huge allocas are what a JIT register allocator chokes on)
#   - PhysicalStorageBuffer pointers, OpConvertUToPtr/PtrToU, distinct
#     OpBitcast type pairs
#   - largest function (instructions), OpPhi count
# With --log: the pipeline_create_begin lines that have no _end (the driver
# call a crash happened in) and the dump files their module hashes name.
#
# Dump file names (see reims-vgpu runtime/spirv_dump.rs):
#   pipe<ref>-<stage>-<hash>.spv   translator output per guest pipeline stage
#   mod-<hash>.spv                 exact words given to vkCreateShaderModule
set -u

TARGET_ENV=${TARGET_ENV:-vulkan1.2}
dump=""; log=""; out=""; jobs=$(nproc 2>/dev/null || echo 4)

# Worker mode: validate + disassemble one module. Invoked through xargs.
if [ "${1:-}" = "__one" ]; then
  spv=$2; o=$3; base=$(basename "$spv" .spv)
  if spirv-val --target-env "$TARGET_ENV" "$spv" > "$o/$base.val" 2>&1; then
    echo valid > "$o/$base.verdict"
  else
    echo invalid > "$o/$base.verdict"
  fi
  spirv-dis "$spv" -o "$o/$base.spvasm" 2> "$o/$base.dis.err" || : > "$o/$base.spvasm"
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --log) log=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    -j) jobs=$2; shift 2 ;;
    -h|--help) sed -n 2,26p "$0"; exit 0 ;;
    *) dump=$1; shift ;;
  esac
done
[ -n "$dump" ] && [ -d "$dump" ] || { echo "usage: $0 <dump-dir> [--log fail.log] [--out dir] [-j N]" >&2; exit 2; }
for t in spirv-val spirv-dis; do
  command -v "$t" >/dev/null || { echo "missing $t (apt install spirv-tools)" >&2; exit 2; }
done
out=${out:-$dump/triage}
mkdir -p "$out"

mapfile -t mods < <(find "$dump" -maxdepth 1 -name '*.spv' | sort)
echo "== $(date -Is)  dump=$dump  modules=${#mods[@]}  target-env=$TARGET_ENV  out=$out"
[ ${#mods[@]} -gt 0 ] || exit 0

printf '%s\0' "${mods[@]}" | xargs -0 -P "$jobs" -I{} bash "$0" __one {} "$out"

# One awk pass per disassembly -> one tab-separated record per module.
read -r -d '' AWK <<'AWKEOF'
function desc(t,   s) {
  if (t in tdesc) return tdesc[t]
  return t
}
function bytes(t) { return (t in tsize) ? tsize[t] : 0 }
BEGIN { OFS = "\t"; maxvec = 0; maxarr = 0; fnmax = 0; infn = 0 }
{
  if ($2 == "=") { id = $1; op = $3; a = 4 } else { id = ""; op = $1; a = 2 }
  if (infn) fnlen++
  if (op == "OpCapability") caps[$2] = 1
  else if (op == "OpExtension") { gsub(/"/, "", $2); exts[$2] = 1 }
  else if (op == "OpExtInstImport") { x = $4; gsub(/"/, "", x); imps[x] = 1 }
  else if (op == "OpTypeInt") {
    w = $4; tdesc[id] = ($5 == 1 ? "i" : "u") w; tsize[id] = w / 8
    if (w != 32) widths["int" w] = 1
  }
  else if (op == "OpTypeFloat") {
    w = $4; tdesc[id] = "f" w; tsize[id] = w / 8
    if (w != 32) widths["float" w] = 1
  }
  else if (op == "OpTypeBool") { tdesc[id] = "bool"; tsize[id] = 4 }
  else if (op == "OpTypeVector") {
    n = $5 + 0; c = $4; tdesc[id] = "v" n desc(c); tsize[id] = bytes(c) * n
    if (n > maxvec) { maxvec = n; maxvecd = tdesc[id] }
    if (desc(c) ~ /^[iu](8|16|64)$|^f(16|64)$/) oddvec[tdesc[id]] = 1
  }
  else if (op == "OpTypeMatrix") {
    n = $5 + 0; c = $4; tdesc[id] = "m" n "x" desc(c); tsize[id] = bytes(c) * n
    mats[tdesc[id]] = 1
  }
  else if (op == "OpTypeArray") {
    len = ($5 in cval) ? cval[$5] : -1
    tdesc[id] = desc($4) "[" len "]"; tsize[id] = (len > 0) ? bytes($4) * len : 0
    narr++; if (len > maxarr) { maxarr = len; maxarrd = tdesc[id] }
    if (len >= 256) bigarr[tdesc[id]] = 1
  }
  else if (op == "OpTypeRuntimeArray") { tdesc[id] = desc($4) "[]"; tsize[id] = 0 }
  else if (op == "OpTypeStruct") {
    s = 0; d = "{"
    for (i = 4; i <= NF; i++) { s += bytes($i); d = d (i > 4 ? "," : "") desc($i) }
    tsize[id] = s; tdesc[id] = (length(d) > 60 ? substr(d, 1, 57) "..." : d) "}"
  }
  else if (op == "OpTypePointer") {
    psc[id] = $4; pte[id] = $5; tdesc[id] = "ptr<" $4 "," desc($5) ">"; tsize[id] = 8
    if ($4 == "PhysicalStorageBuffer") psb++
  }
  else if (op == "OpConstant") { cval[id] = $5 + 0; rtype[id] = $4 }
  else if (op == "OpVariable") {
    sc = $5; b = bytes(pte[$4])
    if (sc == "Function" || sc == "Private" || sc == "Workgroup") {
      vb[sc] += b
      if (b > vmax) { vmax = b; vmaxd = sc ":" desc(pte[$4]) }
    }
  }
  else if (op == "OpFunction") { infn = 1; fnlen = 0; nfn++ }
  else if (op == "OpFunctionEnd") { infn = 0; if (fnlen > fnmax) fnmax = fnlen }
  else if (op == "OpPhi") nphi++
  else if (op == "OpConvertUToPtr" || op == "OpConvertPtrToU") nptrconv++
  else if (op == "OpBitcast") {
    from = ($5 in rtype) ? desc(rtype[$5]) : "?"
    to = desc($4)
    if (from != to) bc[from "->" to]++
  }
  if (id != "" && a == 4 && op !~ /^OpType/ && op != "OpConstant" && op != "OpVariable" && op != "OpFunction" && op != "OpLabel" && op != "OpExtInstImport" && op != "OpString") rtype[id] = $4
  ninst++
}
END {
  base = "Shader Matrix ImageQuery SampledBuffer ImageBuffer Sampled1D Image1D StorageImageExtendedFormats StorageImageWriteWithoutFormat StorageImageReadWithoutFormat DerivativeControl SampleRateShading MinLod ClipDistance CullDistance InputAttachment ImageGatherExtended StorageImageMultisample ImageCubeArray SampledCubeArray ImageMSArray"
  n = split(base, bl, " "); for (i = 1; i <= n; i++) basecap[bl[i]] = 1
  c = ""; for (k in caps) if (!(k in basecap)) c = c (c ? "," : "") k
  e = ""; for (k in exts) e = e (e ? "," : "") k
  im = ""; for (k in imps) if (k != "GLSL.std.450") im = im (im ? "," : "") k
  w = ""; for (k in widths) w = w (w ? "," : "") k
  ov = ""; for (k in oddvec) ov = ov (ov ? "," : "") k
  mt = ""; for (k in mats) mt = mt (mt ? "," : "") k
  ba = ""; nb = 0; for (k in bigarr) { if (nb++ < 4) ba = ba (ba ? "," : "") k }
  bcs = ""; nbc = 0; for (k in bc) { if (nbc++ < 6) bcs = bcs (bcs ? "," : "") k "x" bc[k] }
  print ninst, nfn + 0, fnmax + 0, nphi + 0, maxvec + 0, (maxvecd ? maxvecd : "-"), \
        (mt ? mt : "-"), (ov ? ov : "-"), (w ? w : "-"), narr + 0, maxarr + 0, (ba ? ba : "-"), \
        vb["Function"] + 0, vb["Private"] + 0, vb["Workgroup"] + 0, (vmaxd ? vmaxd "=" vmax "B" : "-"), \
        psb + 0, nptrconv + 0, (bcs ? bcs : "-"), (c ? c : "-"), (e ? e : "-"), (im ? im : "-")
}
AWKEOF

summary="$out/summary.tsv"
printf 'module\tverdict\twords\tinsts\tfuncs\tmaxfn\tphis\tmaxvec\tmaxvec_type\tmatrices\todd_vectors\tnon32_widths\tarrays\tmaxarr\tbig_arrays\tfn_bytes\tpriv_bytes\twg_bytes\tlargest_var\tpsb_ptrs\tptr_conv\tbitcasts\textra_caps\textensions\text_imports\n' > "$summary"
for spv in "${mods[@]}"; do
  base=$(basename "$spv" .spv)
  words=$(( $(stat -c %s "$spv") / 4 ))
  rec=$(awk "$AWK" "$out/$base.spvasm")
  printf '%s\t%s\t%s\t%s\n' "$base" "$(cat "$out/$base.verdict")" "$words" "$rec" >> "$summary"
done

col() { awk -F'\t' -v c="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==c) k=i; next} {print $1"\t"$k}' "$summary"; }

echo
echo "== invalid modules ($(awk -F'\t' 'NR>1 && $2=="invalid"' "$summary" | wc -l))"
awk -F'\t' 'NR>1 && $2=="invalid"{print $1}' "$summary" | while read -r b; do
  echo "-- $b"; grep -v '^$' "$out/$b.val" | head -4 | sed 's/^/   /'
done

echo
echo "== per module (largest first): words maxfn phis maxvec odd-vectors widths maxarr largest-var psb"
awk -F'\t' 'NR>1{printf "%-48s %-7s %8d w  fn=%-7d phi=%-6d vec=%-3d %-14s %-18s arr=%-6d %-28s psb=%d\n",
  $1,$2,$3,$6,$7,$8,$11,$12,$14,$19,$20}' "$summary" | sort -k3 -n -r | head -40

echo
echo "== capabilities beyond a plain Vulkan shader";  col extra_caps | awk -F'\t' '$2!="-"{n=split($2,a,",");for(i=1;i<=n;i++)c[a[i]]++} END{for(k in c)print "  "c[k]"\t"k}' | sort -rn
echo "== extensions";                                col extensions | awk -F'\t' '$2!="-"{n=split($2,a,",");for(i=1;i<=n;i++)c[a[i]]++} END{for(k in c)print "  "c[k]"\t"k}' | sort -rn
echo "== ext-inst imports (besides GLSL.std.450)";  col ext_imports | awk -F'\t' '$2!="-"{n=split($2,a,",");for(i=1;i<=n;i++)c[a[i]]++} END{for(k in c)print "  "c[k]"\t"k}' | sort -rn
echo "== non-32-bit scalar widths (Int8/Int16/Int64/Float16/Float64)"
col non32_widths | awk -F'\t' '$2!="-"{n=split($2,a,",");for(i=1;i<=n;i++){c[a[i]]++; m[a[i]]=m[a[i]]" "$1}} END{for(k in c)print "  "c[k]"\t"k"\t"substr(m[k],1,200)}' | sort -rn
echo "== vectors of 8/16/64-bit components"
col odd_vectors | awk -F'\t' '$2!="-"{print "  "$1"\t"$2}' | head -30
echo "== widest vectors";   awk -F'\t' 'NR>1 && $8>4{print "  "$1"\t"$9}' "$summary" | head -30; echo "  (anything > 4 components is outside core Vulkan)"
echo "== matrices";         col matrices | awk -F'\t' '$2!="-"{n=split($2,a,",");for(i=1;i<=n;i++)c[a[i]]++} END{for(k in c)print "  "c[k]"\t"k}' | sort -rn
echo "== arrays with >= 256 elements"; col big_arrays | awk -F'\t' '$2!="-"{print "  "$1"\t"$2}' | head -30
echo "== Function/Private/Workgroup variable bytes (top 15 by largest single variable)"
awk -F'\t' 'NR>1 && $19!="-"{split($19,v,"=");b=v[2];sub(/B$/,"",b);printf "  %10d  %-46s fn=%d priv=%d wg=%d  %s\n",b,$1,$16,$17,$18,v[1]}' "$summary" | sort -rn | head -15
echo "== physical storage buffer pointers / pointer<->int conversions"
awk -F'\t' 'NR>1 && ($20>0 || $21>0){print "  "$1"\tpsb_ptr_types="$20"\tconvert="$21}' "$summary" | head -30
echo "== distinct OpBitcast type pairs (first 6 per module)"
col bitcasts | awk -F'\t' '$2!="-"{n=split($2,a,",");for(i=1;i<=n;i++){p=a[i];sub(/x[0-9]+$/,"",p);c[p]++}} END{for(k in c)print "  "c[k]"\t"k}' | sort -rn | head -30

if [ -n "$log" ]; then
  echo
  echo "== driver calls that began and never ended ($log)"
  grep -a 'pipeline_create_\(begin\|end\)' "$log" | awk '
    /pipeline_create_begin/ { for (i=1;i<=NF;i++) if ($i ~ /^seq=/) s=$i; open[s]=$0; order[++n]=s }
    /pipeline_create_end/   { for (i=1;i<=NF;i++) if ($i ~ /^seq=/) delete open[$i] }
    END { for (i=1;i<=n;i++) if (order[i] in open) print open[order[i]] }' | while read -r line; do
    echo "  $line"
    for h in $(echo "$line" | grep -o '=[0-9a-f]\{16\}/' | tr -d '=/'); do
      f=$(ls "$dump"/*-"$h".spv 2>/dev/null | tr '\n' ' ')
      v=$(for x in $f; do b=$(basename "$x" .spv); echo "$b:$(cat "$out/$b.verdict" 2>/dev/null)"; done | tr '\n' ' ')
      echo "     $h -> ${v:-not in dump}"
      grep -a "spirv_dump_bind" "$log" | grep "$h" | head -2 | sed 's/^/       /'
    done
  done
fi
echo
echo "full table: $summary   disassembly: $out/*.spvasm"
