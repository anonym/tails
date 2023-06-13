require 'fileutils'
require 'tempfile'
require 'open3'

def post_vm_start_hook
  $vm.late_patch if $config['LATE_PATCH']

  # Sometimes the first click is lost (presumably it's used to give
  # focus to virt-viewer or similar) so we do that now rather than
  # having an important click lost. The point we click should be
  # somewhere where no clickable elements generally reside.
  @screen.click(@screen.w - 1, @screen.h / 2)
end

def post_snapshot_restore_hook(snapshot_name, num_try)
  scenario_indent = ' ' * 4

  # Press escape to wake up the display
  @screen.press('Escape')

  $vm.wait_until_remote_shell_is_up
  pattern = if snapshot_name.end_with?('tails-greeter')
              'TailsGreeter.png'
            else
              "GnomeApplicationsMenu#{$language}.png"
            end
  begin
    try_for(10, delay: 0) do
      # We use @screen.real_find here instead of @screen.wait because we
      # don't want check_and_raise_display_output_not_active() to be called.
      @screen.real_find(pattern)
      # Sometimes the display becomes inactive 1 to 2 seconds after the
      # snapshot was restored. To catch those cases, we wait a short time
      # and make sure that we can still find the pattern.
      # We don't want this to be longer than necessary, because this will
      # slow down all tests which restore snapshots.
      sleep 3
      @screen.real_find(pattern)
    rescue FindFailed
      # Press escape to wake up the display
      @screen.press('Escape')
      next
    end
  rescue Timeout::Error
    if num_try == 3
      raise 'Failed to restore snapshot'
    end

    debug_log(scenario_indent + 'Failed to restore snapshot, retrying...',
              color: :yellow, timestamp: false)
    reach_checkpoint(snapshot_name, num_try + 1)
    return
  end

  post_vm_start_hook

  # Increase the chances that by the time we leave this function, if
  # the click in post_vm_start_hook() has opened the Applications menu
  # (which sometimes happens, go figure), that menu is closed and the
  # desktop is back to its normal state. Otherwise, all kinds of
  # trouble may arise: for example, pressing SUPER to open the
  # Activities Overview would fail (SUPER has no effect when the
  # Applications menu is still opened).
  @screen.press('Escape')
  # Wait for the menu to be closed
  sleep 1

  # The guest's Tor circuits are likely to get out of sync
  # with our Chutney network, so we ensure that we have fresh circuits.
  # Time jumps and incorrect clocks also confuse Tor in many ways.
  already_synced_time_host_to_guest = false
  # tor@default.service is always active, so we need to check if Tor
  # was configured in the snapshot we are using: for example,
  # with-network-logged-in-unsafe-browser connects to the LAN
  # but did not configure Tor.
  if $vm.connected_to_network? &&
     $vm.execute('systemctl --quiet is-active tor@default.service').success? &&
     check_disable_network != '1'
    debug_log('Restarting Tor...')
    $vm.execute('systemctl stop tor@default.service')
    $vm.host_to_guest_time_sync
    already_synced_time_host_to_guest = true
    $vm.execute('systemctl start tor@default.service')
    wait_until_tor_is_working
  end
  $vm.host_to_guest_time_sync unless already_synced_time_host_to_guest
end

Given /^a computer$/ do
  $vm&.destroy_and_undefine
  $vm = VM.new($virt, VM_XML_PATH, $vmnet, $vmstorage, DISPLAY)
end

Given /^the computer is set to boot from the Tails DVD$/ do
  $vm.set_cdrom_boot(TAILS_ISO)
end

Given /^the computer is set to boot from (.+?) drive "(.+?)"$/ do |type, name|
  $vm.set_disk_boot(name, type.downcase)
end

Given /^I (temporarily )?create an? (\d+) ([[:alpha:]]+) (?:([[:alpha:]]+) )?disk named "([^"]+)"$/ do |temporary, size, unit, type, name|
  type ||= 'qcow2'
  begin
    $vm.storage.create_new_disk(name, size: size, unit: unit, type: type)
  rescue NoSpaceLeftError => e
    cmd = "du -ah \"#{$config['TMPDIR']}\" | sort -hr | head -n20"
    info_log("#{cmd}\n" + `#{cmd}`)
    raise e
  end
  add_after_scenario_hook { $vm.storage.delete_volume(name) } if temporary
end

Given /^I plug (.+) drive "([^"]+)"$/ do |bus, name|
  $vm.plug_drive(name, bus.downcase)
  sleep 1
  step "drive \"#{name}\" is detected by Tails" if $vm.running?
end

Then /^drive "([^"]+)" is detected by Tails$/ do |name|
  raise 'Tails is not running' unless $vm.running?

  try_for(20, msg: "Drive '#{name}' is not detected by Tails") do
    $vm.disk_detected?(name)
  end
end

Given /^the network is plugged$/ do
  $vm.plug_network
end

Given /^the network is unplugged$/ do
  $vm.unplug_network
end

def activate_gnome_shell_menu_entry(label)
  gnome_shell = Dogtail::Application.new('gnome-shell')
  menu_entry = gnome_shell.child(label,
                                 roleName:    'label',
                                 showingOnly: true)
  try_for(5) do
    menu_entry.grabFocus
    menu_entry.focused
  end
  @screen.press('Return')
end

Given /^I (dis)?connect the network through GNOME$/ do |disconnect|
  open_gnome_system_menu

  # Expand the menu entry for the wired connection
  if disconnect
    activate_gnome_shell_menu_entry('Wired Connected')
  else
    activate_gnome_shell_menu_entry('Wired Off')
  end

  # Activate the Connect/Disconnect entry
  if disconnect
    activate_gnome_shell_menu_entry('Turn Off')
  else
    activate_gnome_shell_menu_entry('Connect')
  end
end

Given /^the network connection is ready(?: within (\d+) seconds)?$/ do |timeout|
  timeout ||= 30
  try_for(timeout.to_i) { $vm.connected_to_network? }
end

Given /^the hardware clock is set to "([^"]*)"$/ do |time|
  dt = if time.start_with?('+') || time.start_with?('-')
         DateTime.parse(
           cmd_helper(['date', '-d', time], env: { 'TZ' => 'UTC' })
         )
       else
         DateTime.parse(time)
       end
  debug_log("Set hw clock to #{dt}")
  $vm.set_hardware_clock(dt.to_time)
end

Given /^I capture all network traffic$/ do
  @sniffer = Sniffer.new('sniffer', $vmnet)
  @sniffer.capture
  add_after_scenario_hook do
    @sniffer.stop
    @sniffer.clear
  end
end

Given /^I set Tails to boot with options "([^"]*)"$/ do |options|
  @boot_options = options
end

When /^I start the computer$/ do
  assert(!$vm.running?,
         'Trying to start a VM that is already running')
  $vm.start
  $language = ''
  $lang_code = ''
end

Given /^I start Tails( from DVD)?( with network unplugged)?( and genuine APT sources)?( and I login)?$/ do |dvd_boot, network_unplugged, keep_apt_sources, do_login|
  step 'the computer is set to boot from the Tails DVD' if dvd_boot
  if network_unplugged
    step 'the network is unplugged'
  else
    step 'the network is plugged'
  end
  step 'I start the computer'
  if keep_apt_sources
    step 'the computer boots Tails with genuine APT sources'
  else
    step 'the computer boots Tails'
  end
  if do_login
    step 'I log in to a new session'
    if network_unplugged
      step 'all notifications have disappeared'
    else
      step 'Tor is ready'
      step 'all notifications have disappeared'
      step 'available upgrades have been checked'
    end
  end
