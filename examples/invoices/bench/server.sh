# The Cepheus server of the measures, in OUT/srv, sourced by the scripts of bench/ with srv and out set: serve starts
# it (and waits for its ready line), stop stops it, and each script stops what it started when it ends (trap). Its
# descriptors above 2 are closed: a server started under a lock (flock) must not keep the lock open after the script.
B=cepheus
serve() {
  setsid $B serve --config "$srv/cluster.toml" < /dev/null >> "$out/serve.log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
  echo $! > "$out/serve.pid"
  for _ in $(seq 200); do [ "$(grep -c ready "$out/serve.log")" -gt "${1:-0}" ] && return 0; sleep 0.02; done
  echo "the server did not start"; exit 1
}
stop() {  # the server of this folder only, by its pid and its command
  [ -f "$out/serve.pid" ] || return 0
  p=$(cat "$out/serve.pid")
  grep -q "$srv/cluster.toml" "/proc/$p/cmdline" 2>/dev/null || return 0
  kill "$p"
  while kill -0 "$p" 2>/dev/null; do sleep 0.02; done
}
# serve_seeded: the server on the seeded data, started here unless it runs already; stopped at the end if started here
serve_seeded() {
  if [ -f "$out/serve.pid" ] && grep -q "$srv/cluster.toml" "/proc/$(cat "$out/serve.pid")/cmdline" 2>/dev/null; then return 0; fi
  serve "$(grep -c ready "$out/serve.log" 2>/dev/null || echo 0)"
  started_here=1
}
