#!/usr/bin/env bash
set -euo pipefail
upstream="$(realpath "$1")"
proposal="$(realpath "$2")"
cd "$upstream"
mkdir -p evidence
export CARGO_TERM_COLOR=never
expected_sha=8cadfede7063c896b944e7bae05daa3549ae97ea
expected_tree=3ed5db20847e09a9f3d157660e27c8d2c3141fc3
expected_main_blob=8bbf1dc2c4cf6f238eb96618e7abc23e3b4a33ce
expected_lock_blob=ae996317722a2195a171d7b51adb0cb0ec725ea6
fixture_sha=262022fc069f9b3a574ad282dbc751ca70f91c01896dc13651cb4778b1ec24cb

verify_source() {
  python3 - "$1" "$expected_sha" "$expected_tree" "$expected_main_blob" "$expected_lock_blob" "$fixture_sha" <<'PY'
import hashlib
from pathlib import Path
import subprocess
import sys

injected, sha, tree, main_blob, lock_blob, fixture_sha = sys.argv[1:]

def git(*args):
    return subprocess.check_output(['git', *args])

def line(*args):
    return git(*args).decode().strip()

assert line('rev-parse', 'HEAD') == sha, 'upstream HEAD changed'
assert line('rev-parse', 'HEAD^{tree}') == tree, 'upstream tree mismatch'
assert line('rev-parse', 'HEAD:encoding-decoding-demo/src/main.rs') == main_blob
assert line('hash-object', 'Cargo.lock') == lock_blob, 'Cargo.lock changed'
assert not git('diff', '--cached', '--name-only'), 'unexpected staged source changes'
assert not git('diff', '--summary'), 'unexpected source mode/rename changes'
main = Path('encoding-decoding-demo/src/main.rs')
original = git('show', 'HEAD:encoding-decoding-demo/src/main.rs')
suffix = b'\n#[cfg(test)]\nmod decode_custom_tool_regression;\n'
module = Path('encoding-decoding-demo/src/decode_custom_tool_regression.rs')
changed = set(git('diff', '--name-only', '-z').decode().split('\0')) - {''}
if injected == 'yes':
    assert main.read_bytes() == original + suffix, 'production main changed beyond the exact cfg(test) suffix'
    assert changed == {str(main)}, f'unexpected tracked changes: {changed}'
    assert hashlib.sha256(module.read_bytes()).hexdigest() == fixture_sha, 'fixture changed'
else:
    assert main.read_bytes() == original, 'original production source mismatch'
    assert not changed, f'pre-existing source changes: {changed}'
    assert not module.exists(), 'pre-existing test module'
extra = set(git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')) - {''}
allowed_module = {str(module)} if injected == 'yes' else set()
assert all(path in allowed_module or path.startswith('evidence/') for path in extra), f'unexpected untracked source: {extra}'
print(f'SOURCE_BINDING_VERIFIED: injected={injected} sha={sha} tree={tree} main_blob={main_blob} lock_blob={lock_blob} fixture_sha256={fixture_sha}')
PY
}
verify_source no | tee evidence/source-before.log
{
  printf 'upstream=%s\nupstream_tree=%s\nCargo.lock_blob=%s\noriginal_main_blob=%s\n' "$expected_sha" "$expected_tree" "$expected_lock_blob" "$expected_main_blob"
  printf 'proposal_commit=%s\n' "${GITHUB_SHA:-local-unpublished}"
  rustc +1.97.1 --version
  cargo +1.97.1 --version
  sha256sum Cargo.lock "$proposal/decode_custom_tool_regression.rs" "$proposal/run-baseline.sh"
} | tee evidence/provenance.log
printf '%s  %s\n' "$fixture_sha" "$proposal/decode_custom_tool_regression.rs" | sha256sum --check --strict
cp "$proposal/decode_custom_tool_regression.rs" encoding-decoding-demo/src/decode_custom_tool_regression.rs
printf '\n#[cfg(test)]\nmod decode_custom_tool_regression;\n' >> encoding-decoding-demo/src/main.rs
verify_source yes | tee evidence/source-instrumented.log
git diff -- encoding-decoding-demo/src/main.rs | tee evidence/test-instrumentation.patch
# Verify source integrity even when Cargo or the semantic failure gate rejects the run.
on_exit() {
  status=$?
  trap - EXIT
  set +e
  verify_source yes > evidence/source-after.log 2>&1
  integrity_status=$?
  cat evidence/source-after.log
  printf '%s\n' "$status" > evidence/runner-original.exitcode
  printf '%s\n' "$integrity_status" > evidence/source-integrity.exitcode
  if [ "$integrity_status" -ne 0 ]; then exit 1; fi
  exit "$status"
}
trap on_exit EXIT

set +e
cargo +1.97.1 test -p encoding-decoding-demo --bin encoding-decoding-demo --locked \
  decode_custom_tool_regression::control_ -- --nocapture 2>&1 | tee evidence/controls.log
statuses=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${statuses[0]}" > evidence/controls-cargo.exitcode
printf '%s\n' "${statuses[1]}" > evidence/controls-tee.exitcode
test "${statuses[0]}" -eq 0
test "${statuses[1]}" -eq 0
python3 - <<'PY'
from pathlib import Path
import re
log = Path('evidence/controls.log').read_text()
for name in ('control_responses_function_with_same_name_keeps_arguments', 'control_chat_completions_keeps_function_arguments', 'control_messages_keeps_tool_input'):
    assert re.search(r'^test decode_custom_tool_regression::' + name + r' \.\.\. ok$', log, re.M), f'missing passing control: {name}'
assert re.search(r'^test result: ok\. 3 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out;', log, re.M), 'not exactly three passing native controls'
PY

set +e
cargo +1.97.1 test -p encoding-decoding-demo --bin encoding-decoding-demo --locked \
  decode_custom_tool_regression::responses_custom_tool_keeps_native_input -- --exact --nocapture \
  2>&1 | tee evidence/expected-red.log
statuses=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${statuses[0]}" > evidence/expected-red-cargo.exitcode
printf '%s\n' "${statuses[1]}" > evidence/expected-red-tee.exitcode
test "${statuses[0]}" -eq 101
test "${statuses[1]}" -eq 0
python3 - <<'PY'
from pathlib import Path
import re
log = Path('evidence/expected-red.log').read_text()
name = 'decode_custom_tool_regression::responses_custom_tool_keeps_native_input'
marker = 'CUSTOM_TOOL_TYPE_MISMATCH: demo must retain the Responses custom tool declaration'
assert re.search(r'^test ' + re.escape(name) + r' \.\.\. FAILED$', log, re.M), 'the exact native demo regression did not fail'
assert re.search(r'^test result: FAILED\. 0 passed; 1 failed; 0 ignored; 0 measured; 3 filtered out;', log, re.M), 'unexpected test result set'
assert re.findall(r"^thread '([^']+)'(?: \(\d+\))? panicked at", log, re.M) == [name], 'a different panic/fixture failure occurred'
assert log.count(marker) == 1, 'the target type assertion was not the sole semantic failure'
assert re.search(r'left:\s+"function_call"\s+right:\s+"custom_tool_call"', log), 'unexpected actual/expected tool types'
assert re.search(r'^    ' + re.escape(name) + r'$', log, re.M), 'exact failure list missing'
assert 'native-demo-response: ' in log, 'native handler response was not observed'
PY
printf 'BASELINE_CONFIRMED: 3 named native controls pass; the exact original demo handler type assertion fails as predicted.\n' | tee evidence/result.log
