from enum import Enum
import gettext
import gi
import os

_ = gettext.gettext

# Don't connect to the udisks service when we're just running the
# tests - they don't use it and it might not even be running,
# which would cause this line to throw an exception
udisks = None
if not os.getenv("BEHAVE") and not os.getenv("NO_UDISKS"):
    gi.require_version('UDisks', '2.0')
    from gi.repository import UDisks
    # noinspection PyArgumentList
    udisks = UDisks.Client.new_sync()  # type: UDisks.Client

DBUS_SERVICE_NAME = "org.boum.tails.PersistentStorage"
DBUS_ROOT_OBJECT_PATH = "/org/boum/tails/PersistentStorage"
DBUS_FEATURES_PATH = "/org/boum/tails/PersistentStorage/Features"
DBUS_JOBS_PATH = "/org/boum/tails/PersistentStorage/Jobs"
DBUS_SERVICE_INTERFACE = "org.boum.tails.PersistentStorage"
DBUS_FEATURE_INTERFACE = "org.boum.tails.PersistentStorage.Feature"
DBUS_JOB_INTERFACE = "org.boum.tails.PersistentStorage.Job"

TPS_MOUNT_POINT = "/live/persistence/TailsData_unlocked"
TPS_BACKUP_MOUNT_POINT = "/media/amnesia/TailsData"

SYSTEM_PARTITION_MOUNT_POINT = "/lib/live/mount/medium"
LUKS_HEADER_BACKUP_PATH = SYSTEM_PARTITION_MOUNT_POINT + "/luks-header-backup"

ON_ACTIVATED_HOOKS_DIR = "/usr/local/lib/persistent-storage/on-activated-hooks"
ON_DEACTIVATED_HOOKS_DIR = "/usr/local/lib/persistent-storage/on-deactivated-hooks"


class State(Enum):
    UNKNOWN = 0
    ERROR = 1
    NOT_CREATED = 2
    CREATING = 3
    DELETING = 4
    NOT_UNLOCKED = 5
    UNLOCKING = 6
    UNLOCKED = 7
    UPGRADING = 8


IN_PROGRESS_STATES = (State.CREATING, State.DELETING, State.UNLOCKING)

PROFILING = False
PROFILES_DIR = "/run/tails-persistent-storage/profiles"