end

Given /^I start Tails from (.+?) drive "(.+?)"( with network unplugged)?( and I login( with persistence enabled)?( with the changed persistence passphrase)?( (?:and|with) an administration password)?)?$/ do |drive_type, drive_name, network_unplugged, do_login, persistence_on, persistence_with_changed_passphrase, admin_password| # rubocop:disable Metrics/ParameterLists
  step "the computer is set to boot from #{drive_type} drive \"#{drive_name}\""
  if network_unplugged
    step 'the network is unplugged'
  else
    step 'the network is plugged'
  end
  step 'I start the computer'
  step 'the computer boots Tails'
  if do_login
    step 'I enable persistence' if persistence_on
    step 'I enable persistence with the changed passphrase' if persistence_with_changed_passphrase
    step 'I set an administration password' if admin_password
    step 'I log in to a new session'
    step 'the Additional Software installation service has started'
    if network_unplugged
      step 'all notifications have disappeared'
    else
      step 'Tor is ready'
      step 'all notifications have disappeared'
      step 'available upgrades have been checked'
    end
  end
end

Given /^I start Tails from a freshly installed USB drive with an administration password and the network is plugged and I login$/ do
  step 'I have started Tails without network from a USB drive ' \
       'without a persistent partition ' \
       "and stopped at Tails Greeter's login screen"
  step 'I set an administration password'
  step 'I log in to a new session'
  step 'the network is plugged'
  step 'Tor is ready'
  step 'all notifications have disappeared'
  step 'available upgrades have been checked'
end

When /^I power off the computer$/ do
  assert($vm.running?,
         'Trying to power off an already powered off VM')
  $vm.power_off
end

When /^I cold reboot the computer$/ do
  step 'I shutdown Tails and wait for the computer to power off'
  step 'I start the computer'
end

def boot_menu_cmdline_images
  case @os_loader
  when 'UEFI'
    # XXX: Once we require Bookworm or newer to run the test suite,
    # drop TailsBootMenuKernelCmdlineUEFI_Bullseye.png.
    [
      'TailsBootMenuKernelCmdlineUEFI_Bullseye.png',
      'TailsBootMenuKernelCmdlineUEFI_Bookworm.png',
    ]
  else
    ['TailsBootMenuKernelCmdline.png', 'TailsBootMenuKernelCmdline_alt.png']
  end
end

def boot_menu_images
  case @os_loader
  when 'UEFI'
    # XXX: Once we require Bookworm or newer to run the test suite,
    # drop TailsBootMenuGRUB_Bullseye.png.
    ['TailsBootMenuGRUB_Bullseye.png', 'TailsBootMenuGRUB_Bookworm.png']
  else
    ['TailsBootMenuSyslinux.png', 'TailsBootMenuSyslinux_alt.png']
  end
end

def up_spammer_code(domain_name)
  <<-SCRIPT
    require 'libvirt'
    up_key_code = 0x67
    virt = Libvirt::open("qemu:///system")
    begin
      domain = virt.lookup_domain_by_name('#{domain_name}')
      loop do
        domain.send_key(Libvirt::Domain::KEYCODE_SET_LINUX, 0, [up_key_code])
        sleep 1
      end
    ensure
      virt.close
    end
  SCRIPT
end

def start_up_spammer(domain_name)
  up_spammer_unit_name = 'tails-test-suite-up-spammer.service'
  bus = ENV['USER'] == 'root' ? '--system' : '--user'
  systemctl = ['/bin/systemctl', bus]
  kill_up_spammer = proc do
    if system(*systemctl, '--quiet', 'is-active', up_spammer_unit_name)
      system(*systemctl, 'stop', up_spammer_unit_name)
    end
  rescue StandardError
    # noop
  end
  kill_up_spammer.call
  up_spammer_job = fatal_system(
    '/usr/bin/systemd-run',
    bus,
    "--unit=#{up_spammer_unit_name}",
    '--quiet',
    '--collect',
    '/usr/bin/ruby',
    '-e', up_spammer_code(domain_name)
  )
  add_after_scenario_hook { kill_up_spammer.call }
  [up_spammer_job, kill_up_spammer]
end

def enter_boot_menu_cmdline
  boot_timeout = 3 * 60
  # Simply looking for the boot splash image is not robust; sometimes
  # our image matching is not fast enough to see it. Here we hope that spamming
  # UP, which will halt the boot process, will make this a bit more robust.
  # The below code is not completely reliable, so we might have to
  # retry by rebooting.
  try_for(boot_timeout) do
    begin
      _up_spammer_job, kill_up_spammer = start_up_spammer($vm.domain_name)
      @screen.wait_any(boot_menu_images, 15)
      kill_up_spammer.call

      # Navigate to the end of the kernel command-line
      case @os_loader
      when 'UEFI'
        @screen.type('e')
        3.times { @screen.press('Down') }
        @screen.press('End')
      else
        @screen.press('Tab')
      end
      @screen.wait_any(boot_menu_cmdline_images, 5)
    rescue FindFailed => e
      debug_log('We missed the boot menu before we could deal with it, ' \
                'resetting...')
      @has_been_reset = true
      $vm.reset
      raise e
    ensure
      kill_up_spammer.call
    end
    true
  end
end

Given /^the computer (?:re)?boots Tails( with genuine APT sources)?$/ do |keep_apt_sources|
  enter_boot_menu_cmdline
  boot_key = @os_loader == 'UEFI' ? 'F10' : 'Return'
  early_patch = config_bool('EARLY_PATCH') ? ' early_patch=umount' : ''
  extra_boot_options = $config['EXTRA_BOOT_OPTIONS'] || ''
  @screen.type(' autotest_never_use_this_option' \
               ' blacklist=psmouse' \
               " #{early_patch} #{@boot_options} #{extra_boot_options}",
               [boot_key])
  $vm.wait_until_remote_shell_is_up(5 * 60)
  try_for(60) do
    !greeter.nil?
  end

  post_vm_start_hook
  configure_simulated_Tor_network unless config_bool('DISABLE_CHUTNEY')
  # This is required to use APT in the test suite as explained in
  # commit e2510fae79870ff724d190677ff3b228b2bf7eac
  step 'I configure APT to use non-onion sources' unless keep_apt_sources
end

Given /^I set the language to (.*) \((.*)\)$/ do |lang, lang_code|
  $language = lang
  $lang_code = lang_code
  # The listboxrow does not expose any actions through AT-SPI,
  # so Dogtail is unable to click it directly. We let it grab focus
  # and activate it via the keyboard instead.
  try_for(10) do
    row = greeter
          .child(description: 'Configure Language', showingOnly: true)
    row.grabFocus
    row.focused
  end
  @screen.press('Return')
  try_for(10) do
    greeter
      .child('Search', roleName: 'text', showingOnly: true)
      .focused
  end
  @screen.type($language)
  sleep(2) # Gtk needs some time to filter the results
  @screen.press('Return')
