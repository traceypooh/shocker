#!/usr/bin/env bash
# Rootless shocker tests -- run as a regular user (needs unprivileged user namespaces):
#   tests/rootless.sh
# Uses a temp image store (or $SHOCKER_ROOT -- not on overlayfs or NFS) & pulls alpine.
set -o nounset -o pipefail
cd "$(dirname "$0")/.."
[[ $(id -u) != 0 ]] || { echo "run as a regular user"; exit 2; }

export SHOCKER_ROOT="${SHOCKER_ROOT:-$(mktemp -d)}"
T=$(mktemp -d)
S=./shocker
trap 'rm -rf --one-file-system "$T" "$SHOCKER_ROOT"' EXIT
source tests/lib.sh

function containers() { ls -d "$SHOCKER_ROOT"/ps-* 2>/dev/null | wc -l; }
function locks()      { ls "$SHOCKER_ROOT"/.rm/ 2>/dev/null | wc -l; }
function img_of()     { $S images | awk -v n="$1" -F'\t+' '$2 == n { print $1 }'; }
function new_ps()     { ls "$SHOCKER_ROOT" | grep ps- | grep -vx "${1:-}" | head -1; }


# ---- an empty store, w/ stdin left open (like a terminal): nothing may wait on it ----
out=$(timeout 10 $S prune 2>&1 < <(sleep 30)); rc=$?
check "empty store: prune returns"             '[[ $rc == 0 ]]'
out=$(timeout 10 $S run --rm alpine true 2>&1 < <(sleep 30)); rc=$?
check "empty store: run by name says no image" '[[ $rc == 1 && "$out" == *"No image named"* ]]'

# ---- pull ----
out=$(timeout 60 $S pull alpine 2>&1 < <(sleep 30))
check "pull: creates an image"                 '[[ "$out" == *"Created: img-"* ]]'
IMG=$(img_of alpine:latest)
check "pull: saves the digest"                 'grep -qE "^sha256:[0-9a-f]{64}$" "$SHOCKER_ROOT/$IMG/shocker/digest"'
out=$($S pull alpine 2>&1)
check "pull: same digest => up to date"        '[[ "$out" == "Up to date: $IMG" ]]'
echo sha256:0 > "$SHOCKER_ROOT/$IMG/shocker/digest"
out=$($S pull alpine 2>&1)
NEW=$(img_of alpine:latest)
check "pull: changed digest => new image"      '[[ -n "$NEW" && "$NEW" != "$IMG" ]]'
check "pull: old image marked _none_"          '[[ "$(< "$SHOCKER_ROOT/$IMG/shocker/source")" == _none_ ]]'
OLD=$IMG IMG=$NEW


# ---- run ----
out=$($S run --rm --net=none alpine echo hello 2>&1)
check "run: by name"                           '[[ "$out" == hello ]]'
out=$($S run --rm --net=none alpine sh -c 'exit 7' 2>&1); rc=$?
check "run: returns the exit status"           '[[ $rc == 7 ]]'
check "run --rm: no container left"            '[[ $(containers) == 0 ]]'
check "run --rm: no lock left"                 '[[ $(locks) == 0 ]]'
out=$($S run --rm --net=none alpine id -u 2>&1)
check "rootless: uid 0 inside"                 '[[ "$out" == 0 ]]'
mkdir "$T/vol"
out=$($S run --rm --net=none -v "$T/vol:/v" alpine touch /v/f 2>&1)
check "-v: writes land on the host, as me"     '[[ -O "$T/vol/f" ]]'
out=$($S run --rm --net=none -v "$T/vol:/v:ro" alpine touch /v/g 2>&1); rc=$?
check "-v :ro: read-only"                      '[[ $rc != 0 && ! -e "$T/vol/g" ]]'
out=$($S run --rm --net=none -v "$T/vol" alpine ls "$T/vol" 2>&1)
check "-v w/o dst: same path inside"           '[[ "$out" == f ]]'
out=$($S run --rm --net=none -v "$T/nope:/x" alpine true 2>&1); rc=$?
check "-v: a missing source is an error"       '[[ $rc != 0 ]]'
out=$($S run --rm --net=none -e FOO=bar alpine sh -c 'echo $FOO $PATH' 2>&1)
check "-e, & the image's ENV"                  '[[ "$out" == "bar /usr/local/sbin:"* ]]'
out=$($S run --rm --net=none alpine sh -c 'ip -o link | wc -l' 2>&1)
check "--net=none: loopback only"              '[[ "$out" == 1 ]]'
out=$($S run --rm --net=none alpine sh -c 'echo x > /dev/null && echo ok' 2>&1)
check "/dev: /dev/null works"                  '[[ "$out" == ok ]]'


