#!/bin/bash
# Build pipe.c, make name-length variants of sh.comp, create each on kisak dzn.
# Repro for a Dozen bug: a SPIR-V debug name (OpName/OpMemberName) of 256+ bytes smashes the
# stack in create_compute_pipelines. Expected (kisak Mesa 26.2.5, RX 6750 XT): 255 -> create_compute_pipelines=0, 256+ -> stack smashing.
# st.comp is the struct/member/SSBO-name variant (sed its OpName/OpMemberName strings likewise).
set -u; cd "$(dirname "$0")"; mk=${GG_MESA:-${GG_HOME:-$HOME/gg}/opt/mesa-kisak}; T=${TMPDIR:-/tmp}/dznname; mkdir -p $T
gcc -O1 -o $T/dznpipe pipe.c -lvulkan || exit 1
glslc -fshader-stage=compute sh.comp -o $T/dzn-base.spv || exit 1
spirv-dis $T/dzn-base.spv > $T/dzn-base.spvasm
for len in ${LENS:-16 200 250 254 255 256 300 600}; do
  name=$(python3 -c "import sys; n=int(sys.argv[1]); s='_ZZN2CA6Render12BlurFilterEE12sample_cache'; print((('x'*n)+s)[-n:] if n>len(s) else s[:n])" $len)
  sed "s/\"NAMEPLACEHOLDER\"/\"$name\"/" $T/dzn-base.spvasm > $T/dzn-$len.spvasm
  spirv-as --target-env vulkan1.0 $T/dzn-$len.spvasm -o $T/dzn-$len.spv || continue
  out=$(VK_DRIVER_FILES=$mk/dzn_icd.json LD_LIBRARY_PATH=$mk/usr/lib/x86_64-linux-gnu:/usr/lib/wsl/lib timeout 60 $T/dznpipe $T/dzn-$len.spv 2>&1 | tail -2 | tr '\n' ' ')
  echo "len=$len rc=${PIPESTATUS[0]} $out"
done
