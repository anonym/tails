import logging
import os.path
import json
import gettext
from typing import Dict, Any, Tuple, Optional
import copy

import gi
import stem
import pytz

from tca.ui.asyncutils import GAsyncSpawn, idle_add_chain
from tca.torutils import (
    TorConnectionProxy,
    TorConnectionConfig,
    InvalidBridgeTypeException,
    MalformedBridgeException,
    VALID_BRIDGE_TYPES,
)
import tca.config
import tca.ui.dialogs


gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GLib", "2.0")


from gi.repository import Gdk, GdkPixbuf, Gtk, GLib  # noqa: E402

MAIN_UI_FILE = "main.ui"
CSS_FILE = "tca.css"
IMG_FOOTPRINTS = "/usr/share/doc/tails/website/about/footprints.svg"
IMG_RELAYS = "/usr/share/doc/tails/website/about/relays.svg"
IMG_WALKIE = "/usr/share/doc/tails/website/about/walkie-talkie.svg"
IMG_SIDE: Dict[str, str] = {
    "bridge": IMG_FOOTPRINTS,
    "hide": IMG_RELAYS,
    "connect": IMG_WALKIE,
    "proxy": IMG_WALKIE,
    "progress": IMG_WALKIE,
    "error": IMG_WALKIE,
    "offline": IMG_RELAYS,
}

TOR_BOOTSTRAP_STATUS_CONN_DONE = 10  # see tor.git:src/feature/control/control_events.h
TOR_SIGNOFLIFE_TIMEOUT = 10  # this timeout means "time to wait for the first sign of life" which we define as bootstrap-phase=BOOTSTRAP_STATUS_CONN_DONE
TOR_BOOTSTRAP_TIMEOUT = 600  # this is *summed* to the previous timeout

# META {{{
# Naming convention for widgets:
# step_<stepname>_<type> if there's a single type in that step
# step_<stepname>_<type>_<name> otherwise
# Callbacks have a similar name, and start with cb_step_<stepname>_
#
# Mixins are used to avoid the "huge class" so typical in UI development. They are NOT meant for code reuse,
# so feel free to break encapsulation whenever you see fit
# Each Mixin cares about one of the steps. Each step has a name
# Special methods:
#  - before_show_<stepname>() is called when changing from one step to the other
# }}}

translation = gettext.translation("tails", "/usr/share/locale", fallback=True)
_ = translation.gettext

log = logging.getLogger(__name__)


class StepOfflineHideMixin:
    def cb_step_offline_wificonf_clicked(self, user_data=None):
        self.app.portal.call_async("open-wifi-config", None)


class StepChooseHideMixin:
    """
    Handles the "consent question" step.

    Here, the user can choose between an easier configuration and going unnoticed.
    """

    def before_show_hide(self, coming_from):
        self.state.setdefault("hide", {})
        first_time = self.state['hide'].get('first', True)
        self.state['hide'].setdefault('first', False)

        self.builder.get_object("radio_unnoticed_none").set_active(True)
        self.builder.get_object("radio_unnoticed_yes").set_active(False)
        self.builder.get_object("radio_unnoticed_no").set_active(False)
        self.builder.get_object("radio_unnoticed_none").hide()
        made_a_choice = self.user_wants_hide in (True, False)
        definitive = self.state.get("progress", {}).get("started", False)
        if definitive:
            assert made_a_choice
            if self.user_wants_hide:
                self.builder.get_object("radio_unnoticed_no").set_sensitive(False)
                self.builder.get_object("radio_unnoticed_yes").set_active(True)
            else:
                self.builder.get_object("radio_unnoticed_yes").set_sensitive(False)
                self.builder.get_object("radio_unnoticed_no").set_active(True)
        elif made_a_choice:  # the user is changing their mind before connecting to Tor
            hide = self.user_wants_hide
            self.builder.get_object("radio_unnoticed_yes").set_active(hide)
            self.builder.get_object("radio_unnoticed_no").set_active(not hide)

        if first_time:
            log.debug("Initialize easy-bridge widget based on data+config (first run)")
            self.builder.get_object("radio_unnoticed_no_bridge").set_active(
                    self.state["hide"].get("bridge", False)
                    )

    def _step_hide_next(self):
        if self.state["hide"]["bridge"]:
            self.change_box("bridge")
        else:
            self.change_box("progress")

    def cb_step_hide_radio_changed(self, *args):
        easy = self.builder.get_object("radio_unnoticed_no").get_active()
        hide = self.builder.get_object("radio_unnoticed_yes").get_active()
        active = easy or hide
        self.builder.get_object("step_hide_btn_submit").set_sensitive(active)
        if easy:
            self.builder.get_object("step_hide_box_bridge").show()
        else:
            self.builder.get_object("step_hide_box_bridge").hide()

    def cb_step_hide_btn_connect_clicked(self, user_data=None):
        easy = self.builder.get_object("radio_unnoticed_no").get_active()
        hide = self.builder.get_object("radio_unnoticed_yes").get_active()
        if not easy and not hide:
            return
        assert easy is not hide
        if hide:
            self.state["hide"]["hide"] = True
            self.state["hide"]["bridge"] = True
        else:
            self.state["hide"]["hide"] = False
            if self.builder.get_object("radio_unnoticed_no_bridge").get_active():
                self.state["hide"]["bridge"] = True
            else:
                self.state["hide"]["bridge"] = False
        self._step_hide_next()

    def cb_toggle_help_unnoticed_no(self, user_data=None):
        widget = self.builder.get_object("unnoticed_no_help")
        widget.set_visible(not widget.is_visible())

    def cb_toggle_help_unnoticed_yes(self, user_data=None):
        widget = self.builder.get_object("unnoticed_yes_help")
        widget.set_visible(not widget.is_visible())

    def cb_toggle_help_bridges(self, user_data=None):
        widget = self.builder.get_object("bridges_help")
        widget.set_visible(not widget.is_visible())


