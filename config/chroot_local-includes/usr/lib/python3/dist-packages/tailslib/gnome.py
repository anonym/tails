#!/usr/bin/python3

from functools import lru_cache
import os
from pathlib import Path
import pwd

GNOME_ENV_FILE = "/run/user/{uid}/gnome-env"

@lru_cache(maxsize=1)
def gnome_env(user=None) -> dict:
    if user is None:
        uid = os.geteuid()
    else:
        uid = pwd.getpwnam(user).pw_uid

    env = dict()
    env_file = GNOME_ENV_FILE.format(uid=uid)
    for line in Path(env_file).read_text().split('\0'):
        if not line:
            continue
        key, value = line.split("=", 1)
        env[key] = value
    return env


def gnome_env_vars(user=None) -> list:
    return [f"{key}={value}" for key, value in gnome_env(user).items()]
