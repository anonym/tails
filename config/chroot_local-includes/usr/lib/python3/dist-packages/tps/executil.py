import logging
import os.path
import tempfile
from os import PathLike
from pathlib import Path
import subprocess
from typing import List, Union

import tps
import tps.logging

logger = tps.logging.get_logger(__name__)


def run(cmd: List, *args, **kwargs) -> subprocess.CompletedProcess:
    cmd = [str(s) for s in cmd]
    logger.debug(f"Executing command {' '.join(cmd)}", stacklevel=2)
    if tps.PROFILING:
        cmd = prepare_for_profiling(cmd)
    try:
        return subprocess.run(cmd, *args, **kwargs)
    finally:
        logger.debug(f"Done executing command", stacklevel=2)


def check_call(cmd: List, *args, **kwargs):
    cmd = [str(s) for s in cmd]
    logger.debug(f"Executing command {' '.join(cmd)}", stacklevel=2)
    if tps.PROFILING:
        cmd = prepare_for_profiling(cmd)
    try:
        subprocess.check_call(cmd, *args, **kwargs)
    finally:
        logger.debug(f"Done executing command", stacklevel=2)


def check_output(cmd: List, *args, **kwargs) -> str:
    cmd = [str(s) for s in cmd]
    logger.debug(f"Executing command {' '.join(cmd)}", stacklevel=2)
    if tps.PROFILING:
        cmd = prepare_for_profiling(cmd)
    try:
        return subprocess.check_output(cmd, text=True, *args, **kwargs)
    finally:
        logger.debug(f"Done executing command", stacklevel=2)


def execute_hooks(hooks_dir: Union[str, PathLike]):
    """
    Execute all regular files in the specified directory, in (locale) lexicographic order.

    If any of these runs fails, the execution is stopped, and an exception is raised immediately.
    """
    hooks_dir = Path(hooks_dir)
    if not hooks_dir.exists():
        return

    for file in sorted(hooks_dir.iterdir()):
        if file.is_dir():
            continue
        logger.info(f"Executing hook {file}", stacklevel=2)
        cmd = [str(file)]
        if tps.PROFILING:
            cmd = prepare_for_profiling(cmd)
        try:
            subprocess.check_call(cmd)
        finally:
            logger.debug(f"Done executing hook", stacklevel=2)


def prepare_for_profiling(cmd: List) -> List:
    uptime = Path("/proc/uptime").read_text().split()[0]
    profile_file = tempfile.NamedTemporaryFile(prefix=f"{uptime}-{os.path.basename(cmd[0])}.",
                                               dir=tps.PROFILES_DIR,
                                               delete=False)
    profile_file.close()
    logger.info(f"Creating profile in {profile_file.name}")
    return [
        "strace",
        "--follow-forks",
        "--quiet",
        "--relative-timestamps",
        "--syscall-times",
        "--summary",
        "--trace=file,process,network,signal,ipc,desc,memory",
        f"--output={profile_file.name}"] + cmd
