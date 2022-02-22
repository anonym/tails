"""
This module is meant to provide informations about Tails release data
(ie: /etc/amnesia/version).
"""

import datetime


def get_release_date() -> datetime.datetime:
    with open('/etc/amnesia/version') as buf:
        firstline = next(iter(buf))
    _, source_date = firstline.split(' - ')
    source_dt = datetime.datetime.strptime(source_date, '%Y%m%d')
    return source_dt
