# The eject job is running: it holds $EGPU_RUN/lock and names itself.
fx_base_healthy
fx_deg2 authorized true
fx_egpu_nvidia nvidia
fx_nvidia_modules
mkdir -p "$EGPU_RUN"
echo eject >"$EGPU_RUN/job"
flock "$EGPU_RUN/lock" sleep 60 >/dev/null 2>&1 &
fx_bg $!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$EGPU_RUN/lock" true || break; sleep 0.1; done