end

Given /^I log in to a new session(?: in ([^ ]*) \(([^ ]*)\))?( without activating the Persistent Storage)?( after having activated the Persistent Storage| expecting no warning about the Persistent Storage not being activated)?$/ do |lang, lang_code, expect_warning, expect_no_warning|
  # We'll record the location of the login button before changing
  # language so we only need one (English) image for the button while
  # still being able to click it in any language.
  login_button = if RTL_LANGUAGES.include?(lang)
                   # If we select a RTL language below, the
                   # login and shutdown buttons will
                   # swap place.
                   ['TailsGreeterShutdownButton.png']
                 else
                   ['TailsGreeterLoginButton.png', 'TailsGreeterLoginButtonGerman.png']
                 end
  login_button_region = @screen.wait_any(login_button, 15)
  if lang && lang != 'English'
    step "I set the language to #{lang} (#{lang_code})"
    # After selecting options (language, administration password,
    # etc.), the Greeter needs some time to focus the main window
    # back, so that typing the accelerator for the "Start Tails"
    # button is honored.
    sleep(10)
  end
  login_button_region.click

  begin
    @screen.wait('PersistentStorageNotUnlocked.png', 3)
    assert(!expect_no_warning)
    saw_warning = true
    @screen.press('Right')
    @screen.press('Return')
  rescue FindFailed
    saw_warning = false
  end

  if expect_warning
    assert(saw_warning)
  end

  step 'the Tails desktop is ready'
end

def open_greeter_additional_settings
  button = greeter.child('Add an additional setting', roleName: 'push button')
  try_for(5) do
    button.grabFocus
    button.focused
  end
  @screen.press('Return')

  greeter.child('Additional Settings', roleName: 'dialog', showingOnly: true)
end

Given /^I open Tails Greeter additional settings dialog$/ do
  open_greeter_additional_settings
end

Given /^I disable networking in Tails Greeter$/ do
  dialog = open_greeter_additional_settings
  row = dialog.child(description: 'Configure Offline Mode')
  try_for(5) do
    row.grabFocus
    row.focused
  end
  @screen.press('Return')

  row = dialog.child('Disable all networking').parent.parent
  try_for(5) do
    row.grabFocus
    row.focused
  end
  @screen.press('Return')
end

Given /^I set an administration password$/ do
  open_greeter_additional_settings
  @screen.wait('TailsGreeterAdminPassword.png', 20).click
  @screen.wait('TailsGreeterAdminPasswordDialog.png', 10)
  @screen.type(@sudo_password)
  @screen.press('Tab')
  @screen.type(@sudo_password)
  @screen.press('Return')
  # Wait for the Administration Password dialog to be closed,
  # otherwise the next step can fail.
  @screen.wait('TailsGreeterLoginButton.png', 10)
end

Given /^I disable the Unsafe Browser$/ do
  open_greeter_additional_settings
  @screen.wait('TailsGreeterUnsafeBrowser.png', 20).click
  @screen.wait('TailsGreeterUnsafeBrowserDisable.png', 20).click
  @screen.wait('TailsGreeterAdditionalSettingsAdd.png', 10).click
end

Given /^the Tails desktop is ready$/ do
  desktop_started_picture = "GnomeApplicationsMenu#{$language}.png"
  @screen.wait(desktop_started_picture, 180)
  # We want to ensure the Tails Documentation desktop icon is visible,
  # but it might be obscured by TCA or other windows depending on the
  # order of steps run before this one.
  # XXX: Once #18407 is fixed we may be able to remove this.
  try_for(30) do
    begin
      @screen.find('DesktopTailsDocumentation.png')
    rescue FindFailed
      # Switch to new workspace
      @screen.press('super', 'page_down')
      next
    end
    true
  end
  # Switch back to initial workspace, in case we changed it above
  @screen.press('super', 'home')
  # Disable screen blanking since we sometimes need to wait long
  # enough for it to activate, which can cause problems when we are
  # waiting for an image for a very long time.
  $vm.execute_successfully(
    'gsettings set org.gnome.desktop.session idle-delay 0',
    user: LIVE_USER
  )
  # We need to enable the accessibility toolkit for dogtail.
  $vm.execute_successfully(
    'gsettings set org.gnome.desktop.interface toolkit-accessibility true',
    user: LIVE_USER
  )
  # And also for the root user for applications that run with
  # sudo/pkexec under XWayland.
  $vm.execute_successfully(
    'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus ' \
    'gsettings set org.gnome.desktop.interface toolkit-accessibility true'
  )
  # Optimize upgrade check: avoid 30 second sleep
  $vm.execute_successfully(
    'sed -i "s/^ExecStart=.*$/& --no-wait/" /usr/lib/systemd/user/tails-upgrade-frontend.service'
  )
  $vm.execute_successfully('systemctl --user daemon-reload', user: LIVE_USER)
end

When /^I see the "(.+)" notification(?: after at most (\d+) seconds)?$/ do |title, timeout|
  timeout = timeout ? timeout.to_i : nil
  gnome_shell = Dogtail::Application.new('gnome-shell')
  notification_list = gnome_shell.child(
    'No Notifications', roleName: 'label', showingOnly: false
  ).parent.parent
  try_for(timeout) do
    notification_list.child?(title, roleName: 'label', showingOnly: false)
  end
end

Given /^Tor is ready$/ do
  # deprecated: please choose between "I successfully configure Tor" and "I wait until Tor is ready"
  step 'I successfully configure Tor'
end

##
# this is a #18293-aware version of `tor_variable get --type=conf DisableNetwork`
def check_disable_network
  disable_network = nil
  # Gather debugging information for #18557
  try_for(10) do
    disable_network = $vm.execute_successfully(
      '/usr/local/lib/tor_variable get --type=conf DisableNetwork'
    ).stdout.chomp
    if disable_network == ''
      debug_log('Tor claims DisableNetwork is an empty string')
      false
    else
      true
    end
  end
  disable_network
end

Given /^I successfully configure Tor$/ do
  # First we wait for tor's control port to be ready...
  try_for(60) do
    $vm.execute_successfully('/usr/local/lib/tor_variable get --type=info version')
    true
  end
  # ... so we can ask if the tor's networking is disabled, in which
  # case Tor Connection Assistant has not been dealt with yet. If
  # tor's networking is enabled at this stage it means we already ran
  # some steps dealing with Tor Connection Assistant, presumably to
  # configure bridges.  Otherwise we just treat this as the default
  # case, where it is not important for the test scenario that we go
  # through the extra hassle and use bridges, so we simply attempt a
  # direct connection.
  disable_network = check_disable_network
  if disable_network == '1'
    # This variable is initialized to false in each scenario, and only
    # ever set to true in some previously run step that configures tor
    # to explicitly use PTs; please note that when it is false, it still
    # means that Tor _might_ be using bridges
    debug_log('DisableNetwork=1, so we autoconnect')
    assert(!@user_wants_pluggable_transports, 'This is a test suite bug!')
    @user_wants_pluggable_transports = false
    step 'the Tor Connection Assistant autostarts'
    step 'I configure a direct connection in the Tor Connection Assistant'
  end

  step 'I wait until Tor is ready'
end

