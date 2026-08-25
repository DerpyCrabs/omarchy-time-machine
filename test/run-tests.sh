#!/usr/bin/env bash
# Regression suite for omarchy-time-machine.
#
# Runs entirely against a throwaway restic repository in a temporary
# directory, with XDG_CONFIG_HOME and XDG_STATE_HOME redirected there, so it
# can never touch a real configuration or a real backup.
#
# Beyond "does it work", this suite pins down the properties that are easy to
# break and expensive to discover in production: that status costs no secret,
# that a planted symlink cannot redirect a write, that input coming back from
# the widget is refused rather than repaired, and that a --json command emits
# nothing but JSON on stdout.
#
#   test/run-tests.sh

set -uo pipefail

CLI="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/omarchy-time-machine"
WORK="$(mktemp -d)"
# No desktop notifications from a test run. Without this the suite fires real
# sticky notifications at whoever happens to be logged in, and they have to
# dismiss each one by hand.
export OMARCHY_TIME_MACHINE_QUIET=1
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"

PASSED=0
FAILED=0

cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

ok()   { PASSED=$((PASSED + 1)); printf '  \033[32mpass\033[0m  %s\n' "$1"; }
no()   { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
check(){ if [ "$1" = "0" ]; then ok "$2"; else no "$2"; fi; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- fixture ---------------------------------------------------------------

mkdir -p "$XDG_CONFIG_HOME/omarchy-time-machine" "$WORK/repo" "$WORK/src/docs" "$WORK/src/pics"
echo "hello" > "$WORK/src/docs/note.txt"
echo "report" > "$WORK/src/docs/report.md"
head -c 200000 /dev/urandom > "$WORK/src/pics/photo.bin"
echo "should not be backed up" > "$WORK/src/.env"
echo ".env" > "$WORK/excludes.txt"

cat > "$XDG_CONFIG_HOME/omarchy-time-machine/config.json" <<JSON
{
  "version": 1,
  "source": "$WORK/src",
  "exclude_file": "$WORK/excludes.txt",
  "retention": { "daily": 7, "weekly": 4, "monthly": 12, "yearly": 3 },
  "destinations": [
    { "name": "test", "repository": "$WORK/repo", "schedule": "*-*-* 03:00:00" }
  ]
}
JSON

# --- before there is a key -------------------------------------------------

group "Without a key"

$CLI status --json | jq -e '.configured == true' >/dev/null 2>&1
check $? "status works with no key and no network"

# Output is captured first: under `set -o pipefail` the status of
# `cmd | grep` is the command's, not grep's, and every one of these commands
# exits non-zero on purpose.
OUT="$($CLI backup --dest test 2>&1)"
grep -q "key set --dest test" <<<"$OUT"
check $? "a missing key names the command that fixes it"

# --- setup -----------------------------------------------------------------

group "Setup"

printf 'test-password\n' | $CLI key set --dest test >/dev/null 2>&1
check $? "key set"

[ "$(stat -c %a "$XDG_CONFIG_HOME/omarchy-time-machine/test.key")" = "600" ]
check $? "the key file is 600"

[ "$(stat -c %a "$XDG_CONFIG_HOME/omarchy-time-machine")" = "700" ]
check $? "the config directory is 700"

$CLI init --dest test >/dev/null 2>&1
check $? "init creates the repository"

# --- backup ----------------------------------------------------------------

group "Backup"

$CLI backup --dest test >/dev/null 2>&1
check $? "backup exits 0"

STATUS="$XDG_STATE_HOME/omarchy-time-machine/status.json"
jq -e '.destinations.test.last_run.result == "ok"' "$STATUS" >/dev/null 2>&1
check $? "status.json records the result"

jq -e '.destinations.test.last_run.duration_seconds >= 0' "$STATUS" >/dev/null 2>&1
check $? "duration is computed (jq cannot parse date -Iseconds, so epochs are stored too)"

jq -e '.destinations.test.snapshot_count >= 1 and .destinations.test.repo_size_bytes > 0' "$STATUS" >/dev/null 2>&1
check $? "snapshot count and repository size are recorded"

[ "$($CLI snapshots --dest test --json | jq -r '.snapshots[0].summary.total_files_processed')" = "3" ]
check $? "the exclude file is honoured (.env stayed out)"

# --- reading the repository ------------------------------------------------

group "Reading"

SNAP="$($CLI snapshots --dest test --json | jq -r '.snapshots[0].id')"

[ "$($CLI ls --dest test --snapshot "$SNAP" --path "$WORK/src" --json | jq -r '[.entries[].name] | join(",")')" = "docs,pics" ]
check $? "ls returns direct children only, directories first"

$CLI restore --dest test --snapshot "$SNAP" --path "$WORK/src/docs/report.md" --target "$WORK/restored" >/dev/null 2>&1
[ "$(cat "$WORK/restored$WORK/src/docs/report.md" 2>/dev/null)" = "report" ]
check $? "restore writes the file into the target directory"

# --- input validation ------------------------------------------------------
#
# Snapshot ids and paths travel from the widget back into restic. They are
# treated as input: refused on the wrong shape rather than repaired.

group "Input validation"

$CLI ls --dest test --snapshot "../../etc/passwd" --path /tmp --json | jq -e '.ok == false' >/dev/null 2>&1
check $? "a path-traversal snapshot id is refused"

$CLI ls --dest test --snapshot "$SNAP" --path "relative/path" --json | jq -e '.ok == false' >/dev/null 2>&1
check $? "a relative path is refused"

$CLI restore --dest test --snapshot "zzz" --path /tmp --json | jq -e '.ok == false' >/dev/null 2>&1
check $? "restore refuses an invalid id (die inside \$( ) would only kill a subshell)"

# --- stdout discipline -----------------------------------------------------
#
# The widget parses stdout. A stray progress line there is indistinguishable
# from a crashed script, which is exactly what a pre_command once caused.

group "stdout discipline"

CONFIG="$XDG_CONFIG_HOME/omarchy-time-machine/config.json"
cp "$CONFIG" "$WORK/config.bak"
jq '.destinations[0].pre_command = "echo noise from pre_command"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

$CLI snapshots --dest test --json 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1
check $? "a pre_command does not pollute JSON on stdout"

cp "$WORK/config.bak" "$CONFIG"

# --- file safety -----------------------------------------------------------

group "File safety"

echo "MUST SURVIVE" > "$WORK/victim.txt"
rm -f "$STATUS"
ln -s "$WORK/victim.txt" "$STATUS"
$CLI backup --dest test >/dev/null 2>&1
[ "$(cat "$WORK/victim.txt")" = "MUST SURVIVE" ]
check $? "a symlink planted on status.json cannot redirect the write"

[ ! -L "$STATUS" ]
check $? "and the planted symlink is removed"

# Dotfiles managed with stow are symlinks by design. Strictness that refuses
# them would break an ordinary setup, so paths the user names are followed.
mkdir -p "$WORK/dotfiles"
cp "$CONFIG" "$WORK/dotfiles/config.json"
rm "$CONFIG"
ln -s "$WORK/dotfiles/config.json" "$CONFIG"

$CLI status --json | jq -e '.configured == true' >/dev/null 2>&1
check $? "a stowed (symlinked) config.json is read"

$CLI backup --dest test >/dev/null 2>&1
check $? "and a backup runs with it"

[ -L "$CONFIG" ]
check $? "and it is not swept away by the directory hardening"

rm -f "$CONFIG"
cp "$WORK/dotfiles/config.json" "$CONFIG"

# --- configuration errors --------------------------------------------------

group "Configuration errors"

jq '.destinations[0].password_command = "echo x"
    | .destinations[0].password_file = "'"$XDG_CONFIG_HOME"'/omarchy-time-machine/test.key"' \
  "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
OUT="$($CLI backup --dest test 2>&1)"
grep -q "pick one" <<<"$OUT"
check $? "setting both password sources is refused rather than silently resolved"
cp "$WORK/config.bak" "$CONFIG"

jq '.exclude_file = "/nope/missing.txt"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI backup --dest test >/dev/null 2>&1
[ "$(find "$XDG_STATE_HOME/omarchy-time-machine" -maxdepth 1 -name '.summary.*' | wc -l)" = "0" ]
check $? "a failing run leaves no scratch files behind"
cp "$WORK/config.bak" "$CONFIG"

# --- failure handling ------------------------------------------------------

group "Failure handling"

jq --arg r "$WORK/does-not-exist" \
   --arg c "printf hooked > $WORK/hook.txt" \
   '.destinations[0].repository = $r | .on_failure_command = $c' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
rm -f "$WORK/hook.txt"

$CLI backup --dest test >/dev/null 2>&1
jq -e '.destinations.test.last_run.result == "failed"' "$STATUS" >/dev/null 2>&1
check $? "a failed run is recorded as failed"

$CLI report-failure --dest test >/dev/null 2>&1
sleep 1
[ -f "$WORK/hook.txt" ]
check $? "the OnFailure path runs on_failure_command"

# The reason, not the exit code. restic reports fatal errors as JSON on stderr
# when --json is set, so it lands in the log rather than in the stdout stream
# and has to be dug back out of there.
jq -e '.destinations.test.last_run.error | test("repository does not exist")' \
  "$STATUS" >/dev/null 2>&1
check $? "a failure records why it failed, in restic's own words"

jq -e '.destinations.test.last_run.error | test("^Fatal") | not' "$STATUS" >/dev/null 2>&1
check $? "and without restic's Fatal: prefix"

$CLI status --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "status still emits valid JSON after a failure"

cp "$WORK/config.bak" "$CONFIG"

# --- staleness -------------------------------------------------------------

group "Progress staleness"

PROGRESS="$XDG_STATE_HOME/omarchy-time-machine/progress-test.json"
jq '.state = "running" | .updated_epoch = (now - 600 | floor)' "$PROGRESS" > "$PROGRESS.n" && mv "$PROGRESS.n" "$PROGRESS"
$CLI status --json | jq -e '.destinations[0].running == false' >/dev/null 2>&1
check $? "a progress file older than the threshold is not treated as a running backup"

jq '.state = "running" | .updated_epoch = (now | floor)' "$PROGRESS" > "$PROGRESS.n" && mv "$PROGRESS.n" "$PROGRESS"
$CLI status --json | jq -e '.destinations[0].running == true' >/dev/null 2>&1
check $? "a fresh progress file is"

# --- systemd ---------------------------------------------------------------

group "systemd units"

$CLI install >/dev/null 2>&1
for unit in "omarchy-time-machine@.service" "omarchy-time-machine-failed@.service" "omarchy-time-machine@test.timer"; do
  [ -f "$XDG_CONFIG_HOME/systemd/user/$unit" ]
  check $? "install writes $unit"
done

grep -q "SuccessExitStatus=3" "$XDG_CONFIG_HOME/systemd/user/omarchy-time-machine@.service"
check $? "the service treats restic exit 3 as success, not as a nightly failure"

# install exits non-zero here because systemd cannot enable a unit under a
# redirected XDG_CONFIG_HOME. What is under test is that it rewrites nothing.
OUT="$($CLI install 2>&1)"
[ "$(grep -c 'unchanged' <<<"$OUT")" = "3" ]
check $? "install rewrites nothing on a second run"

if command -v systemd-analyze >/dev/null 2>&1; then
  (cd "$XDG_CONFIG_HOME/systemd/user" && systemd-analyze --user verify ./omarchy-time-machine@.service >/dev/null 2>&1)
  check $? "systemd accepts the generated service"
fi

# --- multiple destinations -------------------------------------------------

group "Multiple destinations"

cp "$WORK/config.bak" "$CONFIG"
mkdir -p "$WORK/repo-b"
jq --arg r "$WORK/repo-b" '
  .destinations += [{name:"second", repository:$r, retention:{daily:2, weekly:1}}]' \
  "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

printf 'second-password\n' | $CLI key set --dest second >/dev/null 2>&1
$CLI init --dest second >/dev/null 2>&1
$CLI backup --dest second >/dev/null 2>&1
check $? "a second destination backs up independently"

[ "$($CLI status --json | jq -r '[.destinations[].name] | join(",")')" = "test,second" ]
check $? "status reports every destination"

# Every scheduled destination gets its own timer, whichever one is "active".
# Somebody with two destinations expects both to run overnight, and reading
# "active" as "the one that runs" would be a quiet way to lose half a backup
# strategy.
jq '.destinations[0].schedule = "*-*-* 03:00:00"
    | .destinations[1].schedule = "*-*-* 04:00:00"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI install >/dev/null 2>&1
[ -f "$XDG_CONFIG_HOME/systemd/user/omarchy-time-machine@test.timer" ] \
  && [ -f "$XDG_CONFIG_HOME/systemd/user/omarchy-time-machine@second.timer" ]
check $? "each scheduled destination gets its own timer, active or not"
jq 'del(.destinations[].schedule)' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

# Per-destination retention overrides the global block key by key, rather than
# replacing it: `second` sets daily and weekly and inherits monthly and yearly.
grep -qh "keep 2 daily, 1 weekly, 12 monthly, 3 yearly" "$XDG_STATE_HOME/omarchy-time-machine/logs/second/"*.log
check $? "per-destination retention overrides key by key, not wholesale"

# A destination pointing at nothing must not take the others down with it.
jq '.destinations += [{name:"broken", repository:"/nonexistent/repo"}]' \
  "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI status --json | jq -e '.ok == true and (.destinations | length) == 3' >/dev/null 2>&1
check $? "a broken destination does not break status for the rest"

cp "$WORK/config.bak" "$CONFIG"

# --- labels and failure reporting ------------------------------------------

group "Labels and failure state"

cp "$WORK/config.bak" "$CONFIG"
jq '.destinations[0].display_name = "The Big Disk"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
[ "$($CLI status --json | jq -r '.destinations[0].display_name')" = "The Big Disk" ]
check $? "display_name is reported separately from the identifier"

[ "$($CLI status --json | jq -r '.destinations[0].name')" = "test" ]
check $? "and the identifier is unchanged, so units and key files keep their names"

cp "$WORK/config.bak" "$CONFIG"
[ "$($CLI status --json | jq -r '.destinations[0].display_name')" = "test" ]
check $? "without display_name it falls back to the name"

# A failure must not erase the record of the last good backup: how stale your
# files now are is the thing you actually need after one.
jq --arg r "$WORK/gone" '.destinations[0].repository = $r' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI backup --dest test >/dev/null 2>&1
jq -e '.destinations.test.last_success_at != null and .destinations.test.last_run.result == "failed"' \
  "$STATUS" >/dev/null 2>&1
check $? "a failed run keeps the previous last_success_at"
cp "$WORK/config.bak" "$CONFIG"

# --- saving the key to 1Password -------------------------------------------
#
# Stubbed, because a test suite has no business touching somebody's vault. What
# is under test is the part that can leak: the secret must reach op on stdin,
# never as an argument, and the note that goes with it must not carry a
# password of its own.

group "Saving the key to 1Password"

mkdir -p "$WORK/stub"
cat > "$WORK/stub/op" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "vault list") echo '[{"name":"Private"}]' ;;
  "item get") exit 1 ;;
  "item create") printf '%s' "$*" > "$OP_ARGV"; cat > "$OP_CAPTURE"; exit 0 ;;
