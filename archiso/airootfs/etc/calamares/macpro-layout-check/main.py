"""Calamares storage-layout gate for the Mac Pro installation profile."""

import subprocess

import libcalamares


def _field(partition, *names):
    for name in names:
        if name in partition:
            return partition[name]
    return None


def _true(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return isinstance(value, str) and value.strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def _contains_forbidden(value):
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key).lower()
            if any(word in key_text for word in ("encrypt", "mapper", "crypt")):
                if child is not None and not (
                    child is False
                    or child == 0
                    or (isinstance(child, str) and child.strip().lower() in {"", "false", "no", "off", "none"})
                ):
                    return "encryption or a mapper field is set"
            result = _contains_forbidden(child)
            if result:
                return result
        return None
    if isinstance(value, (list, tuple)):
        for child in value:
            result = _contains_forbidden(child)
            if result:
                return result
        return None
    if isinstance(value, str):
        text = value.strip().lower()
        if "btrfs" in text:
            return "Btrfs is not supported"
        if "subvol" in text or "subvolume" in text:
            return "Btrfs subvolumes are not supported"
        if text in {"btrfs", "luks", "crypt", "encrypted", "mapper", "device-mapper", "logical-volume"}:
            return "encrypted or mapped devices are not supported"
        if "/dev/mapper/" in text or text.startswith("/dev/dm-"):
            return "mapper devices are not supported"
    return None


def _plain_device(partition):
    device = _field(partition, "device", "path")
    if not isinstance(device, str) or not device.startswith("/dev/") or device == "/dev/":
        return False, "device is not a direct disk partition"
    if device.startswith(("/dev/mapper/", "/dev/dm-", "/dev/md", "/dev/crypt")):
        return False, "device is an encrypted or mapped device"
    try:
        result = subprocess.run(
            ["lsblk", "-dnro", "TYPE", "--", device],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return False, "device type could not be verified with lsblk"
    if not isinstance(result.stdout, str) or result.stdout.strip().splitlines() != ["part"]:
        return False, "lsblk did not identify the device as a partition"
    return True, ""


def _validate(partitions):
    if not isinstance(partitions, (list, tuple)) or not partitions:
        return "Calamares did not provide a non-empty partition selection."

    roots = []
    boots = []
    for index, partition in enumerate(partitions, start=1):
        if not isinstance(partition, dict):
            return f"Selected partition {index} is not a structured partition record."

        forbidden = _contains_forbidden(partition)
        if forbidden:
            return f"Selected partition {index} is unsafe: {forbidden}."

        mount_point = _field(partition, "mountPoint", "mountpoint", "mount")
        filesystem = _field(partition, "fs", "filesystem", "fileSystem")
        if not isinstance(filesystem, str):
            filesystem = ""
        filesystem = filesystem.strip().lower()

        if mount_point == "/":
            if filesystem != "ext4":
                return f"The selected root partition uses {filesystem or 'an unknown filesystem'}; plain ext4 is required."
            valid, reason = _plain_device(partition)
            if not valid:
                return f"The selected root partition is invalid: {reason}."
            if _true(_field(partition, "encrypt", "encrypted", "encryption")):
                return "The selected root partition is encrypted; an unencrypted direct partition is required."
            roots.append(partition)
        elif mount_point == "/boot":
            if filesystem not in {"vfat", "fat32"}:
                return f"The selected /boot partition uses {filesystem or 'an unknown filesystem'}; vfat or fat32 is required."
            valid, reason = _plain_device(partition)
            if not valid:
                return f"The selected /boot partition is invalid: {reason}."
            if _true(_field(partition, "encrypt", "encrypted", "encryption")):
                return "The selected /boot partition is encrypted; an unencrypted direct partition is required."
            boots.append(partition)

    if len(roots) != 1:
        return f"Exactly one plain direct-partition ext4 root mounted at / is required; found {len(roots)}."
    if len(boots) != 1:
        return f"Exactly one plain direct-partition vfat/fat32 /boot partition is required; found {len(boots)}."
    return None


def pretty_name():
    return "Mac Pro storage layout check"


def run():
    error = _validate(libcalamares.globalstorage.value('partitions'))
    if error:
        return ("Unsupported Mac Pro storage layout", error)
    return None