Then /^I wait until Tor is ready$/ do
  # Here we actually check that Tor is ready
  step 'Tor has built a circuit'
  step 'the time has synced'
  debug_log('user_wants_pluggable_transports = ' \
           "#{@user_wants_pluggable_transports} " \
           'tor_network_is_blocked = ' \
           "#{@tor_network_is_blocked}")
  must_use_pluggable_transports = \
    if !@user_wants_pluggable_transports
      # In this case, tca is allowing both methods,
      # and will use PTs depending on network conditions
      defined?(@tor_network_is_blocked) && @tor_network_is_blocked
    else
      true
    end
  if must_use_pluggable_transports
    step 'Tor is not confined with Seccomp'
  else
    step 'Tor is confined with Seccomp'
  end
  @tor_success_configs ||= []
  @tor_success_configs << $vm.execute_successfully(
    '/usr/local/lib/tor_variable get --type=info config-text', libs: 'tor'
  ).stdout
  # When we test for ASP upgrade failure the following tests would fail,
  # so let's skip them in this case.
  unless $vm.file_exist?('/run/live-additional-software/doomed_to_fail')
    step 'the Additional Software upgrade service has started'
    begin
      try_for(30) { $vm.execute('systemctl is-system-running').success? }
    rescue Timeout::Error
      jobs = $vm.execute('systemctl list-jobs').stdout
      units_status = $vm.execute('systemctl --all --state=failed').stdout
      raise "The system is not fully running yet:\n#{jobs}\n#{units_status}"
    end
  end
end

Given /^Tor has built a circuit$/ do
  wait_until_tor_is_working
end

class TimeSyncingError < StandardError
end

class HtpdateError < TimeSyncingError
end

Given /^the time has synced$/ do
  try_for(300) { $vm.file_exist?('/run/htpdate/success') }
rescue Timeout::Error
  raise HtpdateError, 'Time syncing failed'
end

Given /^available upgrades have been checked$/ do
  try_for(300) { $vm.file_exist?('/run/tails-upgrader/checked_upgrades') }
end

When /^I start the Tor Browser( in offline mode)?$/ do |offline|
  step 'I start "Tor Browser" via GNOME Activities Overview'
  if offline
    start_button = Dogtail::Application
                   .new('zenity')
                   .dialog('Tor is not ready', showingOnly: true)
                   .button('Start Tor Browser Offline', showingOnly: true)
    # Sometimes this click is lost. Maybe the dialog is not fully setup yet?
    sleep 2
    start_button.click
  end
  step 'the Tor Browser has started'
  if offline
    step 'the Tor Browser shows the ' \
         '"The proxy server is refusing connections" error'
  end
end

Given /^the Tor Browser (?:has started|starts)$/ do
  try_for(60) do
    @torbrowser = Dogtail::Application.new('Firefox')
    @torbrowser.child?(roleName: 'frame', recursive: false)
  end
  browser_info = xul_application_info('Tor Browser')
  @screen.wait(browser_info[:new_tab_button_image], 10)
  try_for(120, delay: 3) do
    # We can't use Dogtail here: this step must support many languages
    # and using Dogtail would require maintaining a list of translations
    # for the "Stop" and "Reload" buttons.
    @screen.wait_vanish(browser_info[:browser_stop_button_image], 120)
    if RTL_LANGUAGES.include?($language)
      @screen.wait(browser_info[:browser_reload_button_image_rtl], 120)
    else
      @screen.wait(browser_info[:browser_reload_button_image], 120)
    end
  end
end

Given /^the Tor Browser loads the (startup page|Tails homepage|Tails GitLab)$/ do |page|
  case page
  when 'startup page'
    titles = [
      'Tails',
      'Tails - Trying a testing version of Tails',
      'Tails - Welcome to Tails!',
      'Tails - Dear Tails user,',
    ]
  when 'Tails homepage'
    titles = ['Tails']
  when 'Tails GitLab'
    titles = ['tails · GitLab']
  else
    raise "Unsupported page: #{page}"
  end
  page_has_loaded_in_the_tor_browser(titles)
end

When /^I request a new identity using Torbutton$/ do
  @torbrowser.child('New Identity', roleName: 'push button').press
  @torbrowser.child('Restart Tor Browser', roleName: 'push button').press
end

Given /^I add a bookmark to eff.org in the Tor Browser$/ do
  url = 'https://www.eff.org'
  step "I open the address \"#{url}\" in the Tor Browser"
  step 'the Tor Browser shows the ' \
       '"The proxy server is refusing connections" error'
  @screen.press('ctrl', 'd')
  prompt = @torbrowser.child('Add bookmark', roleName: 'panel')
  prompt.click
  @screen.paste(url)
  prompt.child('Location', roleName: 'combo box').open
  prompt.child('Bookmarks Menu', roleName: 'menu item').click
  prompt.button('Save').press
end

Given /^the Tor Browser has a bookmark to eff.org$/ do
  @screen.press('alt', 'b')
  @screen.wait('TorBrowserEFFBookmark.png', 10)
end

Given /^all notifications have disappeared$/ do
  gnome_shell = Dogtail::Application.new('gnome-shell')
  retry_action(10, recovery_proc: proc { @screen.press('Escape') }) do
    @screen.press('super', 'v') # Show the notification list
    gnome_shell.child('Do Not Disturb',
                      roleName: 'label', showingOnly: true)
    # Check if there are notifications or if the "No Notifications"
    # label is visible. Don't retry to avoid long delays - if there are
    # no notifications, the button should be visible when the
    # "Do Not Disturb" button is visible.
    no_notifications = gnome_shell.child?(
      'No Notifications',
      roleName: 'label', showingOnly: true, retry: false
    )
    unless no_notifications
      try_for(3) do
        button = gnome_shell.child(
          'Clear',
          roleName: 'push button', showingOnly: true
        )
        button.grabFocus
        button.focused
      end
      @screen.press('Return')
      gnome_shell.child?('No Notifications', roleName: 'label', showingOnly: true)
    end
  end
  @screen.press('Escape')
  # Increase the chances that by the time we leave this step, the
  # notifications menu was closed and the desktop is back to its
  # normal state. Otherwise, all kinds of trouble may arise: for
  # example, pressing SUPER to open the Activities Overview sometimes
  # fails (SUPER has no effect when the notifications menu is still
  # opened). We sleep here, instead of in "I start […] via GNOME
  # Activities Overview", because it's our responsibility to return to
  # a normal desktop state that any following step can rely upon.
  sleep 1
end

Then /^I (do not )?see "([^"]*)" after at most (\d+) seconds$/ do |negation, image, time|
  if negation
    @screen.wait_vanish(image, time.to_i)
  else
    @screen.wait(image, time.to_i)
  end
end

Given /^I enter the sudo password in the pkexec prompt$/ do
  step "I enter the \"#{@sudo_password}\" password in the pkexec prompt"
end

def deal_with_polkit_prompt(password, **opts)
  opts[:expect_success] = true if opts[:expect_success].nil?
  image = 'PolicyKitAuthPrompt.png'
  @screen.wait(image, 60)
  @screen.type(password, ['Return'])
  if opts[:expect_success]
    @screen.wait_vanish(image, 20)
  else
    @screen.wait('PolicyKitAuthFailure.png', 20)
    # Ensure the dialog is ready to handle whatever else
    # we want to do with it next, such as pressing Escape
    sleep 0.5
  end
