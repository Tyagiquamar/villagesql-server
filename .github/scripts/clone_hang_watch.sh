#!/bin/bash
# Copyright (c) 2026 VillageSQL Contributors
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, see <https://www.gnu.org/licenses/>.

# Temporary diagnostic for the villagesql/clone.clone_preserves_schema hang in
# the sanitizer job. Not for merging.
#
# Watches every running mysqld_safe. A hang is a mysqld_safe whose error log
# ends with "MySQL Server - end." and has not changed for STALE seconds:
# mysqld_safe normally logs within ~2 s after its child exits. For each hang it
# takes two snapshots STALE seconds apart (to tell "stuck" from "slow"), then
# optionally SIGKILLs the mysqld child to see whether mysqld_safe reacts and so
# the test can move on.
#
# usage: clone_hang_watch.sh <out_dir> [stale_seconds] [kill_after_capture]

out="$1"
stale="${2:-30}"
kill_after="${3:-yes}"
mkdir -p "$out"

declare -A seen
declare -A safe_log

descendants() {
  local p
  for p in $(pgrep -P "$1"); do
    echo "$p"
    descendants "$p"
  done
}

arg_of() {
  sed -n "s/.*--$1=\([^ ]*\).*/\1/p" <<< "$2"
}

# Captures, for mysqld_safe, the server named by its pid file, and all their
# descendants (LSan's leak check runs a tracer as a child of mysqld). The /proc
# state is read before gdb attaches: threads already ptrace-stopped by LSan
# show a nonzero TracerPid, and gdb then fails to attach to them.
snapshot() {
  local safe="$1" dir="$2" pidfile="$3" p t server=""
  mkdir -p "$dir"
  ps -eo pid,ppid,pgid,stat,wchan:32,etime,args --forest > "$dir/ps.txt"
  if [ -f "$pidfile" ]; then
    server=$(cat "$pidfile")
    echo "pid file $pidfile: $server" > "$dir/pidfile.txt"
  else
    echo "pid file $pidfile: missing" > "$dir/pidfile.txt"
  fi
  for p in $(printf '%s\n' "$safe" $server $(descendants "$safe") \
               ${server:+$(descendants "$server")} | sort -un); do
    [ -d "/proc/$p" ] || continue
    {
      echo "### pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline")"
      sudo cat "/proc/$p/status"
      echo "wchan: $(cat "/proc/$p/wchan")"
      echo "fds:"
      sudo ls -l "/proc/$p/fd"
      for t in /proc/"$p"/task/*; do
        echo
        echo "== task ${t##*/} comm=$(cat "$t/comm") wchan=$(cat "$t/wchan")"
        grep -E '^(State|TracerPid):' "$t/status"
        sudo cat "$t/stack"
      done
    } > "$dir/proc_$p.txt" 2>&1
  done
  # gdb second, in its own pass, so it can't disturb the /proc reads above.
  # For mysqld_safe (a shell) the C stack still shows what it waits on.
  for p in $(printf '%s\n' "$safe" $server $(descendants "$safe") \
               ${server:+$(descendants "$server")} | sort -un); do
    [ -d "/proc/$p" ] || continue
    sudo timeout 600 gdb -p "$p" -batch \
      -ex 'info threads' -ex 'thread apply all bt' \
      > "$dir/gdb_$p.txt" 2>&1
  done
}

{
  echo "uname: $(uname -a)"
  echo "nproc: $(nproc)"
  echo "ptrace_scope: $(cat /proc/sys/kernel/yama/ptrace_scope 2>&1)"
  echo "container: $([ -f /.dockerenv ] && echo docker || echo none-detected)"
  echo "cgroup: $(head -3 /proc/1/cgroup)"
  free -g
  gdb --version | head -1
} > "$out/runner_env.txt" 2>&1

echo "watcher started $(date -u +%T), stale=${stale}s kill_after=$kill_after"
while true; do
  for safe in $(pgrep -f '[m]ysqld_safe'); do
    args=$(tr '\0' ' ' < "/proc/$safe/cmdline" 2>/dev/null) || continue
    log=$(arg_of log-error "$args")
    pidfile=$(arg_of pid-file "$args")
    [ -f "$log" ] || continue
    tail -1 "$log" | grep -q 'MySQL Server - end\.' || continue
    age=$(( $(date +%s) - $(stat -c %Y "$log") ))
    [ "$age" -ge "$stale" ] || continue
    key="$safe:$(stat -c %s "$log")"
    [ -n "${seen[$key]}" ] && continue
    seen[$key]=1

    tag="hang_$(date -u +%H%M%S)_$safe"
    echo "HANG $tag: log=$log quiet ${age}s"
    cp "$log" "$out/$tag.err_at_detect"
    snapshot "$safe" "$out/$tag/a" "$pidfile"
    sleep "$stale"
    snapshot "$safe" "$out/$tag/b" "$pidfile"

    if [ "$kill_after" = yes ]; then
      kids=$(printf '%s\n' $(pgrep -P "$safe") \
               $(cat "$pidfile" 2>/dev/null) | sort -u)
      echo "  killing server/children of $safe: ${kids:-none}"
      [ -n "$kids" ] && kill -9 $kids
      sleep 15
      echo "  mysqld_safe $safe alive after kill: $([ -d /proc/$safe ] && echo yes || echo no)"
      cp "$log" "$out/$tag.err_after_kill"
    fi
    echo "  captured $tag"
  done

  # The other explanation: mysqld_safe itself went away silently. Its
  # normal exit logs "mysqld from pid file ... ended", so a log whose
  # mysqld_safe is gone but which still ends at "MySQL Server - end." is
  # suspect.
  for safe in "${!safe_log[@]}"; do
    [ -d "/proc/$safe" ] && continue
    log="${safe_log[$safe]}"
    unset "safe_log[$safe]"
    if tail -1 "$log" | grep -q 'MySQL Server - end\.'; then
      tag="safe_gone_$(date -u +%H%M%S)_$safe"
      echo "MYSQLD_SAFE GONE $tag: log=$log"
      cp "$log" "$out/$tag.err"
      ps -eo pid,ppid,pgid,stat,wchan:32,etime,args --forest > "$out/$tag.ps.txt"
    fi
  done
  for safe in $(pgrep -f '[m]ysqld_safe'); do
    [ -n "${safe_log[$safe]}" ] && continue
    log=$(arg_of log-error "$(tr '\0' ' ' < "/proc/$safe/cmdline" 2>/dev/null)")
    [ -n "$log" ] && safe_log[$safe]="$log"
  done
  sleep 5
done
