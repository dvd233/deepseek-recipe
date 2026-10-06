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
main_sha=8bd8534719710fdb57788a7619f7dd032bc47ffc9c141d45c7ba66772c5115de
fixture_sha=d9c693b9e975219aaedfce2514819217ce9115466c8dc53e89909f69c37fc8a3

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
if installed == 'yes':
    assert hashlib.sha256(main.read_bytes()).hexdigest() == main_sha, 'candidate production bytes changed'
    fixture = module.read_bytes()
    assert hashlib.sha256(fixture).hexdigest() == fixture_sha, 'candidate test bytes changed'
    assert hashlib.sha256(fixture[:3926]).hexdigest() == '262022fc069f9b3a574ad282dbc751ca70f91c01896dc13651cb4778b1ec24cb', 'the original verified baseline tests changed'
    assert changed == {str(main)}, f'unexpected tracked changes: {changed}'
else:
    assert line('hash-object', str(main)) == original_main
    assert not changed
    assert not module.exists()
extra = set(git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')) - {''}
allowed_module = {str(module)} if installed == 'yes' else set()
assert all(path in allowed_module or path.startswith('evidence/') for path in extra), f'unexpected untracked source: {extra}'
print(f'SOURCE_BINDING_VERIFIED: installed={installed} sha={sha} tree={tree} lock_blob={lock_blob} candidate_sha256={main_sha} tests_sha256={fixture_sha}')
PY
}
verify_source no | tee evidence/source-before.log
printf '%s  %s\n' "$main_sha" "$proposal/main.rs" "$fixture_sha" "$proposal/decode_custom_tool_regression.rs" | sha256sum --check --strict
cp "$proposal/main.rs" encoding-decoding-demo/src/main.rs
cp "$proposal/decode_custom_tool_regression.rs" encoding-decoding-demo/src/decode_custom_tool_regression.rs
verify_source yes | tee evidence/source-installed.log
{
  printf 'proposal_commit=%s\n' "${GITHUB_SHA:-local-unpublished}"
  rustc +1.97.1 --version
  cargo +1.97.1 --version
  sha256sum Cargo.lock "$proposal/main.rs" "$proposal/decode_custom_tool_regression.rs" "$proposal/run-fixed.sh"
} | tee evidence/provenance.log
git diff -- encoding-decoding-demo/src/main.rs > evidence/candidate.patch
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
run_check focused-tests cargo +1.97.1 test -p encoding-decoding-demo --bin encoding-decoding-demo --locked decode_custom_tool_regression -- --nocapture --test-threads=1
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
Path('evidence/result.log').write_text('FIXED_CONFIRMED: all 6 real demo handler tests, affected demo clippy, and repository format check passed. The broader four-package protocol test suite was not run.\n')
print(Path('evidence/result.log').read_text(), end='')
PY
