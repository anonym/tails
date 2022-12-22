# Tails configuration file for WhisperBack
# ==========================================
#
# This is a Python script that will be read at startup. Any Python
# syntax is valid.

# IMPORTS

# Custom imports
import os
import subprocess
import random
import re
import locale
import gettext

# DOCUMENTATION


def _(string):
    try:
        encoded = gettext.translation("tails", "/usr/share/locale").lgettext(string)
        string = encoded.decode('utf-8')
    except IOError:
        pass
    finally:
        return string


# ENCRYPTION
#
# This section defines encryption parameters

# The path to the OpenPGP keyring to use. If None, use OpenPGP default
# keyring.
gnupg_keyring = "/usr/share/keyrings/whisperback-keyring.gpg"

# RECIPIENT
#
# This section defines the recepient parameters

# The address of the recipient
to_address = "tails-bugs@boum.org"

# The fingerprint of the recipient's GPG key
to_fingerprint = "1F56EDD30741048035DAC1C5EC57B56EF0C43132"

# SENDER
#
# This section defines the sender parameters

# The address of the sender
from_address = "devnull@tails.boum.org"

# SMTP
#
# This section defines the SMTP server parameters
#
# The SMTP server to use to send the mail
smtp_host = "xgvhluz6szspb2od6yi37cs4tdm27hgjunbig23yc5hxececcax5wlyd.onion"
# The port to connect to on that SMTP server
smtp_port = 25

# SOCKS
#
# This section defines the SOCKS proxy parameters
#
# The SOCKS proxy to use to send the mail
socks_host = "127.0.0.1"
# The port to connect to on that SOCKS proxy
socks_port = 9062

# MESSAGE
#
# This section defines the message parameters

# The subject of the email to be sent
# Please take into account that this will not be encrypted
mail_subject = "Bug report: %x" % random.randrange(16**32)


def mail_prepended_info():
    """Return the version of the running Tails system.

    A callback function to get information to prepend to the mail
    (this information will be encrypted). This is useful to add
    software version.

    It should not take any parameter, and should return a string to be
    preprended to the email

    @return The output of tails-version, if any, or an English string
            explaining the error
    """
    try:
        tails_version_process = subprocess.Popen("tails-version",
                                                 stdout=subprocess.PIPE)
        tails_version_process.wait()
        tails_version = tails_version_process.stdout.read().decode('utf-8')
    except OSError:
        tails_version = "tails-version command not found"
    except subprocess.CalledProcessError:
        tails_version = "tails-version returned an error"

    return "Tails-Version: %s\n" % tails_version


def mail_appended_info():
    """Return debugging information on the running Tails system.

    A callback function to get information to append to the email
    (this information will be encrypted). This is useful to add
    configuration files useful for debugging.

    It should not take any parameter, and should return a string serialized
    json to be deserialized to append infos to the email

    @return a string containing serialized json with debugging information
    """
    debugging_info = ""

    try:
        process = subprocess.Popen(["sudo", "/usr/local/sbin/tails-debugging-info"],
                                   stdout=subprocess.PIPE)
        for line in process.stdout:
            debugging_info += re.sub(r'^--\s*', '', line.decode('utf-8'))
        process.wait()
    except OSError:
        debugging_info += "sudo command not found\n"
    except subprocess.CalledProcessError:
        debugging_info += "debugging command returned an error\n"
    return debugging_info
