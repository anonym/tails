#!/usr/bin/python3
import sys
from functools import lru_cache
import os
from pathlib import Path
import pwd

USER_ENV_FILE = "/run/user/{uid}/user-env"

@lru_cache(maxsize=1)
def user_env(user=None) -> dict:
    if user is None:
        uid = os.geteuid()
    else:
        uid = pwd.getpwnam(user).pw_uid

    env = dict()
    env_file = USER_ENV_FILE.format(uid=uid)
    for line in Path(env_file).read_text().split('\0'):
        if not line:
            continue
        try:
            key, value = line.split("=", 1)
        except Exception as e:
            print(f"Invalid environment variable: '{line}'", file=sys.stderr)
            raise e
        env[key] = value
    return env


def user_env_vars(user=None) -> list:
    return [f"{key}={value}" for key, value in user_env(user).items()]
