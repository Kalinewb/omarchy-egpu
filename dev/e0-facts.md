# E0 facts 2026-10-09T23:02:48+02:00

 23:02:48 up 4 days,  7:20,  1 user,  load average: 2.16, 2.31, 3.03
7.2.5-3-omarchy

## boltctl list
 * Micro Computer (HK) Tech. Ltd. TBGAA
   |- type:          peripheral
   |- name:          TBGAA
   |- vendor:        Micro Computer (HK) Tech. Ltd.
   |- uuid:          ba7e8780-0085-dcfa-ffff-ffffffffffff
   |- generation:    USB4
   |- status:        authorized
   |  |- domain:     e6e08780-60a7-e01b-ffff-ffffffffffff
   |  |- rx speed:   40 Gb/s = 2 lanes * 20 Gb/s
   |  |- tx speed:   40 Gb/s = 2 lanes * 20 Gb/s
   |  `- authflags:  none
   |- authorized:    Fri 09 Oct 2026 09:02:32 PM UTC
   |- connected:     Fri 09 Oct 2026 09:02:31 PM UTC
   `- stored:        Fri 25 Sep 2026 05:03:01 PM UTC
      |- policy:     iommu
      `- key:        no


## boltctl info (all)
 * Micro Computer (HK) Tech. Ltd. TBGAA
   |- type:          peripheral
   |- name:          TBGAA
   |- vendor:        Micro Computer (HK) Tech. Ltd.
   |- uuid:          ba7e8780-0085-dcfa-ffff-ffffffffffff
   |- dbus path:     /org/freedesktop/bolt/devices/ba7e8780_0085_dcfa_ffff_ffffffffffff
   |- generation:    USB4
   |- status:        authorized
   |  |- domain:     e6e08780-60a7-e01b-ffff-ffffffffffff
   |  |- parent:     e6e08780-60a7-e01b-ffff-ffffffffffff
   |  |- syspath:    /sys/devices/pci0000:00/0000:00:0d.2/domain0/0-0/0-1
   |  |- rx speed:   40 Gb/s = 2 lanes * 20 Gb/s
   |  |- tx speed:   40 Gb/s = 2 lanes * 20 Gb/s
   |  `- authflags:  none
   |- authorized:    Fri 09 Oct 2026 09:02:32 PM UTC
   |- connected:     Fri 09 Oct 2026 09:02:31 PM UTC
   `- stored:        Fri 25 Sep 2026 05:03:01 PM UTC
      |- policy:     iommu
      `- key:        no


## lspci -tv
-[0000:00]-+-00.0  Intel Corporation Core Ultra 200V Series Processors with 4 P-Cores 4 E-Cores Host Bridge
           +-02.0  Intel Corporation Core Ultra 200V Series Processors Arc Graphics 130V/140V GPU
           +-04.0  Intel Corporation Core Ultra 200V Series Processors Dynamic Tuning Technology (DTT)
           +-07.0-[01-2a]----00.0-[02-2a]--+-00.0-[03]--+-00.0  NVIDIA Corporation AD104 [GeForce RTX 4070 SUPER]
           |                               |            \-00.1  NVIDIA Corporation AD104 High Definition Audio Controller
           |                               +-01.0-[04-10]--
           |                               +-02.0-[11-1d]--
           |                               \-03.0-[1e-2a]--
           +-0a.0  Intel Corporation Core Ultra 200V Series Processors Crash Log and Telemetry
           +-0b.0  Intel Corporation Core Ultra 200V Series Processors NPU
           +-0d.0  Intel Corporation Core Ultra 200V Series Processors Type-C Subsystem xHCI
           +-0d.2  Intel Corporation Core Ultra 200V Series Processors Thunderbolt DMA0
           +-12.0  Intel Corporation Core Ultra 200V Series Processors Integrated Sensor Hub (ISH)
           +-13.0  Intel Corporation Core Ultra 200V Series Processors CSME HECI #1
           +-14.0  Intel Corporation Core Ultra 200V Series Processors Standalone xHCI Controller
           +-14.2  Intel Corporation Core Ultra 200V Series Processors Shared SRAM
           +-14.3  Intel Corporation BE200 Series Wi-Fi 7
           +-15.0  Intel Corporation Core Ultra 200V Series Processors I2C #0
           +-15.2  Intel Corporation Core Ultra 200V Series Processors I2C #2
           +-16.0  Intel Corporation Core Ultra 200V Series Processors CSME HECI #1 (CSE)
           +-19.0  Intel Corporation Core Ultra 200V Series Processors I2C #4
           +-19.1  Intel Corporation Core Ultra 200V Series Processors I2C #5
           +-1c.0-[2b]----00.0  Sandisk Corp WD PC SN5000S M.2 2280 NVMe SSD (DRAM-less)
           +-1e.0  Intel Corporation Core Ultra 200V Series Processors UART #0
           +-1f.0  Intel Corporation Core Ultra 200V Series Processors eSPI Controller
           +-1f.3  Intel Corporation Core Ultra 200V Series Processors HD Audio
           +-1f.4  Intel Corporation Lunar Lake-M SMbus Controller
           \-1f.5  Intel Corporation Core Ultra 200V Series Processors SPI (flash) Controller

