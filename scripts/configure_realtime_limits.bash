#!/usr/bin/env bash

set -euo pipefail

LIMITS_DIR="/etc/security/limits.d"
LIMITS_FILE="$LIMITS_DIR/99-rtsyn.conf"
UDEV_RULES_DIR="/etc/udev/rules.d"
UDEV_RULE_FILE="$UDEV_RULES_DIR/99-rtsyn-cpu-dma-latency.rules"
QOS_GROUP="rtsyn-qos"
RT_PRIORITY_LIMIT="${RTSYN_RTPRIO_LIMIT:-95}"
TARGET_USER="${1:-${USER:-}}"

if ((EUID == 0)); then
    printf 'error: run this script as the user who will run RTSyn, not through sudo\n' >&2
    printf 'the script requests sudo only to install system configuration and add group membership\n' >&2
    exit 1
fi

if [[ -z "$TARGET_USER" ]] || ! getent passwd "$TARGET_USER" >/dev/null; then
    printf 'error: invalid local user: %s\n' "${TARGET_USER:-<empty>}" >&2
    exit 1
fi

if [[ ! "$RT_PRIORITY_LIMIT" =~ ^[0-9]+$ ]] \
    || ((RT_PRIORITY_LIMIT < 1 || RT_PRIORITY_LIMIT > 99)); then
    printf 'error: RTSYN_RTPRIO_LIMIT must be an integer from 1 through 99\n' >&2
    exit 1
fi

for command_name in sudo install getent mktemp udevadm id cmp stat; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'error: required command not found: %s\n' "$command_name" >&2
        exit 1
    fi
done

temporary_file="$(mktemp /tmp/rtsyn-limits.XXXXXX)"
udev_temporary_file="$(mktemp /tmp/rtsyn-cpu-dma-latency.XXXXXX)"
cleanup() {
	rm -f "$temporary_file" "$udev_temporary_file"
}
trap cleanup EXIT INT TERM

printf '%s soft memlock unlimited\n' "$TARGET_USER" >"$temporary_file"
printf '%s hard memlock unlimited\n' "$TARGET_USER" >>"$temporary_file"
printf '%s soft rtprio %s\n' "$TARGET_USER" "$RT_PRIORITY_LIMIT" >>"$temporary_file"
printf '%s hard rtprio %s\n' "$TARGET_USER" "$RT_PRIORITY_LIMIT" >>"$temporary_file"

printf 'SUBSYSTEM=="misc", KERNEL=="cpu_dma_latency", GROUP="%s", MODE="0660"\n' \
    "$QOS_GROUP" >"$udev_temporary_file"

if sudo test -e "$UDEV_RULE_FILE" && ! sudo cmp -s "$udev_temporary_file" "$UDEV_RULE_FILE"; then
    printf 'error: existing udev rule differs from the RTSyn rule: %s\n' "$UDEV_RULE_FILE" >&2
    printf '%s\n' 'Inspect or rename it before rerunning; it was not overwritten.' >&2
    exit 1
fi

printf 'Installing realtime limits for %s in %s...\n' "$TARGET_USER" "$LIMITS_FILE"
sudo install -D -o root -g root -m 0644 "$temporary_file" "$LIMITS_FILE"

printf 'Configuring /dev/cpu_dma_latency access for group %s...\n' "$QOS_GROUP"
sudo groupadd --system --force "$QOS_GROUP"
if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -Fxq "$QOS_GROUP"; then
    sudo usermod -aG "$QOS_GROUP" "$TARGET_USER"
    printf 'Added %s to group %s.\n' "$TARGET_USER" "$QOS_GROUP"
else
    printf '%s is already a member of %s.\n' "$TARGET_USER" "$QOS_GROUP"
fi

sudo install -D -o root -g root -m 0644 "$udev_temporary_file" "$UDEV_RULE_FILE"
sudo udevadm control --reload-rules
if [[ -e /dev/cpu_dma_latency ]]; then
    sudo udevadm trigger --action=change --subsystem-match=misc \
        --sysname-match=cpu_dma_latency
fi

printf '%s\n' 'Installed configuration:'
sudo sed -n '1,20p' "$LIMITS_FILE"
printf '\nInstalled udev rule:\n'
sudo sed -n '1,5p' "$UDEV_RULE_FILE"
printf '\nCurrent QoS device permissions:\n'
if [[ -e /dev/cpu_dma_latency ]]; then
    stat -c '  %A %U:%G %n' /dev/cpu_dma_latency
else
    printf '%s\n' '  /dev/cpu_dma_latency is not present; the udev rule will apply if it appears.'
fi

printf '\nA complete logout and login is required for both group membership and PAM limits to take effect; a new terminal is not sufficient.\n'
printf '%s\n' 'After logging in again, verify:'
printf '%s\n' '  ulimit -Sl   # expected: unlimited'
printf '  ulimit -Sr   # expected: %s\n' "$RT_PRIORITY_LIMIT"
printf '%s\n' '  id -nG      # should include rtsyn-qos'
printf '%s\n' '  test -w /dev/cpu_dma_latency && echo writable'
printf '\nMembers of %s can request low CPU idle-exit latency, which may increase power use.\n' "$QOS_GROUP"
