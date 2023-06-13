#!/usr/bin/python3
"""
Standalone/module to simplify composing emails.

The purpose of this module is to make it easier to convert machine-ready emails into actually composing
emails.
"""

import time
import sys
from argparse import ArgumentParser
from email.parser import Parser
from email import policy
import tempfile
from pathlib import Path
import subprocess


def parse(body: str):
    msg = Parser(policy=policy.default).parsestr(body)
    return msg


def mailer_thunderbird(body: str):
    msg = parse(body)
    spec = []
    for key in ['to', 'cc', 'subject']:
        if key in msg:
            spec.append(f"{key}='{msg[key]}'")
    with tempfile.TemporaryDirectory() as tmpdir:
        fpath = Path(tmpdir) / 'email.eml'
        with fpath.open('w') as fp:
            fp.write(msg.get_body().get_content())
        spec.append("format=text")
        spec.append(f"message={fpath}")
        cmdline = ['thunderbird', '-compose', ','.join(spec)]
        subprocess.check_output(cmdline)

        # this is a workaround to the fact that Thunderbird will terminate *before* reading the file
        # we don't really know how long does it take, but let's assume 2s are enough
        time.sleep(2)


def mailer(mailer: str, body: str):
    if mailer == 'thunderbird':
        return mailer_thunderbird(body)
    if mailer == 'notmuch':
        return mailer_notmuch(body)
    if not mailer or mailer == 'print':
        print(body)


def add_parser_mailer(parser: ArgumentParser):
    parser.add_argument('--mailer', default=None, choices=['print', 'thunderbird', 'notmuch'])


if __name__ == '__main__':
    parser = ArgumentParser()
    add_parser_mailer(parser)
    args = parser.parse_args()
    body = sys.stdin.read()
    mailer(args.mailer, body)