class StepChooseBridgeMixin:
    def before_show_bridge(self, coming_from):
        self.state["bridge"]: Dict[str, Any] = {}
        self.persistence_config_failed = False

        self.builder.get_object("step_bridge_box").show()
        self.builder.get_object("step_bridge_radio_none").set_active(True)
        self.builder.get_object("step_bridge_radio_none").hide()
        self.builder.get_object("step_bridge_text").get_buffer().connect(
            "inserted_text", self.cb_step_bridge_text_changed
        )
        self.builder.get_object("step_bridge_text").get_buffer().connect(
            "deleted_text", self.cb_step_bridge_text_changed
        )
        hide_mode: bool = self.state["hide"]["hide"]
        if hide_mode:
            self.builder.get_object("step_bridge_text").grab_focus()
        else:
            self.builder.get_object("step_bridge_radio_default").grab_focus()
        self.get_object("radio_default").set_sensitive(not hide_mode)

        self.builder.get_object("step_bridge_radio_type").set_active(hide_mode)
        self.get_object(
            "combo"
        ).hide()  # we are forcing that to obfs4 until we support meek
        self.get_object("box_warning").hide()
        self._step_bridge_init_from_tor_config()
        self._step_bridge_set_actives()
        self._step_bridge_update_persistence_ui()

    def _step_bridge_init_from_tor_config(self):
        bridges = self.app.configurator.tor_connection_config.bridges
        if not bridges:
            return
        if len(bridges) > 1 and set(bridges) == set(
            TorConnectionConfig.get_default_bridges()
        ):
            self.get_object("radio_default").set_active(True)
        else:
            self.get_object("radio_type").set_active(True)
            bridge = bridges[0]
            self.get_object("text").get_buffer().set_text(bridge, len(bridge))
            self.get_object("label_type").set_label(
                _("_Use a bridge that you already know")
            )

    def _step_bridge_set_persistence_sensitivity(self, sensitive: bool):
        if self.persistence_config_failed:
            sensitive = False
        for obj in [
            "step_bridge_persistence_switch_box",
            "step_bridge_persistence_help_box",
            "step_bridge_persistence_error_box",
        ]:
            self.builder.get_object(obj).set_sensitive(sensitive)

    def _step_bridge_update_persistence_ui(self):
        # Enable this UI iff. we're using custom bridges
        self._step_bridge_set_persistence_sensitivity(
            self.builder.get_object("step_bridge_radio_type").get_active()
        )

        # Unlocked persistence
        if self.app.has_persistence and self.app.has_unlocked_persistence:
            self.builder.get_object("step_bridge_persistence_help_box").hide()

            def cb_set_up_persistence_switch(gjsonrpcclient, res, error):
                log.debug("Persistence enabled: %s", res)
                active = res is not None and res.get("returncode", 1) == 0
                self.builder.get_object("step_bridge_persistence_switch").set_active(
                    active
                )
                self.builder.get_object("step_bridge_persistence_switch_box").show()

            self.app.portal.call_async(
                "is-tor-configuration-persistent?",
                cb_set_up_persistence_switch,
            )

        else:
            self.builder.get_object("step_bridge_persistence_switch_box").hide()
            # Locked persistence
            if self.app.has_persistence:
                help_label = _(
                    "To save your bridge, "
                    '<a href="doc/first_steps/persistence">'
                    "unlock you Persistent Storage</a>."
                )
            # No persistence
            else:
                help_label = _(
                    "To save your bridge, "
                    '<a href="doc/first_steps/persistence">'
                    "create a Persistent Storage</a> "
                    "on your Tails USB stick."
                )
            self.builder.get_object("step_bridge_persistence_help_label").set_label(
                help_label
            )
            self.builder.get_object("step_bridge_persistence_help_box").show()

    def _step_bridge_is_text_valid(self, text: Optional[str] = None) -> bool:
        def set_warning(msg):
            self.get_object("label_warning").set_label(msg)
            self.get_object("box_warning").show()

        if text is None:
            text = self.get_object("text").get_buffer().get_text()
        try:
            bridges = TorConnectionConfig.parse_bridge_lines([text])
        except InvalidBridgeTypeException as exc:
            set_warning(_("Invalid: {exception}").format(exception=str(exc)))
            return False
        except (ValueError, IndexError):
            self.get_object("box_warning").hide()
            return False
        self.get_object("box_warning").hide()

        if self.state["hide"]["hide"]:
            for br in bridges:
                if br.split()[0] not in (VALID_BRIDGE_TYPES - {"bridge"}):
                    set_warning(
                        _(
                            "You need to configure an obfs4 bridge to hide that you are using Tor"
                        )
                    )
                    return False

        return len(bridges) > 0

    def _step_bridge_set_actives(self):
        default = self.builder.get_object("step_bridge_radio_default").get_active()
        manual = self.builder.get_object("step_bridge_radio_type").get_active()
        scan = self.builder.get_object("step_bridge_radio_scan").get_active()
        self.get_object("combo").set_sensitive(default)
        self.builder.get_object("step_bridge_text").set_sensitive(manual)
        self.builder.get_object("step_bridge_btn_scanqrcode").set_sensitive(scan)
        self.builder.get_object("step_bridge_btn_submit").set_sensitive(
            default or (manual and self._step_bridge_is_text_valid())
            or (scan and self.get_object('label_scanresult').get_property('visible'))
        )

    def cb_step_bridge_radio_changed(self, *args):
        self._step_bridge_set_actives()
        manual = self.builder.get_object("step_bridge_radio_type").get_active()
        self._step_bridge_set_persistence_sensitivity(manual)

    def cb_step_bridge_text_changed(self, *args):
        self._step_bridge_set_actives()

    def cb_step_bridge_persistence_switch_toggled(self, switch, state, *args):
        log.debug("Persistence switch toggled, setting state to %s", state)
        btn_submit = self.builder.get_object("step_bridge_btn_submit")
        btn_submit_initially_sensitive = btn_submit.get_sensitive()
        btn_submit.set_sensitive(False)
        disabled_widgets = ["step_bridge_text", "step_bridge_btn_back"]
        for widget in disabled_widgets:
            self.builder.get_object(widget).set_sensitive(False)
        self.builder.get_object("step_bridge_persistence_spinner").set_visible(True)

        def cb_persistence_config_changed(gjsonrpcclient, res, error):
            log.debug(
                "cb_persistence_config_changed called with args: %s",
                args,
            )
            if res and res.get("returncode", 1) == 0:
                switch.set_state(state)
            else:
                self.builder.get_object(
                    "step_bridge_persistence_switch_box"
                ).set_sensitive(False)
                self.builder.get_object(
                    "step_bridge_persistence_error_label"
                ).set_label(_("Failed to configure your Persistent Storage"))
                self.builder.get_object("step_bridge_persistence_error_box").show()
                self.persistence_config_failed = True

            for widget in disabled_widgets:
                self.builder.get_object(widget).set_sensitive(True)
            if btn_submit_initially_sensitive:
                btn_submit.set_sensitive(True)
            self.builder.get_object("step_bridge_persistence_spinner").set_visible(
                False
            )

        if state:
            portal_method = "enable-tor-configuration-persistence"
        else:
            portal_method = "disable-tor-configuration-persistence"
        self.app.portal.call_async(
            portal_method,
            cb_persistence_config_changed,
        )
        return True  # disable the default handler

    def cb_step_bridge_btn_submit_clicked(self, *args):
        default = self.builder.get_object("step_bridge_radio_default").get_active()
        manual = self.builder.get_object("step_bridge_radio_type").get_active()
        self.state["hide"]["bridge"] = True
        if default:
            self.state["bridge"]["kind"] = "default"
            self.state["bridge"]["default_method"] = self.get_object(
                "combo"
            ).get_active_id()
        elif manual:
            self.state["bridge"]["kind"] = "manual"
            text = self.get_object("text").get_buffer().get_text()
            self.state["bridge"]["bridges"] = TorConnectionConfig.parse_bridge_lines(
                [text]
            )
            log.info("Bridges parsed: %s", self.state["bridge"]["bridges"])

        self.change_box("progress")

    def cb_step_bridge_btn_back_clicked(self, *args):
        self.change_box("hide")

    def scan_qrcode(self):
        # yes, the *exactly* same code is run, no matter if you are calling
        # this from "bridge" step or from "error" step

        step_called_from = self.state['step']

        def on_qrcode_scanned(gjsonrpcclient, res, error):
            if self.state['step'] != step_called_from:
                log.info("QR code scanned (exitcode: %d) too late, ignoring",
                         res.get('returncode', -1) if res else -1)
                return

            if not res or res.get("returncode", 1) != 0:
                dialog = Gtk.MessageDialog(
                        transient_for=self,
                        flags=0,
                        message_type=Gtk.MessageType.ERROR,
                        buttons=Gtk.ButtonsType.OK,
                        text=_("Could not acquire QR code"),
                        )
                dialog.format_secondary_text(_("Maybe you have no supported webcam?"))
                dialog.run()
                dialog.destroy()
                return

            raw_content = res.get('stdout', '').strip()
            if not raw_content:
                # if the output is empty, we assume that the user closed the window by themself
                # to be really sure, we should use zbarcam --xml;
                # however, do "empty" QR codes even exists?

                # If the user closed window by themself, they don't need to be informed
                return

            try:
                self.state['bridge']['bridges'] = TorConnectionConfig.parse_qr_content(raw_content)
            except Exception:
                dialog = Gtk.MessageDialog(
                        transient_for=self,
                        flags=0,
                        message_type=Gtk.MessageType.ERROR,
                        buttons=Gtk.ButtonsType.OK,
                        text=_("Invalid QR code"),
                        )
                dialog.format_secondary_text(_(
                    "Try sending another email and scanning again."
                ))
                dialog.run()

                dialog.destroy()
            else:
                # it should be content = '\n'.join(bridges), but #18981
                content = self.state['bridge']['bridges'][0]

                bridge_info = content.split()[1]  # IP address
                bridge_type=content.split()[0]
                informative_message = _("Scanned {bridge_type} bridge: <b>{bridge_info}</b>")
                self.get_object("label_scanresult").set_text(
                        informative_message.format(
                            bridge_info=bridge_info,
                            bridge_type=bridge_type,
                            )
                        )
                self.get_object('label_scanresult').set_property("use-markup", True)
                self.get_object('label_scanresult').show()
                self._step_bridge_set_actives()

        self.app.portal.call_async("scan-qrcode", on_qrcode_scanned)

    def cb_step_bridge_btn_scanqrcode_clicked(self, *args):
        self.scan_qrcode()