## lspci -nnk display
00:02.0 VGA compatible controller [0300]: Intel Corporation Core Ultra 200V Series Processors Arc Graphics 130V/140V GPU [8086:64a0] (rev 04)
	Subsystem: Hewlett-Packard Company Device [103c:8d9f]
	Kernel driver in use: xe
	Kernel modules: xe
00:04.0 Signal processing controller [1180]: Intel Corporation Core Ultra 200V Series Processors Dynamic Tuning Technology (DTT) [8086:641d] (rev 04)
--
03:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD104 [GeForce RTX 4070 SUPER] [10de:2783] (rev a1)
	Subsystem: PNY Device [196e:1423]
	Kernel driver in use: nvidia
	Kernel modules: nouveau, nvidia_drm, nvidia
03:00.1 Audio device [0403]: NVIDIA Corporation AD104 High Definition Audio Controller [10de:22bc] (rev a1)

## nvidia dev sysfs
/sys/bus/pci/devices/0000:03:00.0
class=0x030000
removable=removable
current_link_speed=16.0 GT/s PCIe
current_link_width=4
max_link_speed=16.0 GT/s PCIe
max_link_width=16
driver=cat: '/sys/bus/pci/devices/0000:03:00.0/driver': Is a directory
power/runtime_status=active
lrwxrwxrwx 1 root root 0 Oct  9 23:02 /sys/bus/pci/devices/0000:03:00.0/driver -> ../../../../../../bus/pci/drivers/nvidia
/sys/bus/pci/devices/0000:03:00.1
class=0x040300
removable=removable
current_link_speed=16.0 GT/s PCIe
current_link_width=4
max_link_speed=16.0 GT/s PCIe
max_link_width=16
driver=cat: '/sys/bus/pci/devices/0000:03:00.1/driver': Is a directory
power/runtime_status=active
lrwxrwxrwx 1 root root 0 Oct  9 23:02 /sys/bus/pci/devices/0000:03:00.1/driver -> ../../../../../../bus/pci/drivers/snd_hda_intel

## drm
/dev/dri:
total 0
drwxr-xr-x  2 root root        120 Oct  9 23:02 by-path
crw-rw----+ 1 root video  226,   0 Oct  5 15:43 card0
crw-rw----+ 1 root video  226,   1 Oct  9 23:02 card1
crw-rw-rw-  1 root render 226, 128 Oct  5 15:43 renderD128
crw-rw-rw-  1 root render 226, 129 Oct  9 23:02 renderD129