end

Given /^I enter the "([^"]*)" password in the pkexec prompt$/ do |password|
  deal_with_polkit_prompt(password)
end

Given /^process "([^"]+)" is (not )?running$/ do |process, not_running|
  if not_running
    assert(!$vm.process_running?(process), "Process '#{process}' is running")
  else
    assert($vm.process_running?(process), "Process '#{process}' is not running")
  end
end

Given /^process "([^"]+)" is running within (\d+) seconds$/ do |process, time|
  try_for(time.to_i, msg: "Process '#{process}' is not running after " \
                             "waiting for #{time} seconds") do
    $vm.process_running?(process)
  end
end

Given /^process "([^"]+)" has stopped running after at most (\d+) seconds$/ do |process, time|
  try_for(time.to_i, msg: "Process '#{process}' is still running after " \
                             "waiting for #{time} seconds") do
    !$vm.process_running?(process)
  end
end

Given /^I kill the process "([^"]+)"$/ do |process|
  $vm.execute_successfully("killall #{process}")
  try_for(10, msg: "Process '#{process}' could not be killed") do
    !$vm.process_running?(process)
  end
end

Then /^Tails eventually (shuts down|restarts)$/ do |mode|
  try_for(3 * 60) do
    if mode == 'restarts'
      @screen.find('TailsGreeter.png')
      true
    else
      !$vm.running?
    end
  end
end

Given /^I shutdown Tails and wait for the computer to power off$/ do
  $vm.spawn('systemctl poweroff')
  step 'Tails eventually shuts down'
end

def open_gnome_menu(name)
  menu = Dogtail::Application.new('gnome-shell')
                             .child(name, roleName: 'menu')
  try_for(5) do
    menu.grabFocus
    menu.focused
  end
  @screen.press('Return')
end

def open_gnome_places_menu
  open_gnome_menu('Places')
end

def open_gnome_system_menu
  open_gnome_menu('System')
end

When /^I request a (shutdown|reboot) using the system menu$/ do |action|
  gnome_shell = Dogtail::Application.new('gnome-shell')
  open_gnome_system_menu
  menu_item_name = if action == 'shutdown'
                     'Power Off'
                   else
                     'Restart'
                   end
  try_for(5) do
    menu_item = gnome_shell.child(menu_item_name, roleName: 'label')
    menu_item.grabFocus
    menu_item.focused
  end
  @screen.press('Return')
end

When /^I warm reboot the computer$/ do
  $vm.spawn('reboot')
end

Given /^the package "([^"]+)" is( not)? installed( after Additional Software has been started)?$/ do |package, absent, asp|
  if absent
    wait_for_package_removal(package)
  else
    step 'the Additional Software installation service has started' if asp
    wait_for_package_installation(package)
  end
end

Given /^I add a ([a-z0-9.]+ |)wired DHCP NetworkManager connection called "([^"]+)"$/ do |version, con_name|
  raise "Unsupported version '#{version}'" unless version.empty?

  $vm.execute_successfully(
    "nmcli connection add con-name #{con_name} " \
    'type ethernet autoconnect yes ifname eth0'
  )

  try_for(10) do
    nm_con_list = $vm.execute('nmcli --terse --fields NAME connection show')
                     .stdout
    nm_con_list.split("\n").include? con_name.to_s
  end
end

Given /^I switch to the "([^"]+)" NetworkManager connection$/ do |con_name|
  $vm.execute("nmcli connection up id #{con_name}")
  try_for(60) do
    $vm.execute(
      'nmcli --terse --fields NAME,STATE connection show'
    ).stdout.chomp.split("\n").include?("#{con_name}:activated")
  end
end

When /^I run "([^"]+)" in GNOME Terminal$/ do |command|
  if !$vm.process_running?('gnome-terminal-server')
    step 'I start "GNOME Terminal" via GNOME Activities Overview'
    @screen.wait('GnomeTerminalWindow.png', 40)
  else
    @screen.wait('GnomeTerminalWindow.png', 20).click
  end
  @screen.paste(command, app: :terminal)
  @screen.press('Return')
end

When /^the file "([^"]+)" exists(?:| after at most (\d+) seconds)$/ do |file, timeout|
  timeout = 10 if timeout.nil?
  try_for(
    timeout.to_i,
    msg: "The file #{file} does not exist after #{timeout} seconds"
  ) do
    $vm.file_exist?(file)
  end
end

When /^the file "([^"]+)" does not exist$/ do |file|
  assert(!$vm.file_exist?(file))
end

When /^the directory "([^"]+)" exists$/ do |directory|
  assert($vm.directory_exist?(directory))
end

When /^the directory "([^"]+)" does not exist$/ do |directory|
  assert(!$vm.directory_exist?(directory))
end

When /^the file "([^"]+)" has the content "([^"]+)"$/ do |file, content|
  $vm.file_content(file) == content
end

When /^I copy "([^"]+)" to "([^"]+)" as user "([^"]+)"$/ do |source, destination, user|
  c = $vm.execute("cp \"#{source}\" \"#{destination}\"", user: user)
  assert(c.success?, "Failed to copy file:\n#{c.stdout}\n#{c.stderr}")
end

def is_persistence_active?(app)
  conf = get_tps_bindings(true)[app.to_s]
  c = $vm.execute("findmnt --noheadings --output SOURCE --target '#{conf}'")
  c.success? && (c.stdout.chomp != 'overlay')
end

Then /^persistence for "([^"]+)" is (|not )active$/ do |app, active|
  case active
  when ''
    assert(is_persistence_active?(app), 'Persistence should be active.')
  when 'not '
    assert(!is_persistence_active?(app), 'Persistence should not be active.')
  end
end

def language_has_non_latin_input_source(language)
  # NOTE: we'll have to update the list when fixing #12638 or #18076
  ['Persian', 'Russian'].include?(language)
end

# In the situations where we call this method
# (language_has_non_latin_input_source), we have exactly 2 input
# sources, so calling this method switches back and forth
# between them.
def switch_input_source
  @screen.press('super', 'space')
  sleep 1
end

Given /^I start "([^"]+)" via GNOME Activities Overview$/ do |app_name|
  # Search disambiguations: below we assume that there is only one
  # result, since multiple results introduces a race that leads to a
  # non-deterministic choice (at least under load). To make the life
  # easier for users of this step, let's collect workarounds here.
  case app_name
  when 'GNOME Terminal'
    # "GNOME Terminal" and "Terminal" shows both the (non-Root)
    # "Terminal" and "Root Terminal" search results, so let's use a
    # keyword only found in the former's .desktop file.
    app_name = 'commandline'
  when 'Persistent Storage'
    # "Persistent Storage" also matches "Back Up Persistent Storage"
    # (tails-backup.desktop).
    app_name = 'Configure which files'
  end
  @screen.wait("GnomeApplicationsMenu#{$language}.png", 10)
  @screen.press('super')
  pic = if RTL_LANGUAGES.include?($language)
          'GnomeActivitiesOverviewSearchRTL.png'
        else
          'GnomeActivitiesOverviewSearch.png'
        end
  @screen.wait(pic, 20)
  if language_has_non_latin_input_source($language)
    # Temporarily switch to en_US keyboard layout to type the name of the app
    switch_input_source
  end
  # Trigger startup of search providers
  @screen.type(app_name[0])
  # Give search providers some time to start (#13469#note-5) otherwise
  # our search sometimes returns no results at all.
  sleep 2
  # Type the rest of the search query
  @screen.type(app_name[1..-1])
  sleep 4
  @screen.press('ctrl', 'Return')
  if language_has_non_latin_input_source($language)
    # Switch back to $language's default keyboard layout
    switch_input_source
  end