class StepConnectProgressMixin:
    def before_show_progress(self, coming_from):
        self.save_conf()
        self.state["progress"]["error"] = None
        self.builder.get_object("step_progress_box").show()
        for obj in [
            "box_start",
            "box_tortestok",
            "box_internetok",
            "box_internettest",
            "box_tor_direct_fail",
        ]:
            self.get_object(obj).hide()
        self.connection_progress.set_fraction(0.0, allow_going_back=True)
        self.show_connect_pbar()
        if not self.state["progress"]["success"]:
            if not self.state["hide"]["hide"]:
                self.get_object("label_status").set_text(_("Synchronizing the system's clock…"))
                self.app.set_time_from_network(self.cb_system_time_set_from_network)
            else:
                self.spawn_tor_connect()
        else:
            self._step_progress_success_screen()

    def cb_system_time_set_from_network(self, result, error):
        log.debug("System time set, let's spawn_tor_connect")
        self.spawn_tor_connect()

    def spawn_internet_test(self):
        # this is just a stub
        test_spawn = GAsyncSpawn()
        test_spawn.connect("process-done", self.cb_internet_test)
        test_spawn.run(["/bin/sh", "-c", "sleep 0.5; true"])

    def spawn_tor_test(self):
        # this is just a stub
        test_spawn = GAsyncSpawn()
        test_spawn.connect("process-done", self.cb_tor_test)
        test_spawn.run(["/bin/sh", "-c", "sleep 0.5; true"])

    def show_connect_pbar(self):
        self.builder.get_object("step_progress_box_torconnect").show()
        self.builder.get_object("step_progress_pbar_torconnect").show()

    def spawn_tor_connect(self):
        def _apply_proxy():
            if not self.state["proxy"] or self.state["proxy"]["proxy_type"] == "no":
                self.app.configurator.tor_connection_config.proxy = (
                    TorConnectionProxy.noproxy()
                )
            else:
                proxy_conf = self.state["proxy"]
                if proxy_conf["proxy_type"] != "Socks5":
                    del proxy_conf["username"]
                    del proxy_conf["password"]
                conf_obj = copy.copy(proxy_conf)
                conf_obj["proxy_type"] += "Proxy"
                assert proxy_conf["proxy_type"] != conf_obj["proxy_type"]
                self.app.configurator.tor_connection_config.proxy = (
                    TorConnectionProxy.from_obj(conf_obj)
                )

        def do_tor_connect_config():
            if not self.state["hide"]["bridge"]:
                self.app.configurator.tor_connection_config.disable_bridges()
                self.get_object("label_status").set_text(
                    _("Connecting to Tor without bridges…")
                )
            elif self.state["bridge"].get("kind", "") == "default":
                self.app.configurator.tor_connection_config.enable_default_bridges(
                    only_type=self.state["bridge"]["default_method"]
                )
                self.get_object("label_status").set_text(
                    _("Connecting to Tor with default bridges…")
                )
            elif self.state["bridge"]["bridges"]:
                self.app.configurator.tor_connection_config.enable_bridges(
                    self.state["bridge"]["bridges"]
                )
                self.get_object("label_status").set_text(
                    _("Connecting to Tor with a custom bridge…")
                )
            else:
                raise ValueError(
                    "inconsistent state! you discovered a programming error"
                )
            _apply_proxy()
            self.connection_progress.set_fraction(
                ConnectionProgress.PROGRESS_CONFIGURATION_CONFIG
            )
            return True

        def do_tor_connect_default_bridges():
            self.app.configurator.tor_connection_config.enable_default_bridges(
                only_type="obfs4"
            )
            self.get_object("label_status").set_text(
                _("Connecting to Tor with default bridges…")
            )
            _apply_proxy()
            self.connection_progress.set_fraction(
                ConnectionProgress.PROGRESS_CONFIGURATION_CONFIG
            )
            return True

        def do_tor_connect_apply():
            def error_handler(error):
                self.connection_progress.set_fraction(0)
                self.state["progress"]["error"] = "setconf"
                self.state["progress"]["error_data"] = error
                self.change_box("error")

            def conf_applied_cb(gjsonrpcclient, res, error):
                log.debug("tor configuration applied callback returned: %s", res)
                success = res and res.get("returncode", 1) == 0
                if not success:
                    error_handler(error=error)
                    return False
                self.state["progress"]["started"] = True
                self.connection_progress.set_fraction(
                    ConnectionProgress.PROGRESS_CONFIGURATION_APPLIED
                )
                self.timer_check = GLib.timeout_add(
                    1000,
                    do_tor_connect_check,
                    {"count": TOR_SIGNOFLIFE_TIMEOUT, "sign_of_life": False},
                )

            try:
                updating_sandbox_conf = self.app.configurator.apply_conf(
                    callback=conf_applied_cb
                )
                if updating_sandbox_conf:
                    log.debug("updating sandbox configuration")
                else:
                    log.debug("tor configuration applied")
            except stem.InvalidRequest as exc:
                error_handler(exc.message)
                return False
            return False

        def do_tor_connect_check(d: dict):
            # this dictionary trick is a argument to circumvent the fact that integers are immutable in
            # Python; the dictionary is just acting like a mutable reference, job that might be done with
            # weakref or other methods, but dicts are easier to understand.
            if d["count"] <= 0:
                self.connection_progress.set_fraction(0)

                if (
                    not self.state["hide"]["hide"] and not self.state["hide"]["bridge"]
                ) and not self.app.configurator.tor_connection_config.bridges:
                    log.info("Retrying with default bridges")
                    self.get_object("box_tor_direct_fail").show()
                    self.connection_progress.set_fraction(0.0, allow_going_back=True)
                    idle_add_chain(
                        [do_tor_connect_default_bridges, do_tor_connect_apply]
                    )
                else:
                    self.state["progress"]["error"] = "tor"
                    self.app.configurator.stop_connecting()
                    log.info("Failed with bridges")
                    self.change_box("error")
                return False
            d["count"] -= 1

            ok = self.app.is_tor_working
            if ok:
                self.state["progress"]["success"] = True
                self.connection_progress.set_fraction(1)
                self._step_progress_success_screen()
                return False
            else:
                progress = self.app.configurator.tor_bootstrap_phase()
                if not d["sign_of_life"] and progress >= TOR_BOOTSTRAP_STATUS_CONN_DONE:
                    log.info("We received some sign of life from Tor network")
                    d["sign_of_life"] = True
                    d["count"] = TOR_BOOTSTRAP_TIMEOUT - 1
                self.connection_progress.set_fraction_from_bootstrap_phase(progress)
                return True

        idle_add_chain([do_tor_connect_config, do_tor_connect_apply])

    def _step_progress_success_screen(self):
        self.save_conf(successful_connect=True)
        self.get_object("box_torconnect").hide()
        self.get_object("box_tortestok").show()

        if self.app.is_tor_over_bridges:
            status = _("Connected to Tor successfully with bridges")
        else:
            status = _("Connected to Tor successfully")

        self.get_object("label_connected").set_text(status)
        self.get_object("label_connected_explain").set_text(_(
            "You can now browse the Internet anonymously and uncensored."
        ))
        self.get_object("box_start").show()

    def cb_internet_test(self, spawn, retval):
        if retval == 0:
            self.builder.get_object("step_progress_box_internettest").hide()
            self.builder.get_object("step_progress_box_internetok").show()
            self.builder.get_object("step_progress_box_tortest").show()
            self.spawn_tor_test()
        else:
            self.state["progress"]["error"] = "internet"
            self.change_box("error")

    def cb_tor_test(self, spawn, retval):
        self.builder.get_object("step_progress_box_tortest").hide()
        self.builder.get_object("step_progress_box_torok").show()
        if retval == 0:
            self.spawn_tor_connect()
            return
        else:
            self.builder.get_object("step_progress_box_tortest").hide()
            self.builder.get_object("step_progress_box_torok").show()
            self.builder.get_object("step_progress_img_torok").set_from_stock(
                "gtk-dialog-error", Gtk.IconSize.BUTTON
            )

    def cb_step_progress_btn_starttbb_clicked(self, *args):
        self.app.portal.call_async("open-tbb", None)

    def cb_step_progress_btn_reset_clicked(self, *args):
        self.app.portal.call_async("tor/restart", None)

    def cb_step_progress_btn_monitor_clicked(self, *args):
        self.app.portal.call_async("open-networkmonitor", None)

    def cb_step_progress_btn_onioncircuits_clicked(self, *args):
        self.app.portal.call_async("open-onioncircuits", None)


