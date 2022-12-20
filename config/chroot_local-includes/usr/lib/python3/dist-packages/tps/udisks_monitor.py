from abc import ABCMeta, abstractmethod
from gi.repository import Gio, GLib, UDisks
from typing import TYPE_CHECKING

from tps import udisks

if TYPE_CHECKING:
    from tps.device import BootDevice
    from tps.job import Job

SERVICE_NAME = "org.freedesktop.UDisks2"
OBJECT_NAME = "/org/freedesktop/UDisks2"


class UDisksMonitor(object, metaclass=ABCMeta):
    def __init__(self, job: "Job", device: "BootDevice"):
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)  # type: Gio.DBusConnection
        self.job = job
        self.device = device
        self.step = 0

    def __enter__(self):
        self.manager = Gio.DBusObjectManagerClient.new_sync(
            self.bus,
            Gio.DBusObjectManagerClientFlags.NONE,
            SERVICE_NAME,
            OBJECT_NAME,
            None,
            None,
            None,
        )  # type: Gio.DBusObjectManagerClient
        self.manager.connect("object-added", self.on_object_added)

    def __exit__(self, exc_type, exc_val, exc_tb):
        pass

    @property
    @abstractmethod
    def expected_steps(self) -> int:
        pass

    @abstractmethod
    def on_job_added(self, job: UDisks.Job):
        pass

    def on_next_job_started(self, job: UDisks.Job):
        description = udisks.get_job_description(job)
        self.job.Status = description
        progress = self.step / self.expected_steps
        self.job.Progress = int(progress * 100)
        self.step += 1

    def on_object_added(self, manager, object: Gio.DBusObjectProxy):
        if not object.get_interface("org.freedesktop.UDisks2.Job"):
            return

        udisks_obj = udisks.get_object(object.get_object_path())  # type: UDisks.Object
        job = udisks_obj.get_job()  # type: UDisks.Job
        GLib.idle_add(self.on_job_added, job)


class UDisksCreationMonitor(UDisksMonitor):
    expected_steps = 4

    def on_job_added(self, job: UDisks.Job):
        # All the jobs we expect to be spawned are only for one object
        if len(job.props.objects) != 1:
            return
        handled_obj = udisks.get_object(job.props.objects[0])

        if self.step == 0:
            # We expect a partition-create job for the boot device
            if job.props.operation != "partition-create":
                return
            if self.is_boot_device(handled_obj):
                self.on_next_job_started(job)
        elif self.step in (1, 2):
            # We expect a format-mkfs job for a partition of the boot device
            # I'm not sure why two jobs are started for this, but they are.
            if job.props.operation != "format-mkfs":
                return
            if self.is_partition_of_boot_device(handled_obj):
                self.on_next_job_started(job)
        elif self.step == 3:
            # We expect a format-mkfs job for the cleartext device of
            # a partition of the boot device
            if job.props.operation != "format-mkfs":
                return
            block = handled_obj.get_block()
            if not block:
                return
            crypto_backing_obj = udisks.get_object(
                block.props.crypto_backing_device)
            if self.is_partition_of_boot_device(crypto_backing_obj):
                self.on_next_job_started(job)

    def is_boot_device(self, obj: UDisks.Object) -> bool:
        block = obj.get_block()
        if not block:
            return False
        device_path = block.props.device
        return device_path == self.device.device_path

    def is_partition_of_boot_device(self, obj: UDisks.Object) -> bool:
        partition = obj.get_partition()
        if not partition:
            return False
        partition_table_obj = udisks.get_object(partition.props.table)
        if not partition_table_obj:
            return False
        return self.is_boot_device(partition_table_obj)
