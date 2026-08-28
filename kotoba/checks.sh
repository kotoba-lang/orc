#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Compile kotoba/orc.kotoba with Kotoba 0.7.2 (wasm32, i64-v1) and assert
# header fields from CLI output. Missing fields are failures.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ROOT}/.." && pwd)"
FIXTURE="${ROOT}/fixtures/tiny.orc"
SRC="${ROOT}/orc.kotoba"
EXPECTED_VALUE="111102"
KOTOBA_VERSION="0.7.2"
KOTOBA_TARBALL="kotoba-linux-amd64.tar.gz"
# sha256 of https://github.com/kotoba-lang/kotoba/releases/download/v0.7.2/kotoba-linux-amd64.tar.gz
KOTOBA_SHA256="95e225461e1b8a21849b251e8c8b654693d2c8a516b258532771651e978e1977"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

need_file() {
  [[ -f "$1" ]] || fail "missing $1"
}

need_file "${FIXTURE}"
need_file "${SRC}"

python3 - "${FIXTURE}" "${SRC}" <<'PY'
import re
import sys

fixture_path, src_path = sys.argv[1], sys.argv[2]
data = open(fixture_path, "rb").read()
if len(data) < 4:
    print("FAIL: fixture shorter than 4 bytes", file=sys.stderr)
    sys.exit(1)
if data[:3] != b"ORC":
    print("FAIL: fixture header is %r, not ORC" % (data[:3],), file=sys.stderr)
    sys.exit(1)
ps_len = data[-1]
if ps_len < 4 or ps_len >= len(data):
    print("FAIL: postscript length byte %d is not usable" % ps_len, file=sys.stderr)
    sys.exit(1)
if data[-(1 + 3):-1] != b"ORC":
    print("FAIL: postscript does not end in ORC magic", file=sys.stderr)
    sys.exit(1)

src = open(src_path, encoding="utf-8").read()
pairs = [(int(i), int(b)) for i, b in re.findall(r"\(if \(= i (\d+)\) (\d+)", src)]
if not pairs:
    print("FAIL: no fixture-byte literals in orc.kotoba", file=sys.stderr)
    sys.exit(1)
indexes = [i for i, _ in pairs]
if indexes != list(range(len(data))):
    print("FAIL: fixture-byte indexes %s do not cover 0..%d" % (indexes, len(data) - 1), file=sys.stderr)
    sys.exit(1)
embedded = [b for _, b in pairs]
file_bytes = list(data)
if embedded != file_bytes:
    print("FAIL: orc.kotoba fixture-byte literals do not match fixtures/tiny.orc", file=sys.stderr)
    for i, (a, b) in enumerate(zip(embedded, file_bytes)):
        if a != b:
            print("  index %d: module=%d file=%d" % (i, a, b), file=sys.stderr)
            break
    sys.exit(1)
print("fixture: %d bytes, magic ORC, psLen=%d, module bytes match file" % (len(data), ps_len))
PY

if [[ -n "${KOTOBA:-}" ]]; then
  KOTOBA_BIN="${KOTOBA}"
  [[ -x "${KOTOBA_BIN}" ]] || fail "KOTOBA=${KOTOBA_BIN} is not executable"
else
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  if [[ "${uname_s}" != "Linux" || "${uname_m}" != "x86_64" ]]; then
    fail "no KOTOBA set; automatic install is linux-amd64 only (this host is ${uname_s}/${uname_m})"
  fi
  cache="${ROOT}/.kotoba-cli/${KOTOBA_VERSION}"
  mkdir -p "${cache}"
  archive="${cache}/${KOTOBA_TARBALL}"
  if [[ ! -x "${cache}/kotoba" ]]; then
    url="https://github.com/kotoba-lang/kotoba/releases/download/v${KOTOBA_VERSION}/${KOTOBA_TARBALL}"
    echo "downloading Kotoba ${KOTOBA_VERSION} from ${url}"
    curl -fsSL -o "${archive}" "${url}"
    got="$(sha256sum "${archive}" | awk '{print $1}')"
    if [[ "${got}" != "${KOTOBA_SHA256}" ]]; then
      fail "checksum mismatch for ${KOTOBA_TARBALL}: got ${got} expected ${KOTOBA_SHA256}"
    fi
    tar -xzf "${archive}" -C "${cache}" kotoba
  fi
  KOTOBA_BIN="${cache}/kotoba"
  [[ -x "${KOTOBA_BIN}" ]] || fail "extracted kotoba binary missing"
fi

echo "using ${KOTOBA_BIN}"

compile_out="$("${KOTOBA_BIN}" compile "${SRC}" --target wasm -o "${ROOT}/orc.wasm")"
printf '%s\n' "${compile_out}"

printf '%s\n' "${compile_out}" | python3 -c '
import sys
text = sys.stdin.read()
need = [
    ":kotoba.cli/ok? true",
    ":compile/emitted",
    ":target :wasm32-kotoba-v1",
    ":value-abi :kotoba.i64/direct-v1",
    ":value-profile :kotoba.value/i64-v1",
]
missing = [item for item in need if item not in text]
if missing:
    print("FAIL: compile output missing %s" % ", ".join(missing), file=sys.stderr)
    sys.exit(1)
if ":compile/failed" in text:
    print("FAIL: compile output contains :compile/failed", file=sys.stderr)
    sys.exit(1)
print("compile: wasm32-kotoba-v1 i64-v1 emitted")
'

run_out="$("${KOTOBA_BIN}" run "${SRC}")"
printf '%s\n' "${run_out}"

printf '%s\n' "${run_out}" | python3 -c '
import re
import sys
expected = sys.argv[1]
text = sys.stdin.read()
if ":kotoba.runtime/ok? true" not in text:
    print("FAIL: run output has no :kotoba.runtime/ok? true", file=sys.stderr)
    sys.exit(1)
match = re.search(r":kotoba.runtime/value (-?\d+)", text)
if match is None:
    print("FAIL: run output has no integer :kotoba.runtime/value", file=sys.stderr)
    sys.exit(1)
value = match.group(1)
if value != expected:
    print("FAIL: runtime value %s, expected %s" % (value, expected), file=sys.stderr)
    sys.exit(1)
print("run: header fields %s" % value)
' "${EXPECTED_VALUE}"

echo "PASS: Kotoba 0.7.2 compiled wasm32 i64-v1 and asserted ORC header fields ${EXPECTED_VALUE}"
