#!/usr/bin/python3

import functools
import sys
import logging
import gettext
from argparse import ArgumentParser, ArgumentDefaultsHelpFormatter
from pathlib import Path
from typing import Dict, Any

from stem.control import Controller
import prctl
import gi
import dbus
import dbus.mainloop.glib
import systemd.daemon

from tca.ui.main_window import TCAMainWindow
import tca.config
from tca.torutils import (
    recover_fd_from_parent,
    TorLauncherUtils,
    TorLauncherNetworkUtils,
)
from tca.timeutils import GET_NETWORK_TIME_RETURN_CODE
from tca.ui.asyncutils import GJsonRpcClient
from tailslib.logutils import configure_logging


gi.require_version("GLib", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Gio  # noqa: E402


dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)

TOR_HAS_BOOTSTRAPPED_PATH = Path("/run/tor-has-bootstrapped/done")


class TCAApplication(Gtk.Application):
    """main controller for TCA."""

    def __init__(self, args):
        super().__init__(
            application_id="org.boum.tails.tor-connection-assistant",
            flags=Gio.ApplicationFlags.FLAGS_NONE,
        )
        self.log = logging.getLogger(self.__class__.__name__)
        self.state_buf, portal_sock = recover_fd_from_parent()
        self.controller = controller = Controller.from_port(port=951)
        controller.set_caching(False)
        controller.authenticate(password=None)
        self.portal = GJsonRpcClient(portal_sock)
        self.portal.connect("response-error", self.on_portal_error)
        self.portal.connect("response-success", self.on_portal_response)
        self.portal.run()
        set_tor_sandbox_fn = functools.partial(
            self.portal.call_async, "set-tor-sandbox"
        )
        read_config_fn = functools.partial(
            self.portal.call_async, "read-tca-config"
        )
        write_config_fn = functools.partial(
            self.portal.call_async, "write-tca-config"
        )
        self.configurator = TorLauncherUtils(
            self.controller,
            read_config_fn,
            write_config_fn,
            self.state_buf,
            set_tor_sandbox_fn,
        )
        self.netutils = TorLauncherNetworkUtils()
        self.args = args
        self.debug = args.debug
        self.window = None
        self.sys_dbus = dbus.SystemBus()
        self.last_nm_state = None
        self._tor_is_working: bool = TOR_HAS_BOOTSTRAPPED_PATH.exists()
        self.tor_info: Dict[str, Any] = {"DisableNetwork": None}
        self.has_persistence = args.has_persistence
        self.has_unlocked_persistence = args.has_unlocked_persistence
        self.log.debug(
            "Persistence = %s, unlocked = %s",
            self.has_persistence,
            self.has_unlocked_persistence,
        )
        self.get_network_time_result = {
            "status": None,
            "reason": None,
        }

    def load_configuration(self):
        """Load our configuration, possibly asynchronously."""
        if self.has_been_started_already():
            # synchronous
            self.configurator.load_conf_from_tor()
        else:
            # asynchronous
            self.configurator.load_conf_from_file()

    def has_been_started_already(self):
        return self.configurator.read_tca_state() != {}

    def do_monitor_tor_is_working(self):
        # init tor-ready monitoring
        f = Gio.File.new_for_path(str(TOR_HAS_BOOTSTRAPPED_PATH))
        monitor = f.monitor(Gio.FileMonitorFlags.NONE, None)
        self._tor_is_working_monitor = monitor  # otherwise it will get GC'ed
        monitor.connect("changed", self.check_tor_is_working)

        return False

    def check_tor_is_working(self, monitor, _file, otherfile, event):
        if event == Gio.FileMonitorEvent.CREATED:
            self._tor_is_working = True
        elif event == Gio.FileMonitorEvent.DELETED:
            self._tor_is_working = False
        else:
            return
        self.log.info("tor_is_working = %s", self._tor_is_working)
        GLib.idle_add(self.window.on_tor_working_changed, self.is_tor_working)

    def check_tor_state(self, repeat: bool):
        # this is called periodically
        changed = set()
        for infokey in ["DisableNetwork"]:
            resp = self.controller.get_conf(infokey)
            if resp is None:
                self.log.warn("No response from tor (asking %s)", infokey)
            else:
                if self.tor_info[infokey] != resp:
                    changed.add(infokey)
                self.tor_info[infokey] = resp

        if changed:
            self.log.info("tor state changed: %s", ",".join(changed))
            if hasattr(self.window, "on_tor_state_changed"):
                GLib.idle_add(self.window.on_tor_state_changed, self.tor_info, changed)

        return repeat

    @property
    def is_tor_working(self) -> bool:
        return bool(self._tor_is_working)

    @property
    def is_tor_over_bridges(self) -> bool:
        bridges = self.configurator.tor_connection_config.bridges
        return bool(bridges)

    @property
    def is_network_link_ok(self) -> bool:
        return self.last_nm_state is not None and self.last_nm_state >= 60

    def on_portal_response(self, portal, result: dict, errordata):
        self.log.debug("response from portal : %s", result)

    def on_portal_error(self, portal, error: str, errordata):
        self.log.error("response-error from portal : %s", error)

    def cb_dbus_nm_state(self, val):
        self.log.debug("NetworkManager state is now: %d", int(val))
        changed = False
        if self.last_nm_state != val:
            changed = True

        self.last_nm_state = val

        def wait_window():
            if self.window is None:
                return True
            GLib.idle_add(self.window.on_network_changed)
            return False

        if changed:
            if self.window is not None:
                GLib.idle_add(self.window.on_network_changed)
            else:
                GLib.timeout_add(100, wait_window)

    def finish_startup_if_configuration_has_been_loaded(self):
        """If configuration has been loaded, finish startup of the app."""
        if self.configurator.tor_connection_config is None:
            self.log.debug(
                "Our configuration was not loaded yet, let's wait some more"
            )
            return True
        else:
            self.log.debug(
                "Tor connection config: %s",
                self.configurator.tor_connection_config.to_dict(),
            )

            GLib.idle_add(self.finish_startup)

            # Destroy the timer that called this method so it's not
            # called again
            return False

    def finish_startup(self):
        """Finish starting the application.

        Set up everything that's still needed before we can say the
        application is ready, then tell systemd we're ready and
        display our main window.

        In this method, we can assume the configuration has been
        loaded already.
        """
        action = Gio.SimpleAction.new("quit", None)
        action.connect("activate", self.on_quit)
        self.add_action(action)

        # one time only
        GLib.timeout_add(1, self.do_fetch_nm_state)
        GLib.timeout_add(1, self.do_monitor_tor_is_working)
        GLib.timeout_add(1, self.check_tor_state, False)

        # timers
        GLib.timeout_add(1000, self.check_tor_state, True)

        try:
            systemd.daemon.notify("READY=1")
        except OSError:  # not run as a systemd service
            pass

        # We're now ready to finish initializing our main window
        # and to display it on screen
        GLib.idle_add(self.window.finish_init)

    def do_startup(self):
        """Set up the application when we received the `startup` signal."""
        Gtk.Application.do_startup(self)

        self.log.debug("Loading our configuration…")
        # Note: in some cases, loading the configuration is
        # asynchronous, so we have no guaranteed that the
        # configuration has been loaded once this method exits, so
        # we'll wait below using a timer before we do anything that
        # needs the configuration.
        self.load_configuration()

        self.log.debug("Waiting for our configuration to be loaded…")
        # Note: GLib does not start timers immediately when we're
        # handling the `startup` signal: it really starts them only
        # once we've created the main window, which we do in
        # do_activate (i.e. when we're handling the `activate`
        # signal).
        GLib.timeout_add(100, self.finish_startup_if_configuration_has_been_loaded)

    def do_fetch_nm_state(self):
        def handle_hello_error(*args, **kwargs):
            self.log.warn("Error getting information from NetworkManager")
            self.last_nm_state = None

        nm_obj = self.sys_dbus.get_object(
            "org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager"
        )
        nm = dbus.Interface(nm_obj, "org.freedesktop.NetworkManager")

        # get immediately
        nm.state(reply_handler=self.cb_dbus_nm_state, error_handler=handle_hello_error)
        # subscribe for changes
        nm.connect_to_signal("StateChanged", self.cb_dbus_nm_state)

        return False

    def set_time_from_network(self, callback):
        def on_set_system_time(portal, result, error, errordata):
            self.log.debug(
                "System time set: error=%s, result=%s", str(error), str(result)
            )
            GLib.idle_add(callback, result, error)

        def on_get_network_time(portal, result, error, errordata):
            if error:
                self.get_network_time_result["status"] = "error"
                if (
                        errordata.get("code") ==
                        GET_NETWORK_TIME_RETURN_CODE["captive-portal"]
                        ):
                    self.get_network_time_result["reason"] = "captive-portal"
                    self.log.info("Detected captive portal")
                else:
                    self.log.warning("get-network-time failed: %s", error)
                GLib.idle_add(callback, result, error)
            else:
                self.get_network_time_result["status"] = "success"
                self.portal.call_async(
                    "set-system-time", on_set_system_time, result["stdout"].rstrip()
                )

        self.portal.call_async("get-network-time", on_get_network_time)

    def do_activate(self):
        """Handle the `activate` signal."""
        if self.window is None:
            # Windows are associated with the application
            # when the last one is closed the application shuts down
            self.window = TCAMainWindow(self)

        # Show the window if, and only if, we're not the primary
        # instance of the application: for the primary instance,
        # finish_startup_if_configuration_has_been_loaded takes care
        # of it at a more appropriate time.
        if self.get_is_remote():
            self.window.show()

    def on_quit(self, action, param):
        self.full_quit()

    def full_quit(self):
        try:
            systemd.daemon.notify("STOPPING=1")
        except OSError:  # not run as a systemd service
            pass
        self.quit()