/dev/dri/by-path:
total 0
lrwxrwxrwx 1 root root  8 Oct  5 15:43 pci-0000:00:02.0-card -> ../card0
lrwxrwxrwx 1 root root 13 Oct  5 15:43 pci-0000:00:02.0-render -> ../renderD128
lrwxrwxrwx 1 root root  8 Oct  9 23:02 pci-0000:03:00.0-card -> ../card1
lrwxrwxrwx 1 root root 13 Oct  9 23:02 pci-0000:03:00.0-render -> ../renderD129
card0-DP-1 status=disconnected enabled=disabled
card0-DP-2 status=disconnected enabled=disabled
card0-eDP-1 status=connected enabled=enabled
card0-HDMI-A-1 status=disconnected enabled=disabled
card1-DP-3 status=disconnected enabled=disabled
card1-DP-4 status=disconnected enabled=disabled
card1-DP-5 status=disconnected enabled=disabled
card1-HDMI-A-2 status=connected enabled=disabled

## modules
nvidia_uvm           3915776  0
nvidia_drm            155648  2
nvidia_modeset       1941504  1 nvidia_drm
nvidia              111702016  3 nvidia_uvm,nvidia_drm,nvidia_modeset
typec_thunderbolt      16384  1
typec                 135168  2 typec_thunderbolt,typec_ucsi
drm_ttm_helper         20480  2 nvidia_drm,xe
ttm                   155648  2 drm_ttm_helper,xe
drm_buddy              12288  1 xe
drm_suballoc_helper    20480  1 xe
drm_gpuvm              57344  1 xe
drm_exec               12288  2 drm_gpuvm,xe
video                  81920  2 xe,nvidia_modeset
drm_gpusvm_helper      61440  1 xe
drm_display_helper    307200  1 xe
cec                   102400  2 drm_display_helper,xe
thunderbolt           626688  1 typec
nvidia refcnt=3
nvidia_modeset refcnt=1
nvidia_uvm refcnt=0
nvidia_drm refcnt=2

## nvidia-drm params
modeset=cat: /sys/module/nvidia_drm/parameters/modeset: Permission denied
fbdev=cat: /sys/module/nvidia_drm/parameters/fbdev: Permission denied

## nvidia-smi (10s timeout)
Fri Oct  9 23:02:49 2026       
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.178.04             Driver Version: 580.178.04     CUDA Version: 13.0     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA GeForce RTX 4070 ...    Off |   00000000:03:00.0 Off |                  N/A |
|  0%   29C    P0             18W /  220W |      33MiB /  12282MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+
rc=0

## hung tasks / D state
    718 D    irq/108-ELAN2514:00
 480984 D<   kworker/u36:11+i915_flip

## dmesg tail (user perms)
dmesg: read kernel buffer failed: Operation not permitted