end

When /^I press the "([^"]+)" key$/ do |key|
  @screen.press(key)
end

Then /^the (amnesiac|persistent) Tor Browser directory (exists|does not exist)$/ do |persistent_or_not, mode|
  case persistent_or_not
  when 'amnesiac'
    dir = "/home/#{LIVE_USER}/Tor Browser"
  when 'persistent'
    dir = "/home/#{LIVE_USER}/Persistent/Tor Browser"
  end
  step "the directory \"#{dir}\" #{mode}"
end

Then /^there is a GNOME bookmark for the (amnesiac|persistent) Tor Browser directory$/ do |persistent_or_not|
  bookmark = 'Tor Browser'
  bookmark += ' (persistent)' if persistent_or_not == 'persistent'
  open_gnome_places_menu
  Dogtail::Application.new('gnome-shell').child(bookmark, roleName: 'label', showingOnly: true)
  @screen.press('Escape')
end

def pulseaudio_sink_inputs
  pa_info = $vm.execute_successfully('pacmd info', user: LIVE_USER).stdout
  sink_inputs_line = pa_info.match(/^\d+ sink input\(s\) available\.$/)[0]
  sink_inputs_line.match(/^\d+/)[0].to_i
end

When /^I double-click on the (Tails documentation|Report an Error) launcher on the desktop$/ do |launcher|
  image = "Desktop#{launcher.split.map(&:capitalize).join}.png"
  info = xul_application_info('Tor Browser')
  # Sometimes the double-click is lost (#12131).
  retry_action(10) do
    if $vm.execute(
      "pgrep --uid #{info[:user]} --full --exact '#{info[:cmd_regex]}'"
    ).failure?
      @screen.wait(image, 10).click(double: true)
    end
    step 'the Tor Browser has started'
  end
end

When /^I (can|cannot) save the current page as "([^"]+[.]html)" to the (.*) directory$/ do |should_work, output_file, output_dir|
  should_work = should_work == 'can'

  file_dialog = save_page_as

  case output_dir
  when 'persistent Tor Browser'
    output_dir = "/home/#{LIVE_USER}/Persistent/Tor Browser"
    # Select the "Tor Browser (persistent)" bookmark in the file chooser's
    # sidebar. It doesn't expose an action via the accessibility API, so we
    # have to grab focus and use the keyboard to activate it.
    try_for(3) do
      bookmark = file_dialog.child(
        description: output_dir,
        roleName:    'list item',
        showingOnly: true
      )
      bookmark.grabFocus
      bookmark.focused
    end
    @screen.press('Space')
  when 'default downloads'
    output_dir = "/home/#{LIVE_USER}/Tor Browser"
  else
    # Enter the output directory in the text entry
    text_entry = file_dialog.child('Name', roleName: 'label').labelee
    text_entry.text = output_dir
    # Do the "activate" action of the text entry (same effect as
    # pressing Enter) to open the directory.
    text_entry.activate
  end

  # Enter the output filename in the text entry
  text_entry = file_dialog.child('Name', roleName: 'label').labelee
  text_entry.text = output_file
  file_dialog.child('Save', roleName: 'push button').click

  if should_work
    try_for(20,
            msg: "The page was not saved to #{output_dir}/#{output_file}") do
      $vm.file_exist?("#{output_dir}/#{output_file}")
    end
  else
    @screen.wait('TorBrowserCannotSavePage.png', 10)
  end
end

When /^I can print the current page as "([^"]+[.]pdf)" to the (default downloads|persistent Tor Browser) directory$/ do |output_file, output_dir|
  output_dir = if output_dir == 'persistent Tor Browser'
                 "/home/#{LIVE_USER}/Persistent/Tor Browser"
               else
                 "/home/#{LIVE_USER}/Tor Browser"
               end
  @screen.press('ctrl', 'p')
  @torbrowser.child('Save', roleName: 'push button').press
  file_dialog = @torbrowser.child('Save As',
                                  roleName:    'file chooser',
                                  showingOnly: true)
  # Enter the output filename in the text entry
  text_entry = file_dialog.child('Name', roleName: 'label').labelee
  filename = "#{output_dir}/#{output_file}"
  text_entry.text = filename
  file_dialog.child('Save', roleName: 'push button').click

  try_for(30,
          msg: "The page was not printed to #{output_dir}/#{output_file}") do
    $vm.file_exist?("#{output_dir}/#{output_file}")
  end
end

Given /^a web server is running on the LAN$/ do
  # Start a new web server unless one is already running
  unless @web_server_url
    start_web_server
  end
end

def start_web_server
  @web_server_ip_addr = $vmnet.bridge_ip_addr
  @web_server_port = 8000
  @web_server_url = "http://#{@web_server_ip_addr}:#{@web_server_port}"
  web_server_hello_msg = 'Welcome to the LAN web server!'

  # Ensure that the LAN web server data directory is empty
  FileUtils.rm_rf(LAN_WEB_SERVER_DATA_DIR)
  FileUtils.mkdir_p(LAN_WEB_SERVER_DATA_DIR)

  @captive_portal_login_file = "#{LAN_WEB_SERVER_DATA_DIR}/logged-in"
  @lan_web_server_headers_dir = "#{LAN_WEB_SERVER_DATA_DIR}/headers"

  add_extra_allowed_host(@web_server_ip_addr, @web_server_port)

  _, out, proc = Open3.popen2e(
    "#{GIT_DIR}/features/scripts/lan-web-server",
    '--address', @web_server_ip_addr,
    '--port', @web_server_port.to_s,
    '--hello-message', web_server_hello_msg,
    '--data-dir', LAN_WEB_SERVER_DATA_DIR
  )

  # Log all the web server output (stdout and stderr) to the debug log
  Thread.new do
    out.each_line do |line|
      debug_log("LAN web server: #{line}")
    end
  end

  try_for(10, msg: 'It seems the LAN web server failed to start') do
    Process.kill(0, proc.pid) == 1
  end

  add_after_scenario_hook do
    Process.kill('TERM', proc.pid)
    Process.wait(proc.pid)
  end

  # It seems necessary to actually check that the LAN server is
  # serving, possibly because it isn't doing so reliably when setting
  # up. If e.g. the Unsafe Browser (which *should* be able to access
  # the web server) tries to access it too early, Firefox seems to
  # take some random amount of time to retry fetching. Curl gives a
  # more consistent result, so let's rely on that instead.
  try_for(30, msg: 'Something is wrong with the LAN web server') do
    # Use /usr/bin/curl instead of our curl wrapper script because the
    # wrapper script makes curl use Tor and we want to access the LAN.
    msg = cmd_helper(['curl', '--silent', '--fail', @web_server_url])
    web_server_hello_msg == msg
  end

  # Remove the header file that was saved by the web server for the
  # previous request (we just remove all files in the headers directory
  # because we don't know the filename and there shouldn't be any other
  # files in there anyway).
  FileUtils.rm_f(Dir.glob("#{@lan_web_server_headers_dir}/*"))