class StepErrorMixin:
    def before_show_error(self, coming_from):
        self.state["error"] = {
            "fix_attempt": False  # has the user done something to fix it?
        }
        if coming_from == "progress":
            if (
                self.state["hide"]["bridge"]
                and self.state["bridge"].get("kind") == "manual"
            ):
                bridge = self.state["bridge"]["bridges"][0]
                self.get_object("text").get_buffer().set_text(bridge, len(bridge))
        self.get_object("text").get_buffer().connect(
            "inserted_text", self.cb_step_error_text_changed
        )
        self.get_object("text").get_buffer().connect(
            "deleted_text", self.cb_step_error_text_changed
        )
        if coming_from in ["proxy"]:
            self.state["error"]["fix_attempt"] = True
        self._step_error_submit_allowed()

    def cb_step_error_btn_proxy_clicked(self, *args):
        self.change_box("proxy")

    def cb_step_error_btn_time_clicked(self, *args):
        tz = self.state["time"].get("tz", None)
        time_dialog = tca.ui.dialogs.get_time_dialog(initial_tz=tz)
        time_dialog.set_modal(True)
        time_dialog.set_transient_for(self)
        time_dialog.connect("response", self.on_time_dialog_complete)
        time_dialog.show_all()

    def on_time_dialog_complete(self, time_dialog, response):
        log.debug("time dialog closed: %s", response == Gtk.ResponseType.APPLY)

        def on_set_system_time(portal, result, error):
            if error:
                log.error("Error setting system time! %s", error)
                dialog = Gtk.MessageDialog(
                    transient_for=time_dialog,
                    flags=Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                    message_type=Gtk.MessageType.ERROR,
                    buttons=Gtk.ButtonsType.OK,
                    text="Error setting system time",
                )
                dialog.format_secondary_text(
                    "%s\n\nThis should not happen. Please report a bug." % error
                )
                dialog.run()
                dialog.destroy()
                time_dialog.destroy()
                return
            self.state["error"]["fix_attempt"] = True
            self._step_error_submit_allowed()
            time_dialog.destroy()

        if response == Gtk.ResponseType.APPLY:
            self.state["time"]["tz"] = time_dialog.get_tz_name()
            self.save_conf()
            aware_dt = time_dialog.get_date()
            utc_dt = aware_dt.astimezone(pytz.utc)
            timestr = utc_dt.isoformat("T", "seconds")
            self.app.portal.call_async(
                "set-system-time", on_set_system_time, timestr
            )
        else:
            time_dialog.destroy()

    def cb_step_error_btn_captive_clicked(self, *args):
        # we are not checking the result of this command, because nothing depends on it
        self.app.portal.call_async("open-unsafebrowser", None)

        self.state["error"]["fix_attempt"] = True
        self._step_error_submit_allowed()

    def _step_error_submit_allowed(self):
        def set_warning(msg):
            self.get_object("label_warning").set_label(msg)
            self.get_object("box_warning").show()

        def is_allowed():
            text = self.get_object("text").get_buffer().get_text()
            try:
                bridges = TorConnectionConfig.parse_bridge_lines([text])
            except InvalidBridgeTypeException as exc:
                set_warning(_("Invalid: {exception}").format(exception=str(exc)))
                return False
            except (MalformedBridgeException, ValueError, IndexError):
                set_warning(_("Bridge address malformed"))
                return False
            else:
                self.get_object("box_warning").hide()

            if self.state["hide"]["hide"]:
                for br in bridges:
                    if br.split()[0] not in (VALID_BRIDGE_TYPES - {"bridge"}):
                        set_warning(
                            _(
                                "You need to configure an obfs4 bridge to hide that you are using Tor"
                            )
                        )
                        return False

            if not bridges and self.state["hide"]["hide"]:
                set_warning(
                    _(
                        "Setting a bridge is needed if you want to hide that you are using Tor"
                    )
                )
                return False

            if bridges:
                return True

            return True

        self.get_object("btn_submit").set_sensitive(is_allowed())

    def cb_step_error_text_changed(self, *args):
        self._step_error_submit_allowed()

    def cb_step_error_btn_submit_clicked(self, *args):
        text = self.get_object("text").get_buffer().get_text()
        self.state["bridge"]["bridges"] = TorConnectionConfig.parse_bridge_lines([text])
        # If the user is selecting any bridge, encode it properly
        # If they are _not_, let's keep the previous settings, which could be default bridges
        if self.state["bridge"]["bridges"]:
            self.state["hide"]["bridge"] = True
            self.state["bridge"]["kind"] = "manual"
        self.change_box("progress")

    def cb_step_error_btn_scanqrcode_clicked(self, *args):
        self.cb_step_bridge_btn_scanqrcode_clicked(*args)


