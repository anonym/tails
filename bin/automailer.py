#!/usr/bin/python3
"""
Standalone/module to simplify composing emails.

The purpose of this module is to make it easier to convert machine-ready emails into actually composing
emails.
"""

import os.path
import time
import sys
from argparse import ArgumentParser, ArgumentDefaultsHelpFormatter
from email.parser import Parser
from email import policy
import tempfile
from pathlib import Path
import subprocess

from xdg.BaseDirectory import xdg_config_home  # type: ignore


def read_config() -> dict:
    config_files = sorted(
        list((Path(xdg_config_home) / "tails/automailer/").glob("*.toml"))
    )
    if not config_files:
        return {}
    try:
        import toml
    except ImportError:
        print(
            "Warning: could not import `toml`. Your configuration will be ignored",
            file=sys.stderr,
        )
        return {}

    data = {}
    for fpath in config_files:
        data.update(toml.load(open(fpath)))
    return data


def parse(body: str):
    header, body = body.split("\n\n", 1)
    msg = Parser(policy=policy.default).parsestr(header)
    return msg, body


def mailer_thunderbird(body: str):
    msg, body = parse(body)
    spec = []
    for key in ["to", "cc", "subject"]:
        if key in msg:
            spec.append(f"{key}='{msg[key]}'")
    if 'x-attach' in msg:
        attachments = []
        for fpath in msg['x-attach'].split(','):
            fpath = fpath.strip()
            if not fpath:
                continue
            if not os.path.exists(fpath):
                print(f"Skipping attachemt '{fpath}': not found", file=sys.stderr)
                continue
            attachments.append(fpath)
        if attachments:
            spec.append("attachment='%s'" % ','.join(attachments))


    with tempfile.TemporaryDirectory() as tmpdir:
        fpath = Path(tmpdir) / "email.eml"
        with fpath.open("w") as fp:
            fp.write(body)
        spec.append("format=text")
        spec.append(f"message={fpath}")
        cmdline = ["thunderbird", "-compose", ",".join(spec)]
        subprocess.check_output(cmdline)

        # this is a workaround to the fact that Thunderbird will terminate *before* reading the file
        # we don't really know how long does it take, but let's assume 2s are enough
        time.sleep(2)


def mailer_notmuch(body: str):
    msg, body = parse(body)
    cmdline = ["notmuch-emacs-mua", "--client", "--create-frame"]

    for key in ["cc", "subject"]:
        if key in msg:
            cmdline.append(f"--{key}={msg[key]}")

    for address in msg["to"].split(","):
        cmdline.append(address.strip())

    subprocess.check_output(cmdline)


def mailer(mailer: str, body: str):
    if mailer == "thunderbird":
        return mailer_thunderbird(body)
    elif mailer == "notmuch":
        return mailer_notmuch(body)
    elif not mailer or mailer == "print":
        print(body)
    else:
        print(f"Unsupported mailer: '{mailer}'")


def add_parser_mailer(parser: ArgumentParser, config: dict):
    parser.add_argument(
        "--mailer",
        default=config.get("mailer"),
        choices=["print", "thunderbird", "notmuch"],
        help="Your favorite MUA",
    )


if __name__ == "__main__":
    config = read_config()
    parser = ArgumentParser(formatter_class=ArgumentDefaultsHelpFormatter)
    add_parser_mailer(parser, config)
    args = parser.parse_args()
    body = sys.stdin.read()
    mailer(args.mailer, body)
