# Sourced by sysinfo-collect and sysinfo-menu.
. /etc/sysinfo.conf

# A collection runs under `flock "$LOCK"`, which holds the lock while the
# collector is alive; the kernel drops it when they exit, so a killed
# collector can never leave a stale lock behind.
#
# running: is $LOCK locked? Checked by scanning /proc/locks rather than
# trying the lock, so the probe can never make a real start fail, and
# without forking, so the menu can poll it cheaply. The device:inode key is
# looked up once and redone only if the lock file was replaced, which is
# noticed by comparing it with our open fd 8 on it (a builtin test).
lock_key=
running() {
	if [ -z "$lock_key" ] || ! [ "$LOCK" -ef /proc/self/fd/8 ]; then
		lock_key=
		[ -e "$LOCK" ] || return 1
		exec 8<"$LOCK"
		set -- $(stat -L -c '%d %i' /proc/self/fd/8 2>/dev/null)
		[ -n "$2" ] || return 1
		# st_dev -> "MAJ:MIN" in the hex form /proc/locks uses.
		lock_key=$(printf '%02x:%02x:%s' $((($1 >> 8) & 0xfff)) \
			$((($1 & 0xff) | (($1 >> 12) & 0xfff00))) "$2")
	fi
	while read -r _ type _ _ _ key _; do
		[ "$type" = FLOCK ] && [ "$key" = "$lock_key" ] && return 0
	done </proc/locks
	return 1
}
