# config.json pins a different card; the attached 4070 SUPER is not the eGPU.
fx_base_healthy
fx_deg2 authorized true
fx_egpu_nvidia nvidia
fx_nvidia_modules
echo '{"device": {"match": {"vendor": "0x10de", "device": "0x2684"}}}' >"$EGPU_CONFIG"
