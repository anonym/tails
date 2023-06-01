import os
from pathlib import Path
import time
import re
import stat
from typing import Optional, Callable

import psutil
from gi.repository import GLib, UDisks

from tailslib import LIVE_USER_UID, LIVE_USERNAME
import tps.logging
from tps import executil
from tps import _, TPS_MOUNT_POINT, udisks
from tps.dbus.errors import IncorrectPassphraseError, TargetIsBusyError, NotEnoughMemoryError
from tps.job import Job

logger = tps.logging.get_logger(__name__)

TAILS_MOUNTPOINT = "/lib/live/mount/medium"
PARTITION_GUID = "8DA63339-0007-60C0-C436-083AC8230908" # Linux reserved
PARTITION_LABEL = "TailsData"

# Leave at lest 200 MiB of memory to the system to avoid triggering the
# OOM killer.
MEMORY_LEFT_TO_SYSTEM_KIB = 200 * 1024

# Use at least 256 MiB of memory for Argon2id. That should be low enough
# that even when the system doesn't have enough available memory, the
# user can free up some memory by closing applications and try again.
# It's also well within the range that's chosen by cryptsetup by default
# (32 KiB to 1 GiB).
MINIMUM_PBKDF_MEMORY_KIB = 256 * 1024

# Support up to 1 GiB of memory for Argon2id. This is the maximum value
# that's chosen by cryptsetup by default and it's low enough that
# systems with only 2 GiB of RAM can still unlock the Persistent Storage
# in the Welcome Screen.
MAXIMUM_PBKDF_MEMORY_KIB = 1 * 1024 * 1024


class InvalidPartitionError(Exception):
    pass

class PartitionNotUnlockedError(Exception):
    pass

class InvalidBootDeviceError(Exception):
    pass

class InvalidCleartextDeviceError(Exception):
    pass

class InvalidStatError(Exception):
    pass


class BootDevice(object):
    def __init__(self, udisks_object: UDisks.Object):
        self.udisks_object = udisks_object
        self.partition_table = \
            udisks_object.get_partition_table() # type: UDisks.PartitionTable
        partition_table_type = self.partition_table.props.type
        if partition_table_type != 'gpt':
            logger.debug(f"Partition table type: {partition_table_type}")
            raise InvalidBootDeviceError(
                "You can only create a Persistent Storage on a USB stick "
                "installed with a USB image or Tails Installer."
            )
        self.block = self.udisks_object.get_block()
        if not self.block:
            raise InvalidBootDeviceError("Device is not a block device")
        self.device_path = self.block.props.device

    @classmethod
    def get_tails_boot_device(cls) -> "BootDevice":
        """Get the device which Tails was booted from. Raise a
        InvalidBootDeviceError if it can't be found."""
        # Get the underlying block device of the Tails system partition
        try:
            dev_num = os.stat(TAILS_MOUNTPOINT).st_dev
        except FileNotFoundError as e:
            raise InvalidBootDeviceError(e)

        block = udisks.get_block_for_dev(dev_num)
        if not block or not block.get_object():
            msg = f"Could not get udisks object of boot device " \
                  f"{os.major(dev_num)}:{os.minor(dev_num)}"
            raise InvalidBootDeviceError(msg)
        device_object = block.get_object()

        # Get the udisks partition object
        partition = device_object.get_partition()
        if not partition:
            msg = f"Boot device {block.props.device} is not a partition"
            raise InvalidBootDeviceError(msg)
        partition_name = partition.props.name
        if partition_name != 'Tails':
            logger.debug(f"Partition name: {partition_name}")
            raise InvalidBootDeviceError(
                "You can only create a Persistent Storage on a USB stick "
                "installed with a USB image or Tails Installer."
            )

        return BootDevice(udisks.get_object(partition.props.table))

    def get_beginning_of_free_space(self) -> int:
        """Get the beginning of the free space on the device, in bytes"""
        # Get the partitions
        partitions = [udisks.get_object(p).get_partition()
                      for p in self.partition_table.props.partitions]
        # Get the ends of the partitions, in bytes
        partition_ends = [p.props.offset + p.props.size for p in partitions]
        # Return the end of the last partition, which is the beginning
        # of the free space.
        return max(partition_ends)


