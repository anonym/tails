import logging
import os.path
import tempfile
from os import PathLike
import sys
from pathlib import Path
import subprocess
from typing import List, Union

import tps
import tps.logging

logger = tps.logging.get_logger(__name__)


def _run(cmd: List, *args, **kwargs) -> subprocess.CompletedProcess:
    """Run a command and print it's stderr continuously but also return
    stderr in the return CompletedProcess and any raised CalledProcessError.

    This allows us to have stderr both in the logs of the tps service
    and in the error message which might be returned to the client."""
    cmd = [str(s) for s in cmd]
    # This method will be called from executil.run() (or check_call, or check_output),
    # and we want to attribute the log message to its caller
    # we should use logger.debug, but #19871 pushes us towards higher log level
    logger.info(f"Executing command {' '.join(cmd)}", stacklevel=5)

    if tps.PROFILING:
        cmd = prepare_for_profiling(cmd)

    kwargs["stderr"] = subprocess.PIPE
    kwargs["text"] = True
    try:
        p = subprocess.run(cmd, *args, **kwargs)
    except subprocess.CalledProcessError as e:
        print(e.stderr, file=sys.stderr)
        raise
    else:
        print(p.stderr, file=sys.stderr)
        return p
    finally:
        logger.debug(f"Done executing command", stacklevel=5)


def run(cmd: List, *args, **kwargs) -> subprocess.CompletedProcess:
    return _run(cmd, *args, **kwargs)


def check_call(cmd: List, *args, **kwargs):
    return _run(cmd, *args, **kwargs, check=True)


def check_output(cmd: List, *args, **kwargs) -> str:
    p = _run(cmd, *args, **kwargs, check=True, stdout=subprocess.PIPE)
    return p.stdout


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
        logger.info(f"Executing hook {file}", stacklevel=4)
        try:
            check_call([str(file)])
        finally:
            logger.debug(f"Done executing hook", stacklevel=4)


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