## journal kernel since plug
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT0: ccs2 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT0: ccs3 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: Using GuC firmware from xe/lnl_guc_70.bin version 70.72.1
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: Using HuC firmware from xe/lnl_huc.bin version 9.4.13
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: Using GSC firmware from xe/lnl_gsc_1.bin version 104.0.5.1429
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vcs1 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vcs2 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vcs3 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vcs4 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vcs5 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vcs6 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vcs7 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vecs1 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vecs2 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: vecs3 fused off
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] DSB 0 poll error
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Registered 3 planes with drm panic
Oct 05 15:43:01 user kernel: [drm] Initialized xe 1.1.0 for 0000:00:02.0 on minor 0
Oct 05 15:43:01 user kernel: fbcon: xedrmfb (fb0) is primary device
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] fb0: xedrmfb frame buffer device
Oct 05 15:43:01 user kernel: xe 0000:00:02.0: [drm] Tile0: GT1: found GSC cv104.1.0
Oct 05 15:43:01 user systemd[1]: Load Kernel Module drm skipped, unmet condition check ConditionKernelModuleLoaded=!drm
Oct 05 15:43:01 user kernel: nvidia: loading out-of-tree module taints kernel.
Oct 05 15:43:01 user kernel: nvidia: module license 'NVIDIA' taints kernel.
Oct 05 15:43:01 user kernel: nvidia: module verification failed: signature and/or required key missing - tainting kernel
Oct 05 15:43:01 user kernel: nvidia: module license taints kernel.
Oct 05 15:43:01 user kernel: nvidia-nvlink: Nvlink Core is being initialized, major device number 235
Oct 05 15:43:01 user kernel: NVRM: No NVIDIA GPU found.
Oct 05 15:43:01 user kernel: nvidia-nvlink: Unregistered Nvlink Core, major device number 235
Oct 05 15:43:01 user kernel: intel_vpu 0000:00:0b.0: [drm] Firmware: intel/vpu/vpu_40xx_v1.bin, version: Jun 30 2026*NPU40xx*build/ci/npu-fw-ci-ci_branch_UD202628_npu_release_26ww25-20260626_085052-f9a611865dbf3e6b37a17a0b01a7e81e7fc812e7-1-g3b431d96211*3b431d96211eb618edf1f7c444daa8185f1e686c
Oct 05 15:43:01 user kernel: intel_vpu 0000:00:0b.0: [drm] Scheduler mode: HW
Oct 05 15:43:01 user kernel: [drm] Initialized intel_vpu 1.0.0 for 0000:00:0b.0 on minor 0
Oct 05 15:48:30 user kernel: xe 0000:00:02.0: Using 41-bit DMA addresses
Oct 05 17:42:10 user kernel: xe 0000:00:02.0: vgaarb: VGA decodes changed: olddecodes=io,decodes=io:owns=io+mem
Oct 05 18:55:39 user kernel: xe 0000:00:02.0: vgaarb: VGA decodes changed: olddecodes=io,decodes=io:owns=io+mem
Oct 06 18:33:13 user kernel: xe 0000:00:02.0: vgaarb: VGA decodes changed: olddecodes=io,decodes=io:owns=io+mem
Oct 06 20:10:45 user kernel: xe 0000:00:02.0: vgaarb: VGA decodes changed: olddecodes=io,decodes=io:owns=io+mem
Oct 07 22:46:41 user kernel: xe 0000:00:02.0: vgaarb: VGA decodes changed: olddecodes=io,decodes=io:owns=io+mem
Oct 09 22:15:51 user kernel: xe 0000:00:02.0: vgaarb: VGA decodes changed: olddecodes=io,decodes=io:owns=io+mem
Oct 09 23:02:31 user kernel: thunderbolt 0-1: new device found, vendor=0x41f device=0xd002
Oct 09 23:02:31 user kernel: thunderbolt 0-1: Micro Computer (HK) Tech. Ltd. TBGAA
Oct 09 23:02:31 user kernel: thunderbolt 0-0:1.1: new retimer found, vendor=0x8087 device=0xd9c
Oct 09 23:02:32 user kernel: pcieport 0000:00:07.0: pciehp: Slot(6): Card present
Oct 09 23:02:32 user kernel: pcieport 0000:00:07.0: pciehp: Slot(6): Link Up
Oct 09 23:02:32 user kernel: pcieport 0000:02:01.0: pciehp: Slot #1 AttnBtn- PwrCtrl- MRL- AttnInd- PwrInd- HotPlug+ Surprise+ Interlock- NoCompl+ IbPresDis- LLActRep+
Oct 09 23:02:32 user kernel: pcieport 0000:02:02.0: pciehp: Slot #2 AttnBtn- PwrCtrl- MRL- AttnInd- PwrInd- HotPlug+ Surprise+ Interlock- NoCompl+ IbPresDis- LLActRep+
Oct 09 23:02:32 user kernel: pcieport 0000:02:03.0: pciehp: Slot #3 AttnBtn- PwrCtrl- MRL- AttnInd- PwrInd- HotPlug+ Surprise+ Interlock- NoCompl+ IbPresDis- LLActRep+
Oct 09 23:02:32 user kernel: input: HDA NVidia HDMI/DP,pcm=3 as /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.1/sound/card1/input44
Oct 09 23:02:32 user kernel: input: HDA NVidia HDMI/DP,pcm=7 as /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.1/sound/card1/input45
Oct 09 23:02:32 user kernel: input: HDA NVidia HDMI/DP,pcm=8 as /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.1/sound/card1/input46
Oct 09 23:02:32 user kernel: input: HDA NVidia HDMI/DP,pcm=9 as /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.1/sound/card1/input47
Oct 09 23:02:33 user kernel: nvidia-nvlink: Nvlink Core is being initialized, major device number 508
Oct 09 23:02:33 user kernel: nvidia 0000:03:00.0: enabling device (0000 -> 0003)
Oct 09 23:02:33 user kernel: nvidia 0000:03:00.0: vgaarb: VGA decodes changed: olddecodes=io+mem,decodes=none:owns=none
Oct 09 23:02:33 user kernel: NVRM: loading NVIDIA UNIX x86_64 Kernel Module  580.178.04  Tue Jul  7 12:38:21 UTC 2026
Oct 09 23:02:33 user kernel: nvidia-modeset: Loading NVIDIA Kernel Mode Setting Driver for UNIX platforms  580.178.04  Tue Jul  7 12:03:04 UTC 2026
Oct 09 23:02:33 user kernel: [drm] [nvidia-drm] [GPU ID 0x00000300] Loading driver
Oct 09 23:02:34 user kernel: [drm] Initialized nvidia-drm 0.0.0 for 0000:03:00.0 on minor 1
Oct 09 23:02:34 user kernel: nvidia 0000:03:00.0: [drm] fb1: nvidia-drmdrmfb frame buffer device
Oct 09 23:02:34 user kernel: nvidia_uvm: module uses symbols nvUvmInterfaceDisableAccessCntr from proprietary module nvidia, inheriting taint.

