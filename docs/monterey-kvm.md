# Experimental Monterey KVM

This is an experimental, local validation record for a Monterey guest. It does not change the ISO build or package behavior.

## Validated baseline

- Apple Recovery was downloaded and chunklist-verified.
- The host uses QEMU 11.1.1 and edk2-ovmf 202608-1.
- A fresh 32 GiB qcow2 guest was installed from Recovery and cold-booted without Recovery media.
- A host-CPU passthrough test guest booted to Monterey.
- Virtio networking works.
- The only validated display device is unaccelerated `vmware-svga`.

Use 4 vCPU and 8 GiB of RAM as the baseline profile. Optional 6 vCPU/8 GiB and 12 vCPU/24 GiB profiles are test profiles only; they are not claimed to have been tested.

Do not attach host physical disks or partitions to the guest. Use fresh guest storage and keep host storage outside the VM boundary.

## Recovery, checkpoints, and rollback

Keep the chunklist-verified Apple Recovery assets available for installation or recovery work. Install into a new qcow2 disk and verify a cold boot without Recovery before making changes.

After that first successful boot, preserve an untouched checkpoint containing the guest qcow2 disk and its matching OVMF variables. Make a separate copy after clean shutdown before changing CPU, firmware, display, or passthrough settings. Roll back by shutting down the VM and restoring both checkpoint files together; never modify the fresh-install checkpoint in place.

The opt-in helpers in [`scripts/monterey-kvm/`](../scripts/monterey-kvm/) require operator-provided lawful OpenCore configuration and Apple Recovery assets. They create only isolated image files and do not support physical-disk passthrough. This document supplies neither OpenCore binaries or configuration nor Apple installer or recovery media.

## Unvalidated graphics plan

GPU passthrough has not been validated. A future test may inventory IOMMU groups, select a non-host D700 display and its paired HDMI-audio function, retain a working Linux display, and bind only the selected pair to VFIO. It must include a clean checkpoint first, physical-output testing, and cold-start/reset testing. Do not use the active Linux GPU, ACS override, or an unverified ROM.

If physical output is unsuitable, remoting can be evaluated as a separate fallback for guest access. GPU passthrough, physical output, reset behavior, and remoting are all unvalidated and must not be treated as supported configurations.
