#!/usr/bin/env bash
# Download UMLS RRF subset files needed for pico-dag local backend.
#
# Requires: UMLS_API_KEY env var  (same key the REST API uses)
# Target:   /srv/umls/rrf/
#
# Files downloaded:
#   MRCONSO.RRF  — concept names + source codes (~1.5 GB)
#   MRREL.RRF    — relations                   (~2.5 GB)
#   MRSTY.RRF    — semantic types              (~100 MB)
#   MRSAT.RRF    — attributes (LOINC LCN)      (~1.5 GB)
#
# Usage (on VPS):
#   UMLS_API_KEY=<your-key> bash download_umls.sh [2024AB]
#
# The release version defaults to the latest if not supplied.
# Check https://www.nlm.nih.gov/research/umls/licensedcontent/umlsknowledgesources.html
# for the current release tag.

set -euo pipefail

RELEASE="${1:-2024AB}"
DEST="/srv/umls/rrf"
TGT_URL="https://utslogin.nlm.nih.gov/cas/v1/api-key"
BASE="https://download.nlm.nih.gov/umls/kss/${RELEASE}"
# NLM filename pattern: umls-{RELEASE}-full.zip
ZIPNAME="umls-${RELEASE}-full.zip"

if [[ -z "${UMLS_API_KEY:-}" ]]; then
  echo "ERROR: UMLS_API_KEY not set" >&2
  exit 1
fi

mkdir -p "$DEST"

# ── 1. Get a Ticket Granting Ticket (TGT) ──────────────────────────────────
echo "Authenticating with UTS..."
TGT_LOCATION=$(curl -s -D - -o /dev/null \
  -d "apikey=${UMLS_API_KEY}" \
  "${TGT_URL}" \
  | grep -i "^Location:" | tr -d '\r' | awk '{print $2}')

if [[ -z "$TGT_LOCATION" ]]; then
  echo "ERROR: Failed to get TGT. Check your API key." >&2
  exit 1
fi
echo "TGT: $TGT_LOCATION"

# ── Helper: get a single-use Service Ticket and download one file ───────────
download_rrf() {
  local filename="$1"
  local dest_file="${DEST}/${filename}"

  if [[ -f "$dest_file" ]]; then
    echo "SKIP: $filename already exists ($(du -h "$dest_file" | cut -f1))"
    return
  fi

  echo "Fetching service ticket for $filename..."
  ST=$(curl -s \
    -d "service=${BASE}/${RELEASE}-full.zip" \
    "$TGT_LOCATION" \
    | tr -d '[:space:]')

  echo "Downloading $filename..."
  # The full zip contains all RRF files; we stream-extract just the one we need.
  curl -L --progress-bar \
    "${BASE}/${RELEASE}-full.zip?ticket=${ST}" \
    | python3 -c "
import sys, zipfile, io
data = sys.stdin.buffer.read()
z = zipfile.ZipFile(io.BytesIO(data))
target = [n for n in z.namelist() if n.endswith('/${filename}')]
if not target:
    print('ERROR: ${filename} not found in zip', file=sys.stderr)
    sys.exit(1)
sys.stdout.buffer.write(z.read(target[0]))
" > "$dest_file"

  echo "Done: $dest_file ($(du -h "$dest_file" | cut -f1))"
}

# The full-zip stream approach above works but downloads the whole zip for each
# file. The smarter path is to download the full zip once, then extract.
# Do that instead:

echo "Fetching service ticket for full release..."
ST=$(curl -s \
  -d "service=${BASE}/${ZIPNAME}" \
  "$TGT_LOCATION" \
  | tr -d '[:space:]')

ZIPFILE="/srv/umls/${ZIPNAME}"

if [[ ! -f "$ZIPFILE" ]]; then
  echo "Downloading UMLS full release ${RELEASE} (~4 GB compressed)..."
  # Cookie jar required: CAS sets MOD_AUTH_CAS cookie on first redirect
  # which must be carried through the second redirect to the actual file.
  curl -L --progress-bar \
    -c /tmp/umls_cookies.txt \
    -b /tmp/umls_cookies.txt \
    "${BASE}/${ZIPNAME}?ticket=${ST}" \
    -o "$ZIPFILE"
  # Verify zip magic bytes (PK = 0x504b)
  MAGIC=$(xxd -l 2 "$ZIPFILE" 2>/dev/null | awk '{print $2$3}')
  if [[ "$MAGIC" != "504b" ]]; then
    echo "ERROR: Download failed — not a valid zip (magic: $MAGIC). First bytes:" >&2
    head -5 "$ZIPFILE" >&2
    rm -f "$ZIPFILE"
    exit 1
  fi
  echo "Download complete: $(du -h "$ZIPFILE" | cut -f1)"
else
  echo "SKIP: $ZIPFILE already exists"
fi

# ── 2. Extract only the RRF files we need ──────────────────────────────────
echo "Extracting RRF files..."
for rrf in MRCONSO.RRF MRREL.RRF MRSTY.RRF MRSAT.RRF; do
  dest_file="${DEST}/${rrf}"
  if [[ -f "$dest_file" ]]; then
    echo "SKIP: $rrf already extracted"
    continue
  fi
  echo "Extracting $rrf..."
  unzip -p "$ZIPFILE" "*/META/${rrf}" > "$dest_file"
  echo "  → $(du -h "$dest_file" | cut -f1)"
done

echo ""
echo "All files in $DEST:"
ls -lh "$DEST"
echo ""
echo "Next step: Rscript /srv/umls/build_umls_db.R"
