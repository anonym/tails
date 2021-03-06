// This is the Debian specific preferences file for Mozilla Firefox
// You can make any change in here, it is the purpose of this file.
// You can, with this file and all files present in the
// /etc/thunderbird/pref directory, override any preference that is
// present in /usr/lib/thunderbird/defaults/pref directory.
// While your changes will be kept on upgrade if you modify files in
// /etc/thunderbird/pref, please note that they won't be kept if you
// do them in /usr/lib/thunderbird/defaults/pref.

pref("extensions.update.enabled", false);

// Use LANG environment variable to choose locale from system
// The old environment setting 'pref("intl.locale.matchOS", true);' is
// currently not working anymore. The new introduced setting
// 'intl.locale.requested' is now used for this. Setting an empty string is
// pulling the system locale into Thunderbird.
pref("intl.locale.requested", "");

// Disable default mail checking (gnome).
pref("mail.shell.checkDefaultMail", false);

// if you are not using gnome
pref("network.protocol-handler.app.http", "x-www-browser");
pref("network.protocol-handler.app.https", "x-www-browser");

// Disable mail indexing
pref("mailnews.database.global.indexer.enabled", false);

// Disable chat
pref("mail.chat.enabled", false);

// Hide the "Know your rights" message
pref("mail.rights.version", 1);

// Disable system addons
pref("extensions.autoDisableScopes", 3);
pref("extensions.enabledScopes", 4);

// Only show the tab bar if there's more than one tab to display
pref("mail.tabs.autoHide", true);

// Try to disable "Would you like to help Thunderbird Mail/News by automatically reporting memory usage, performance, and responsiveness to Mozilla"
pref("toolkit.telemetry.prompted", 2);
pref("toolkit.telemetry.rejected", true);
pref("toolkit.telemetry.enabled", false);

// Only allow SSL channels when fetching from the ISP.
pref("mailnews.auto_config.fetchFromISP.ssl_only", true);
// Only allow Thunderbird's automatic configuration wizard to use and
// configure secure (SSL/TLS) protocols.
pref("mailnews.auto_config.ssl_only_mail_servers", true);
// Old name for mailnews.auto_config.ssl_only_mail_servers, to make
// this configuration still work in case we have to revert to a previous
// version of the #6156 patchset.
pref("mailnews.auto_config.account_constraints.ssl_only", true);
// Drop auto-fetched configurations using Oauth2 -- they do not work
// together with Torbirdy since it disables needed functionality (like
// JavaScript and cookies) in the embedded browser.
pref("mailnews.auto_config.account_constraints.allow_oauth2", false);
// The timeout (in seconds) for each guess
pref("mailnews.auto_config.guess.timeout", 30);

// We disable Memory Hole for encrypted email until support is more
// mature and widely spread (#15201).
pref("extensions.enigmail.protectedHeaders", 0);
// This setting is a good guess - but not used at the moment
pref("extensions.torbirdy.custom.extensions.enigmail.protectedHeaders", 0);

// Those settings are useless at the moment, just needed to display
// the correct checkmark in torbirdy (#13649#note-31).
pref("extensions.enigmail.protectHeaders", false);
pref("extensions.torbirdy.custom.extensions.enigmail.protectHeaders", false);

// Disable Autocrypt by default for new accounts (#16222).
// This does not change anything for accounts that were created before.
pref("mail.server.default.enableAutocrypt", false);

// Don't decrypt subordinate message parts that otherwise might reveal
// decrypted content to the attacker, i.e. the optional part of the fixes
// for EFAIL.
// Reference: https://www.thunderbird.net/en-US/thunderbird/52.9.1/releasenotes/
pref("mailnews.p7m_subparts_external", true);