## hyprland monitors
Monitor eDP-1 (ID 0):
	description: Samsung Display Corp. 0x41AA
	disabled: false

## hyprland log drm lines
/run/user/1000/hypr/efb50993780079460b0cbed1363e2166a2de1d9f_1791207785_610245289/hyprland.log
DEBUG from aquamarine ]: drm: Scanning connector id 141
DEBUG from aquamarine ]: drm: Connector id 141 already initialized
DEBUG from aquamarine ]: drm: Connector 141 connection state: 2
DEBUG from aquamarine ]: drm: Rechecking CRTCs
DEBUG from aquamarine ]: drm: Skipping connector HDMI-A-2, has crtc 64 and is connected
DEBUG from aquamarine ]: drm: connector DP-3, has crtc -1, will be rechecked
DEBUG from aquamarine ]: drm: connector DP-4, has crtc -1, will be rechecked
DEBUG from aquamarine ]: drm: connector DP-5, has crtc -1, will be rechecked
DEBUG from aquamarine ]: drm: slot 0 crtc 64 taken by HDMI-A-2, skipping
DEBUG from aquamarine ]: drm: slot 1 crtc 83 unassigned
DEBUG from aquamarine ]: drm: slot 2 crtc 102 unassigned
DEBUG from aquamarine ]: drm: slot 3 crtc 121 unassigned
DEBUG from aquamarine ]: drm: Initializing secondary renderer on /dev/dri/card1, has enabled outputs
DEBUG from aquamarine ]: Created a GBM allocator with drm fd 250
DEBUG from aquamarine ]: Supported EGL client extensions: (16) EGL_EXT_platform_base EGL_EXT_device_base EGL_EXT_device_enumeration EGL_EXT_device_query EGL_KHR_client_get_all_proc_addresses EGL_EXT_client_extensions EGL_KHR_debug EGL_KHR_platform_x11 EGL_EXT_platform_x11 EGL_EXT_platform_device EGL_MESA_platform_surfaceless EGL_EXT_explicit_device EGL_KHR_platform_wayland EGL_EXT_platform_wayland EGL_KHR_platform_gbm EGL_MESA_platform_gbm EGL_EXT_platform_xcb
ERR from aquamarine ]: [EGL] Command eglQueryDevicesEXT errored out with EGL_BAD_ALLOC (0x12291): EGL_BAD_ALLOC error: In eglQueryDevicesEXT: Failed to allocate device list.
ERR from aquamarine ]: [EGL] Command eglQueryDevicesEXT errored out with EGL_BAD_ALLOC (0x12291): EGL_BAD_ALLOC error: In eglQueryDevicesEXT: Failed to allocate device list.
DEBUG from aquamarine ]: CDRMRenderer(drm): Using device /dev/dri/card1
ERR from aquamarine ]: [EGL] Command eglInitialize errored out with EGL_NOT_INITIALIZED (0x12289): DRI2: failed to create screen
ERR from aquamarine ]: [EGL] Command eglInitialize errored out with EGL_NOT_INITIALIZED (0x12289): DRI2: failed to create screen
ERR from aquamarine ]: [EGL] Command eglInitialize errored out with EGL_NOT_INITIALIZED (0x12289): DRI2: failed to load driver
ERR from aquamarine ]: [EGL] Command eglInitialize errored out with EGL_NOT_INITIALIZED (0x12289): eglInitialize
ERR from aquamarine ]: CDRMRenderer: fail, eglInitialize failed
ERR from aquamarine ]: drm: initMgpu: no renderer
ERR from aquamarine ]: drm: Failed to update renderer state for /dev/dri/card1
DEBUG from aquamarine ]: udev: new udev change event for card1
DEBUG from aquamarine ]: udev: DRM device card1 changed
DEBUG from aquamarine ]: drm: Got a lease event for /dev/dri/card1
DEBUG from aquamarine ]: udev: new udev change event for card1
DEBUG from aquamarine ]: udev: DRM device card1 changed
DEBUG from aquamarine ]: drm: Got a lease event for /dev/dri/card1
DEBUG from aquamarine ]: udev: new udev change event for card1
DEBUG from aquamarine ]: udev: DRM device card1 changed
DEBUG from aquamarine ]: drm: Got a lease event for /dev/dri/card1
DEBUG from aquamarine ]: udev: new udev change event for card1
DEBUG from aquamarine ]: udev: DRM device card1 changed
DEBUG from aquamarine ]: drm: Got a lease event for /dev/dri/card1
DEBUG from aquamarine ]: udev: new udev change event for card1
DEBUG from aquamarine ]: udev: DRM device card1 changed
DEBUG from aquamarine ]: drm: Got a lease event for /dev/dri/card1

