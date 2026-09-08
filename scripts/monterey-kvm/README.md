# Monterey QEMU/KVM templates

These templates create and launch a fresh Monterey VM using only image files.
They do not contain Apple firmware keys, OpenCore assets, recovery media, or
host-specific paths. They never attach block devices, pass through physical
disks, bind VFIO devices, use `sudo`, or change host KVM settings.

## Prepare

Provide your own recovery DMG, OVMF files, and OpenCore disk:

```text
./prepare-monterey.sh \
  --vm-dir ./monterey-vm \
  --recovery-dmg /path/to/recovery.dmg \
  --ovmf-code /path/to/OVMF_CODE.fd \
  --ovmf-vars /path/to/OVMF_VARS.fd \
  --opencore-disk /path/to/OpenCore.qcow2
```

The VM directory must not already exist. It receives `recovery.raw`, a
writable `recovery.qcow2` overlay, sparse `guest.qcow2` (32G by default), and
a private writable `OVMF_VARS.fd`. The OVMF code and OpenCore disk are only
validated by this helper; launch receives their paths explicitly.

## Launch

Set the Apple SMC OSK in the environment without placing it in a script or
command file. The launcher does not print it:

```text
APPLE_SMC_OSK='your-user-provided-value' ./launch-monterey.sh \
  --vm-dir ./monterey-vm \
  --ovmf-code /path/to/OVMF_CODE.fd \
  --opencore-disk /path/to/OpenCore.qcow2 \
  --recovery
```

Recovery is optional; omit `--recovery` for a normal guest-disk boot. Defaults
are q35/KVM, the validated Penryn-compatible CPU profile
`Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check`,
4 vCPUs (1 socket, 2 cores, 2 threads), 8192 MiB RAM, vmware-svga with GTK,
and user networking without port forwarding. Networking uses
`virtio-net-pci`. The optional `--cpu-profile host` profile maps to
`host,kvm=on,vendor=GenuineIntel,+invtsc`; it is experimental and unvalidated
for portability.

Memory is limited to 2048..32768 MiB for the MacPro6,1 experiments. Recommended
profiles are:

```text
--vcpus 4  --memory-mib 8192
--vcpus 6  --memory-mib 12288
--vcpus 12 --memory-mib 24576
```

If `/sys/module/kvm/parameters/ignore_msrs` is observable and disabled, the
launcher warns that the user must choose how to enable it temporarily. The
launcher never changes that host setting. Run either helper with `--help` for
the complete interface.
