# shocker caveats & design notes

Edge cases & reasoning that don't need to be in the README.

## Known gaps
- **`exec` rootless:** untested, & likely broken. A rootless `shocker exec` re-execs into its own,
  new user namespace, a sibling of the container's, & `nsenter` can't join namespaces from there.
  It would need to skip the re-exec & `nsenter -U` (as the user who owns the container's user
  namespace, who has full rights in it).
- **OCI whiteouts:** `pull` doesn't apply layer deletions (`.wh.*` files, & `.wh..wh..opq` for
  whole-dir replacement), so files a later layer deleted come back.

## Storage auto-pick
With no `--fs=`, shocker uses btrfs only if `$SHOCKER_ROOT` is on btrfs *right now*.  If a btrfs
mount for it hasn't happened yet (boot order, an fstab typo), shocker quietly builds an overlay
store in the underlying dir -- hidden once the mount appears.  If you expect btrfs, check `mount`
or pass `--fs=btrfs`.

## Rootless
- **The re-exec marker:** `SHOCKER_ROOTLESS` (set before re-exec'ing in `unshare`) both marks
  "already in our user namespace" & is read from the environment.  Run as real root w/ it set,
  shocker would run in rootless mode w/o a user namespace.  Unlikely; a private name would rule it
  out.
- **Mounts are private:** every mount of a rootless run lives in its own mount namespace --
  invisible to `findmnt` on the host, & gone when the run exits.  So rootless runs can't leak
  mounts onto the host (rootful ones can, & a leaked one once let `find -delete` wipe a `/dev`).

## prune
- **Orphaned containers:** each `--rm` run takes an `flock` on `.rm/<ps-id>`, inherited by every
  process in the container, so the kernel frees it only once they've *all* exited, however they
  died.  An unlocked `.rm/ps-*` is an orphan.  Kept containers (no `--rm`) never lock, so are
  never pruned.  (Orphans from before this have no lock file: `shocker rm` them by hand.)
- **Replaced images (`_none_`)** are in use if a container's `.overlay/*/lower` names one, or any
  running process's command line names its id (shocker-relay runs & mounts images by id).  Both
  are read once per prune: on a busy host, per-image `pgrep`s add up.  A run starting after that
  can't pick an old image: names resolve to the current one.
- **Half-done pulls** (an `img-*` w/o `shocker/source`, which a pull writes last) are only removed
  when no `shocker pull` is running at all: a directory's mtime doesn't change while files land in
  its subdirs, so a slow pull can look old.
- **Grace period:** nothing changed in the last 3h (default; `shocker prune SECS`) is touched.

## bash gotchas
- **`nullglob`** is on: a glob that matches nothing vanishes, so `grep pattern dir/*/file` w/ no
  matches greps *stdin* (a terminal: hangs), & `grep -r` searches the current dir.  Always add
  `/dev/null` as a file argument.
