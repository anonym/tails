"""Tails persistence related tests."""

import os
import subprocess

from tailslib.utils import start_as_transient_user_scope_unit


PERSISTENCE_DIR = "/live/persistence/TailsData_unlocked"
PERSISTENCE_PARTITION = "/dev/disk/by-partlabel/TailsData"


def get_persistence_path(return_nonexistent=False) -> str:
    """Return the path of the (newly created) persistence.

    Return PERSISTENCE_DIR if it exists.

    If return_nonexistent is true, also return PERSISTENCE_DIR if it
    does not exist.

    If no persistence directory exists and return_nonexistent is false,
    raise FileNotFoundError.
    """
    if os.path.isdir(PERSISTENCE_DIR) or return_nonexistent:
        return PERSISTENCE_DIR
    else:
        raise FileNotFoundError(
            "No persistence directory found in {dir}".format(
                dir=PERSISTENCE_DIR))


def has_persistence():
    """Return true iff PERSISTENCE_PARTITION exists."""
    return os.path.exists(PERSISTENCE_PARTITION)


def has_unlocked_persistence():
    """Return true iff a persistence directory exists."""
    try:
        get_persistence_path()
    except FileNotFoundError:
        return False
    else:
        return True


def is_tails_media_writable():
    """Return true iff tails is started from a writable media."""
    return subprocess.run(
        "/usr/local/lib/tails-boot-device-can-have-persistence"
    ).returncode == 0


def spawn_tps_frontend(*args):
    """Launch tps-frontend, don't wait for its completion."""
    start_as_transient_user_scope_unit("/usr/local/bin/tps-frontend-wrapper",
                                       *args)


def additional_software_persistence_feature_is_active() -> bool:
    """Return True iff the AdditionalSoftware feature is active."""
    return subprocess.run(
        ["/usr/local/lib/tpscli", "is-active", "AdditionalSoftware"]
    ).returncode == 0
