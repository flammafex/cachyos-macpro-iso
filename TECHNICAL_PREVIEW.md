# CachyOS Mac Pro 6,1 Technical Preview

This is an **unofficial live-USB-only preview** for the 2013 Mac Pro 6,1. It is not an installation release.

## Artifact

- ISO: `cachyos-macpro-2026.09.07-x86_64.iso`
- Size: `3,308,619,776` bytes
- SHA-256: `ca80d6bcc46aafbcc7893b08b6a940a70f653ac0a5cd1aa7bc0df2a6bcdbe611`
- Signing: **unsigned**; verify the hash before writing the USB

The physical reference system is a 2013 Mac Pro 6,1 with dual D700 GPUs, a Xeon E5-2697 v2, and NVMe storage.

## Validated live scope

Reference test path: **Apple Option Picker → USB systemd-boot → desktop**.

The live image carries kernel release `7.2.0-macpro61` and this exact package quartet:

```text
linux-macpro61          7.2-5
linux-macpro61-headers  7.2-5
macfanctld              0.6-2
macpro61-support        1-5
```

The live fan daemon is `macfanctld`. The preview hardware checks cover visible SMC, GPU, and NVMe sensors.

## Safe-use and reporting

1. Verify the downloaded image:

   ```bash
   sha256sum -c cachyos-macpro-2026.09.07-x86_64.iso.sha256
   ```

2. Write it to a USB device using a tool that identifies the correct device. Do not test installation.
3. Start from a **cold power-on**: power off first, then press the power button and hold **Option**.
4. Select the USB systemd-boot entry and wait for the desktop.
5. For a report, include the exact SHA-256, Mac Pro hardware/GPU configuration, cold-boot result, `uname -r`, fan-daemon state, and SMC/GPU/NVMe sensor output. Power off rather than rebooting when ending the test.

Report failures with the ISO hash, boot path, hardware details, and relevant journal or command output. Avoid publishing serial numbers or other private identifiers.

## Explicit non-claims

This preview does **not** claim:

- a working or supported Calamares installation;
- installed-system boot, update, or rollback behavior;
- support for GPU configurations other than the reference dual-D700 system;
- support for encrypted, mapped, Btrfs, or other non-plain storage layouts;
- production readiness, durability, or general hardware compatibility;
- authenticity or integrity through a release signature.

The source worktrees were uncommitted when this artifact was created. The artifact hash above is therefore the current immutable identifier for collaboration. Before third-party collaboration, commit and publish the exact source snapshots used to build it.
