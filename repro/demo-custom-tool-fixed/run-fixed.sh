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
main_sha=8dc5631dedfeff6130b3aea7de2fb6385ca0fbd073814266b5d0f2702ddb546e
fixture_sha=7c2017110cc500536bfa66bfff3eb1b7c49865d6a18e6972213126846a77da3e

verify_source() {
  python3 - "$1" "$expected_sha" "$expected_tree" "$expected_main_blob" "$expected_lock_blob" "$main_sha" "$fixture_sha" <<'PY'
import hashlib
from pathlib import Path
import subprocess
import sys
installed, sha, tree, original_main, lock_blob, main_sha, fixture_sha = sys.argv[1:]
def git(*args):
    return subprocess.check_output(['git', *args])
def line(*args):
    return git(*args).decode().strip()
assert line('rev-parse', 'HEAD') == sha
assert line('rev-parse', 'HEAD^{tree}') == tree
assert line('rev-parse', 'HEAD:encoding-decoding-demo/src/main.rs') == original_main
assert line('hash-object', 'Cargo.lock') == lock_blob, 'Cargo.lock changed'
assert not git('diff', '--cached', '--name-only'), 'unexpected staged source'
assert not git('diff', '--summary'), 'unexpected source mode/rename changes'
main = Path('encoding-decoding-demo/src/main.rs')
module = Path('encoding-decoding-demo/src/decode_custom_tool_regression.rs')
changed = set(git('diff', '--name-only', '-z').decode().split('\0')) - {''}
if installed == 'baseline':
    suffix = b'\n#[cfg(test)]\nmod decode_custom_tool_regression;\n'
    assert main.read_bytes() == git('show', 'HEAD:encoding-decoding-demo/src/main.rs') + suffix, 'original production code changed beyond test instrumentation'
    assert hashlib.sha256(module.read_bytes()).hexdigest() == '403a742f461abc609a53a11eac732932c1835d774d8d8732eb7610272257be08', 'formatted baseline fixture changed'
    assert changed == {str(main)}, f'unexpected tracked baseline changes: {changed}'
elif installed == 'yes':
    assert hashlib.sha256(main.read_bytes()).hexdigest() == main_sha, 'candidate production bytes changed'
    fixture = module.read_bytes()
    assert hashlib.sha256(fixture).hexdigest() == fixture_sha, 'candidate test bytes changed'
    assert hashlib.sha256(fixture[:3978]).hexdigest() == '403a742f461abc609a53a11eac732932c1835d774d8d8732eb7610272257be08', 'formatted baseline test prefix changed'
    assert changed == {str(main)}, f'unexpected tracked changes: {changed}'
else:
    assert line('hash-object', str(main)) == original_main
    assert not changed
    assert not module.exists()
extra = set(git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')) - {''}
allowed_module = {str(module)} if installed in ('baseline', 'yes') else set()
assert all(path in allowed_module or path.startswith('evidence/') for path in extra), f'unexpected untracked source: {extra}'
print(f'SOURCE_BINDING_VERIFIED: installed={installed} sha={sha} tree={tree} lock_blob={lock_blob} candidate_sha256={main_sha} tests_sha256={fixture_sha}')
PY
}
verify_source no | tee evidence/source-before.log
printf '%s  %s\n' "$main_sha" "$proposal/main.rs" "$fixture_sha" "$proposal/decode_custom_tool_regression.rs" | sha256sum --check --strict
python3 - "$proposal/decode_custom_tool_regression.rs" <<'PY'
from pathlib import Path
import hashlib
import sys
prefix = Path(sys.argv[1]).read_bytes()[:3978]
assert hashlib.sha256(prefix).hexdigest() == '403a742f461abc609a53a11eac732932c1835d774d8d8732eb7610272257be08'
Path('encoding-decoding-demo/src/decode_custom_tool_regression.rs').write_bytes(prefix)
PY
printf '\n#[cfg(test)]\nmod decode_custom_tool_regression;\n' >> encoding-decoding-demo/src/main.rs
phase=baseline
verify_source "$phase" | tee evidence/source-baseline-installed.log
{
  printf 'proposal_commit=%s\n' "${GITHUB_SHA:-local-unpublished}"
  rustc +1.97.1 --version
  cargo +1.97.1 --version
  sha256sum Cargo.lock "$proposal/main.rs" "$proposal/decode_custom_tool_regression.rs" "$proposal/run-fixed.sh"
} | tee evidence/provenance.log
git diff -- encoding-decoding-demo/src/main.rs > evidence/baseline-instrumentation.patch
on_exit() {
  status=$?
  trap - EXIT
  set +e
  verify_source "$phase" > evidence/source-after.log 2>&1
  integrity_status=$?
  cat evidence/source-after.log
  printf '%s\n' "$status" > evidence/runner-original.exitcode
  printf '%s\n' "$integrity_status" > evidence/source-integrity.exitcode
  if [ "$integrity_status" -ne 0 ]; then exit 1; fi
  exit "$status"
}
trap on_exit EXIT

run_check() {
  label="$1"
  shift
  set +e
  "$@" 2>&1 | tee "evidence/$label.log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  printf '%s\n' "${statuses[0]}" > "evidence/$label-command.exitcode"
  printf '%s\n' "${statuses[1]}" > "evidence/$label-tee.exitcode"
}
run_check baseline-controls cargo +1.97.1 test -p encoding-decoding-demo --bin encoding-decoding-demo --locked decode_custom_tool_regression::control_ -- --nocapture
test "$(cat evidence/baseline-controls-command.exitcode)" -eq 0
test "$(cat evidence/baseline-controls-tee.exitcode)" -eq 0
python3 - <<'PY'
from pathlib import Path
import re
log = Path('evidence/baseline-controls.log').read_text()
for name in ('control_responses_function_with_same_name_keeps_arguments', 'control_chat_completions_keeps_function_arguments', 'control_messages_keeps_tool_input'):
    assert re.search(r'^test decode_custom_tool_regression::' + name + r' \.\.\. ok$', log, re.M), f'missing passing control: {name}'
assert re.search(r'^test result: ok\. 3 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out;', log, re.M), 'not exactly three passing native controls'
PY
run_check baseline-red cargo +1.97.1 test -p encoding-decoding-demo --bin encoding-decoding-demo --locked decode_custom_tool_regression::responses_custom_tool_keeps_native_input -- --exact --nocapture
test "$(cat evidence/baseline-red-command.exitcode)" -eq 101
test "$(cat evidence/baseline-red-tee.exitcode)" -eq 0
python3 - <<'PY'
from pathlib import Path
import re
log = Path('evidence/baseline-red.log').read_text()
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
verify_source "$phase" | tee evidence/source-baseline-after.log
printf 'FORMATTED_BASELINE_CONFIRMED: original production code still gives exactly 3 passing controls and the custom-tool type assertion failure.\n' | tee evidence/baseline-result.log
cp "$proposal/main.rs" encoding-decoding-demo/src/main.rs
cp "$proposal/decode_custom_tool_regression.rs" encoding-decoding-demo/src/decode_custom_tool_regression.rs
phase=yes
verify_source "$phase" | tee evidence/source-fixed-installed.log
git diff -- encoding-decoding-demo/src/main.rs > evidence/candidate.patch
run_check focused-tests cargo +1.97.1 test -p encoding-decoding-demo --bin encoding-decoding-demo --locked decode_custom_tool_regression -- --test-threads=1
run_check demo-clippy cargo +1.97.1 clippy -p encoding-decoding-demo --all-targets --locked -- -D warnings
run_check format-check cargo +1.97.1 fmt --all -- --check
python3 - <<'PY'
from pathlib import Path
import re
for label in ('focused-tests', 'demo-clippy', 'format-check'):
    for kind in ('command', 'tee'):
        value = Path(f'evidence/{label}-{kind}.exitcode').read_text().strip()
        assert value == '0', f'{label} {kind} exit was {value}'
log = Path('evidence/focused-tests.log').read_text()
names = (
    'responses_custom_tool_keeps_native_input',
    'control_responses_function_with_same_name_keeps_arguments',
    'control_chat_completions_keeps_function_arguments',
    'control_messages_keeps_tool_input',
    'responses_stream_request_still_returns_complete_custom_tool_call',
    'responses_custom_input_preserves_metadata_names_and_escapes',
)
for name in names:
    assert re.search(r'^test decode_custom_tool_regression::' + name + r' \.\.\. ok$', log, re.M), f'missing passing native test: {name}'
assert re.search(r'^test result: ok\. 6 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;', log, re.M)
Path('evidence/result.log').write_text('FIXED_CONFIRMED: formatted original baseline gives 3 passing controls and 1 exact semantic failure; all 6 fixed handler tests, demo clippy, and repository format check pass. The broader four-package protocol test suite was not run.\n')
print(Path('evidence/result.log').read_text(), end='')
PY
