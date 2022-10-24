"""Miscelaneous Tails Python utilities."""

import contextlib
import os
import logging
import subprocess

from tailslib import LIVE_USERNAME

X_ENV = {"DISPLAY": ":1",
         "XAUTHORITY": "/run/user/1000/gdm/Xauthority"}


# Credits go to kurin from this Reddit thread:
#   https://www.reddit.com/r/Python/comments/1sxil3/chdir_a_context_manager_for_switching_working/ce29rcm
@contextlib.contextmanager
def chdir(path):
    curdir = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(curdir)


def launch_x_application(command, *args):
    """Launch an X application as LIVE_USERNAME and wait for its completion."""
    cmdline = ["sudo", "-u", LIVE_USERNAME, command]
    cmdline.extend(args)
    try:
        subprocess.run(cmdline,
                       stderr=subprocess.PIPE,
                       env=X_ENV,
                       check=True,
                       universal_newlines=True)
    except subprocess.CalledProcessError as e:
        logging.error("{command} returned with {returncode}".format(
            command=command, returncode=e.returncode))
        for line in e.stderr.splitlines():
            logging.error(line)
        raise


def spawn_x_application(command, *args):
    """Launch an X application as LIVE_USERNAME without blocking."""
    cmdline = ["sudo", "-u", LIVE_USERNAME, command]
    cmdline.extend(args)
    subprocess.Popen(cmdline,
                     stderr=subprocess.PIPE,
                     env=X_ENV,
                     universal_newlines=True)
