# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# Watcher scenario: starts with no eGPU; watch-script.sh (run by the fake
# udevadm monitor) then plugs the DEG2 in, lets bolt authorize it, brings the
# 4070 SUPER up, connects an HDMI monitor the compositor does not pick up, and
# finally yanks the enclosure. Policy egpu-hdmi: only then is a monitor on
# the eGPU's port that the compositor did not light a reason to log out.
fx_base_healthy
echo '{"display":{"policy":"egpu-hdmi"}}' >"$EGPU_CONFIG"
