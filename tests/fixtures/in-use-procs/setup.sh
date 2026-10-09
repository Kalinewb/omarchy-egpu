# Ready, two apps on the eGPU (one graphics, one compute), Steam running.
fx_base_healthy
fx_hypr_links card1
fx_deg2 authorized true
fx_egpu_nvidia nvidia
fx_nvidia_modules
fx_gpu_proc 4242 G /usr/bin/vkcube 12
fx_gpu_proc 4343 C "/opt/some app/bin/worker" 512
fx_process steam 5000
