# Disposable containers without CoW: hardlink farms + repair

An idea for getting near-free, throwaway containers on systems **without** a copy-on-write
filesystem or overlayfs — eg: [iSH on iOS](README.md#using-shocker-on-ios-ish), where shocker's
"lite" `run` currently runs **in place** (changes persist in the image dir).

Contents:
- [Background: why plain hardlinks aren't enough](#background-why-plain-hardlinks-arent-enough)
- [The idea: two copies, link, run, detect, repair](#the-idea-two-copies-link-run-detect-repair)
- [Sketch](#sketch)
- [Caveats](#caveats)
- [Using less than 2x storage: keep the layer tarballs](#using-less-than-2x-storage-keep-the-layer-tarballs)


## Background: why plain hardlinks aren't enough

`cp -al image/ ctr/` makes a "hardlink farm": every file in `ctr/` is another name for the
**same inode** as in `image/`. It's instant and uses no extra space.

How each kind of write inside the container plays out:

| write inside `ctr/` | effect on `image/` |
|---|---|
| create a new file | none — only exists in `ctr/` |
| `rm` a file | none — only that name is removed |
| **replace** a file (write temp file + `rename()` over it: `apk add`, `sed -i`, most editors) | none — `ctr/` name now points at a new inode |
| **modify in place** (`>>` append, logs, databases, `chmod`/`chown`) | ⚠️ **image is changed** — it's the same inode |

So it's *almost* CoW — just not for in-place writes.
btrfs/APFS clones copy blocks on first write; overlayfs copies the whole file up to its
upper dir when it's opened for writing. A hardlink farm has no such hook.

Making files read-only first doesn't help much: root ignores permission bits, and
`chattr +i` (immutable) also blocks the `rename()`-over that `apk add` relies on.


## The idea: two copies, link, run, detect, repair

We can't *prevent* in-place writes, but we can cheaply **detect** them after the run — and,
with a pristine copy on hand, **repair** them.

Key observation: after a run, any file in `ctr/` that still has **link count > 1** is an inode
shared with the image. If its **ctime** is newer than the run start, it was changed in place
(content writes and `chmod`/`chown` both bump ctime; unlike mtime, programs can't set it back).
Replaced or new files have their own inode (link count 1), so they don't show up.

Setup, once per image pull:
- `alpine1` — pristine copy; **never** run from or linked to
- `alpine2` — a full copy of `alpine1`; the "base" every container links from

Each run:
1. `touch` a start stamp, then `sleep 1` (in case ctime only has 1-second resolution)
2. `cp -al alpine2 alpine3` (start a "container")
3. run in `alpine3` (then container exits)
4. `find alpine3 -links +1 -cnewer stamp` → the in-place-modified (dirty) files
5. for each dirty file: restore `alpine2`'s copy from `alpine1`
6. `rm -rf alpine3` — container gone, `alpine2` is clean again


## Sketch

```bash
#!/usr/bin/env bash
# usage: hardlink-run <pristine-dir> <base-dir> [shocker run args...]
set -o errexit -o nounset -o pipefail

pristine=$1  # eg: alpine1
base=$2      # eg: alpine2
shift 2

ctr="$base.$$"
stamp="$ctr.start"

touch "$stamp"
sleep 1  # in case ctime has only 1-second resolution
cp -al "$base" "$ctr"

shocker run "$@" "./$ctr" || true

# repair: any shared inode changed during the run gets a fresh copy in $base
( cd "$ctr" && find . -links +1 -cnewer "../$stamp" -print0 ) |
  while IFS= read -r -d '' f; do
    [[ -e "$pristine/$f" ]] || continue  # hardlink made inside the container
    echo "repairing: $f" >&2
    rm -f "$base/$f"
    cp -a "$pristine/$f" "$base/$f"
  done

rm -rf "$ctr" "$stamp"
```

Pull side:

```sh
shocker --dest=alpine1 pull alpine
cp -a alpine1 alpine2
```

On Alpine/iSH you may want GNU find (`apk add findutils`) for `-cnewer` and `-print0`.


## Caveats

- **Concurrent runs share in-place writes.** Two containers linked from the same `alpine2` at
  the same time will see each other's in-place changes *during* the run, so they aren't
  isolated from each other. The image is still safe: each run's `find` catches its own dirty
  files, and `alpine1` is never touched.
- **Restore with `rm` + `cp`, not `cp` over the top.** That gives `alpine2` a fresh inode, so
  another container still running keeps its own (dirty) inode instead of seeing a file swap
  under it.
- **ctime has to work properly.** Check that your filesystem (eg: iSH's fakefs) updates
  ctime on writes and `chmod`, and at what resolution.
- **Hardlinks within the image** (rare; Alpine's busybox uses symlinks) become separate files
  in `alpine2` after a repair. That's harmless, but uses a bit more space.
- **Bulletproof but slower:** skip the timestamps and just `rsync -a alpine1/ alpine2/` after
  each run (add `-c` to also catch edits that kept the same size and mtime). rsync writes a temp
  file then renames it, so you get fresh inodes too. It costs a full tree walk every time.


## Storage

| | per image | per container |
|---|---|---|
| in-place run (today) | 1x | 0 — but not disposable |
| `cp -a` before each run | 1x | 1x |
| **`alpine1` + `alpine2` + hardlinks** | **2x** | **~0** (only new/replaced files) |
| **layer tarballs + `alpine2` + hardlinks** (below) | **~1.3–1.5x** | **~0** |


## Using less than 2x storage: keep the layer tarballs

The pristine copy doesn't have to be a second unpacked tree.
The image's **compressed layer blobs** hold the same content and are typically a third to half the unpacked size
(eg: alpine is ~3.5 MB compressed vs ~8 MB unpacked → ~1.4x total instead of 2x).
They can be a little larger if later layers overwrite files from earlier ones, since both
versions are kept.

Today `shocker pull` streams each blob straight into `tar` without saving it
([shocker:214](shocker#L214)). This would mean:

1. **At pull**, also save each layer blob (`layer0.tgz`, `layer1.tgz`, …), plus an index of
   its contents (`tar tzf layerN.tgz > layerN.list`) so a restore doesn't have to decompress
   every layer just to find a path.
2. **At repair**, for each dirty path, search the layers **top-down** (newest first):
   - the first layer that contains the path wins: `rm` it from `alpine2`, then
     `tar xzf layerN.tgz -C alpine2 ./path/to/file` (with matching path prefix)
   - stop early if a layer has a whiteout for it (`.wh.<name>` in the same dir, or an opaque
     `.wh..wh..opq` in a parent). That can't really happen for a dirty file that exists in
     `alpine2`, but the same logic covers it.

More work than a second tree, but a better fit for a phone's limited storage.
