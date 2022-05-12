#!/usr/bin/python3

import shlex
import subprocess
from functools import lru_cache

GNOME_SH_PATH = "/usr/local/lib/tails-shell-library/gnome.sh"

def _gnome_sh_wrapper(cmd) -> str:
    command = shlex.split(
        "env -i sh -c '. {lib} && {cmd}'".format(lib=GNOME_SH_PATH, cmd=cmd)
    )
    return subprocess.check_output(command).decode()


@lru_cache(maxsize=1)
def _get_gnome_env_vars():
    return _gnome_sh_wrapper("echo ${GNOME_ENV_VARS}").strip().split()


def gnome_env_vars() -> list:
    ret = []
    for line in _gnome_sh_wrapper("export_gnome_env && env").split("\n"):
        (key, _, value) = line.rstrip().partition("=")
        if key in _get_gnome_env_vars():
            ret.append(key + "=" + value)
    return ret
