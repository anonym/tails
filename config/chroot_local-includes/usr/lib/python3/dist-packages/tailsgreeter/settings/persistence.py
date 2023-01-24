# Copyright 2012-2016 Tails developers <tails@boum.org>
# Copyright 2011 Max <govnototalitarizm@gmail.com>
# Copyright 2011 Martin Owens
#
# This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>
#
"""Persistent Storage handling"""
import logging
import os

import gettext
_ = gettext.gettext

from gi.repository import Gio, GLib

from tps.dbus.errors import IncorrectPassphraseError

import tailsgreeter         # NOQA: E402
import tailsgreeter.config  # NOQA: E402
import tailsgreeter.errors  # NOQA: E402


BUS_NAME = "org.boum.tails.PersistentStorage"
OBJECT_PATH = "/org/boum/tails/PersistentStorage"
INTERFACE_NAME = "org.boum.tails.PersistentStorage"


class PersistentStorageSettings(object):
    """Controller for settings related to Persistent Storage"""
    def __init__(self):
        self.is_unlocked = False
        self.cleartext_name = 'TailsData_unlocked'
        self.cleartext_device = '/dev/mapper/' + self.cleartext_name
        self.service_proxy = Gio.DBusProxy.new_sync(
            Gio.bus_get_sync(Gio.BusType.SYSTEM, None),
            Gio.DBusProxyFlags.NONE, None,
            BUS_NAME, OBJECT_PATH, INTERFACE_NAME, None,
        )  # type: Gio.DBusProxy
        device_variant = self.service_proxy.get_cached_property("Device")  # type: GLib.Variant
        self.device = device_variant.get_string() if device_variant else "/"

    def has_persistence(self):
        return self.service_proxy.\
            get_cached_property("IsCreated")

    def unlock(self, passphrase) -> bool:
        """Unlock the Persistent Storage partition

        Returns: True if everything went fine, False if the user should try
        again."""
        logging.debug("Unlocking Persistent Storage")
        if os.path.exists(self.cleartext_device):
            logging.warning(f"Cleartext device {self.cleartext_device} already"
                            f"exists")
            return True

        try:
            self.service_proxy.call_sync(
                method_name="Unlock",
                parameters=GLib.Variant("(s)", (passphrase,)),
                flags=Gio.DBusCallFlags.NONE,
                # -1 means the default timeout of 25 seconds is used,
                # which should be enough.
                timeout_msec=-1,
            )
        except GLib.GError as err:
            if IncorrectPassphraseError.is_instance(err):
                return False
            raise tailsgreeter.errors.PersistentStorageError(
                _("Error unlocking Persistent Storage: {}").format(err)
            )

        self.is_unlocked = True
        return True

    def activate_persistent_storage(self):
        """Activate the already unlocked Persistent Storage"""
        try:
            self.service_proxy.call_sync(
                method_name="Activate",
                parameters=None,
                flags=Gio.DBusCallFlags.NONE,
                # In some cases, the default timeout of 25 seconds was not
                # enough, so we use a timeout of 120 seconds instead.
                timeout_msec=120000,
            )
        except GLib.GError as err:
            raise tailsgreeter.errors.PersistentStorageError(
                _("Error activating Persistent Storage: {}").format(err)
            )