## env
local paths = require("default.hypr.paths")

local nvidia = paths.omarchy_path .. "/bin/omarchy-hw-nvidia"
local nvidia_gsp = paths.omarchy_path .. "/bin/omarchy-hw-nvidia-gsp"
local nvidia_without_gsp = paths.omarchy_path .. "/bin/omarchy-hw-nvidia-without-gsp"

-- These detectors read cached sysfs IDs rather than shelling out to lspci.
-- lspci reads PCI config space, which resumes a runtime-suspended GPU, and on a
-- hybrid laptop that wake alone outlasts Hyprland's 1.5s config reload budget.
if o.shell_succeeds(o.shell_quote(nvidia)) then
  if o.shell_succeeds(o.shell_quote(nvidia_gsp)) then
    hl.env("NVD_BACKEND", "direct")
    hl.env("LIBVA_DRIVER_NAME", "nvidia")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
  elseif o.shell_succeeds(o.shell_quote(nvidia_without_gsp)) then
    hl.env("NVD_BACKEND", "egl")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
  end
end

## vulkaninfo

## initramfs nvidia
0

## extra checks
error: package 'vulkan-tools' was not found
egl-gbm 1.1.4-1
egl-wayland 4:1.1.22-1
egl-x11 1.0.6-1
/usr/lib/gbm:
dri_gbm.so
nvidia-drm_gbm.so

/usr/share/egl/egl_external_platform.d:
10_nvidia_wayland.json
15_nvidia_gbm.json
20_nvidia_xcb.json
20_nvidia_xlib.json

