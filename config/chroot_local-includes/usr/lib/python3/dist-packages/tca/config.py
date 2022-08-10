import gettext

translation = gettext.translation("tails", "/usr/share/locale", fallback=True)
_ = translation.gettext

data_path = "/usr/share/tails/tca/"
locale_dir = "/usr/share/locale/"
APPLICATION_TITLE = _("Tor Connection")
APPLICATION_WM_CLASS = 'TorConnectionAssistant'
CONFIG_FILE = "/var/lib/tca/tca.conf"
