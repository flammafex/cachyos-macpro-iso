# CachyOS Mac Pro 6,1 ISO

Custom [CachyOS](https://cachyos.org) ISO for the **Mac Pro 6,1 (Late 2013)** — the infamous "Trash Can" Mac — with full hardware support, GPU firmware, fan control, and macOS Monterey KVM.

## What You Get

- **CachyOS KDE Plasma** desktop with 17+ DE options via installer
- **Custom `linux-macpro61` kernel** with:
  - AMD FirePro D300/D500/D700 GPU firmware embedded (amdgpu SI support)
  - All critical drivers built-in (=y) — no initramfs needed for basic boot
  - BORE CPU scheduler + BBR3 congestion control
  - ACPI GPE16 storm fix (Thunderbolt log spam eliminated)
  - NVMe + TRIM support out of the box
  - KVM built-in for macOS Monterey virtualization
- **Fan control** — `applesmc` + `macfanctld` for thermal management
- **Cold boot protection** — `reboot` aliased to `poweroff`, `reboot.target` masked
- **SSH enabled** in live environment for headless setup
- **Post-install script** that fixes the kernel, boot entries, and hardware config

## Quick Start

### Download the ISO

Download the latest release from [GitHub Releases](https://github.com/flammafex/cachyos-macpro-iso/releases).

### Flash to USB

```bash
# Reassemble the split files
`cat cachyos-macpro-2026.09.16-x86_64.iso.part* > cachyos-macpro-2026.09.16-x86_64.iso
`
# sha256 of reassembled iso
#0695e9ce9781e51136e964e755af4f20fa6dbdcd16be5af8a009cb69a910422a `

# Run to verify
`sha256sum cachyos-macpro-2026.09.16-x86_64.iso`

# Flash to USB
sudo dd if=cachyos-macpro-2026.09.16-x86_64.iso` of=/dev/sdX bs=4M status=progress && sync

# Or use balenaEtcher / Rufus (Windows)
```

### Boot your Mac Pro

1. **Power off** the Mac Pro (never reboot — GPU firmware only initializes on cold boot)
2. Press the power button and **immediately hold the Option key**
3. Select the USB drive
4. Choose **"CachyOS (Mac Pro 6,1)"** from the GRUB menu
5. Desktop loads — double-click the installer icon

### ⚠️ After Install: Always Power Off

The Mac Pro 6,1 has an Apple EFI quirk: **the GPU only initializes on cold boot**. After installation:
```bash
sudo poweroff    # NOT reboot!
# Then press the power button
```

## Build the ISO Yourself

You need an Arch Linux or CachyOS machine (can be the Mac Pro itself).

### Step 1: Clone both repos

```bash
git clone https://github.com/eonicman/linux-mac.git
git clone https://github.com/eonicman/cachyos-macpro-iso.git
cd cachyos-macpro-iso
```

### Step 2: Build the kernel

```bash
./scripts/build-kernel.sh /path/to/linux-mac
# Takes 30-90 min on a Mac Pro
```

### Step 3: Build the Mac Pro support packages

```bash
./scripts/build-macfanctld.sh
./scripts/build-support.sh
```

### Step 4: Build the Calamares installer package

```bash
./scripts/build-calamares.sh
```

### Step 5: Set up the local repo

```bash
./scripts/setup-local-repo.sh
```

### Step 6: Build the ISO

```bash
sudo pacman -S archiso mkinitcpio-archiso squashfs-tools grub --needed
sudo pacman-key --recv-keys 882DCFE48E2051D48E2562ABF3B607488DB35A47
sudo pacman-key --lsign-key 882DCFE48E2051D48E2562ABF3B607488DB35A47
./scripts/build-iso.sh -v
```

## macOS Monterey KVM

The kernel has KVM built-in. See [docs/monterey-kvm.md](docs/monterey-kvm.md) for running macOS Monterey in a VM with ~2-5% CPU overhead.

**Current state:** Software-rendered QXL display — usable for CLI and light desktop work. GPU passthrough via PVG is on the roadmap in `linux-mac/docs/pvg-linux.md`.

## Hardware Support

| Feature | Status | Notes |
|---------|--------|-------|
| GPU (D300/D500/D700) | ✅ Working | amdgpu built-in, radeonsi/RADV via Mesa |
| Display (DP/HDMI) | ✅ Working | Via amdgpu + DC |
| Vulkan / OpenGL | ✅ Working | Mesa RADV / radeonsi |
| Ethernet (both ports) | ✅ Working | tg3 + Broadcom PHY built-in |
| Wi-Fi | ⚠️ Proprietary | `broadcom-wl-dkms` (AUR) |
| Audio | ✅ Working | Intel HDA + Cirrus CS4208 (`model=macpro6 inv_jack_detect=1`) |
| USB 3.0 | ✅ Working | xHCI built-in |
| Thunderbolt 2 | ⚠️ Partial | Works with log spam (GPE16 masked) |
| NVMe + TRIM | ✅ Working | Built-in; enable `fstrim.timer` |
| Bluetooth | ✅ Working | Broadcom via btusb |
| Fan Control | ✅ Working | applesmc + macfanctld |
| KVM (macOS Monterey) | ✅ Working | ~2-5% CPU overhead |
| Sleep/Wake | ❌ Disabled | Unreliable on this hardware |

## Audio Fix (v2)

The Mac Pro 6,1 uses a **Cirrus Logic CS4208** audio codec behind an Intel C600/X79 HDA controller. The generic `snd_hda_intel` driver doesn't apply the correct pin layout, so internal speakers and headphone jack are silent.

**Fix:** Two config files injected into the ISO's airootfs:

- `modprobe.d/macpro-audio.conf` — forces `model=macpro6` pin layout + `inv_jack_detect=1` (fixes phantom headphone detection that mutes internal speakers)
- `modules-load.d/macpro-sound.conf` — loads `snd-hda-codec-cirrus` codec module

**Critical:** After applying or changing audio config, you must **cold shutdown** (`sudo poweroff`), not reboot. The Mac Pro 6,1 EFI doesn't reset audio power lanes on warm reboot.

## What's Changed from the Original

| Area | Change |
|------|--------|
| `modprobe.d/macpro-audio.conf` | **NEW** — Mac Pro 6,1 audio pin layout + jack detect fix |
| `modules-load.d/macpro-sound.conf` | **NEW** — Load Cirrus Logic CS4208 codec module |
| `local-repo/` | Build scripts to populate with kernel packages |
| `packages_desktop.x86_64` | Added `macfanctld` and `macpro61-support` |
| EFI boot entries | Added `03-macpro61.conf` + `04-macpro61-fallback.conf` |
| `systemd/system/` | Added `sshd.service`, `macpro-fancontrol.service`, `applesmc_load.service` |
| `modules-load.d/` | Added `applesmc.conf` |
| `ufw/applications.d/` | Added SSH UFW rule |
| Post-install | `macpro-postinstall.sh` — swaps kernel, configures boot, fan control |
| Installer wrapper | `macpro-installer-launch.sh` — runs Calamares then applies fixes |
| Calamares storage/boot flow | Plain ext4 `/` plus FAT `/boot`; the package finalizer owns systemd-boot writes |
| `profiledef.sh` | Added new scripts to file_permissions |
| Build scripts | `scripts/build-kernel.sh`, `build-macfanctld.sh`, `build-support.sh`, `build-calamares.sh`, `setup-local-repo.sh`, `build-iso.sh` |

## Testing Checklist

- [ ] ISO boots to desktop with Mac Pro kernel (GRUB entry 1)
- [ ] `applesmc` loaded, fans audible (`sensors | grep applesmc`)
- [ ] `macfanctld` running (`systemctl status macfanctld`)
- [ ] GPU detected (`lspci | grep AMD`, `glxinfo | grep renderer`)
- [ ] SSH accessible from another machine
- [ ] `reboot` command warns and powers off instead
- [ ] Calamares installer runs successfully
- [ ] Installed system boots with `linux-macpro61` kernel
- [ ] Installed system has macfanctld, no-reboot alias, and a `/boot` ESP
- [ ] `pacman -Syu` can update from [macpro] repo
- [ ] Cold boot (poweroff + power on) restores GPU
- [ ] Audio works (internal speakers + headphone jack)
- [ ] `alsamixer` shows HDA Intel PCH with unmuted controls
- [ ] Warm reboot produces warning and powers off

## Credits

- **wolffcatskyy** — original kernel config, hardware audit, KVM docs, and ISO framework
- **eonicman** - fixed critical issues with wolffcatskyy's repo
- **CachyOS** — base ISO builder and optimized packages
- **linux-mac** — custom kernel for Mac Pro 6,1

## License

GPL-2.0 (same as the Linux kernel)
