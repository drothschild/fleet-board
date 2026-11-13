# Sourced by the supervisor suites. The socket base under /tmp is shared with real services, so a
# suite removes only what its own run created, and only when it is empty (rmdir never deletes content).
socket_base="/tmp/fleet-board-$(id -u)"
socket_base_snapshot() {
  if [ -e "$socket_base" ]; then had_base=1; else had_base=0; fi
  base_before=$(ls -A "$socket_base" 2>/dev/null | tr '\n' ' ')
}
socket_base_cleanup() {
  [ -d "$socket_base" ] || return 0
  for entry in $(ls -A "$socket_base" 2>/dev/null); do
    case " $base_before " in *" $entry "*) ;; *) rmdir "$socket_base/$entry" 2>/dev/null || true ;; esac
  done
  [ "$had_base" = 1 ] || rmdir "$socket_base" 2>/dev/null || true
}
