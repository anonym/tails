"""
This module is meant to provide informations about Tails release data
(ie: /etc/tails/version).
"""

import datetime


def get_release_date() -> datetime.datetime:
    with open('/etc/tails/version') as buf:
        firstline = next(iter(buf))
    _, source_date = firstline.split(' - ')
    source_date = source_date.strip()
    source_dt = datetime.datetime.strptime(source_date, '%Y%m%d')
    source_dt = source_dt.replace(tzinfo=datetime.timezone.utc)
    return source_dt