def is_tails_debug_mode() -> bool:
    """Return True IFF Tails is started with the debug flag."""
    with open("/proc/cmdline") as buf:
        flags = buf.read().split()
    return "debug" in flags


def get_parser():
    p = ArgumentParser(formatter_class=ArgumentDefaultsHelpFormatter)
    p.add_argument("--debug", dest="debug", action="store_true", default=False)
    p.add_argument("--debug-statefile")
    p.add_argument(
        "--has-persistence",
        dest="has_persistence",
        action="store_true",
        default=False,
    )
    p.add_argument(
        "--has-unlocked-persistence",
        dest="has_unlocked_persistence",
        action="store_true",
        default=False,
    )
    p.add_argument(
        "--log-level",
        default="DEBUG" if is_tails_debug_mode() else "INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Minimum log level to be displayed",
    )
    p.add_argument(
        "--log-target",
        default="auto",
        choices=["auto", "stderr", "syslog"],
        help="Where to send log to; 'auto' will pick syslog IF stderr is not a tty",
    )
    p.add_argument("gtk_args", nargs="*")

    return p


class RemoveUselessStemMessages(logging.Filter):
    def filter(self, record):
        """
        Even when we want to debug messages to the control port,
        let's avoid this frequent polling messages
        """
        return 'disablenetwork' not in record.getMessage()


if __name__ == "__main__":
    prctl.set_name("tca")  # this get set as syslog identity!
    args = get_parser().parse_args()

    log_conf = {"level": logging.DEBUG if args.debug else args.log_level}
    configure_logging(hint=args.log_target, ident="tca", **log_conf)
    logging.getLogger("stem").setLevel(logging.DEBUG)
    logging.getLogger("stem").addFilter(RemoveUselessStemMessages())

    GLib.set_prgname(tca.config.APPLICATION_TITLE)
    GLib.set_application_name(tca.config.LOCALIZED_APPLICATION_TITLE)

    application = TCAApplication(args)
    application.run([sys.argv[0]])
