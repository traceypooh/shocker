# Bocker
Docker implemented in around 200 lines of bash.

  * [Prerequisites](#prerequisites)
  * [Example Usage](#example-usage)
  * [Functionality: Currently Implemented](#functionality-currently-implemented)
  * [Functionality: Not Yet Implemented](#functionality-not-yet-implemented)
  * [License](#license)

## Prerequisites

The following packages are needed to run bocker.

* btrfs-progs
* curl
* iproute2
* iptables
* libcgroup-tools
* util-linux >= 2.25.2
* coreutils >= 7.5

Because most distributions do not ship a new enough version of util-linux you will probably need to grab the sources from [here](https://www.kernel.org/pub/linux/utils/util-linux/v2.25/) and compile it yourself.

Additionally your system will need to be configured with the following:

* A btrfs filesystem mounted under `/var/bocker`
* A network bridge called `bridge0` and an IP of 10.0.0.1/24
* IP forwarding enabled in `/proc/sys/net/ipv4/ip_forward`
* A firewall routing traffic from `bridge0` to a physical interface.

For ease of use a Vagrantfile is included which will build the needed environment.

Even if you meet the above prerequisites you probably still want to **run bocker in a virtual machine**. Bocker runs as root and among other things needs to make changes to your network interfaces, routing table, and firewall rules. **I can make no guarantees that it won't trash your system**.

## Example Usage

```sh
$ bocker pull centos 7
######################################################################## 100.0%
######################################################################## 100.0%
######################################################################## 100.0%
Created: img_42150

$ bocker images
IMAGE_ID        SOURCE
img_42150       centos:7

$ bocker run img_42150 cat /etc/centos-release
CentOS Linux release 7.1.1503 (Core)

$ bocker ps
CONTAINER_ID       COMMAND
ps_42045           cat /etc/centos-release

$ bocker logs ps_42045
CentOS Linux release 7.1.1503 (Core)

$ bocker rm ps_42045
Removed: ps_42045

$ bocker run img_42150 which wget
which: no wget in (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/bin)

$ bocker run img_42150 yum install -y wget
Installing : wget-1.14-10.el7_0.1.x86_64                                  1/1
Verifying  : wget-1.14-10.el7_0.1.x86_64                                  1/1
Installed  : wget.x86_64 0:1.14-10.el7_0.1
Complete!

$ bocker ps
CONTAINER_ID       COMMAND
ps_42018           yum install -y wget
ps_42182           which wget

$ bocker commit ps_42018 img_42150
Removed: img_42150
Created: img_42150

$ bocker run img_42150 which wget
/usr/bin/wget

$ bocker run img_42150 cat /proc/1/cgroup
...
4:memory:/ps_42152
3:cpuacct,cpu:/ps_42152

$ cat /sys/fs/cgroup/cpu/ps_42152/cpu.shares
512

$ cat /sys/fs/cgroup/memory/ps_42152/memory.limit_in_bytes
512000000

$ BOCKER_CPU_SHARE=1024 \
	BOCKER_MEM_LIMIT=1024 \
	bocker run img_42150 cat /proc/1/cgroup
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

† `bocker init` provides a very limited implementation of `docker build`

## 2026 Modernization
### What broke in bocker and what shocker fixes
- `bocker_pull` → full rewrite for Registry v2
  - The original used Docker's v1 registry API (`index.docker.io/v1/`), which was shut down in 2023. Shocker uses the v2 API with proper OAuth2 Bearer token auth, fetches the manifest (accepting both Docker schema v2 and OCI formats), extracts layer digests, and pulls blobs by digest.
- `cgroups v1 → v2 support`
  - Most modern distros (Ubuntu 22.04+, Fedora 31+, etc.) ship with cgroups v2 unified hierarchy. The original's cgcreate/cgset/cgexec/cgdelete commands only work with v1. Shocker detects the version at startup and uses either:
  - v2: writes directly to `/sys/fs/cgroup/`, maps `cpu.shares` → `cpu.weight`, `memory.limit_in_bytes` → `memory.max`
  - v1: falls back to the original cgroup-tools commands
- UUID space expansion
  - Bocker used `shuf -i 42002-42254` — only 252 possible values, almost guaranteed collision if you run a few containers. Shocker uses 5 hex digits `($RANDOM * $RANDOM % 0xFFFFF)` = ~1 million values.
- MAC address generation
  - The original's `02:42:ac:11:00$mac` was only a 2-octet suffix from 3 decimal digits, producing malformed MACs. Shocker derives a proper 6-octet MAC from 4 hex chars of the UUID.
- `shocker_exec PID` lookup
  - The original's nested `ps | grep | awk | grep` pipeline was fragile and often broke. Replaced with a single `ps -eo pid,args | awk` that matches the unshare process for the container UUID.

### Things that still require the same host setup as bocker
- `btrfs` filesystem mounted at `/var/shocker`
- `bridge0` network bridge already configured
- ip / iptables for NAT (same as before)
- Running as root

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
