#!/usr/bin/env python3
"""
This module is useful for all those scripts that are meant to run a specific application inside a network namespace.

This functions make many assumptions about the working of it; that's in the hope that those scripts will keep
a somewhat similar structure. This is:
    - the netns has already been created, of course
    - somewhere in /etc/sudoers.d/ the wrapper can be run as root
    - the systemd user unit tails-a11y-bus-proxy is running
"""
import os
import logging

from tailslib.userenv import user_env_vars
from tailslib import LIVE_USERNAME

A11Y_BUS_PROXY_PATH="/run/user/1000/.dbus-proxy/a11y-bus-proxy.sock"
IBUS_PROXY_PATH="/run/user/1000/.dbus-proxy/ibus-proxy.sock"
A11Y_BUS_SANDBOX_PATH="/run/user/1000/tails-sandbox/a11y-bus-proxy.sock"
IBUS_SANDBOX_PATH="/run/user/1000/tails-sandbox/ibus-proxy.sock"


def run_in_netns(*args, netns, root="/", bind_mounts=[]):
    # base bwrap sharing most of the system
    bwrap = ["bwrap", "--bind", root, "/", "--proc", "/proc", "--dev", "/dev"]
    for src, dest in bind_mounts:
        bwrap += ["--bind", src, dest]

    bwrap += [
        "--bind", A11Y_BUS_PROXY_PATH, A11Y_BUS_SANDBOX_PATH,
        "--bind", IBUS_PROXY_PATH, IBUS_SANDBOX_PATH,
    ]

    ch_netns = ["ip", "netns", "exec", netns]
    runuser = ["/sbin/runuser", "-u", LIVE_USERNAME]
    envcmd = [
        "/usr/bin/env", "--",
        *user_env_vars(LIVE_USERNAME),
        f"AT_SPI_BUS_ADDRESS=unix:path={A11Y_BUS_SANDBOX_PATH}",
        f"IBUS_ADDRESS=unix:path={IBUS_SANDBOX_PATH}",
    ]
    # We run tca with several wrappers to accomplish our privilege-isolation-magic:
    # connect_drop: opens a privileged file and pass FD to new process
    # ch_netns: enter the new namespace
    # runuser: change back to unprivileged user
    # bwrap: Mount D-Bus proxies. See also tails-a11y-bus-proxy.service and tails-ibus-proxy.service.
    # envcmd: set the "right" environment; this means getting all "normal" gnome variables, AND clarifying
    #         where is the {a11y,ibus} bus, which is related to bwrap

    cmd = [*ch_netns, *runuser, "--", *bwrap, "--", *envcmd, *args]
    logging.info("Running %s", cmd)
    os.execvp(cmd[0], cmd)


def run(
    real_executable: str,
    netns: str,
    wrapper_executable: str,
    keep_env=True,
    extra_env={},
    extra_args=[],
):
    if os.getuid() == 0:
        run_in_netns(real_executable, *extra_args, netns=netns)
    else:
        env = os.environ.copy() if keep_env else {}
        env.update(extra_env)
        args = ["sudo", "--non-interactive", wrapper_executable] + extra_args
        os.execvpe(args[0], args, env=env)