class StepProxyMixin:
    def before_show_proxy(self, coming_from):
        self.state["proxy"].setdefault("proxy_type", "no")
        self.builder.get_object("step_proxy_combo").set_active_id(
            self.state["proxy"]["proxy_type"]
        )

        for entry in ("address", "port", "username", "password"):
            buf = self.get_object("entry_" + entry).get_buffer()
            buf.connect("deleted-text", self.cb_step_proxy_entry_changed)
            buf.connect("inserted-text", self.cb_step_proxy_entry_changed)
            if entry in self.state["proxy"]:
                content = self.state["proxy"][entry]
                buf.set_text(content, len(content))

        self._step_proxy_set_actives()
        self.get_object("combo").grab_focus()

    def _step_proxy_is_valid(self) -> bool:
        proxy_type = self.get_object("combo").get_active_id()

        def get_text(name):
            return self.get_object("entry_" + name).get_text()

        if proxy_type == "no":
            return True
        if not get_text("address"):
            return False
        if not get_text("port"):
            return False
        if proxy_type == "Socks5":
            if get_text("username") and not get_text("password"):
                return False
        return True

    def _step_proxy_set_actives(self):
        proxy_type = self.get_object("combo").get_active_id()
        if proxy_type == "no":
            for entry in ("address", "port", "username", "password"):
                self.get_object("entry_%s" % entry).set_sensitive(False)
        elif proxy_type in ("HTTPS", "Socks4"):
            for entry in ("address", "port"):
                self.get_object("entry_%s" % entry).set_sensitive(True)
            for entry in ("username", "password"):
                self.get_object("entry_%s" % entry).set_sensitive(False)
        else:
            for entry in ("address", "port", "username", "password"):
                self.get_object("entry_%s" % entry).set_sensitive(True)

        self.get_object("btn_submit").set_sensitive(self._step_proxy_is_valid())

    def _step_proxy_is_port_valid(self):
        entry = self.get_object("entry_port")
        port = entry.get_text()
        if not port:
            return True
        elif port.isdigit() and int(port) > 0 and int(port) < 65536:
            return True
        else:
            return False

    def cb_step_proxy_entry_changed(self, *args):
        self._step_proxy_set_actives()
        if self._step_proxy_is_port_valid():
            icon_name = ""
        else:
            icon_name = "gtk-dialog-warning"
        entry = self.get_object("entry_port")
        entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY, icon_name)

    def cb_step_proxy_combo_changed(self, *args):
        self._step_proxy_set_actives()

    def cb_step_proxy_btn_back_clicked(self, *args):
        self.change_box("error")

    def cb_step_proxy_btn_submit_clicked(self, *args):
        self.state["proxy"]["proxy_type"] = self.get_object("combo").get_active_id()
        for entry in ("address", "port", "username", "password"):
            self.state["proxy"][entry] = self.get_object("entry_%s" % entry).get_text()

        self.change_box("error")