end

When /^I open a page on the LAN web server in the (.*)$/ do |browser|
  step "I open the address \"#{@web_server_url}\" in the #{browser}"
end

Given /^I wait (?:between (\d+) and )?(\d+) seconds$/ do |min, max|
  time = if min
           rand(max.to_i - min.to_i + 1) + min.to_i
         else
           max.to_i
         end
  puts "Slept for #{time} seconds"
  sleep(time)
end

Given /^I (?:re)?start monitoring the AppArmor log of "([^"]+)"$/ do |profile|
  # AppArmor log entries may be dropped if printk rate limiting is
  # enabled.
  $vm.execute_successfully('sysctl -w kernel.printk_ratelimit=0')
  # We will only care about entries for this profile from this time
  # and on.
  guest_time = $vm.execute_successfully(
    'date +"%Y-%m-%d %H:%M:%S"'
  ).stdout.chomp
  @apparmor_profile_monitoring_start ||= {}
  @apparmor_profile_monitoring_start[profile] = guest_time
end

When /^AppArmor has (not )?denied "([^"]+)" from opening "([^"]+)"$/ do |anti_test, profile, file|
  assert(@apparmor_profile_monitoring_start &&
         @apparmor_profile_monitoring_start[profile],
         "It seems the profile '#{profile}' isn't being monitored by the " \
         "'I monitor the AppArmor log of ...' step")
  audit_line_regex = format(
    'apparmor="DENIED" operation="open" profile="%<profile>s" name="%<file>s"',
    profile: profile,
    file:    file
  )
  begin
    try_for(10, delay: 1) do
      audit_log = $vm.execute(
        'journalctl --full --no-pager ' \
        "--since='#{@apparmor_profile_monitoring_start[profile]}' " \
        "SYSLOG_IDENTIFIER=kernel | grep -w '#{audit_line_regex}'"
      ).stdout.chomp
      assert(audit_log.empty? == (anti_test ? true : false))
      true
    end
  rescue Timeout::Error, Test::Unit::AssertionFailedError => e
    raise e, "AppArmor has #{anti_test ? '' : 'not '}denied the operation"
  end
end

Then /^I force Tor to use a new circuit$/ do
  force_new_tor_circuit
end

When /^I eject the boot medium$/ do
  dev = boot_device
  dev_type = device_info(dev)['ID_TYPE']
  case dev_type
  when 'cd'
    $vm.eject_cdrom
  when 'disk'
    boot_disk_name = $vm.disk_name(dev)
    $vm.unplug_drive(boot_disk_name)
  else
    raise "Unsupported medium type '#{dev_type}' for boot device '#{dev}'"
  end
end

Given /^Tails is fooled to think it is running version (.+)$/ do |version|
  $vm.execute_successfully(
    'sed -i ' \
    "'s/^TAILS_VERSION_ID=.*$/TAILS_VERSION_ID=\"#{version}\"/' " \
    '/etc/os-release'
  )
end

Given /^Tails is fooled to think that version (.+) was initially installed$/ do |version|
  initial_os_release_file =
    '/lib/live/mount/rootfs/filesystem.squashfs/etc/os-release'
  fake_os_release_file = $vm.execute_successfully('mktemp').stdout.chomp
  fake_os_release_content = <<~OSRELEASE
    TAILS_PRODUCT_NAME="Tails"
    TAILS_VERSION_ID="#{version}"
  OSRELEASE
  $vm.file_overwrite(fake_os_release_file, fake_os_release_content)
  $vm.execute_successfully("chmod a+r #{fake_os_release_file}")
  $vm.execute_successfully(
    "mount --bind '#{fake_os_release_file}' '#{initial_os_release_file}'"
  )
  # Let's verify that the deception works
  assert_equal(
    version,
    $vm.execute_successfully(
      ". #{initial_os_release_file} && echo ${TAILS_VERSION_ID}"
    ).stdout.chomp,
    'Implementation error, alert the test suite maintainer!'
  )
end

def running_tails_version
  $vm.execute_successfully('tails-version').stdout.split.first
end

Then /^Tails is running version (.+)$/ do |version|
  v1 = running_tails_version
  assert_equal(version, v1, "The version doesn't match tails-version's output")
  v2 = $vm.file_content('/etc/os-release')
          .scan(/TAILS_VERSION_ID="(#{version})"/).flatten.first
  assert_equal(version, v2, "The version doesn't match /etc/os-release")
end

def size_of_shared_disk_for(files)
  files = [files] if files.instance_of?(String)
  assert_equal(Array, files.class)
  disk_size = files.map { |f| File.new(f).size }.reduce(0, :+)
  # Let's add some extra space for filesystem overhead etc.
  disk_size += [convert_to_bytes(16, 'MiB'), (disk_size * 0.15).ceil].max
  disk_size
end

def share_host_files(files)
  files = [files] if files.instance_of?(String)
  assert_equal(Array, files.class)
  disk_size = size_of_shared_disk_for(files)
  disk = random_alpha_string(10)
  step "I temporarily create an #{disk_size} bytes disk named \"#{disk}\""
  step "I create a gpt partition labeled \"#{disk}\" with an ext4 " \
       "filesystem on disk \"#{disk}\""
  $vm.storage.guestfs_disk_helper(disk) do |g, _|
    partition = g.list_partitions.first
    g.mount(partition, '/')
    files.each { |f| g.upload(f, "/#{File.basename(f)}") }
  end
  step "I plug USB drive \"#{disk}\""
  mount_dir = $vm.execute_successfully('mktemp -d').stdout.chomp
  dev = $vm.disk_dev(disk)
  partition = "#{dev}1"
  $vm.execute_successfully("mount #{partition} #{mount_dir}")
  $vm.execute_successfully("chmod -R a+rX '#{mount_dir}'")
  mount_dir
end

def mount_usb_drive(disk, **fs_options)
  fs_options[:encrypted] ||= false
  @tmp_usb_drive_mount_dir = $vm.execute_successfully('mktemp -d').stdout.chomp
  dev = $vm.disk_dev(disk)
  partition = "#{dev}1"
  if fs_options[:encrypted]
    password = fs_options[:password]
    assert_not_nil(password)
    luks_mapping = "#{disk}_unlocked"
    $vm.execute_successfully(
      "echo #{password} | " \
      "cryptsetup luksOpen #{partition} #{luks_mapping}"
    )
    $vm.execute_successfully(
      "mount /dev/mapper/#{luks_mapping} #{@tmp_usb_drive_mount_dir}"
    )
  else
    $vm.execute_successfully("mount #{partition} #{@tmp_usb_drive_mount_dir}")
  end
  @tmp_filesystem_disk = disk
  @tmp_filesystem_options = fs_options
  @tmp_filesystem_partition = partition
  @tmp_usb_drive_mount_dir
end

When(/^I plug and mount a (\d+) MiB USB drive with an? (.*)$/) do |size_MiB, fs|
  disk_size = convert_to_bytes(size_MiB.to_i, 'MiB')
  disk = random_alpha_string(10)
  step "I temporarily create an #{disk_size} bytes disk named \"#{disk}\""
  step "I create a gpt partition labeled \"#{disk}\" with " \
       "an #{fs} on disk \"#{disk}\""
  step "I plug USB drive \"#{disk}\""
  fs_options = {}
  fs_options[:filesystem] = /(.*) filesystem/.match(fs)[1]
  if /\bencrypted with password\b/.match(fs)
    fs_options[:encrypted] = true
    fs_options[:password] = /encrypted with password "([^"]+)"/.match(fs)[1]
  end
  mount_dir = mount_usb_drive(disk, **fs_options)
  @tmp_filesystem_size_b = convert_to_bytes(
    avail_space_in_mountpoint_kB(mount_dir),
    'KB'
  )