# ---- kept containers: ps, logs, commit, rm ----
out=$($S run --net=none alpine sh -c 'echo made > /made; echo logged' 2>&1)
PS=$(new_ps)
out=$($S ps 2>&1)
check "kept: listed by ps"                     '[[ -n "$PS" && "$out" == *"$PS"* ]]'
out=$($S logs "$PS" 2>&1)
check "kept: logs after its run ended"         '[[ "$out" == logged ]]'
out=$($S commit "$PS" "$IMG" 2>&1)
out=$($S run --rm --net=none "$IMG" cat /made 2>&1)
check "commit onto its own image"              '[[ "$out" == made ]]'
out=$($S rm "$PS" 2>&1)
check "rm: container gone"                     '[[ $(containers) == 0 ]]'
out=$($S pull alpine 2>&1)
check "pull after commit: not 'up to date'"    '[[ "$out" == *"Created: img-"* ]]'
IMG=$(img_of alpine:latest)
touch "$T/canary"
out=$(cd "$T" && SHOCKER_ROOT="$T/vol" $OLDPWD/shocker rm .. 2>&1); rc=$?
check "rm: refuses a non-id, eg: .."           '[[ $rc != 0 && -e "$T/canary" ]]'


# ---- prune: replaced images ----
out=$($S prune 2>&1)
check "prune: keeps a just-replaced image"     '[[ -d "$SHOCKER_ROOT/$OLD" ]]'
out=$($S run --net=none "$OLD" true 2>&1)
PS=$(new_ps)
out=$($S prune 0 2>&1)
check "prune: keeps an image w/ a container"   '[[ -d "$SHOCKER_ROOT/$OLD" ]]'
out=$($S rm "$PS" 2>&1)
$S run --rm --net=none -v "$SHOCKER_ROOT/$OLD:/x:ro" "$IMG" sleep 5 > /dev/null 2>&1 &
sleep 2
out=$($S prune 0 2>&1)
check "prune: keeps an image a run mounts"     '[[ -d "$SHOCKER_ROOT/$OLD" ]]'
wait
out=$($S prune 0 2>&1)
check "prune: removes an unused old image"     '[[ ! -d "$SHOCKER_ROOT/$OLD" ]]'
check "prune: keeps the current image"         '[[ -d "$SHOCKER_ROOT/$IMG" ]]'
mkdir -p "$SHOCKER_ROOT/img-0dead/shocker" "$SHOCKER_ROOT/img-0dead/etc"  # (a pull that died)
out=$($S images 2>&1)
check "images: lists a half-done pull, w/o errors" '[[ "$out" == *"img-0dead"*"pull died"* && "$out" != *"No such file"* ]]'
out=$($S prune 2>&1)
check "prune: keeps a recent half-done pull"   '[[ -d "$SHOCKER_ROOT/img-0dead" ]]'
out=$($S prune 0 2>&1)
check "prune: removes an old half-done pull"   '[[ ! -d "$SHOCKER_ROOT/img-0dead" ]]'


# ---- prune: orphaned containers ----
out=$($S run --net=none alpine true 2>&1)  # kept (no --rm): never pruned
KEPT=$(new_ps)
# an --rm run whose shocker dies, but whose container keeps running: not an orphan (yet)
setsid $S run --rm --net=none alpine sleep 6 > /dev/null 2>&1 &
pid=$!
sleep 2
{ kill -9 $pid; wait $pid; } 2>/dev/null
out=$($S prune 0 2>&1)
check "prune: keeps a container still running" '[[ $(containers) == 2 ]]'
sleep 6
out=$($S prune 0 2>&1)
check "prune: removes it once it's done"       '[[ $(containers) == 1 && $(locks) == 0 ]]'
# an --rm run killed outright: SIGKILL to all of it
setsid $S run --rm --net=none alpine sleep 60 > /dev/null 2>&1 &
pid=$!
sleep 2
{ kill -9 -- -$pid; wait $pid; } 2>/dev/null
sleep 1
check "orphan: left behind by SIGKILL"         '[[ $(containers) == 2 ]]'
out=$($S prune 0 2>&1)
check "prune: removes the orphan"              '[[ $(containers) == 1 && $(locks) == 0 ]]'
check "prune: keeps the kept container"        '[[ -d "$SHOCKER_ROOT/$KEPT" ]]'

summary
