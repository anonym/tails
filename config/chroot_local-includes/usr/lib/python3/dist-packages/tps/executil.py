import logging
from os import PathLike
from pathlib import Path
import subprocess
from typing import List, Union

logger = logging.getLogger(__name__)

def run(cmd: List, *args, **kwargs) -> subprocess.CompletedProcess:
    cmd = [str(s) for s in cmd]
    logger.debug(f"Executing command {' '.join(cmd)}", stacklevel=2)
    return subprocess.run(cmd, *args, **kwargs)


def check_call(cmd: List, *args, **kwargs):
    cmd = [str(s) for s in cmd]
    logger.debug(f"Executing command {' '.join(cmd)}", stacklevel=2)
    subprocess.check_call(cmd, *args, **kwargs)


def check_output(cmd: List, *args, **kwargs) -> str:
    cmd = [str(s) for s in cmd]
    logger.debug(f"Executing command {' '.join(cmd)}", stacklevel=2)
    return subprocess.check_output(cmd, text=True, *args, **kwargs)


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
        subprocess.check_call([file])
