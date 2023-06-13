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
from typing import List

_ = gettext.gettext

from gi.repository import Gio, GLib

import tps.dbus.errors as tps_errors

import tailsgreeter         # NOQA: E402
from tailsgreeter import config  # NOQA: E402
import tailsgreeter.errors  # NOQA: E402


BUS_NAME = "org.boum.tails.PersistentStorage"
OBJECT_PATH = "/org/boum/tails/PersistentStorage"
INTERFACE_NAME = "org.boum.tails.PersistentStorage"


class PersistentStorageSettings(object):
    """Controller for settings related to Persistent Storage"""
    def __init__(self):
        self.failed_with_unexpected_error = False
        self.cleartext_name = 'TailsData_unlocked'
        self.cleartext_device = '/dev/mapper/' + self.cleartext_name
        self.service_proxy = Gio.DBusProxy.new_sync(
            Gio.bus_get_sync(Gio.BusType.SYSTEM, None),
            Gio.DBusProxyFlags.NONE, None,
            BUS_NAME, OBJECT_PATH, INTERFACE_NAME, None,
        )  # type: Gio.DBusProxy
        device_variant = self.service_proxy.get_cached_property("Device")  # type: GLib.Variant
        self.device = device_variant.get_string() if device_variant else "/"
        self.is_unlocked = False
        self.is_created = self.service_proxy.get_cached_property("IsCreated")
        self.is_upgraded = self.service_proxy.get_cached_property("IsUpgraded")
        self.service_proxy.connect("g-properties-changed", self.on_properties_changed)

    def on_properties_changed(self, proxy: Gio.DBusProxy,
                              changed_properties: GLib.Variant,
                              invalidated_properties: List[str]):
        """Callback for when the Persistent Storage properties change"""
        logging.debug("changed properties: %s", changed_properties)
        keys = set(changed_properties.keys())

        if "IsCreated" in keys:
            self.is_created = changed_properties["IsCreated"]
        if "IsUpgraded" in keys:
            self.is_upgraded = changed_properties["IsUpgraded"]
        if "Device" in keys:
            self.device = changed_properties["Device"]

    def unlock(self, passphrase):
        """Unlock the Persistent Storage partition

        Raises:
            WrongPassphraseError if the passphrase is incorrect.
            PersistentStorageError if something else went wrong."""
        logging.debug("Unlocking Persistent Storage")
        if os.path.exists(self.cleartext_device):
            logging.warning(f"Cleartext device {self.cleartext_device} already"
                            f"exists")
            self.is_unlocked = True
            return

        try:
            self.service_proxy.call_sync(
                method_name="Unlock",
                parameters=GLib.Variant("(s)", (passphrase,)),
                flags=Gio.DBusCallFlags.NONE,
                # In some cases, the default timeout of 25 seconds was not
                # enough, so we use a timeout of 120 seconds instead.
                timeout_msec=120000,
            )
        except GLib.GError as err:
            if tps_errors.IncorrectPassphraseError.is_instance(err):
                raise tailsgreeter.errors.WrongPassphraseError() from err

            self.failed_with_unexpected_error = True
            raise tailsgreeter.errors.PersistentStorageError(
                _("Error unlocking Persistent Storage: {}").format(err)
            )
        self.is_unlocked = True

    def upgrade_luks(self, passphrase):
        """Upgrade the Persistent Storage to the latest format

        Raises:
            WrongPassphraseError if the passphrase is incorrect.
            PersistentStorageError if something else went wrong."""
        logging.debug("Upgrading Persistent Storage")
        try:
            self.service_proxy.call_sync(
                method_name="UpgradeLUKS",
                parameters=GLib.Variant("(s)", (passphrase,)),
                flags=Gio.DBusCallFlags.NONE,
                timeout_msec=120000,
            )
        except GLib.GError as err:
            if tps_errors.IncorrectPassphraseError.is_instance(err):
                raise tailsgreeter.errors.WrongPassphraseError() from err
            self.failed_with_unexpected_error = True
            raise tailsgreeter.errors.PersistentStorageError(
                _("Error upgrading Persistent Storage: {}").format(err)
            )

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
            if tps_errors.FeatureActivationFailedError.is_instance(err):
                tps_errors.FeatureActivationFailedError.strip_remote_error(err)
                features = err.message.split(":")
                # translate feature names
                features = [config.gettext(feature) for feature in features]
                # Translators: Don't translate {features}, it's a placeholder
                # and will be replaced.
                msg = config.gettext("Failed to activate some features of the Persistent Storage: {features}.").\
                    format(features=", ".join(features))
                raise tailsgreeter.errors.FeatureActivationFailedError(msg)
            self.failed_with_unexpected_error = True
            raise tailsgreeter.errors.PersistentStorageError(
                _("Error activating Persistent Storage: {}").format(err)
            )