esac
STUB
chmod +x "$WORK/stub/op"

jq '.destinations[0].repository = "sftp:me:hunter2@nas:/volume1/backup"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
OP_ARGV="$WORK/op-argv" OP_CAPTURE="$WORK/op-stdin" PATH="$WORK/stub:$PATH" \
  $CLI key save-1password --dest test >/dev/null 2>&1

grep -q "test-password" "$WORK/op-argv" 2>/dev/null && false || true
check $? "the key never appears in op's arguments"

jq -e '.fields[0].value == "test-password"' "$WORK/op-stdin" >/dev/null 2>&1
check $? "it travels on stdin inside the item template"

grep -q "hunter2" "$WORK/op-stdin" 2>/dev/null && false || true
check $? "and the note names the destination without its password"

# op that is present but not signed in must fail immediately. A backup tool
# that can sit waiting on an authentication prompt is worse than one that stops.
cat > "$WORK/stub/op" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "vault" ] && { echo "not signed in" >&2; exit 1; }
sleep 300
STUB
chmod +x "$WORK/stub/op"
START="$(date +%s)"
PATH="$WORK/stub:$PATH" $CLI key save-1password --dest test >/dev/null 2>&1
[ "$(( $(date +%s) - START ))" -lt 5 ]
check $? "a 1Password that will not answer fails fast instead of hanging"