end

When(/^I mount the USB drive again$/) do
  mount_usb_drive(@tmp_filesystem_disk, **@tmp_filesystem_options)
end

When(/^I umount the USB drive$/) do
  $vm.execute_successfully("umount #{@tmp_usb_drive_mount_dir}")
  if @tmp_filesystem_options[:encrypted]
    $vm.execute_successfully('cryptsetup luksClose ' \
                             "#{@tmp_filesystem_disk}_unlocked")
  end
end

When /^Tails system time is magically synchronized$/ do
  $vm.host_to_guest_time_sync
end

# Useful for debugging scenarios: e.g. inject this step in a scenario
# at some point when you want to investigate the state.
When /^I pause$/ do
  pause
end

# Useful for debugging Tails features: let's say you want to fix a bug
# exposed by $SCENARIO, and is working on a fix in $FILE locally. To
# immediately test your fix, simply inject this step into $SCENARIO,
# so that $FILE is put in place (obviously this depends on that no
# extra steps are needed to make $FILE's changes go "live").
When /^I upload "([^"]*)" to "([^"]*)"$/ do |source, destination|
  [source, destination].each { |s| s.sub!(%r{/*$}, '') }
  Dir.glob(source).each do |path|
    if File.directory?(path)
      new_destination = "#{destination}/#{File.basename(path)}"
      $vm.execute_successfully("mkdir -p '#{new_destination}'")
      Dir.new(path).each do |child|
        next if (child == '.') || (child == '..')

        step "I upload \"#{path}/#{child}\" to \"#{new_destination}\""
      end
    else
      File.open(path) do |f|
        final_destination = destination
        if $vm.directory_exist?(final_destination)
          final_destination += "/#{File.basename(path)}"
        end
        $vm.file_overwrite(final_destination, f.read)
      end
    end
  end
end

When /^I disable the (.*) (system|user) unit$/ do |unit, scope|
  options = scope == 'system' ? '' : '--global'
  $vm.execute_successfully("systemctl #{options} disable '#{unit}'")
end

def git_on_a_tag
  system('git describe --tags --exact-match HEAD >/dev/null 2>&1')
end

def git_current_tag
  `git describe --tags --exact-match HEAD`.chomp
end

Then /^the keyboard layout is set to "([^"]+)"$/ do |keyboard_layout|
  input_sources = $vm.execute_successfully(
    'gsettings get org.gnome.desktop.input-sources sources',
    user: LIVE_USER
  ).stdout
  input_countrycode = input_sources.scan(/\('([^']*)', '([^']*)'\)/).first.last
  assert_equal(keyboard_layout, input_countrycode)

  mru_sources = $vm.execute_successfully(
    'gsettings get org.gnome.desktop.input-sources mru-sources',
    user: LIVE_USER
  ).stdout.chomp
  if mru_sources != '@a(ss) []'
    mru_countrycode = mru_sources.scan(/\('([^']*)', '([^']*)'\)/).first.last
    assert_equal(keyboard_layout, mru_countrycode)
  end
end

When /^I enable the screen keyboard$/ do
  $vm.execute_successfully(
    'gsettings set org.gnome.desktop.a11y.applications ' \
    'screen-keyboard-enabled true',
    user: LIVE_USER
  )
end

Then(/^the layout of the screen keyboard is set to "([^"]+)"$/) do |layout|
  @screen.find("ScreenKeyboardLayout#{layout.upcase}.png")
end

Given /^I create a directory "(\S+)"$/ do |path|
  $vm.execute_successfully("mkdir '#{path}'")
end

Given /^I write a file "(\S+)" with contents "([^"]*)"$/ do |path, content|
  $vm.file_overwrite(path, content)
end

Given /^I create a symlink "(\S+)" to "(\S+)"$/ do |link, target|
  $vm.execute_successfully(
    "ln -s --no-target-directory '#{target}' '#{link}'"
  )
end

def gnome_disks_app
  disks_app = Dogtail::Application.new('gnome-disks')
  # Give GNOME Shell some time to draw the minimize/maximize/close
  # buttons in the title bar, to ensure the other title bar buttons we
  # will later click, such as GnomeDisksDriveMenuButton.png, have
  # stopped moving. Otherwise, we sometimes lose the race: the
  # coordinates returned by Screen#wait are obsolete by the time we
  # run Screen#click, which makes us click on the minimize
  # button instead.
  @screen.wait('GnomeWindowActionsButtons.png', 10)
  disks_app
end

def save_qrcode(str)
  # Generate a QR code similar enough to BridgeDB's:
  # https://gitlab.torproject.org/tpo/anti-censorship/bridgedb/-/blob/main/bridgedb/qrcodes.py
  qrencode_output_file = Tempfile.create('qrcode', $config['TMPDIR'])
  qrencode_output_file.close
  output_file = "#{qrencode_output_file.path}.jpg"
  cmd_helper(['qrencode', '-o', qrencode_output_file.path, '--size=5', '--margin=5', str])
  assert(File.exist?(qrencode_output_file.path))
  cmd_helper(['convert', qrencode_output_file.path, output_file])
  assert(File.exist?(output_file))
  output_file
end

Given /^I write (|an old version of )the Tails (ISO|USB) image to disk "([^"]+)"$/ do |old, type, name|
  if old != ''
    match = /^tails-amd64-(\d+[.]\d+(?:[.]\d+)?)[.]img$/
            .match(File.basename(OLD_TAILS_IMG))
    $old_version = match.nil? ? nil : match[1]
    if $old_version.nil?
      debug_log('Failed to extract old version. This is expected, and OK,' \
                'if you passed anything but a stable release to --old-iso')
    else
      debug_log("Old version: #{$old_version}")
    end
  end
  src_disk = {
    path: (if old == ''
             type == 'ISO' ? TAILS_ISO : TAILS_IMG
           else
             type == 'ISO' ? OLD_TAILS_ISO : OLD_TAILS_IMG
           end
          ),
    opts: {
      format:   'raw',
      readonly: true,
    },
  }
  dest_disk = {
    path: $vm.storage.disk_path(name),
    opts: {
      format: $vm.storage.disk_format(name),
    },
  }
  $vm.storage.guestfs_disk_helper(
    src_disk,
    dest_disk
  ) do |g, src_disk_handle, dest_disk_handle|
    g.copy_device_to_device(src_disk_handle, dest_disk_handle, {})
  end
end
