from gettext import gettext
import gi

from tailsgreeter.translatable_window import TranslatableWindow

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk

_ = gettext


class MessageDialog(Gtk.MessageDialog, TranslatableWindow):
    def __init__(self, message_type: Gtk.MessageType, title: str, text: str, cancel_label: str, ok_label: str):
        Gtk.MessageDialog.__init__(self, message_type=message_type, text=title)
        TranslatableWindow.__init__(self, self)
        self.format_secondary_text(text)
        self.button_cancel = self.add_button(cancel_label,
                                             Gtk.ResponseType.CANCEL)
        self.button_ok = self.add_button(ok_label, Gtk.ResponseType.OK)
        self.store_translations(self)
