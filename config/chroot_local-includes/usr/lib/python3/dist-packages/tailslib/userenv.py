#!/usr/bin/python3
import sys
from functools import lru_cache
import os
from pathlib import Path
import pwd
from typing import Mapping

ENV_VARS_TO_DUMP = [
    "DBUS_SESSION_BUS_ADDRESS",
    "DISPLAY",
    "LANG",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XDG_RUNTIME_DIR",
    "XDG_CURRENT_DESKTOP",
]

ALLOWED_ENV_VARS = ENV_VARS_TO_DUMP + [
    "DESKTOP_STARTUP_ID",
]

USER_ENV_FILE_TEMPLATE = "/run/user/{uid}/user-env"


def user_env_file(uid):
    return USER_ENV_FILE_TEMPLATE.format(uid=uid)


def allowed_env(env: Mapping) -> dict:
    """
    >>> allowed_env({"PATH": "/home/", "LANG": "en"})
    {'LANG': 'en'}
    """
    return {key: value for key, value in env.items() if key in ALLOWED_ENV_VARS}


def read_allowed_env_from_file(envfile: str) -> dict:
    env = dict()

    for line in Path(envfile).read_text().split('\0'):
        if not line:
            continue

        try:
            key, value = line.split("=", 1)
        except Exception as e:
            print(f"Invalid environment variable: '{line}'", file=sys.stderr)
            raise e

        env[key] = value

    return allowed_env(env)


@lru_cache(maxsize=1)
def read_user_env(user=None) -> dict:
    if user is None:
        uid = os.geteuid()
    else:
        uid = pwd.getpwnam(user).pw_uid

    return read_allowed_env_from_file(user_env_file(uid))


def user_env_vars(user=None) -> list:
    return [f"{key}={value}" for key, value in read_user_env(user).items()]
