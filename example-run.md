# Sample run of what happens with shocker run

Example shown:

```sh
shocker run -it -v /var/example:/ex alpine sh
```

(assumes `shocker pull alpine` has created `/var/shocker/img-75f6c`)

```sh
# setup bridge networking & new network namespace
ip link add dev veth0_ps-3b157 type veth peer name veth1_ps-3b157
ip link set dev veth0_ps-3b157 up
ip link set veth0_ps-3b157 master bridge0
# create /run/netns/netns_ps-3b157 as bind mount to new network namespace
ip netns add netns_ps-3b157
ip link set veth1_ps-3b157 netns netns_ps-3b157
nsenter --net=/run/netns/netns_ps-3b157 ip link set dev lo up
nsenter --net=/run/netns/netns_ps-3b157 ip link set veth1_ps-3b157 address 02:42:00:03:b1:57
nsenter --net=/run/netns/netns_ps-3b157 ip addr add 10.0.0.140/24 dev veth1_ps-3b157
nsenter --net=/run/netns/netns_ps-3b157 ip link set dev veth1_ps-3b157 up
nsenter --net=/run/netns/netns_ps-3b157 ip route add default via 10.0.0.1


# create disposable CoW "container" dir from already unpacked "image" dir
btrfs subvolume snapshot /var/shocker/img-75f6c /var/shocker/ps-3b157


# use host's DNS resolving
mkdir -p /var/shocker/ps-3b157/etc
cp /etc/resolv.conf /var/shocker/ps-3b157/etc/resolv.conf


# cgroup setup
mkdir -p /sys/fs/cgroup/ps-3b157
echo '+cpu +memory' >> /sys/fs/cgroup/cgroup.subtree_control
echo 39  > /sys/fs/cgroup/ps-3b157/cpu.weight
echo 536870912 > /sys/fs/cgroup/ps-3b157/memory.max


# execution chain (each line hands off to the next via exec):

# 1. place this shell in the cgroup, then exec the rest
echo $$ > /sys/fs/cgroup/ps-3b157/cgroup.procs

# 2. enter the container's network namespace (no mount side-effects)
nsenter --net=/run/netns/netns_ps-3b157

# 3. create new mount / UTS / IPC / PID namespaces
unshare -fmuip --propagation unchanged

# 4. inside the new mount namespace, before chroot
mount -t devtmpfs devtmpfs /var/shocker/ps-3b157/dev
mount -n -t proc proc      /var/shocker/ps-3b157/proc

# -v mounts: bind host path into container
mkdir -p                   /var/shocker/ps-3b157/ex
mount --bind /var/example  /var/shocker/ps-3b157/ex

# 5. drop into the container root and run the `sh` command
chroot /var/shocker/ps-3b157 \
  /bin/sh -c 'cd "/" && exec "$@"' -- sh
```