/usr/share/glvnd/egl_vendor.d:
10_nvidia.json
50_mesa.json
hypr journal/log head:
DEBUG from aquamarine ]: drm: gpu /dev/dri/card0 becomes primary drm
DEBUG from aquamarine ]: drm: Starting backend for /dev/dri/card1, with driver nvidia-drm with primary /dev/dri/card0
197673:DEBUG from aquamarine ]: udev: new udev change event for card1
197683:DEBUG from aquamarine ]: udev: new udev add event for card1
197684:DEBUG from aquamarine ]: libseat: Device /dev/dri/card1 supports kms
197685:DEBUG from aquamarine ]: drm: Starting backend for /dev/dri/card1, with driver nvidia-drm with primary /dev/dri/card0
197686:DEBUG from aquamarine ]: drm: Registered gpu /dev/dri/card1
197728:DEBUG from aquamarine ]: drm: Basic init pass for gpu /dev/dri/card1
197740:DEBUG from aquamarine ]: drm: Scanning connectors for /dev/dri/card1
197809:DEBUG from aquamarine ]: drm: Initializing secondary renderer on /dev/dri/card1, has enabled outputs
197816:DEBUG from aquamarine ]: CDRMRenderer(drm): Using device /dev/dri/card1
197824:DEBUG from aquamarine ]: drm: Initializing secondary renderer on /dev/dri/card1, has enabled outputs
197831:DEBUG from aquamarine ]: CDRMRenderer(drm): Using device /dev/dri/card1
197838:ERR from aquamarine ]: drm: Failed to update renderer state for /dev/dri/card1

## summary
- Hyprland (aquamarine) DID notice the hot-added card1 and its connected HDMI-A-2 (already had a crtc) — O1 resolved: hot-add path fires.
- It then tried "secondary renderer on /dev/dri/card1" and FAILED: eglQueryDevicesEXT BAD_ALLOC, eglInitialize "DRI2: failed to load driver", "initMgpu: no renderer". HDMI-A-2 status=connected but enabled=disabled; hyprctl lists only eDP-1.
- So the missing piece is EGL/GBM on the NVIDIA card inside the compositor (not Thunderbolt, driver or link). Needs E1 investigation: GBM_BACKEND / __EGL_VENDOR_LIBRARY_FILENAMES / egl-gbm presence.
- Link: 16 GT/s x4 (not the 2.5 GT/s seen on first connect); bolt: USB4 40 Gb/s, policy iommu.
- removable attr = "removable" on 03:00.0 and 03:00.1 (usable as eject-safety discriminator).
- nvidia 580.178.04 loaded itself on hotplug; nvidia_drm refcnt=2 (compositor holds card1), nvidia_modeset 1, nvidia 3, uvm 0.
- nvidia-smi responsive (rc 0, 18W idle, P0, 29C).
- nvidia-drm modeset/fbdev params unreadable as user (root-only) -> health row needs the helper or /proc/cmdline/modprobe parsing.
- Boot journal (Oct 5) confirms nvidia.ko was loaded at boot with "No NVIDIA GPU found" => the stale modules-load mask is real.
- initramfs contains no nvidia (0 matches). 
- vulkaninfo not installed on this machine (health row tools.vulkaninfo would warn).
- Two D-state tasks seen (ELAN2514 touch irq, i915_flip kworker) - unrelated looking, noted only.

## Hypothesis added after E0 (eglinfo test, not yet verified in the compositor)
A fresh process using the GBM platform sees the 4070 SUPER fine via NVIDIA EGL (eglinfo -p gbm -B, with or without GBM_BACKEND/__EGL_VENDOR_LIBRARY_FILENAMES). Hyprland, started with no NVIDIA card present, got BAD_ALLOC from eglQueryDevicesEXT and "DRI2: failed to load driver" on card1. Likely cause: glvnd/NVIDIA EGL state initialised once per process while no NVIDIA device existed, so a hot-added card is unusable by that compositor process. If true, `needs_relogin` is the routine path for plug-in-after-login, and only eGPU-present-at-login gives HDMI. Verify at E1(b) (login with eGPU attached) - needs the user.
