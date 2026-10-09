# A clean eject: GPU removed, modules unloaded, enclosure still connected.
fx_base_healthy
fx_deg2 authorized true
mkdir -p "$EGPU_RUN"
echo "{\"uuid\":\"$FX_DEG2_UUID\",\"bdf\":\"0000:03:00.0\"}" >"$EGPU_RUN/ejected"
