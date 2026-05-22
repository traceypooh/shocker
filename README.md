# shocker
Docker implemented in around 300 lines of bash 🧨

Fork of bocker (github.com/p8952/bocker) updated for 2026.

  * [Prerequisites](#prerequisites)
  * [Example Usage](#example-usage)
  * [Functionality: Currently Implemented](#functionality-currently-implemented)
  * [Functionality: Not Yet Implemented](#functionality-not-yet-implemented)
  * [License](#license)

## Prerequisites

The following packages are needed to run shocker.

* btrfs-progs
* curl
* python3
* iproute2
* iptables
* libcgroup-tools
* util-linux
* coreutils

Additionally your system will need to be configured with the following:

* A `btrfs` filesystem mounted under `/var/shocker` (see below for setup help)
* A network bridge called `bridge0` and an IP of 10.0.0.1/24 (gets created if missing)
* IP forwarding enabled in `/proc/sys/net/ipv4/ip_forward`
* A firewall routing traffic from `bridge0` to a physical interface.

Even if you meet the above prerequisites you probably still want to **run shocker in a virtual machine**. shocker runs as `root` and among other things needs to make changes to your network interfaces, routing table, and firewall rules. **I can make no guarantees that it won't trash your system**.

## Example Usage

```sh
$ shocker pull centos 7
######################################################################## 100.0%
######################################################################## 100.0%
######################################################################## 100.0%
Created: img_42150

$ shocker images
IMAGE_ID        SOURCE
img_42150       centos:7

$ shocker run img_42150 cat /etc/centos-release
CentOS Linux release 7.1.1503 (Core)

$ shocker ps
CONTAINER_ID       COMMAND
ps_42045           cat /etc/centos-release

$ shocker logs ps_42045
CentOS Linux release 7.1.1503 (Core)

$ shocker rm ps_42045
Removed: ps_42045

$ shocker run img_42150 which wget
which: no wget in (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/bin)

$ shocker run img_42150 yum install -y wget
Installing : wget-1.14-10.el7_0.1.x86_64                                  1/1
Verifying  : wget-1.14-10.el7_0.1.x86_64                                  1/1
Installed  : wget.x86_64 0:1.14-10.el7_0.1
Complete!

$ shocker ps
CONTAINER_ID       COMMAND
ps_42018           yum install -y wget
ps_42182           which wget

$ shocker commit ps_42018 img_42150
Removed: img_42150
Created: img_42150

$ shocker run img_42150 which wget
/usr/bin/wget

$ shocker run img_42150 cat /proc/1/cgroup
...
4:memory:/ps_42152
3:cpuacct,cpu:/ps_42152

$ cat /sys/fs/cgroup/cpu/ps_42152/cpu.shares
512

$ cat /sys/fs/cgroup/memory/ps_42152/memory.limit_in_bytes
512000000

$ SHOCKER_CPU_SHARE=1024 \
	SHOCKER_MEM_LIMIT=1024 \
	shocker run img_42150 cat /proc/1/cgroup
...
4:memory:/ps_42188
3:cpuacct,cpu:/ps_42188

$ cat /sys/fs/cgroup/cpu/ps_42188/cpu.shares
1024

$ cat /sys/fs/cgroup/memory/ps_42188/memory.limit_in_bytes
1024000000
```

## Functionality: Currently Implemented

* `docker build` †
* `docker pull`
* `docker images`
* `docker ps`
* `docker run`
* `docker exec`
* `docker logs`
* `docker commit`
* `docker rm` / `docker rmi`
* Networking
* Quota Support / CGroups

† `shocker init` provides a very limited implementation of `docker build`

## 2026 Modernization
### What broke in bocker and what shocker fixes
- `shocker_pull` → full rewrite for Registry v2
  - The original used Docker's v1 registry API (`index.docker.io/v1/`), which was shut down in 2023. Shocker uses the v2 API with proper OAuth2 Bearer token auth, fetches the manifest (accepting both Docker schema v2 and OCI formats), extracts layer digests, and pulls blobs by digest.
- `cgroups v1 → v2 support`
  - Most modern distros (Ubuntu 22.04+, Fedora 31+, etc.) ship with cgroups v2 unified hierarchy. The original's cgcreate/cgset/cgexec/cgdelete commands only work with v1. Shocker detects the version at startup and uses either:
  - v2: writes directly to `/sys/fs/cgroup/`, maps `cpu.shares` → `cpu.weight`, `memory.limit_in_bytes` → `memory.max`
  - v1: falls back to the original cgroup-tools commands
- UUID space expansion
  - bocker used `shuf -i 42002-42254` — only 252 possible values, almost guaranteed collision if you run a few containers. shocker uses 5 hex digits `($RANDOM * $RANDOM % 0xFFFFF)` = ~1 million values.
- MAC address generation
  - The original's `02:42:ac:11:00$mac` was only a 2-octet suffix from 3 decimal digits, producing malformed MACs. shocker derives a proper 6-octet MAC from 4 hex chars of the UUID.
- `shocker_exec PID` lookup
  - The original's nested `ps | grep | awk | grep` pipeline was fragile and often broke. Replaced with a single `ps -eo pid,args | awk` that matches the unshare process for the container UUID.

### Second pass of fixes/improvements
- **IP derivation** — now uses the full 5-hex-digit UUID value (`16#${uuid} % 253`) rather than just the last 2 hex digits, significantly reducing the chance of two containers getting the same IP
- **MAC address** — zero-pads the UUID to 8 hex digits with `printf '%08x'` then slices into 4 clean `xx` octets; fixes potential truncation with short UUID values and removes fragile `sed` regex
- **`shocker_pull` — manifest list handling** — now accepts manifest list / OCI image index media types, detects which type was returned, then resolves to the correct platform digest (matching `uname -m` normalized to OCI arch names: `amd64`, `arm64`, `arm`) before fetching the actual image manifest; fixes accidentally pulling layers for the wrong architecture
- **`shocker_pull` — config blob fix** — switched from `grep` on raw JSON to `python3` parsing `layers[]` explicitly; the config blob lives under `config` not `layers`, so the old grep was incorrectly including it and causing `tar` to fail on a non-tarball

### Third pass of fixes
- Default tag to `:latest` when omitted
- Registry v2 API with multi-arch manifest list support
- `SHOCKER_REGISTRY` env var for Nexus/mirror pull-through (see below)
- Two-step CDN blob download to work around proxy allowlists
- `btrfs` check with setup instructions (see below)
- `bridge0` + NAT auto-created on first run
- cgroups v2 support with proper quoting in `_cg_exec`
- --mount-proc=<path> fix for proc inside chroot

### Fourth pass of fixes/improvements
- `run --rm` and `run -it` new optional CLI flags features working
- switch DNS resolver from google to cloudflare
- check `btrfs` for non-help screens
- all commands working 🎉🚀

### Things that still require the same host setup as bocker
- `btrfs` filesystem mounted at `/var/shocker` (see below)
- `bridge0` network bridge already configured (or gets created)
- ip / `iptables` for NAT (same as before)
- Running as root 🤠

## btrfs /var/shocker setup
```sh
# 1. Install btrfs tools if needed
apt install -y btrfs-progs   # Debian/Ubuntu

# 2. Create a sparse 10G image file (sparse = no real disk used until written)
truncate -s 10G /var/shocker.img

# 3. Format it
mkfs.btrfs /var/shocker.img

# 4. Mount it
mkdir -p /var/shocker
mount -o loop /var/shocker.img /var/shocker

# 5. Persist across reboots
echo '/var/shocker.img /var/shocker btrfs loop 0 0' >> /etc/fstab
```

## proxy
If your setup requires a http proxy to access docker hub (etc.) you can set that up esp. for
the `shocker pull` like this:
```sh
SHOCKER_REGISTRY=example.com:8080 shocker pull alpine
```

## Functionality: Not Yet Implemented

* Data Volume Containers
* Data Volumes
* Port Forwarding

## License

Copyright (C) 2015 Peter Wilmott

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.


## Understanding containers from scratch
curious to run just `chroot`?

```sh
# setup a chroot dir (*everything* has to get copied in)
mkdir /tmp/myimg
echo hello > /tmp/myimg/hello.txt

# see what shared libs each binary needs (linux-vdso is virtual — kernel provides it, no file to copy)
BINS=(/bin/sh /bin/cat /bin/echo)
for b in "${BINS[@]}"; do ldd "$b"; done

# mirror each lib's directory structure into the chroot, then copy
for b in "${BINS[@]}"; do ldd "$b" | grep -Eo '/[^ ]+'; done | sort -u | \
while IFS= read -r lib; do
  mkdir -p "/tmp/myimg$(dirname "$lib")"
  cp "$lib" "/tmp/myimg$lib"
done

# copy the binaries themselves
mkdir -p /tmp/myimg/bin
cp "${BINS[@]}" /tmp/myimg/bin/

# mount proc so the shell isn't blind, then drop in
mkdir -p /tmp/myimg/proc
mount -t proc proc /tmp/myimg/proc
chroot /tmp/myimg /bin/sh
# exit to leave

# cleanup
umount /tmp/myimg/proc
```

### example run:
```sh
...
chroot /tmp/myimg /bin/sh
mount: (hint) your fstab has been modified, but systemd still uses
       the old version; use 'systemctl daemon-reload' to reload.
# cat hello.txt
hello
# echo hai
hai
# exit
```

### example layout:
```sh
find /tmp/myimg -type f |sort
/tmp/myimg/bin/cat
/tmp/myimg/bin/echo
/tmp/myimg/bin/sh
/tmp/myimg/hello.txt
/tmp/myimg/lib64/ld-linux-x86-64.so.2
/tmp/myimg/lib/x86_64-linux-gnu/libc.so.6
```