cp "$WORK/config.bak" "$CONFIG"

# --- listing destinations ---------------------------------------------------

group "Listing destinations"

OUT="$($CLI destinations 2>&1)"
grep -q "NAME" <<<"$OUT" && grep -q "test" <<<"$OUT"
check $? "destinations prints a readable table by default"

# Reads config and the local state file only. Somebody checking what they have
# should not have to wait on a sleeping NAS, or plug the drive back in.
jq '.destinations[0].repository = "sftp:nobody@203.0.113.1:/nowhere"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
START="$(date +%s)"
$CLI destinations >/dev/null 2>&1
[ "$(( $(date +%s) - START ))" -lt 3 ]
check $? "and answers instantly with an unreachable destination"
cp "$WORK/config.bak" "$CONFIG"

$CLI destinations --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "--json still gives the widget its machine-readable form"

# --- a broken configuration ------------------------------------------------
#
# A config that exists but is wrong used to be indistinguishable from one that
# is missing, so the panel offered to create a file that was already there and
# said nothing about what was wrong with it.

group "Broken configuration"

cp "$CONFIG" "$WORK/config.good"

jq 'del(.destinations[0].name) | .destinations[0].display_name = "The Big Disk"' \
  "$WORK/config.good" > "$CONFIG"
$CLI status --json | jq -e '.configured == false and .invalid == true' >/dev/null 2>&1
check $? "a destination without a name reports invalid, not missing"

