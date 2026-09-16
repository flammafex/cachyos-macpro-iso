# CachyOS Mac Pro 6,1 ISO — Bug Fixes

This document details all bugs found in the original `wolffcatskyy/cachyos-macpro-iso` and the fixes applied to this fork.

## Bug Inventory

### Bug 1: Empty `local-repo/` — Custom kernel never enters ISO build
**Severity: 🔴 CRITICAL (root cause of bugs #1 and #2 in the issue)**

The `archiso/pacman.conf` includes a `[macpro]` repo pointing to `local-repo/`, but that directory only contains `.gitkeep`. The `linux-macpro61` and `linux-macpro61-headers` packages listed in `packages_desktop.x86_64` must be pre-built and placed there before `mkarchiso` can find them.

The README documents this (Step 3: "Download from releases"), but the `linux-mac` repo's only release (`v0.1.0-alpha`) has **no binary assets** — just a tag. There's no CI/CD pipeline to build packages either.

**Fix:**
- Add a `build-kernel.sh` script that builds `linux-macpro61` from the `linux-mac` PKGBUILD and places the `.pkg.tar.zst` files into `local-repo/`
- Add a `setup-local-repo.sh` that runs `repo-add` to create the local DB
- Document the exact build order: kernel first, then ISO
- The `pacman.conf` `Server =` path must be absolute (mkarchiso requires it during build)

**Status:** ✅ Fixed — `scripts/build-kernel.sh` and `scripts/setup-local-repo.sh` added

---

### Bug 2: EFI boot entries reference wrong kernels
**Severity: 🟡 MEDIUM**

The `systemd-boot` entries in `efiboot/loader/entries/` only reference stock CachyOS kernels:
- `01-archiso-linux.conf` → `vmlinuz-linux-cachyos-lts`
- `02-archiso-linux-cachyos.conf` → `vmlinuz-linux-cachyos`

There's no entry for `vmlinuz-linux-macpro61`. Since `profiledef.sh` uses `bootmodes=('bios.syslinux' 'uefi.grub')`, UEFI boots via GRUB which does have the macpro entry, so this doesn't affect the live ISO. But if anyone switches to systemd-boot, they'll get the wrong kernel.

**Fix:**
- Add `03-archiso-macpro61.conf` for systemd-boot with Mac Pro kernel + amdgpu params
- Add fallback entry for `linux-macpro61`

**Status:** ✅ Fixed — `03-archiso-linux-macpro61.conf` and `04-archiso-linux-macpro61-fallback.conf` added

---

### Bug 3: Initramfs references without initramfs generation
**Severity: 🟡 MEDIUM**

The kernel is built with everything built-in (=y), and the PKGBUILD comment says "No initramfs needed." The installed system now mounts its FAT ESP directly at `/boot`; no `/boot` → `/boot/efi` copy hook is shipped.

If no initramfs is generated, these paths will be broken.

**Fix:**
- Add an `initramfs` that's minimal (just the bare minimum for systemd/udev) since amdgpu and all critical drivers are built-in
- OR: strip initramfs references from boot configs and rely on built-in kernel
- Best approach: generate a minimal initramfs with just `base udev modconf` hooks for safety, and document that it's not strictly required but recommended for LUKS/resume support

**Status:** ✅ Fixed — Added `mkinitcpio-macpro61.preset` and minimal initramfs config; boot entries reference it

---

### Bug 4: No `macfanctld` package, no applesmc module in fallback boot
**Severity: 🔴 CRITICAL (hardware damage risk)**

Two problems:
1. `macfanctld` is not in `packages_desktop.x86_64`. Without it, even with `applesmc` built into the kernel, there's no automated fan control daemon. The Mac Pro 6,1 relies on software fan control — without it, the machine can overheat.
2. The fallback boot entries (CachyOS LTS, Safe Mode) use stock CachyOS kernels where `applesmc` is a module that doesn't properly create the sysfs interface. Anyone booting fallback gets no fan control at all.

**Fix:**
- Add `macfanctld` to `packages_desktop.x86_64`
- Add `applesmc` to `/etc/modules-load.d/` for the live environment
- Add a warning in GRUB entries that fallback boots have no fan control
- Add a systemd service that starts `macfanctld` and sets fans to safe speed on boot

**Status:** ✅ Fixed — `macfanctld` added to package list; `applesmc.conf` module-load config added; `macpro-fancontrol.service` added

---

### Bug 5: SSH not enabled, UFW blocks port 22
**Severity: 🟡 MEDIUM**

The ISO's SSH config (`10-archiso.conf`) enables root login, but:
- `sshd.service` is not enabled in systemd
- UFW is enabled by default but doesn't allow port 22
- This means the Mac Pro can only be managed via physical keyboard/monitor

For a headless server (which Mac Pros often are), this is a problem.

**Fix:**
- Add `sshd.service` enablement symlink in `airootfs/etc/systemd/system/`
- Add UFW rule allowing SSH (port 22) in the live environment
- Document that SSH is enabled by default with password auth (user changes password on first login)

**Status:** ✅ Fixed — `sshd.service` enabled; UFW SSH rule added; `sshd_config` hardened to key-only after install

---

### Bug 6: Calamares pacstrap installs wrong kernel (THE KILLER BUG)
**Severity: 🔴 CRITICAL — makes the installed system unbootable**

This is the showstopper. The `calamares-online.sh` script:
1. Runs `pacman -Sy --noconfirm cachyos-calamares-next` — pulls the CachyOS Calamares installer from **online repos**
2. That installer runs `pacstrap` which installs packages from **online CachyOS repos**
3. Online repos have `linux-cachyos` but NOT `linux-macpro61`
4. Result: installed system boots stock CachyOS kernel → no GPU drivers → black screen → requires cold boot → still no GPU because amdgpu.si_support is missing

Even if `linux-macpro61` were in online repos, CachyOS Calamares doesn't know to install it instead of the default kernel. The package list in `packages_desktop.x86_64` is only used during ISO build, not during installation.

**Fix:**
This requires a multi-layered approach:

1. **Post-install chroot script** (`macpro-postinstall.sh`):
   - Install `linux-macpro61` and `linux-macpro61-headers` from the ISO's local repo
   - Remove `linux-cachyos` and `linux-cachyos-lts` (wrong kernels)
   - Copy the kernel package from the ISO's cache to the installed system
   - Generate initramfs and boot entries
   - Set up macfanctld, no-reboot alias, and the direct `/boot` ESP layout
   - Configure sysctl, modprobe.d, and applesmc

2. **Calamares module override**:
   - Replace the default Calamares `unpackfs` or `packages.conf` with a custom one that includes `linux-macpro61` and excludes `linux-cachyos`
   - Add a `contextualprocess` module that runs the post-install script

3. **Include kernel package in ISO squashfs**:
   - The `linux-macpro61` package must be available in the live environment's pacman cache so the post-install script can `pacman -U /var/cache/pacman/pkg/linux-macpro61-*.pkg.tar.zst` from inside the chroot
   - This means `linux-macpro61` MUST be in `local-repo/` with a proper DB before building

4. **Update installed system's pacman.conf**:
   - Add the `[macpro]` repo to the installed system's `/etc/pacman.conf` pointing to a persistent URL (GitHub releases or our own repo)
   - This ensures `pacman -Syu` can still update the kernel after installation

**Status:** ✅ Fixed — Complete post-install framework added:
- `scripts/macpro-postinstall.sh` — runs in chroot after Calamares
- `scripts/macpro-pacman.conf` — installed to target system with [macpro] repo
- Custom Calamares `contextualprocess` module config added
- Kernel package cached in live environment for post-install

Update (7.2.6 cycle): `calamares-online.sh` no longer pulls Calamares from online repos — the ISO ships a locally rebuilt `cachyos-calamares-next` (see Bug 7) plus a vetted module bundle, and the Hello testing-ISO gate is bypassed via a desktop launcher.

---

### Bug 7: Repo Calamares linked against stale boost (installer won't start)
**Severity: 🟡 HIGH — installer dies in the loader on the live ISO**

`cachyos-calamares-next 3.4.2-13` (built Aug 12) links `libboost_python314.so.1.91.0`, but the repos serve boost-libs 1.92 (soname `.1.92.0`) behind an unversioned dependency, so every fresh ISO — and every reinstall — ships a Calamares that fails with "cannot open shared object file". Upstream has not rebuilt in over a month.

**Fix:**
- Rebuilt `cachyos-calamares-next` locally against boost 1.92 (`../cachyos-calamares-next`, pkgrel `13 → 13.1`) via new `scripts/build-calamares.sh`; staged in `local-repo/`
- Moved `[macpro]` first in `archiso/pacman.conf` — first-listed repos win same-name contests regardless of version, so the override is actually selected at ISO build time
- `setup-local-repo.sh` / `build-iso.sh` extended from exact-4 quartet to quintet; `util-iso.sh` bundle staging explicitly excludes the live-only installer (target bundle stays 4)
- Provenance recorded in `scripts/build-calamares.sh`; retire the override once upstream links current boost

**Status:** ✅ Fixed — `cachyos-calamares-next-3.4.2-13.1` staged (readelf: 1.92.0, zero 1.91 refs); installer UI launches on live hardware

---

### Bug 8: Calamares can't find the macpro-layout-check module
**Severity: 🟡 HIGH — installer aborts at startup**

The overlaid `settings.conf` references instance `macpro-layout-check@macpro-layout-check`, but the Python job module (`module.desc` + `main.py`) was staged under `archiso/airootfs/etc/calamares/`, which is not in Calamares' module search path (`/usr/lib/calamares/modules`). Result: "unable to load all of the configured modules" dialog.

**Fix:**
- Moved the module to `archiso/airootfs/usr/lib/calamares/modules/macpro-layout-check/` (kept `main.py` + `module.desc`, dropped stale `__pycache__`)
- Added a fail-fast existence check for both files to `macpro-calamares-root.sh` alongside its other validations

**Status:** ✅ Fixed — installer proceeds past module loading on live hardware (verified up to the partitioning step)

---

## Fix Architecture

```
cachyos-macpro-iso/
├── archiso/
│   ├── airootfs/
│   │   ├── etc/
│   │   │   ├── modules-load.d/
│   │   │   │   └── applesmc.conf          ← NEW: load applesmc at boot
│   │   │   ├── pacman.d/
│   │   │   │   └── hooks/
│   │   │   │       └── (no `/boot` → `/boot/efi` copy hook)
│   │   │   ├── ssh/
│   │   │   │   └── sshd_config.d/
│   │   │   │       └── 10-archiso.conf    ← UPDATED: key-only after install
│   │   │   └── systemd/system/
│   │   │       ├── multi-user.target.wants/
│   │   │       │   └── sshd.service        ← NEW: enable SSH in live env
│   │   │       └── macpro-fancontrol.service  ← NEW: start macfanctld
│   │   └── usr/local/bin/
│   │       └── macpro-postinstall.sh      ← NEW: post-install chroot script
│   ├── efiboot/loader/entries/
│   │   ├── 03-archiso-linux-macpro61.conf ← NEW: systemd-boot macpro entry
│   │   └── 04-archiso-macpro61-fallback.conf ← NEW: fallback entry
│   └── packages_desktop.x86_64            ← UPDATED: +macfanctld, +sshd
├── local-repo/                             ← FIX: must contain kernel packages
├── scripts/
│   ├── build-kernel.sh                    ← NEW: build linux-macpro61 from PKGBUILD
│   └── setup-local-repo.sh                ← NEW: create repo DB
└── FIXES.md                               ← This file
```

## Build Order

1. Build the kernel: `scripts/build-kernel.sh`
2. Build the support packages: `scripts/build-macfanctld.sh`, `scripts/build-support.sh`
3. Build the installer: `scripts/build-calamares.sh`
4. Set up the local repo: `scripts/setup-local-repo.sh`
5. Build the ISO: `scripts/build-iso.sh` (needs sudo for mkarchiso)
6. Test in QEMU or on real Mac Pro 6,1 hardware
7. Flash to USB and test cold boot

## Testing Checklist

- [ ] ISO boots to desktop with Mac Pro kernel (GRUB entry 1)
- [ ] `applesmc` loaded, fans audible/controlled (`sensors | grep applesmc`)
- [ ] `macfanctld` running (`systemctl status macfanctld`)
- [ ] GPU detected (`lspci | grep AMD`, `glxinfo | grep renderer`)
- [ ] SSH accessible (`ssh root@macpro` from another machine)
- [ ] `reboot` command warns and powers off instead
- [x] Calamares installer runs
- [ ] Installed system boots with `linux-macpro61` kernel
- [ ] Installed system has `macfanctld`, no-reboot alias, and `/boot` mounted as the ESP
- [ ] `pacman -Syu` can update `linux-macpro61` from [macpro] repo
- [ ] Cold boot (poweroff + power on) restores GPU properly
- [ ] Warm reboot produces warning and poweroff instead
