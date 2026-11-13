#!/bin/sh
# labs/m11/probe-matrix.sh — one fixed, harmless capability probe, run in two Pods
#
# Fed to a Pod over stdin, never copied into it:
#
#   kubectl --context kind-grid-sandbox -n agent-probes exec -i probe-sandbox -c agent -- sh -s < m11/probe-matrix.sh
#   kubectl --context kind-grid-sandbox -n agent-probes exec -i probe-plain   -c agent -- sh -s < m11/probe-matrix.sh
#
# Pass probe names after `--` to run only those:
#
#   kubectl ... exec -i probe-sandbox -c agent -- sh -s -- outbound < m11/probe-matrix.sh
#
# POSIX sh and busybox applets only, because both Pods run the same busybox
# image. It prints one line per probe, `probe=<name> result=<what happened>`,
# in a fixed order, so the two runs line up row for row.
#
# HARMLESS BY DESIGN. Every probe either reads a file, opens and closes one
# TCP connection, sends one ICMP echo to the Pod's own loopback, or mounts an
# empty tmpfs on a fresh empty directory and unmounts it straight away. Nothing
# is written outside that directory, which is removed again, nothing is sent to
# any host beyond a TCP handshake, and nothing is left running.
#
# WHAT THIS DOES NOT PROVE. Where the two runs differ, the runtime presented a
# different surface to the workload. That is a capability differential, and a
# capability differential is not proof of isolation. Kernel escapes, side
# channels and the supply chain of the image are not tested here at all.

PROBES="${*:-kernel-version proc-sys-kernel-entries host-kernel-symbols raw-socket privileged-op cloud-metadata kubernetes-api outbound}"

# First line of a command's error output, with spaces made safe for one field.
# busybox ping prints its `PING ...` banner before it fails, so the banner is
# skipped: the course's first run of this probe recorded the banner as the
# "error" and lost the refusal itself.
first_err() {
  grep -v '^PING ' | sed -n '1p' | tr ' ' '_' | cut -c1-60
}

probe_kernel_version() {
  # The third field of /proc/version is the kernel release string.
  r="$(cut -d' ' -f3 /proc/version 2>/dev/null)"
  echo "probe=kernel-version result=${r:-unreadable}"
}

probe_proc_sys_kernel_entries() {
  n="$(ls /proc/sys/kernel 2>/dev/null | wc -l | tr -d ' ')"
  echo "probe=proc-sys-kernel-entries result=${n:-0}"
}

probe_host_kernel_symbols() {
  if [ ! -e /proc/kallsyms ]; then
    echo "probe=host-kernel-symbols result=absent"
  elif head -n 1 /proc/kallsyms >/dev/null 2>&1; then
    echo "probe=host-kernel-symbols result=readable"
  else
    echo "probe=host-kernel-symbols result=unreadable"
  fi
}

probe_raw_socket() {
  # busybox ping opens an ICMP socket, raw or datagram. One echo, to loopback.
  if out="$(ping -c 1 -W 2 127.0.0.1 2>&1)"; then
    echo "probe=raw-socket result=ok"
  else
    echo "probe=raw-socket result=failed:$(printf '%s\n' "${out}" | first_err)"
  fi
}

# The mount point is made first. The busybox image has no /mnt, and the course's
# first run mounted onto it: the plain Pod then failed on the missing directory
# rather than on privilege, and the row showed a difference nobody had tested.
probe_privileged_op() {
  d="$(mktemp -d)" || { echo "probe=privileged-op result=failed:mktemp"; return; }
  if out="$(mount -t tmpfs none "${d}" 2>&1)"; then
    umount "${d}" 2>/dev/null
    echo "probe=privileged-op result=ok"
  else
    echo "probe=privileged-op result=failed:$(printf '%s\n' "${out}" | first_err)"
  fi
  rmdir "${d}" 2>/dev/null
}

tcp_probe() {
  # $1 probe name, $2 host, $3 port, $4 timeout seconds
  if nc -z -w "$4" "$2" "$3" >/dev/null 2>&1; then
    echo "probe=$1 result=open"
  else
    echo "probe=$1 result=closed"
  fi
}

probe_kubernetes_api() {
  if [ -s /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    token=mounted
  else
    token=absent
  fi
  if nc -z -w 3 kubernetes.default.svc 443 >/dev/null 2>&1; then
    echo "probe=kubernetes-api result=open token=${token}"
  else
    echo "probe=kubernetes-api result=closed token=${token}"
  fi
}

for p in ${PROBES}; do
  case "${p}" in
    kernel-version)          probe_kernel_version ;;
    proc-sys-kernel-entries) probe_proc_sys_kernel_entries ;;
    host-kernel-symbols)     probe_host_kernel_symbols ;;
    raw-socket)              probe_raw_socket ;;
    privileged-op)           probe_privileged_op ;;
    cloud-metadata)          tcp_probe cloud-metadata 169.254.169.254 80 3 ;;
    kubernetes-api)          probe_kubernetes_api ;;
    outbound)                tcp_probe outbound registry.k8s.io 443 5 ;;
    *)                       echo "probe=${p} result=unknown-probe" ;;
  esac
done