class Partition(object):
    """The Persistent Storage encrypted partition"""

    def __init__(self, udisks_object: UDisks.Object):
        self.udisks_object = udisks_object
        self.block = self.udisks_object.get_block()
        if not self.block:
            raise InvalidPartitionError("Device is not a block device")
        self.device_path = self.block.props.device
        self.partition = self.udisks_object.get_partition()  # type: UDisks.Partition
        if not self.partition:
            raise InvalidPartitionError(f"Device {self.device_path} is not a "
                                        f"partition")

    def get_cleartext_device(self) -> "CleartextDevice":
        """Get the cleartext device of Persistent Storage encrypted
        partition"""
        encrypted = self._get_encrypted()
        cleartext_device_path = encrypted.props.cleartext_device
        if cleartext_device_path == "/":
            raise PartitionNotUnlockedError(f"Device {self.device_path} is "
                                            f"not unlocked")
        return CleartextDevice(udisks.get_object(cleartext_device_path))

    def _get_encrypted(self) -> UDisks.Encrypted:
        """Get the UDisks.Encrypted interface of the partition"""
        encrypted = self.udisks_object.get_encrypted()
        if not encrypted:
            raise InvalidPartitionError(f"Device {self.device_path} is not "
                                        f"encrypted")
        return encrypted

    def is_unlocked(self) -> bool:
        try:
            self.get_cleartext_device()
            return True
        except (InvalidPartitionError, PartitionNotUnlockedError):
            return False

    def is_unlocked_and_mounted(self) -> bool:
        try:
            cleartext_device = self.get_cleartext_device()
            return cleartext_device.is_mounted()
        except (InvalidPartitionError, PartitionNotUnlockedError):
            return False

    @classmethod
    def exists(cls) -> bool:
        """Return true if the Persistent Storage partition exists and
        false otherwise."""
        return bool(cls.find())

    @classmethod
    def find(cls) -> Optional["Partition"]:
        """Return the Persistent Storage encrypted partition or None
        if it couldn't be found."""
        try:
            parent_device = BootDevice.get_tails_boot_device()
        except InvalidBootDeviceError:
            return None

        partitions = parent_device.partition_table.props.partitions
        for partition_name in sorted(partitions):
            partition = udisks.get_object(partition_name)
            if not partition:
                continue
            if partition.get_partition().props.name == PARTITION_LABEL:
                return Partition(partition)
        return None

    @classmethod
    def create(cls, job: Job, passphrase: str) -> "Partition":
        """Create the Persistent Storage encrypted partition"""

        # This should be the number of next_step() calls
        num_steps = 7
        current_step = 0

        def next_step(description: Optional[str] = None):
            nonlocal current_step
            progress = int((current_step / num_steps) * 100)
            job.refresh_properties(description, progress)
            current_step += 1

        parent_device = BootDevice.get_tails_boot_device()
        offset = parent_device.get_beginning_of_free_space()

        # Calculate the memory cost for Argon2id.
        # When letting cryptsetup choose the memory cost for Argon2id,
        # it sometimes triggers the OOM killer on low-memory systems.
        # We choose a memory cost which leaves some free memory to avoid
        # triggering the OOM killer.
        available_mem_kib = int(psutil.virtual_memory().available / 1024)
        mem_cost_kib = available_mem_kib - MEMORY_LEFT_TO_SYSTEM_KIB

        # Check that the memory cost is not too low, as it would result
        # in a weak key derivation function.
        if mem_cost_kib < MINIMUM_PBKDF_MEMORY_KIB:
            required_mem_kib = MEMORY_LEFT_TO_SYSTEM_KIB + MINIMUM_PBKDF_MEMORY_KIB
            msg = _("Only {available_memory} KiB of memory is available, need "
                    "at least {required_memory} KiB.\n\n"
                    "Try again after closing some applications or rebooting."
                    "").format(available_memory=available_mem_kib,
                               required_memory=required_mem_kib)
            raise NotEnoughMemoryError(msg)

        # Check that the memory cost is not above the maximum.
        mem_cost_kib = min(mem_cost_kib, MAXIMUM_PBKDF_MEMORY_KIB)

        # Create the partition
        logger.info("Creating partition")
        next_step(_("Creating a partition for the Persistent Storage..."))
        partition_table = parent_device.partition_table
        object_path = partition_table.call_create_partition_sync(
            arg_offset=offset,
            # Size 0 means maximal size
            arg_size=0,
            arg_type=PARTITION_GUID,
            arg_name=PARTITION_LABEL,
            arg_options=GLib.Variant('a{sv}', {}),
        )
        udisks.settle()

        # Get the UDisks partition object
        partition = Partition(udisks.get_object(object_path))

        # Initialize the LUKS partition via cryptsetup. We can't use
        # udisks for this because it doesn't support setting the key
        # derivation function which we want to set to argon2id.
        # See https://mjg59.dreamwidth.org/66429.html
        logger.info("Initializing LUKS header")
        next_step(_("Initializing the LUKS encryption... The computer might stop responding for a few seconds."))

        cmd = ["cryptsetup", "luksFormat",
               "--batch-mode",
               "--key-file=-",
               "--type=luks2",
               "--pbkdf=argon2id",
               f"--pbkdf-memory={mem_cost_kib}",
               partition.device_path]
        executil.check_call(cmd, input=passphrase)

        # Wait for the encrypted partition to become available to udisks
        next_step()
        wait_for_udisks_object(partition.device_path,
                               partition.udisks_object.get_encrypted)

        # Unlock the partition
        logger.info("Unlocking partition")
        next_step(_("Unlocking the encryption..."))
        partition.unlock(passphrase)

        # Get the cleartext device
        cleartext_device = partition.get_cleartext_device()

        # Format the cleartext device
        logger.info("Formatting filesystem")
        next_step(_("Formatting the file system..."))
        cleartext_device.block.call_format_sync(
            arg_type="ext4",
            arg_options=GLib.Variant('a{sv}', {
                "label": GLib.Variant('s', PARTITION_LABEL),
            }),
        )
        udisks.settle()

        # Mount the cleartext device
        logger.info("Mounting filesystem")
        next_step(_("Activating the Persistent Storage..."))
        cleartext_device.mount()

        next_step(_("Finishing setting up the Persistent Storage..."))

        return partition

    def delete(self):
        """Delete the Persistent Storage encrypted partition"""
        # Ensure that the partition is unmounted
        self._ensure_unmounted()

        # Delete the partition. By setting tear-down to true, udisks
        # automatically locks the encrypted device if it is currently
        # unlocked.
        self.partition.call_delete_sync(arg_options=GLib.Variant('a{sv}', {
            "tear-down": GLib.Variant('b', True),
        }))

    def unlock(self, passphrase: str):
        """Unlock the Persistent Storage encrypted partition"""
        encrypted = self._get_encrypted()

        try:
            encrypted.call_unlock_sync(
                arg_passphrase=passphrase,
                arg_options=GLib.Variant('a{sv}', {}),
                cancellable=None,
            )
        except GLib.Error as err:
            if err.matches(UDisks.error_quark(), UDisks.Error.FAILED) and \
                    re.search('Failed to activate device: (Operation not '
                              'permitted|Incorrect passphrase)', err.message):
                raise IncorrectPassphraseError(err) from err
            raise

        udisks.settle()

        # Get the cleartext device
        cleartext_device = self.get_cleartext_device()

        # Rename the cleartext device to "TailsData_unlocked", so that
        # is has the same name as after a reboot.
        cleartext_device.rename_dm_device("TailsData_unlocked")

    def _ensure_unmounted(self):
        try:
            cleartext_device = self.get_cleartext_device()
        except (InvalidPartitionError, PartitionNotUnlockedError):
            # There is no cleartext device for this partition, so there
            # is nothing to unmount
            return

        try:
            cleartext_device.force_unmount()
        except GLib.Error as err:
            if err.matches(UDisks.error_quark(), UDisks.Error.DEVICE_BUSY):
                msg = _(
                    "Can't unmount Persistent Storage, some process is still"
                    " using it. Please close all applications that could"
                    " be accessing it and try again. If that doesn't work,"
                    " restart Tails and try deleting the Persistent Storage"
                    " without unlocking it."
                )
                raise TargetIsBusyError(msg) from err
            # Ignore errors caused by the device not being mounted.
            if not err.matches(UDisks.error_quark(), UDisks.Error.NOT_MOUNTED):
                raise

    def change_passphrase(self, passphrase: str, new_passphrase: str):
        """Change the passphrase of the Persistent Storage encrypted
        partition"""
        encrypted = self._get_encrypted()
        try:
            encrypted.call_change_passphrase_sync(
                arg_passphrase=passphrase,
                arg_new_passphrase=new_passphrase,
                arg_options=GLib.Variant('a{sv}', {}),
            )
        except GLib.Error as err:
            if err.matches(UDisks.error_quark(), UDisks.Error.FAILED) and \
                    "No keyslot with given passphrase found" in err.message:
                raise IncorrectPassphraseError(err) from err
            raise