$CLI status --json | jq -e '.error | test("display_name")' >/dev/null 2>&1
check $? "and the message points at the mistake somebody actually makes"

echo 'not json at all' > "$CONFIG"
$CLI status --json | jq -e '.invalid == true' >/dev/null 2>&1
check $? "unparseable JSON reports invalid too"

rm -f "$CONFIG"
$CLI status --json | jq -e '.configured == false and .invalid == false' >/dev/null 2>&1
check $? "a missing file is reported as missing, not broken"

cp "$WORK/config.good" "$CONFIG"
$CLI status --json | jq -e '.configured == true and .invalid == false' >/dev/null 2>&1
check $? "and a good one is neither"

# --- starter configuration -------------------------------------------------

group "Starter configuration"

CONFIG_BACKUP="$WORK/config.keep"
cp "$CONFIG" "$CONFIG_BACKUP"
rm -f "$CONFIG"

$CLI config create >/dev/null 2>&1
jq -e '.destinations[0].repository | test("CHANGE-ME")' "$CONFIG" >/dev/null 2>&1
check $? "config create writes a starter file with an unmistakable placeholder"

[ "$(stat -c %a "$CONFIG")" = "600" ]
check $? "and it is not world readable"

# Refusing to overwrite matters more here than anywhere else: the file it would
# replace holds the only pointer to somebody's backups.
BEFORE="$(cat "$CONFIG")"
$CLI config create >/dev/null 2>&1
[ "$(cat "$CONFIG")" = "$BEFORE" ]
check $? "running it again leaves an existing configuration alone"

cp "$CONFIG_BACKUP" "$CONFIG"

# --- demo mode -------------------------------------------------------------
#
# Screenshots must never show a real home directory, and a click while posing
# must not reach a real repository.

group "Demo mode"

$CLI demo on >/dev/null 2>&1
[ "$($CLI status --json | jq -r '[.destinations[].name] | join(",")')" = "nas,usb,offsite" ]
check $? "demo mode serves invented destinations"

OUT="$($CLI backup --dest test 2>&1)"
grep -q "refusing to run a real backup" <<<"$OUT"
check $? "demo mode makes backup a no-op"

$CLI demo off >/dev/null 2>&1
[ "$($CLI status --json | jq -r '[.destinations[].name] | join(",")')" = "test" ]
check $? "turning demo off restores the real configuration"

# --- result ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = "0" ]