class TCAMainWindow(
    Gtk.ApplicationWindow,
    StepOfflineHideMixin,
    StepChooseHideMixin,
    StepConnectProgressMixin,
    StepChooseBridgeMixin,
    StepErrorMixin,
    StepProxyMixin,
):

    STEPS_ORDER = ["offline", "hide", "bridge", "proxy", "error", "progress"]
    # l10n {{{
    def get_translation_domain(self):
        return "tails"

    # }}}

    def __init__(self, app):
        Gtk.ApplicationWindow.__init__(
            self, title=tca.config.APPLICATION_TITLE, application=app
        )
        self.app = app
        self.set_role(tca.config.APPLICATION_WM_CLASS)
        # set_wm_class is deprecated, but it's the only way I found to set taskbar title; see #18610
        self.set_wmclass(
            tca.config.APPLICATION_WM_CLASS, tca.config.APPLICATION_WM_CLASS
        )
        self.set_title(tca.config.APPLICATION_TITLE)
        # self.state collects data from user interactions. Its main key is the step name
        self.state: Dict[str, Any] = {
            "hide": {},
            "bridge": {},
            "proxy": {},
            "progress": {},
            "step": "hide",
            "offline": {},
            "time": {},
        }
        if self.app.args.debug_statefile is not None:
            log.debug("loading debug statefile")
            with open(self.app.args.debug_statefile) as buf:
                content = json.load(buf)
                log.debug("content found %s", content)
                self.state.update(content)
        else:
            data = self.app.configurator.read_tca_state()
            config = self.app.configurator.tor_connection_config.to_dict()
            if data and data.get("ui"):
                for key in ["hide", "bridge", "time"]:
                    self.state[key].update(data["ui"].get(key, {}))
                self.state["progress"]["started"] = (
                    data["ui"].get("progress", {}).get("started", False)
                )
            elif config and config.get("bridges"):
                self.state["hide"]["bridge"] = True
                self.state["bridge"]["kind"] = "manual"
                self.state["bridge"]["bridges"] = config["bridges"]
            self.state["progress"]["success"] = self.app.is_tor_working
            if self.state["progress"]["success"]:
                self.state["step"] = "progress"

        self.current_language = "en"
        self.connect("delete-event", self.cb_window_delete_event, None)
        self.set_position(Gtk.WindowPosition.CENTER)

        # Load custom CSS
        css_provider = Gtk.CssProvider()
        css_provider.load_from_path(os.path.join(tca.config.data_path, CSS_FILE))
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        # Load UI interface definition
        self.builder = builder = Gtk.Builder()
        builder.set_translation_domain(self.get_translation_domain())
        builder.add_from_file(tca.config.data_path + MAIN_UI_FILE)
        builder.connect_signals(self)

        self.main_container = builder.get_object("box_main_container_image_step")
        self.stack = builder.get_object("box_main_container_stack")
        for step in self.STEPS_ORDER:
            box = builder.get_object("step_{}_box".format(step))
            box.show()
            self.stack.add_named(box, step)

        self.connection_progress = ConnectionProgress(self)
        GLib.timeout_add(1000, self.connection_progress.tick)
        self.add(self.main_container)
        self.show()
        self.change_box(self.state["step"])

    @property
    def user_wants_hide(self) -> Optional[bool]:
        '''
        If the user decided already: returns what they decided, as a boolean.

        Else (first screen), returns None.
        '''
        return self.state.get('hide', {}).get('hide', None)

    def save_conf(self, successful_connect=False):
        log.info("Saving configuration (success=%s)", successful_connect)
        if successful_connect:
            data = {"ui": self.state}
        else:
            save_only = ["hide", "bridge", "time"]
            data = {"ui": {field: self.state[field] for field in save_only}}
        self.app.configurator.save_tca_state(data)
        if successful_connect:
            self.app.configurator.save_conf()

    def get_screen_size(self) -> Tuple[int, int]:
        disp = Gdk.Display.get_default()
        win = self.get_window()
        mon = disp.get_monitor_at_window(win)
        workarea = Gdk.Monitor.get_workarea(mon)
        return workarea.width, workarea.height

    def set_image(self, fname: str):
        screen_width, _ = self.get_screen_size()
        target_width = screen_width / 7
        pixbuf = GdkPixbuf.Pixbuf.new_from_file(fname)
        scale = pixbuf.get_width() / target_width
        pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(
            fname, pixbuf.get_width() / scale, pixbuf.get_height() / scale
        )
        self.builder.get_object("main_img_side").set_from_pixbuf(pixbuf)

    def change_box(self, name: str, **kwargs):
        coming_from = self.state["step"]
        self.state["step"] = name
        self.set_image(IMG_SIDE[self.state["step"]])
        self.stack.set_visible_child_name(name)

        if hasattr(self, "before_show_%s" % name):
            getattr(self, "before_show_%s" % name)(coming_from=coming_from, **kwargs)
        log.debug("Step changed, state is now %s", str(self.state))

        # # resize, just to be sure that everything is properly shown
        # screen_width, screen_height = self.get_screen_size()
        # self.resize(int(screen_width / 2), int(screen_height / 2))

    def get_object(self, name: str):
        """
        Get an object from glade file.

        This is a shortcut over self.builder.get_object which takes steps into account
        """
        return self.builder.get_object("step_%s_%s" % (self.state["step"], name))

    def cb_window_delete_event(self, widget, event, user_data=None):
        if self.state["step"] != "progress" or self.state["progress"]["success"]:
            # just close, no questions asked
            return False

        d = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            buttons=Gtk.ButtonsType.NONE,
            text=_("Are you sure you want to lose progress?"),
        )
        secondary = [
            _(
                "Tails will continue connecting to Tor after you close the Tor Connection assistant.\n\n"
                "If connecting to Tor fails, you will have to wait again until the end of the progress bar to be able to troubleshoot your connection."
            )
        ]
        d.format_secondary_markup("\n".join(secondary))
        d.add_buttons(
            "Close and Lose Progress", Gtk.ResponseType.YES, "Wait", Gtk.ResponseType.NO
        )
        d.set_default_response(Gtk.ResponseType.NO)

        def on_dialog_response(dialog, response):
            dialog.destroy()
            if response == Gtk.ResponseType.YES:
                self.app.full_quit()
                self.destroy()
                # Gtk.main_quit()

        d.connect("response", on_dialog_response)
        d.show()

        # keep the application open; the dialog response will close it
        return True

    def on_link_help_clicked(self, label, uri: str):
        self.app.portal.call_async("open-documentation", None, "--force-local", uri)

    # Called from parent application

    def _move_to_right_step(self):
        """
        This method will make TCA interface move between different states.

        Its purpose is to "centralize" as much as possible the logic that allows tca to move between different
        steps in a single workflow, thus keeping it more readable and hopefully maintainable.

        However, this is currently only called when reacting to changes in extenral components: Tor and
        NetworkManager.
        Other state transitions happen when reacting to events such as clicking.
        """
        disable_network = self.app.tor_info["DisableNetwork"] == "1"
        up = self.app.is_network_link_ok
        tor_working = self.app.is_tor_working
        step = self.state["step"]
        log.info(
            f"Status: up={up} disable_network={disable_network}, working={tor_working}, step={step}"
        )

        def _get_right_step() -> Optional[str]:
            """
            Return the step we need to go to.

            (or None if we should stay where we are)
            """
            if not up:
                self.state["offline"]["previous"] = step
                return "offline"

            # local network is ok

            if disable_network:
                if step in ["error", "progress"]:
                    return "error"
                else:
                    return "hide"

            # tor network is enabled

            if not tor_working:
                log.info("Tor not working")
                if step != "progress":
                    log.info("Not in progress, going there")
                    self.state["progress"]["success"] = False
                    return "progress"
                elif self.state["progress"]["success"]:
                    log.warn("We are not connected to Tor anymore!")
                    return "error"
                else:
                    log.debug(
                        "Tor not working and we're in progress: just wait some more"
                    )
                    return None
            else:
                self.state["progress"]["success"] = True
                return "progress"

        new_step = _get_right_step()
        if new_step and new_step != self.state["step"]:
            log.info("Moving to %s", new_step)
            self.change_box(new_step)
        self.state["progress"]["success"] = tor_working

    def on_network_changed(self):
        log.info("Local network changed %s", self.app.is_network_link_ok)
        self._move_to_right_step()
        log.debug(self.state["step"])

    def on_tor_working_changed(self, working: bool):
        log.info("Tor working changed %s", working)
        self._move_to_right_step()
        log.debug(self.state["step"])

    def on_tor_state_changed(self, tor_info: dict, changed: set):
        """Reacts to DisableNetwork changes."""
        log.info("DisableNetwork changed %s", tor_info["DisableNetwork"])
        self._move_to_right_step()
        log.debug(self.state["step"])

    # called from parent Application }}}