class CleartextDevice(object):
    def __init__(self, udisks_object: UDisks.Object):
        self.udisks_object = udisks_object
        self.block = self.udisks_object.get_block()
        if not self.block:
            raise InvalidCleartextDeviceError("Device is not a block device")
        self.device_path = self.block.props.device
        self.mount_point = Path(TPS_MOUNT_POINT)

    def is_mounted(self):
        p = executil.run(["findmnt", f"--source={self.device_path}",
                          f"--mountpoint={str(self.mount_point)}"])
        if p.returncode == 0:
            return True
        if p.returncode == 1:
            return False
        # If the return code is not 0 and not 1, something unexpected
        # happened, so we raise a CalledProcessException
        p.check_returncode()

    def mount(self):
        # Ensure that the mount point exists
        self.mount_point.mkdir(mode=0o770, parents=True, exist_ok=True)

        # Mount the Persistent Storage partition
        executil.check_call(["mount", "-o", "acl", self.device_path,
                             self.mount_point])

        # Ensure that the mount point has the correct owner, permissions
        # and ACL.
        # Permissions are set to 770. ACLs are set to allow the amnesia
        # user to traverse the directory, which is needed for mounts
        # using the link option (e.g. dotfiles).
        # refs: #7465
        os.chown(self.mount_point, uid=0, gid=0)
        self.mount_point.chmod(0o770)
        executil.check_call(["/bin/setfacl", "--remove-all",
                             self.mount_point])
        executil.check_call(["/bin/setfacl", "--modify",
                             f"user:{LIVE_USERNAME}:x", self.mount_point])

        # Ensure that all persistent directories have safe permissions.
        # refs: #7458
        for d in self.mount_point.iterdir():
            if not d.is_dir():
                continue
            # Note: we chmod even custom persistent directories.
            # This may break things by changing otherwise correct
            # permissions copied from the directory that was made
            # persistent, so we only do that if the persistent directory
            # is owned by amnesia:amnesia, and thus unlikely to be
            # a system directory. This e.g. avoids setting wrong
            # permissions on the APT, CUPS and NetworkManager
            # persistent directories.
            if d.stat().st_uid != LIVE_USER_UID or \
                    d.stat().st_gid != LIVE_USER_UID:
                continue
            # Remove all permissions for group and others
            current = stat.S_IMODE(d.stat().st_mode)
            d.chmod(current & ~stat.S_IRWXG & ~stat.S_IRWXO)

    def force_unmount(self):
        filesystem = self.udisks_object.get_filesystem()
        if not filesystem:
            # There is no filesystem, so there is nothing to unmount
            return
        # Unmount the filesystem until no mount points are left
        while filesystem.props.mount_points:
            filesystem.call_unmount_sync(arg_options=GLib.Variant('a{sv}', {
                # We do not unmount with force, because if force is
                # necessary, locking the encrypted device will fail with
                # "device is still in use", which would leave the
                # device unlocked and unmounted, which is an
                # inconsistent state. Instead, if the device is still
                # in use, we let the unmount call fail already, which
                # will leave the device in a "good" state (unlocked and
                # mounted).
                "force": GLib.Variant('b', False),
            }))

    def get_dm_name(self) -> Optional[str]:
        udisks_devno = self.block.props.device_number
        out = executil.check_output(["dmsetup", "ls", "-o", "devno"])
        for line in out.strip().split("\n"):
            name, devno = line.split()
            if devno == f"({os.major(udisks_devno)}:{os.minor(udisks_devno)})":
                return name
        return None

    def rename_dm_device(self, new_name: str):
        dm_name = self.get_dm_name()
        if not dm_name:
            logger.warning("Can't rename dm device: dm name not found")
            return
        executil.check_call(["dmsetup", "rename", dm_name, new_name])


def wait_for_udisks_object(device: str,
                           func: Callable[[...], Optional[UDisks.Object]],
                           *args,
                           timeout: int = 20) -> UDisks.Object:
    """Repeatedly call `udevadm trigger` and then func() until func()
    returns a udisks object or timeout is reached."""
    start = time.time()
    while time.time() - start < timeout:
        executil.check_call(["udevadm", "trigger"])
        obj = func(*args)
        if obj:
            return obj
        time.sleep(1)
        continue
    raise TimeoutError("Timeout while waiting for udisks object")
