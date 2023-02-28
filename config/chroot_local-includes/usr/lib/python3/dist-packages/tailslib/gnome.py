#!/usr/bin/python3

import glob
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

def gnome_env() -> dict:
    env = dict()
    for line in _gnome_sh_wrapper("gnome_env").split("\n"):
        (key, _, value) = line.rstrip().partition("=")
        if key in _get_gnome_env_vars():
            env[key] = value
    if 'DISPLAY' not in env:
        env['DISPLAY'] = ':0'
    if 'XAUTHORITY' not in env:
        if xauths := glob.glob('/run/user/1000/.mutter-Xwaylandauth.*'):
            env['XAUTHORITY'] = xauths[0]
    if 'WAYLAND_DISPLAY' not in env:
        if displays := glob.glob('/run/user/1000/wayland-*'):
            env['WAYLAND_DISPLAY'] = displays[0]
    return env


def gnome_env_vars() -> list:
    return [f"{key}={value}" for key, value in gnome_env().items()]
