#!/usr/bin/env bash
# shocker-relay tests -- run as a regular user (needs unprivileged user namespaces):
#   tests/relay.sh
# Runs a first container that makes hop requests from a list, then checks each "resume" status,
# & what landed on the host.  Uses a temp image store (or $SHOCKER_ROOT) & pulls alpine.
set -o nounset -o pipefail
cd "$(dirname "$0")/.."
[[ $(id -u) != 0 ]] || { echo "run as a regular user"; exit 2; }

export SHOCKER_ROOT="${SHOCKER_ROOT:-$(mktemp -d)}"
export PATH="$PWD:$PATH"  # (shocker-relay runs `shocker`)
T=$(mktemp -d)
trap 'rm -rf --one-file-system "$T" "$SHOCKER_ROOT"' EXIT
source tests/lib.sh

shocker pull alpine > /dev/null 2>&1 || { echo "can't pull alpine"; exit 2; }

# a job's dir, another job's (w/ a symlink escaping to it), a read-only dir, & a first-only dir
export JOB_DIR="$T/jobs/42" RO_DIR="$T/ro" FIRST_DIR="$T/first"
mkdir -p "$JOB_DIR" "$T/jobs/43" "$RO_DIR" "$FIRST_DIR"
ln -s "$T/jobs/43" "$JOB_DIR/escape"
cat > "$T/policy" <<'EOF'
allow   image  ^alpine$
allow   flag   ^(--rm|--name|--net|-e|-v|--mount|--tmpfs|-m)$
drop    flag   ^--cpus$
reject  flag   ^--privileged$
drop    vol    ^(/var)?/run/docker\.sock$
ro      vol    ^${RO_DIR}(/|$)
allow   vol    ^${JOB_DIR}(/|$)
# only the first container gets this one
allow   vol    ^${FIRST_DIR}(/|$)  first
allow   env    ^FOO$
EOF

# hop requests: <name> <want status> <docker run args…>
REQS=()
function req() { REQS+=("$1	$2	$(jq -cn '$ARGS.positional' --args -- "${@:3}")"); }
req allowed        0   --rm -v "$JOB_DIR:/job" alpine sh -c 'echo hi > /job/out'
req exit-status    7   --rm alpine sh -c 'exit 7'
req read-only      1   --rm -v "$RO_DIR:/ro" alpine touch /ro/x
req other-job      125 --rm -v "$T/jobs/43:/x" alpine true
req symlink-escape 125 --rm -v "$JOB_DIR/escape:/x" alpine true
req dotdot-escape  125 --rm -v "$JOB_DIR/../43:/x" alpine true
req first-only-vol 125 --rm -v "$FIRST_DIR:/x" alpine true
req image-refused  125 --rm busybox true
req flag-rejected  125 --rm --privileged alpine true
req flag-unknown   125 --rm --hostname h alpine true
req flag-dropped   0   --rm --cpus 2 alpine true
req sock-dropped   0   --rm -v /var/run/docker.sock:/var/run/docker.sock alpine true
req env-allowed    0   --rm -e FOO=bar alpine sh -c '[ "$FOO" = bar ]'
req env-refused    125 --rm -e BAR=1 alpine true
req env-no-value   125 --rm -e FOO alpine true
req tmpfs          0   --rm --tmpfs /scratch alpine sh -c 'echo x > /scratch/f'
req image-mount    0   --rm --mount type=image,source=alpine,destination=/opt/a alpine test -f /opt/a/etc/alpine-release
REQS+=("bad-json	125	not json")
printf '%s\n' "${REQS[@]}" | cut -f1,3 > "$FIRST_DIR/requests"

# the first container: send each request, print its resume status, then exit 3
out=$(shocker-relay --policy="$T/policy" --fifo="$T/fifo" --scratch="$T/scratch" -- \
  --rm --net=none -v "$FIRST_DIR:/first" alpine sh -c '
    while IFS="	" read -r name req; do
      echo "$req" > "$SHOCKER_RELAY_FIFO/ready.fifo"
      read -r _ rc < "$SHOCKER_RELAY_FIFO/resume.fifo"
      echo "RESULT $name $rc"
    done < /first/requests
    exit 3' 2>&1)
rc=$?

check "first container's exit status is the relay's" '[[ $rc == 3 ]]'
for r in "${REQS[@]}"; do
  IFS=$'\t' read -r name want _ <<< "$r"
  got=$(grep -m1 "^RESULT $name " <<< "$out" | cut -d' ' -f3)
  check "hop $name: resume $want" '[[ "$got" == "$want" ]]'
done
check "hop allowed: wrote to its job dir"     '[[ "$(cat "$JOB_DIR/out" 2>/dev/null)" == hi ]]'
check "hop read-only: wrote nothing"          '[[ ! -e "$RO_DIR/x" ]]'
check "refusals are logged w/ the reason"     '[[ "$out" == *"refused: -v $JOB_DIR/escape (real path: $T/jobs/43)"* ]]'
check "drops are logged"                      '[[ "$out" == *"dropping --cpus 2"* ]]'
check "--tmpfs scratch removed"               '[[ -z "$(find "$T/scratch" -type f 2>/dev/null)" ]]'
check "fifos removed"                         '[[ ! -e "$T/fifo/ready.fifo" ]]'
check "no containers left"                    '[[ -z "$(ls -d "$SHOCKER_ROOT"/ps-* 2>/dev/null)" ]]'

# the first container must pass the policy too
out=$(shocker-relay --policy="$T/policy" -- --rm -v "$T/jobs/43:/x" alpine true 2>&1); rc=$?
check "first container refused by the policy" '[[ $rc == 2 && "$out" == *"first container refused"* ]]'

summary