class ConnectionProgress:
    """
    This class "handles" the progress bar in the final screen.

    Probably the right approach would have been to subclass Gtk.ProgressBar, but subclassing and glade are
    hard to combine.
    """

    PROGRESS_CONFIGURATION_CONFIG = 0.01
    PROGRESS_CONFIGURATION_APPLIED = 0.1
    PROGRESS_BOOTSTRAP_SIGN_OF_LIFE = 0.5
    PROGRESS_BOOTSTRAP_END = 0.9

    def __init__(self, main_window):
        self.main_window = main_window
        self.bootstrap_phase = 0

    @property
    def progress(self):
        return self.main_window.builder.get_object("step_progress_pbar_torconnect")

    @property
    def log(self):
        return logging.getLogger(self.__class__.__name__)

    @property
    def sign_of_life(self):
        return self.bootstrap_phase >= TOR_BOOTSTRAP_STATUS_CONN_DONE

    @classmethod
    def _get_value_after_tick(cls, current: float, sign_of_life: bool) -> float:
        """
        Calculate value. This is helpful to make testing possible.

        >>> f = lambda x,y: '%.4f' % ConnectionProgress._get_value_after_tick(x,y)
        >>> f(0.1, False)
        '0.1400'
        >>> f(0.5, True)
        '0.5007'

        So in `n` steps we will arrive to the next progress.
        To test this, let's setup a helper function. this will just recurse "n" times
        >>> ft = lambda x: ConnectionProgress._get_value_after_tick(x, True)
        >>> ff = lambda x: ConnectionProgress._get_value_after_tick(x, False)
        >>> ftn = lambda x, n: ftn(ft(x), n-1) if n > 1 else ft(x)

        Let's test the helper itself:
        >>> '%.4f' % ftn(0.5, 1)
        '0.5007'
        >>> '%.4f' % ftn(0.5, 2)
        '0.5013'
        >>> ftn(0.5, TOR_BOOTSTRAP_TIMEOUT) - ConnectionProgress.PROGRESS_BOOTSTRAP_END < 0.001
        True

        >>> ffn = lambda x, n: ffn(ff(x), n-1) if n > 1 else ff(x)

        That's the same, but for "before sign_of_life"
        >>> '%.4f' % ffn(0.1, 1)
        '0.1400'
        >>> '%.4f' % ffn(0.1, 2)
        '0.1800'
        >>> '%.4f' % ffn(0.1, 3)
        '0.2200'
        >>> '%.4f' % ffn(0.1, TOR_SIGNOFLIFE_TIMEOUT)
        '0.5000'


        """
        if not sign_of_life:
            # in TOR_SIGNOFLIFE_TIMEOUT ticks we must go from 0.1 to 0.5 in TOR_SIGNOFLIFE_TIMEOUT seconds
            range_to_cover = (
                cls.PROGRESS_BOOTSTRAP_SIGN_OF_LIFE - cls.PROGRESS_CONFIGURATION_APPLIED
            )
            time_to_cover = TOR_SIGNOFLIFE_TIMEOUT
        else:
            range_to_cover = (
                cls.PROGRESS_BOOTSTRAP_END - cls.PROGRESS_BOOTSTRAP_SIGN_OF_LIFE
            )
            time_to_cover = TOR_BOOTSTRAP_TIMEOUT
        return current + range_to_cover / time_to_cover

    def tick(self):
        """
        Every second, performs "fake" advancement of the progress bar.

        This advancement does not correspond to real progress, but provides more responsive UX.
        """
        current = float(self.progress.get_fraction())
        if current == 0 or current >= self.PROGRESS_BOOTSTRAP_END:
            return True
        new = self._get_value_after_tick(current, self.sign_of_life)
        self.log.debug("tick moves from %.3f to %.3f", current * 100, new * 100)
        self.set_fraction(new)
        return True

    def set_fraction(self, num, allow_going_back=False):
        if (
            not allow_going_back and self.progress.get_fraction() >= num
        ):  # we're never going back because UX
            return
        self.progress.set_fraction(num)
        text = "%d%%" % (num * 100)
        self.progress.set_text(text)

    def get_fraction_from_bootstrap_phase(
        self, progress: int, sign_of_life=None
    ) -> float:
        """
        Calculate fraction based on tor bootstrap-phase.

        The 'progress' argument is the number returned by tor, which is in the range [0,100]
        """
        if sign_of_life is None:
            sign_of_life = self.sign_of_life
        if not sign_of_life:
            return self.PROGRESS_CONFIGURATION_APPLIED
        return self.PROGRESS_BOOTSTRAP_SIGN_OF_LIFE

    def set_fraction_from_bootstrap_phase(self, progress: int):
        if progress == self.bootstrap_phase:
            return
        self.bootstrap_phase = progress
        fraction = self.get_fraction_from_bootstrap_phase(progress)
        self.log.info(
            "new bootstrap_phase received: %d going to %.2f%%", progress, fraction * 100
        )
        return self.set_fraction(fraction)
