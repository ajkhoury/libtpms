#!/bin/bash
# Read the host TPM's fixed identity and patch libtpms VendorInfo.c to match it.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VF="$SRC/src/tpm2/TPMCmd/Platform/src/VendorInfo.c"
[ -f "$VF" ] || { echo "VendorInfo.c not found at $VF"; exit 1; }

echo ">> reading host TPM (sudo may prompt)..."
PROPS=$(sudo tpm2_getcap properties-fixed)

# raw NAME -> the "raw:" hex value under the "NAME:" header (empty if absent).
raw() { awk -v k="$1:" '$1==k{f=1;next} f{if(/raw:/){print $2;exit} if(/:$/)exit}' <<<"$PROPS"; }

MAN=$(raw TPM2_PT_MANUFACTURER)
VS1=$(raw TPM2_PT_VENDOR_STRING_1)
VS2=$(raw TPM2_PT_VENDOR_STRING_2)
VS3=$(raw TPM2_PT_VENDOR_STRING_3)
VS4=$(raw TPM2_PT_VENDOR_STRING_4)
FV1=$(raw TPM2_PT_FIRMWARE_VERSION_1)
FV2=$(raw TPM2_PT_FIRMWARE_VERSION_2)

echo ">> raw values read:"
printf '   MANUFACTURER=%s VS1=%s VS2=%s VS3=%s VS4=%s FV1=%s FV2=%s\n' \
       "${MAN:-0}" "${VS1:-0}" "${VS2:-0}" "${VS3:-0}" "${VS4:-0}" "${FV1:-0}" "${FV2:-0}"

# Convert a 32-bit raw hex (big-endian char order, matching libtpms StringToUint32)
# into a C string literal. NUL bytes use the short "\0" (as the stock file does),
# other non-printables use a 3-digit octal escape. A C octal escape eats up to
# three digits, so "\0" is only emitted when the next char is not an octal digit
# (0-7); otherwise "\000" is used so the bytes stay distinct.
cstr() {
  local n=$(( ${1:-0} )) out="" i byte nb ch
  local -a b
  for i in 24 16 8 0; do b+=( $(( (n >> i) & 0xff )) ); done
  for i in 0 1 2 3; do
    byte=${b[i]}
    nb=$(( i < 3 ? b[i+1] : -1 ))   # next byte, or -1 past the end
    if (( byte >= 32 && byte < 127 && byte != 34 && byte != 92 )); then
      printf -v ch "\\$(printf '%03o' "$byte")"   # emit the character itself
      out+=$ch
    elif (( byte == 0 && (nb < 48 || nb > 55) )); then
      out+="\\0"                     # NUL; next char can't extend the escape
    else
      out+="\\$(printf '%03o' "$byte")"           # 3-digit octal escape
    fi
  done
  printf '"%s"' "$out"
}

# Normalize a firmware word to (0x........).
fw() { printf '(0x%08X)' "$(( ${1:-0} ))"; }

export MAN_S VS1_S VS2_S VS3_S VS4_S FV1_H FV2_H
MAN_S=$(cstr "$MAN"); VS1_S=$(cstr "$VS1"); VS2_S=$(cstr "$VS2")
VS3_S=$(cstr "$VS3"); VS4_S=$(cstr "$VS4")
FV1_H=$(fw "$FV1"); FV2_H=$(fw "$FV2")

echo ">> generated defines:"
cat <<EOF
   #define MANUFACTURER    $MAN_S
   #define VENDOR_STRING_1 $VS1_S
   #define VENDOR_STRING_2 $VS2_S
   #define VENDOR_STRING_3 $VS3_S
   #define VENDOR_STRING_4 $VS4_S
   #define FIRMWARE_V1     $FV1_H
   #define FIRMWARE_V2     $FV2_H
EOF

cp -v "$VF" "$VF.bak"
# Rebuild each #define line from scratch. Replacement values come from the
# environment via ENVIRON[], which awk treats as literal data, so backslashes,
# quotes and '&' in the generated C strings are never reinterpreted.
awk '
  /^#define[ \t]+MANUFACTURER[ \t]/    { print "#define MANUFACTURER    " ENVIRON["MAN_S"]; next }
  /^#define[ \t]+VENDOR_STRING_1[ \t]/ { print "#define VENDOR_STRING_1 " ENVIRON["VS1_S"]; next }
  /^#define[ \t]+VENDOR_STRING_2[ \t]/ { print "#define VENDOR_STRING_2 " ENVIRON["VS2_S"]; next }
  /^#define[ \t]+VENDOR_STRING_3[ \t]/ { print "#define VENDOR_STRING_3 " ENVIRON["VS3_S"]; next }
  /^#define[ \t]+VENDOR_STRING_4[ \t]/ { print "#define VENDOR_STRING_4 " ENVIRON["VS4_S"]; next }
  /^#define[ \t]+FIRMWARE_V1[ \t]/     { print "#define FIRMWARE_V1     " ENVIRON["FV1_H"]; next }
  /^#define[ \t]+FIRMWARE_V2[ \t]/     { print "#define FIRMWARE_V2     " ENVIRON["FV2_H"]; next }
  { print }
' "$VF.bak" > "$VF"

echo ">> patched $VF  (backup at $VF.bak). Diff:"
diff "$VF.bak" "$VF" || true
echo ">> done. Now re-build & install libtpms."
