"""Miscelaneous Tails Python utilities."""

import contextlib
import glob
import os
import logging
import subprocess

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


def run_with_user_env(command, *args):
    """Run a command as amnesia and wait for its completion."""
    cmdline = ["/usr/local/lib/run-with-user-env", command, *args]
    try:
        subprocess.run(cmdline,
                       stderr=subprocess.PIPE,
                       check=True,
                       universal_newlines=True)
    except subprocess.CalledProcessError as e:
        logging.error("{command} returned with {returncode}".format(
            command=command, returncode=e.returncode))
        for line in e.stderr.splitlines():
            logging.error(line)
        raise


def start_as_transient_user_scope_unit(command, *args):
    """Launch a command as amnesia and return immediately. The command
    is run as a transient systemd user scope unit, so it doesn't exit
    when the parent process exits."""
    cmdline = ["/usr/local/lib/run-with-user-env", "--systemd-run",
               command, *args]
    subprocess.Popen(cmdline,
                     stderr=subprocess.PIPE,
                     universal_newlines=True)
