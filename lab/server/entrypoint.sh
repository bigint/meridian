#!/bin/sh
set -e
# A stable identity per server, like a real machine.
[ -s /etc/machine-id ] || tr -d - < /proc/sys/kernel/random/uuid > /etc/machine-id
mkdir -p /root/.ssh && cp /lab/authorized_keys /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A >/dev/null
/usr/sbin/sshd
exec dockerd-entrypoint.sh --insecure-registry registry:5000
