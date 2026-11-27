#!/usr/bin/env bash
# Source this file, then pass the canonical SDK corpus (or an explicit override).
medex_receipt_fixture() {
  local proposed=${MEDEX_RECEIPT_VECTORS:-${1:?Supply the canonical receipt corpus}}
  MEDEX_RECEIPT_VECTORS=$(python3 - "$proposed" <<'PY'
from pathlib import Path
import hashlib
import json
import stat
import sys
p = Path(sys.argv[1]).absolute()
expected = '00e4b87285b26e995f5f0e3bff01c3cce5a8f3c4701e41d9f3981b73a197901b'
try:
    if not stat.S_ISREG(p.lstat().st_mode):
        raise ValueError('not a regular file')
    data = p.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('checksum mismatch')
    corpus = json.loads(data)
    if corpus['schema'] != 'medex.receipt_vectors.v2' or len(corpus['cases']) != 51:
        raise ValueError('wrong corpus identity')
except (OSError, ValueError, KeyError) as error:
    sys.exit('Receipt fixture unavailable: ' + str(error) +
             '; set MEDEX_RECEIPT_VECTORS to the frozen SDK corpus')
print(p)
PY
  ) || return 2
  export MEDEX_RECEIPT_VECTORS
}
