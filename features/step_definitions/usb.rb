require 'securerandom'
require 'json'

# Returns a mapping from the source of a binding to its destination
# for all bindings of all pre-configured tps features that the running
# Tails is aware of.
def get_tps_bindings(skip_links = false)
  # Python script that prints all persistence configuration lines (one per
  # line) in the form: <mount_point>\t<comma-separated-list-of-options>
  script = [
    'from tps.configuration import features',
    'for feature in features.get_classes():',
    '    for mount in feature.Mounts:',
    '        print(mount)',
  ]
  c = RemoteShell::PythonCommand.new($vm, script.join("\n"))
  assert(c.success?, 'Python script for get_tps_bindings failed')
  binding_configs = c.stdout.chomp.split("\n")
  assert binding_configs.size >= 10,
         "Got #{binding_configs.size} binding configuration " \
         'lines, which is too few'
  bindings_mapping = {}
  binding_configs.each do |line|
    destination, options_str = line.split("\t")
    options = options_str.split(',')
    is_link = options.include? 'link'
    next if is_link && skip_links

    source_str = options.find { |option| /^source=/.match(option) }
    # If no source is given as an option, live-boot's persistence
    # feature defaults to the destination minus the initial "/".
    source = if source_str.nil?
               destination.partition('/').last
             else
               source_str.split('=')[1]
             end
    bindings_mapping[source] = destination
  end
  bindings_mapping
end

def tps_bindings
  get_tps_bindings
end

def tps_bind_mounts
  get_tps_bindings(true)
end

def tps_features
  c = $vm.execute_successfully('/usr/local/lib/tpscli get-features')
  JSON.parse(c.stdout.chomp)
end

def tps_feature_is_enabled(feature, reload = true)
  tps_reload if reload
  c = $vm.execute("/usr/local/lib/tpscli is-enabled #{feature}")
  c.success?
end

def tps_feature_is_active(feature, reload = true)
  tps_reload if reload
  c = $vm.execute("/usr/local/lib/tpscli is-active #{feature}")
  c.success?
end

def tps_reload
  $vm.execute_successfully('systemctl reload tails-persistent-storage.service')
end

def persistent_volumes_mountpoints
  $vm.execute('ls -1 -d /live/persistence/*_unlocked/').stdout.chomp.split
end

def persistent_storage_frontend (**opts)
  Dogtail::Application.new('tps-frontend', **opts)
end

def persistent_storage_main_frame
  persistent_storage_frontend.child('Persistent Storage', roleName: 'frame')
end

def persistent_directory_is_active(**opts)
  opts[:user] = 'root'
  opts[:use_system_bus] = true
  dbus_send(
    'org.boum.tails.PersistentStorage',
    '/org/boum/tails/PersistentStorage/Features/PersistentDirectory',
    'org.freedesktop.DBus.Properties.Get',
    'org.boum.tails.PersistentStorage.Feature',
    'IsActive',
    **opts
  )
end

def recover_from_upgrader_failure
  $vm.execute('pkill --full tails-upgrade-frontend-wrapper')
  $vm.execute('killall tails-upgrade-frontend zenity')
  # Do not sleep when retrying
  $vm.spawn('tails-upgrade-frontend-wrapper --no-wait', user: LIVE_USER)
end

def greeter
  Dogtail::Application.new('Welcome to Tails!',
                           user:               'Debian-gdm',
                           translation_domain: 'tails')
end

Given /^I clone USB drive "([^"]+)" to a (new|temporary) USB drive "([^"]+)"$/ do |from, mode, to|
  $vm.storage.clone_to_new_disk(from, to)
  if mode == 'temporary'
    add_after_scenario_hook { $vm.storage.delete_volume(to) }
  end
end

Given /^I unplug USB drive "([^"]+)"$/ do |name|
  $vm.unplug_drive(name)
end

Given /^the computer is set to boot in UEFI mode$/ do
  $vm.set_os_loader('UEFI')
  @os_loader = 'UEFI'
end

def tails_installer_selected_device
  @installer.child('Target USB stick:', roleName: 'label').parent
            .child('', roleName: 'combo box', recursive: false).name
end

def tails_installer_is_device_selected?(name)
  device = $vm.disk_dev(name)
  tails_installer_selected_device[/\(#{device}\d*\)$/]
end

def tails_installer_match_status(pattern)
  @installer.child('', roleName: 'text').text[pattern]
end

When /^I start Tails Installer$/ do
  @installer_log_path = '/tmp/tails-installer.log'
  command = "/usr/local/bin/tails-installer --verbose  2>&1 | tee #{@installer_log_path} | logger -t tails-installer"
  step "I run \"#{command}\" in GNOME Terminal"
  @installer = Dogtail::Application.new('tails-installer')
  @installer.child('Tails Installer', roleName: 'frame')
  # Sometimes Dogtail will find the Installer and click its window
  # before it is shown (searchShowingOnly is not perfect) which
  # generally means clicking somewhere on the Terminal => the click is
  # lost *and* the installer does not go to the foreground. So let's
  # wait a bit extra.
  sleep 3
  @screen.wait('TailsInstallerWindow.png', 10).click
end

When /^I am told by Tails Installer that.*"([^"]+)".*$/ do |status|
  try_for(10) do
    tails_installer_match_status(status)
  end
end

Then /^a suitable USB device is (?:still )?not found$/ do
  @installer.child(
    'No device suitable to install Tails could be found', roleName: 'label'
  )
end

Then /^(no|the "([^"]+)") USB drive is selected$/ do |mode, name|
  try_for(30) do
    if mode == 'no'
      tails_installer_selected_device == ''
    else
      tails_installer_is_device_selected?(name)
    end
  end
end

def persistence_exists?(name)
  data_part_dev = $vm.persistent_storage_dev_on_disk(name)
  $vm.execute("test -b #{data_part_dev}").success?
end

When /^I (install|reinstall|upgrade) Tails (?:to|on) USB drive "([^"]+)" by cloning$/ do |action, name|
  step 'I start Tails Installer'
  # If the device was plugged *just* before this step, it might not be
  # completely ready (so it's shown) at this stage.
  try_for(10) { tails_installer_is_device_selected?(name) }
  begin
    label = if action == 'reinstall'
              'Reinstall (delete all data)'
            else
              action.capitalize
            end
    # Despite being a normal "push button" this button doesn't respond
    # to the "press" action. It has a "click" action, which works, but
    # after that the installer is inaccessible for Dogtail.
    @installer.button(label).grabFocus
    @screen.press('Enter')
    unless action == 'upgrade'
      confirmation_label = if persistence_exists?(name)
                             'Delete Persistent Storage and Reinstall'
                           else
                             'Delete All Data and Install'
                           end
      @installer.child('Question',
                       roleName: 'alert').button(confirmation_label).click
    end
    try_for(15 * 60, delay: 10) do
      @installer
        .child('Information', roleName: 'alert')
        .child('Installation complete!', roleName: 'label')
      true
    end
  rescue StandardError => e
    debug_log("Tails Installer debug log:\n" +
              $vm.file_content(@installer_log_path))
    raise e
  end
end

Given(/^I plug and mount a USB drive containing a Tails USB image$/) do
  usb_image_dir = share_host_files(TAILS_IMG)
  @usb_image_path = "#{usb_image_dir}/#{File.basename(TAILS_IMG)}"
end

def enable_all_tps_features
  assert persistent_storage_main_frame.child('Personal Documents', roleName: 'label')
  switches = persistent_storage_main_frame.children(roleName: 'toggle button')
  switches.each do |switch|
    if switch.checked
      debug_log("#{switch.name} is already enabled, skipping")
    else
      debug_log("enabling #{switch.name}")
      # To avoid having to bother with scrolling the window we just
      # send an AT-SPI action instead of clicking.
      switch.toggle
      try_for(10) { switch.checked }
    end
  end
end

When /^I (enable|disable) the first tps feature$/ do |mode|
  step 'I start "Persistent Storage" via GNOME Activities Overview'
  assert persistent_storage_main_frame.child('Personal Documents', roleName: 'label')
  persistent_folder_switch = persistent_storage_main_frame.child(
    'Activate Persistent Folder',
    roleName: 'toggle button'
  )
  if mode == 'enable'
    assert !persistent_folder_switch.checked
  else
    assert persistent_folder_switch.checked
  end

  persistent_folder_switch.toggle
  try_for(10) do
    # GtkSwitch does not expose its underlying state via AT-SPI (the
    # accessible has the "check" state when the switch is on but the
    # underlying state is false) so we check the state via D-Bus.
    if mode == 'enable'
      assert persistent_folder_switch.checked
      persistent_directory_is_active
    else
      assert !persistent_folder_switch.checked
      !persistent_directory_is_active
    end
  end
  @screen.press('alt', 'F4')
end

Given(/^I enable persistence creation in Tails Greeter$/) do
  @screen.wait('TailsGreeterPersistenceCreate.png', 10).click
end

Given /^I create a persistent partition( with the default settings)?( for Additional Software)?( using the wizard that was already open)?$/ do |default_settings, asp, dontrun|
  # When creating a persistent partition for Additional Software, we
  # want to use the default settings.
  default_settings = true if asp

  mode = asp ? ' for Additional Software' : ''
  step "I try to create a persistent partition#{mode}#{dontrun}"

  # Check that the Persistent Storage was created by checking that the
  # tps frontend shows the features view with the "Personal Documents"
  # label.
  try_for(300) do
    persistent_storage_main_frame.child('Personal Documents', roleName: 'label')
  end

  enable_all_tps_features unless default_settings
end

Given /^I try to create a persistent partition( for Additional Software)?( using the wizard that was already open)?$/ do |asp, dontrun|
  unless asp || dontrun
    step 'I start "Persistent Storage" via GNOME Activities Overview'
  end
  persistent_storage_main_frame.button('Co_ntinue').click
  persistent_storage_main_frame
    .child('Passphrase:', roleName: 'label')
    .labelee
    .text = @persistence_password
  persistent_storage_main_frame
    .child('Confirm:', roleName: 'label')
    .labelee
    .text = @persistence_password
  persistent_storage_main_frame.button('_Create Persistent Storage').click
end

def available_memory_kib
  meminfo = $vm.file_content('/proc/meminfo')
  meminfo =~ /^MemAvailable:\s+(\d+) kB$/
  Regexp.last_match(1).to_i
end

Given /^the system is( very)? low on memory$/ do |very_low|
  # If we're asked to make the system very low on memory, then
  # we leave only 200 MiB of memory available, otherwise we leave 500
  # MiB (500 MiB is enough to create a Persistent Storage with the
  # lowest PBKDF memory cost).
  low_mem_kib = very_low ? 200 * 1024 : 500 * 1024

  # Ensure that the zram swap is disabled, to avoid that the memory
  # pressure is relieved by swapping.
  $vm.execute_successfully('zramswap stop')

  # Get the amount of available memory
  mem_available_kib = available_memory_kib

  # Calculate how much memory we need to fill up
  mem_to_fill_kib = mem_available_kib - low_mem_kib
  if mem_to_fill_kib <= 0
    debug_log("Available memory is already low enough: #{mem_available_kib} KiB")
    return
  end

  # Write a file that will fill up the memory
  $vm.execute_successfully(
    "dd if=/dev/zero of=/fill bs=1M count=#{mem_to_fill_kib / 1024}",
  )

  # Wait for the memory to be filled up
  try_for(20, msg: 'The system did not become low on memory') do
    mem_available_kib = available_memory_kib
    debug_log("Available memory after filling up: #{mem_available_kib} KiB")
    # The memory is considered low if it's within 100 MiB of the low
    # memory threshold.
    low_mem_kib - 100 * 1024 <= mem_available_kib &&
      mem_available_kib <= low_mem_kib + 100 * 1024
  end
end

Given /^I free up some memory$/ do
  # This assumes that the step 'the system is very low on memory' was
  # run before.
  $vm.execute_successfully('rm /fill')
  step 'the system is low on memory'
end

Given /^I close the Persistent Storage app$/ do
  # Close any alerts
  alert = persistent_storage_frontend.child(roleName: 'alert', retry: false)
  while alert
    alert.button('Close').click
    begin
      alert = persistent_storage_frontend.child(roleName: 'alert', retry: false)
    rescue StandardError
      alert = nil
    end
  end

  # Close the main window
  persistent_storage_main_frame.button('Close').click

  # Wait for the app to close
  try_for(10) {
    begin
      persistent_storage_frontend(retry: false)
      false
    rescue StandardError
      true
    end
  }
end

Then /^The Persistent Storage app shows the error message "([^"]*)"$/ do |message|
  persistent_storage_frontend.child(message,
                                    roleName: 'label',
                                    showingOnly: true)
end

Given /^I change the passphrase of the Persistent Storage( back to the original)?$/ do |change_back|
  if change_back
    current_passphrase = @changed_persistence_password
    new_passphrase = @persistence_password
  else
    current_passphrase = @persistence_password
    new_passphrase = @changed_persistence_password
  end

  step 'I start "Persistent Storage" via GNOME Activities Overview'

  # We can't use the click action here because this button causes a
  # modal dialog to be run via gtk_dialog_run() which causes the
  # application to hang when triggered via a ATSPI action. See
  # https://gitlab.gnome.org/GNOME/gtk/-/issues/1281
  persistent_storage_main_frame
    .button('Change Passphrase', showingOnly: true)
    .grabFocus
  @screen.press('Return')
  change_passphrase_dialog = persistent_storage_frontend
                             .child('Change Passphrase', roleName: 'dialog', showingOnly: true)
  change_passphrase_dialog
    .child('Current Passphrase', roleName: 'label', showingOnly: true)
    .labelee
    .grabFocus
  @screen.type(current_passphrase)
  change_passphrase_dialog
    .child('New Passphrase', roleName: 'label', showingOnly: true)
    .labelee
    .grabFocus
  @screen.type(new_passphrase)
  change_passphrase_dialog
    .child('Confirm New Passphrase', roleName: 'label', showingOnly: true)
    .labelee
    .grabFocus
  @screen.type(new_passphrase)
  change_passphrase_dialog.button('Change').click
  # Wait for the dialog to close
  try_for(60) do
    persistent_storage_frontend
      .child('Change Passphrase', roleName: 'dialog')
  rescue Dogtail::Failure
    # The dialog couldn't be found, which is what we want
    true
  else
    false
  end
end

def check_disk_integrity(name, dev, scheme)
  info = $vm.execute("udisksctl info --block-device '#{dev}'").stdout
  info_split = info.split("\n  org\.freedesktop\.UDisks2\.PartitionTable:\n")
  part_table_info = info_split[1]
  assert_match(/^    Type: +#{scheme}/, part_table_info,
               "Unexpected partition scheme on USB drive '#{name}', '#{dev}'")
end

def check_part_integrity(name, dev, usage, fs_type,
                         part_label: nil, part_type: nil)
  info = $vm.execute("udisksctl info --block-device '#{dev}'").stdout
  info_split = info.split("\n  org\.freedesktop\.UDisks2\.Partition:\n")
  dev_info = info_split[0]
  part_info = info_split[1]
  assert_match(/^    IdUsage: +#{usage}$/, dev_info,
               "Unexpected device field 'usage' on drive '#{name}', '#{dev}'")
  assert_match(/^    IdType: +#{fs_type}$/, dev_info,
               "Unexpected device field 'IdType' on drive '#{name}', '#{dev}'")
  if part_label
    assert_match(/^    Name: +#{part_label}$/, part_info,
                 "Unexpected partition label on drive '#{name}', '#{dev}'")
  end
  if part_type
    assert_match(/^    Type: +#{part_type}$/, part_info,
                 "Unexpected partition type on drive '#{name}', '#{dev}'")
  end
end

def tails_is_installed_helper(name, tails_root, loader)
  disk_dev = $vm.disk_dev(name)
  part_dev = disk_dev + '1'
  check_disk_integrity(name, disk_dev, 'gpt')
  check_part_integrity(name, part_dev, 'filesystem', 'vfat',
                       part_label: 'Tails', part_type: ESP_GUID)

  target_root = '/mnt/new'
  $vm.execute("mkdir -p #{target_root}")
  $vm.execute("mount #{part_dev} #{target_root}")

  c = $vm.execute("diff -qr '#{tails_root}/live' '#{target_root}/live'")
  assert(
    c.success?,
    "USB drive '#{name}' has differences in /live:\n#{c.stdout}\n#{c.stderr}"
  )

  syslinux_files = $vm.execute("ls -1 #{target_root}/syslinux")
                      .stdout.chomp.split
  # We deal with these files separately
  ignores = ['syslinux.cfg', 'exithelp.cfg', 'ldlinux.c32', 'ldlinux.sys']
  (syslinux_files - ignores).each do |f|
    assert_vmcommand_success(
      $vm.execute("diff -q '#{tails_root}/#{loader}/#{f}' " \
                  "'#{target_root}/syslinux/#{f}'"),
      "USB drive '#{name}' has differences in '/syslinux/#{f}'"
    )
  end

  # The main .cfg is named differently vs isolinux
  assert_vmcommand_success(
    $vm.execute("diff -q '#{tails_root}/#{loader}/#{loader}.cfg' " \
                "'#{target_root}/syslinux/syslinux.cfg'"),
    "USB drive '#{name}' has differences in '/syslinux/syslinux.cfg'"
  )

  $vm.execute("umount #{target_root}")
  $vm.execute('sync')
end

Then /^the running Tails is installed on USB drive "([^"]+)"$/ do |target_name|
  loader = boot_device_type == 'usb' ? 'syslinux' : 'isolinux'
  tails_is_installed_helper(target_name, '/lib/live/mount/medium', loader)
end

Then /^there is no persistence partition on USB drive "([^"]+)"$/ do |name|
  data_part_dev = $vm.persistent_storage_dev_on_disk(name)
  assert($vm.execute("test -b #{data_part_dev}").failure?,
         "USB drive #{name} has a partition '#{data_part_dev}'")
end

def assert_luks2_with_argon2id(name, device)
  # Tails 5.12 and older used LUKS1 by default
  return if name == 'old' && !$old_version.nil? \
            && system("dpkg --compare-versions '#{$old_version}' le 5.12")

  luks_info = $vm.execute("cryptsetup luksDump #{device}").stdout
  assert_match(/^^Version:\s*2$/, luks_info,
               "Device #{device} is not LUKS2")
  assert_match(/^\s*PBKDF:\s*argon2id$/, luks_info,
               "Device #{device} does not use argon2id")
end


Then /^a Tails persistence partition exists on USB drive "([^"]+)"$/ do |name|
  dev = $vm.persistent_storage_dev_on_disk(name)
  check_part_integrity(name, dev, 'crypto', 'crypto_LUKS',
                       part_label: 'TailsData')

  luks_dev = nil
  # The LUKS container may already be opened, e.g. by udisks after
  # we've created the Persistent Storage.
  c = $vm.execute("ls -1 --hide 'control' /dev/mapper/")
  if c.success?
    c.stdout.split("\n").each do |candidate|
      luks_info = $vm.execute("cryptsetup status '#{candidate}'")
      if luks_info.success? && luks_info.stdout.match("^\s+device:\s+#{dev}$")
        luks_dev = "/dev/mapper/#{candidate}"
        break
      end
    end
  end
  if luks_dev.nil?
    assert_vmcommand_success(
      $vm.execute("echo #{@persistence_password} | " \
                  "cryptsetup luksOpen #{dev} #{name}"),
      "Couldn't open LUKS device '#{dev}' on  drive '#{name}'"
    )
    luks_dev = "/dev/mapper/#{name}"
  end

  assert_luks2_with_argon2id(name, dev)

  # Adapting check_part_integrity() seems like a bad idea so here goes
  info = $vm.execute("udisksctl info --block-device '#{luks_dev}'").stdout
  assert_match(%r{^    CryptoBackingDevice: +'/[a-zA-Z0-9_/]+'$}, info)
  assert_match(/^    IdUsage: +filesystem$/, info)
  assert_match(/^    IdType: +ext[34]$/, info)
  assert_match(/^    IdLabel: +TailsData$/, info)

  mount_dir = "/mnt/#{name}"
  $vm.execute("mkdir -p #{mount_dir}")
  assert_vmcommand_success($vm.execute("mount '#{luks_dev}' #{mount_dir}"),
                           "Couldn't mount opened LUKS device '#{dev}' " \
                           "on drive '#{name}'")

  $vm.execute("umount #{mount_dir}")
  $vm.execute('sync')
  $vm.execute("cryptsetup luksClose #{name}")
end

Given /^I enable persistence( with the changed passphrase)?$/ do |with_changed_passphrase|
  # @type [Dogtail::Node]
  passphrase_entry = nil
  try_for(60) do
    passphrase_entry = greeter
                       .child(roleName: 'password text', showingOnly: true)
    passphrase_entry.grabFocus
    passphrase_entry.focused
  end
  assert !passphrase_entry.nil?

  password = if with_changed_passphrase
               @changed_persistence_password
             else
               @persistence_password
             end
  passphrase_entry.text = password
  @screen.press('Return')

  # Wait until the Persistent Storage was unlocked. We use the fact that
  # the unlock button is made invisible when the Persistent Storage is
  # unlocked.
  try_for(30) do
    !greeter.child?('Unlock', roleName: 'push button', showingOnly: true)
  end

  # Figure out which language is set now that the Persistent Storage is
  # unlocked
  $language, $lang_code = get_greeter_language
end

def get_greeter_language
  english_label = 'English - United States'
  german_label = 'Deutsch - Deutschland (German - Germany)'
  try_for(30) do
    greeter.child(english_label, roleName: 'label', showingOnly: true)
    # We have to set the language to '' for English, setting it to
    # 'English' doesn't work.
    return '', 'en'
  rescue Dogtail::Failure
    greeter.child(german_label, roleName: 'label', showingOnly: true)
    return 'German', 'de'
  end
end

def tails_persistence_enabled?
  libtps_file = '/usr/local/lib/tails-shell-library/libtps.sh'
  $vm.execute(". '#{libtps_file}' && " \
              'tps_is_unlocked').success?
end

Then /^all tps features(| from the old Tails version)(| but the first one) are active$/ do |old_tails_str, except_first_str|
  old_tails = !old_tails_str.empty?
  except_first = !except_first_str.empty?
  assert(!old_tails || !except_first, 'Unsupported case.')
  try_for(120, msg: 'Persistence is disabled') do
    tails_persistence_enabled?
  end

  tps_reload
  features = old_tails ? $remembered_tps_features : tps_features
  features.each do |feature|
    is_active = tps_feature_is_active(feature, reload: false)
    if except_first && feature == 'PersistentDirectory'
      assert !is_active, "Feature '#{feature}' is active"
    else
      assert is_active, "Feature '#{feature}' is not active"
    end
  end
end

Then /^all tps features(| but the first one) are enabled$/ do |except_first_str|
  except_first = !except_first_str.empty?
  tps_reload
  tps_features.each do |feature|
    is_enabled = tps_feature_is_enabled(feature, reload: false)
    if except_first && feature == 'PersistentDirectory'
      assert !is_enabled, "Feature '#{feature}' is enabled"
    else
      assert is_enabled,  "Feature '#{feature}' is not enabled"
    end
  end
end

Then /^all tps features(| but the first one) are enabled and active$/ do |except_first_str|
  except_first = !except_first_str.empty?
  if except_first
    step 'all tps features but the first one are enabled'
    step 'all tps features but the first one are active'
  else
    step 'all tps features are enabled'
    step 'all tps features are active'
  end
end

Then /^the "(\S+)" tps feature is(| not) enabled$/ do |feature, not_str|
  check_not_enabled = !not_str.empty?
  is_enabled = tps_feature_is_enabled(feature)
  if check_not_enabled
    assert !is_enabled, "Feature '#{feature}' is enabled"
  else
    assert is_enabled, "Feature '#{feature}' is not enabled"
  end
end

Then /^the "(\S+)" tps feature is(| not) active$/ do |feature, not_str|
  check_not_active = !not_str.empty?
  is_active = tps_feature_is_active(feature)
  if check_not_active
    assert !is_active, "Feature '#{feature}' is active"
  else
    assert is_active, "Feature '#{feature}' is not active"
  end
end

Then /^the "(\S+)" tps feature is(| not) enabled and(| not) active$/ do |feature, not_enabled_str, not_active_str|
  step "the \"#{feature}\" tps feature is#{not_enabled_str} enabled"
  step "the \"#{feature}\" tps feature is#{not_active_str} active"
end

Then /^persistence is disabled$/ do
  assert(!tails_persistence_enabled?, 'Persistence is enabled')
end

def boot_device
  # Approach borrowed from
  # config/chroot_local_includes/lib/live/config/998-permissions
  boot_dev_id = $vm.execute(
    'udevadm info --device-id-of-file=/lib/live/mount/medium'
  ).stdout.chomp
  $vm.execute("readlink -f /dev/block/'#{boot_dev_id}'").stdout.chomp
end

def device_info(dev)
  # Approach borrowed from
  # config/chroot_local_includes/lib/live/config/998-permissions
  info = $vm.execute("udevadm info --query=property --name='#{dev}'")
            .stdout.chomp
  info.split("\n").map { |e| e.split('=') }.to_h
end

def boot_device_type
  device_info(boot_device)['ID_BUS']
end

# Turn udisksctl info output into something more manipulable:
def parse_udisksctl_info(input)
  tree = {}
  section = nil
  key = nil
  input.chomp.split("\n").each do |line|
    case line
    when %r{^/org/freedesktop/UDisks2/block_devices/}
      true
    when /^  (org\.freedesktop\.UDisks2\..+):$/
      section = Regexp.last_match(1)
      tree[section] = {}
    when /^\s+(.+?):\s+(.+)$/
      key = Regexp.last_match(1)
      value = Regexp.last_match(2)
      tree[section][key] = value
    else
      # XXX: Best effort = consider this a continuation from previous
      # line (e.g. Symlinks), and add the whole line, without
      # stripping anything (e.g. leading whitespaces)
      tree[section][key] += line
    end
  end
  tree
end

Then /^Tails is running from (.*) drive "([^"]+)"$/ do |bus, name|
  bus = bus.downcase
  expected_bus = bus == 'sata' ? 'ata' : bus
  assert_equal(expected_bus, boot_device_type)
  actual_dev = boot_device
  # The boot partition differs between an using Tails installer and
  # isohybrids. There's also a strange case isohybrids are thought to
  # be booting from the "raw" device, and not a partition of it
  # (#10504).
  expected_devs = ['', '1', '4'].map { |e| $vm.disk_dev(name) + e }
  assert(expected_devs.include?(actual_dev),
         "We are running from device #{actual_dev}, but for #{bus} drive " \
         "'#{name}' we expected to run from one of #{expected_devs}")
end

Then /^the boot device has safe access rights$/ do
  super_boot_dev = boot_device.sub(/[[:digit:]]+$/, '')
  devs = $vm.file_glob("#{super_boot_dev}*")
  assert(!devs.empty?, 'Could not determine boot device')
  all_users = $vm.file_content('/etc/passwd')
                 .split("\n")
                 .map { |line| line.split(':')[0] }
  all_users_with_groups = all_users.map do |user|
    groups = $vm.execute("groups #{user}").stdout.chomp.sub(/^#{user} : /,
                                                            '').split(' ')
    [user, groups]
  end
  devs.each do |dev|
    dev_owner = $vm.execute("stat -c %U #{dev}").stdout.chomp
    dev_group = $vm.execute("stat -c %G #{dev}").stdout.chomp
    dev_perms = $vm.execute("stat -c %a #{dev}").stdout.chomp
    assert_equal('root', dev_owner)
    assert(['disk', 'root'].include?(dev_group),
           "Boot device '#{dev}' owned by group '#{dev_group}', expected " \
           "'disk' or 'root'.")
    assert_equal('660', dev_perms)
    all_users_with_groups.each do |user, groups|
      next if user == 'root'

      assert(!groups.include?(dev_group),
             "Unprivileged user '#{user}' is in group '#{dev_group}' which " \
             "owns boot device '#{dev}'")
    end
  end

  info = $vm.execute("udisksctl info --block-device '#{super_boot_dev}'").stdout
  assert_match(/^    HintSystem: +true$/, info,
               "Boot device '#{super_boot_dev}' is not system internal " \
               'for udisks')
end

Then /^all persistent filesystems have safe access rights$/ do
  persistent_volumes_mountpoints.each do |mountpoint|
    fs_owner = $vm.execute("stat -c %U #{mountpoint}").stdout.chomp
    fs_group = $vm.execute("stat -c %G #{mountpoint}").stdout.chomp
    fs_perms = $vm.execute("stat -c %a #{mountpoint}").stdout.chomp
    assert_equal('root', fs_owner)
    assert_equal('root', fs_group)
    # This ensures the amnesia user cannot write to the root of the
    # persistent storage, which in turns ensures this user cannot
    # create a .Trash-1000 folder in there, which is our current best
    # workaround for the lack of proper trash support in Persistent
    # Storage: then the user is not offered to send files to the
    # trash, and they can only delete files permanently (#18118).
    assert_equal('770', fs_perms)
  end
end

Then /^all persistence configuration files have safe access rights$/ do
  persistent_volumes_mountpoints.each do |mountpoint|
    assert_vmcommand_success(
      $vm.execute("test -e #{mountpoint}/persistence.conf"),
      "#{mountpoint}/persistence.conf does not exist, while it should"
    )
    assert_vmcommand_success(
      $vm.execute("test ! -e #{mountpoint}/live-persistence.conf"),
      "#{mountpoint}/live-persistence.conf does exist, while it should not"
    )
    $vm.file_glob(
      "#{mountpoint}/persistence.conf* #{mountpoint}/live-*.conf"
    ).each do |f|
      file_owner = $vm.execute("stat -c %U '#{f}'").stdout.chomp
      file_group = $vm.execute("stat -c %G '#{f}'").stdout.chomp
      file_perms = $vm.execute("stat -c %a '#{f}'").stdout.chomp
      assert_equal('tails-persistent-storage', file_owner)
      assert_equal('tails-persistent-storage', file_group)
      case f
      when %r{.*/live-additional-software.conf$}
        assert_equal('644', file_perms)
      else
        assert_equal('600', file_perms)
      end
    end
  end
end

Then /^all persistent directories(| from the old Tails version) have safe access rights$/ do |old_tails|
  if old_tails.empty?
    expected_bindings = tps_bindings
  else
    assert_not_nil($remembered_tps_bindings)
    expected_bindings = $remembered_tps_bindings
  end
  persistent_volumes_mountpoints.each do |mountpoint|
    expected_bindings.each do |src, dest|
      full_src = "#{mountpoint}/#{src}"
      assert_vmcommand_success $vm.execute("test -d #{full_src}")
      dir_perms = $vm.execute_successfully("stat -c %a '#{full_src}'")
                     .stdout.chomp
      dir_owner = $vm.execute_successfully("stat -c %U '#{full_src}'")
                     .stdout.chomp
      if dest.start_with?("/home/#{LIVE_USER}")
        expected_perms = '700'
        expected_owner = LIVE_USER
      elsif File.basename(src) == 'greeter-settings'
        expected_perms = '700'
        expected_owner = 'Debian-gdm'
      elsif File.basename(src) == 'tca'
        expected_perms = '700'
        expected_owner = 'root'
      else
        expected_perms = '755'
        expected_owner = 'root'
      end
      assert_equal(expected_perms, dir_perms,
                   "Persistent source #{full_src} has permission " \
                   "#{dir_perms}, expected #{expected_perms}")
      assert_equal(expected_owner, dir_owner,
                   "Persistent source #{full_src} has owner " \
                   "#{dir_owner}, expected #{expected_owner}")
    end
  end
end

When /^I write some files expected to persist$/ do
  tps_bind_mounts.each do |_, dir|
    owner = $vm.execute("stat -c %U #{dir}").stdout.chomp
    assert_vmcommand_success(
      $vm.execute("touch #{dir}/XXX_persist", user: owner),
      "Could not create file in persistent directory #{dir}"
    )
  end
end

When /^I write some dotfile expected to persist$/ do
  assert_vmcommand_success(
    $vm.execute(
      'touch /live/persistence/TailsData_unlocked/dotfiles/.XXX_persist',
      user: LIVE_USER
    ),
    'Could not create a file in the dotfiles persistence.'
  )
end

When /^I remove some files expected to persist$/ do
  tps_bind_mounts.each do |_, dir|
    owner = $vm.execute("stat -c %U #{dir}").stdout.chomp
    assert_vmcommand_success(
      $vm.execute("rm #{dir}/XXX_persist", user: owner),
      "Could not remove file in persistent directory #{dir}"
    )
  end
end

When /^I write some files not expected to persist$/ do
  tps_bind_mounts.each do |_, dir|
    owner = $vm.execute("stat -c %U #{dir}").stdout.chomp
    assert_vmcommand_success(
      $vm.execute("touch #{dir}/XXX_gone", user: owner),
      "Could not create file in persistent directory #{dir}"
    )
  end
end

When /^I take note of which tps features are available$/ do
  $remembered_tps_features = tps_features
  $remembered_tps_bind_mounts = tps_bind_mounts
  $remembered_tps_bindings = tps_bindings
end

Then /^the expected persistent files(| created with the old Tails version) are present in the filesystem$/ do |old_tails|
  if old_tails.empty?
    expected_mounts = tps_bind_mounts
  else
    assert_not_nil($remembered_tps_bind_mounts)
    expected_mounts = $remembered_tps_bind_mounts
  end
  expected_mounts.each do |_, dir|
    assert_vmcommand_success(
      $vm.execute("test -e #{dir}/XXX_persist"),
      "Could not find expected file in persistent directory #{dir}"
    )
    assert(
      $vm.execute("test -e #{dir}/XXX_gone").failure?,
      "Found file that should not have persisted in persistent directory #{dir}"
    )
  end
end

Then /^the expected persistent dotfile is present in the filesystem$/ do
  expected_bindings = tps_bindings
  assert_vmcommand_success(
    $vm.execute("test -L #{expected_bindings['dotfiles']}/.XXX_persist"),
    'Could not find expected persistent dotfile link.'
  )
  assert_vmcommand_success(
    $vm.execute(
      "test -e $(readlink -f #{expected_bindings['dotfiles']}/.XXX_persist)"
    ),
    'Could not find expected persistent dotfile link target.'
  )
end

Then /^only the expected files are present on the persistence partition on USB drive "([^"]+)"$/ do |name|
  assert(!$vm.running?)
  disk = {
    path: $vm.storage.disk_path(name),
    opts: {
      format:   $vm.storage.disk_format(name),
      readonly: true,
    },
  }
  $vm.storage.guestfs_disk_helper(disk) do |g, disk_handle|
    partitions = g.part_list(disk_handle).map do |part_desc|
      disk_handle + part_desc['part_num'].to_s
    end
    partition = partitions.find do |part|
      g.blkid(part)['PART_ENTRY_NAME'] == 'TailsData'
    end
    assert_not_nil(partition, "Could not find the 'TailsData' partition " \
                              "on disk '#{disk_handle}'")
    luks_mapping = File.basename(partition) + '_unlocked'
    g.cryptsetup_open(partition, @persistence_password, luks_mapping)
    luks_dev = "/dev/mapper/#{luks_mapping}"
    mount_point = '/'
    g.mount(luks_dev, mount_point)
    assert_not_nil($remembered_tps_bind_mounts)
    $remembered_tps_bind_mounts.each do |dir, _|
      # Guestfs::exists may have a bug; if the file exists, 1 is
      # returned, but if it doesn't exist false is returned. It seems
      # the translation of C types into Ruby types is glitchy.
      assert(g.exists("/#{dir}/XXX_persist") == 1,
             "Could not find expected file in persistent directory #{dir}")
      assert(
        g.exists("/#{dir}/XXX_gone") != 1,
        'Found file that should not have persisted in persistent directory ' +
        dir
      )
    end
    g.umount(mount_point)
    g.cryptsetup_close(luks_dev)
  end
end

When /^I delete the persistent partition$/ do
  step 'I start "Persistent Storage" via GNOME Activities Overview'

  delete_btn = persistent_storage_main_frame.button('Delete Persistent Storage')
  assert delete_btn

  # If we just do delete_btn.click, then dogtail won't find tps-frontend anymore.
  # That's probably a bug somewhere, and this is a simple workaround
  delete_btn.grabFocus
  @screen.press('Return')

  persistent_storage_frontend
    .child('Warning', roleName: 'alert')
    .button('Delete Persistent Storage').click
  assert persistent_storage_main_frame.child(
    'The Persistent Storage was successfully deleted.',
    roleName: 'label'
  )
end

Then /^Tails has started in UEFI mode$/ do
  assert_vmcommand_success($vm.execute('test -d /sys/firmware/efi'),
                           '/sys/firmware/efi does not exist')
end

Given /^I create a ([[:alpha:]]+) label on disk "([^"]+)"$/ do |type, name|
  $vm.storage.disk_mklabel(name, type)
end

# The (crude) bin/create-test-iuks script can be used to generate the IUKs,
# meant to apply these exact changes, that are used by the test suite.
# It's nice to keep that script updated when updating the list of expected
# changes here and uploading new test IUKs.
def iuk_changes(version) # rubocop:disable Metrics/MethodLength
  changes = [
    {
      filesystem:  :rootfs,
      path:        'some_new_file',
      status:      :added,
      new_content: <<~CONTENT,
        Some content
      CONTENT
    },
    {
      filesystem:  :rootfs,
      path:        'etc/amnesia/version',
      status:      :modified,
      new_content: <<~CONTENT,
        #{version} - 20380119
        ffffffffffffffffffffffffffffffffffffffff
        live-build: 3.0.5+really+is+2.0.12-0.tails2
        live-boot: 4.0.2-1
        live-config: 4.0.4-1
      CONTENT
    },
    {
      filesystem:  :rootfs,
      path:        'etc/os-release',
      status:      :modified,
      new_content: <<~CONTENT,
        TAILS_PRODUCT_NAME="Tails"
        TAILS_VERSION_ID="#{version}"
      CONTENT
    },
    {
      filesystem: :rootfs,
      path:       'usr/share/common-licenses/BSD',
      status:     :removed,
    },
    {
      filesystem: :rootfs,
      path:       'usr/share/doc/tor',
      status:     :removed,
    },
    {
      filesystem: :medium,
      path:       'utils/linux/syslinux',
      status:     :removed,
    },
  ]

  case version
  when '2.2~testoverlayfsng'
    changes
  when '2.3~testoverlayfsng'
    changes + [
      {
        filesystem:  :rootfs,
        path:        'some_new_file_2.3',
        status:      :added,
        new_content: <<~CONTENT,
          Some content 2.3
        CONTENT
      },
      {
        filesystem: :rootfs,
        path:       'usr/share/common-licenses/MPL-1.1',
        status:     :removed,
      },
      {
        filesystem: :medium,
        path:       'utils/mbr/mbr.bin',
        status:     :removed,
      },
    ]
  else
    raise "Test suite implementation error: unsupported version #{version}"
  end
end

Given /^the file system changes introduced in version (.+) are (not )?present(?: in the (\S+) Browser's chroot)?$/ do |version, not_present, chroot_browser|
  assert(['2.2~testoverlayfsng', '2.3~testoverlayfsng'].include?(version))
  upgrade_applied = not_present.nil?
  chroot_browser = "#{chroot_browser.downcase}-browser" if chroot_browser
  changes = iuk_changes(version)
  changes.each do |change|
    case change[:filesystem]
    when :rootfs
      path = '/'
      path += "var/lib/#{chroot_browser}/chroot/" if chroot_browser
      path += change[:path]
    when :medium
      path = '/lib/live/mount/medium/' + change[:path]
    else
      raise "Unknown filesystem '#{change[:filesystem]}'"
    end
    case change[:status]
    when :removed
      assert_equal(!upgrade_applied, $vm.file_exist?(path))
    when :added
      assert_equal(upgrade_applied, $vm.file_exist?(path))
      if upgrade_applied && change[:new_content]
        assert_equal(change[:new_content], $vm.file_content(path))
      end
    when :modified
      assert($vm.file_exist?(path))
      if upgrade_applied
        assert_not_nil(change[:new_content])
        assert_equal(change[:new_content], $vm.file_content(path))
      end
    else
      raise "Unknown status '#{change[:status]}'"
    end
  end
end

Then /^I am proposed to install an incremental upgrade to version (.+)$/ do |version|
  recovery_proc = proc do
    recover_from_upgrader_failure
  end
  failure_pic = 'TailsUpgraderFailure.png'
  success_pic = "TailsUpgraderUpgradeTo#{version}.png"
  retry_tor(recovery_proc) do
    found_pic = @screen.wait_any([success_pic, failure_pic], 2 * 60)[:found_pattern]
    assert_equal(success_pic, found_pic)
  end
end

When /^I agree to install the incremental upgrade$/ do
  @orig_syslinux_cfg = $vm.file_content(
    '/lib/live/mount/medium/syslinux/syslinux.cfg'
  )
  @screen.click('TailsUpgraderUpgradeNowButton.png')
end

Then /^I can successfully install the incremental upgrade to version (.+)$/ do |version|
  step 'I agree to install the incremental upgrade'
  recovery_proc = proc do
    recover_from_upgrader_failure
    step "I am proposed to install an incremental upgrade to version #{version}"
    step 'I agree to install the incremental upgrade'
  end
  failure_pic = 'TailsUpgraderFailure.png'
  success_pic = 'TailsUpgraderDownloadComplete.png'
  retry_tor(recovery_proc) do
    found_pic = @screen.wait_any([success_pic, failure_pic], 2 * 60)[:found_pattern]
    assert_equal(success_pic, found_pic)
  end
  @screen.wait('TailsUpgraderApplyUpgradeButton.png', 5).click
  @screen.wait('TailsUpgraderDone.png', 60)
  # Restore syslinux.cfg: our test IUKs replace it with something
  # that would break the next boot
  $vm.file_overwrite(
    '/lib/live/mount/medium/syslinux/syslinux.cfg',
    @orig_syslinux_cfg
  )
end

def default_squash
  'filesystem.squashfs'
end

def installed_squashes
  live = '/lib/live/mount/medium/live'
  listed_squashes = $vm.file_content("#{live}/Tails.module").chomp.split("\n")
  assert_equal(
    default_squash,
    listed_squashes.first,
    "Tails.module does not list #{default_squash} on the first line"
  )
  present_squashes = $vm.file_glob("#{live}/*.squashfs").map do |f|
    f.sub('/lib/live/mount/medium/live/', '')
  end
  # Sanity check
  assert_equal(
    listed_squashes.sort,
    present_squashes.sort,
    'Tails.module does not match the present .squashfs files'
  )
  listed_squashes
end

Given /^Tails is fooled to think a (.+) SquashFS delta is installed$/ do |version|
  old_squashes = installed_squashes
  medium = '/lib/live/mount/medium'
  live = "#{medium}/live"
  new_squash = "#{version}.squashfs"
  $vm.execute_successfully("mount -o remount,rw #{medium}")
  $vm.execute_successfully("touch #{live}/#{new_squash}")
  $vm.file_append("#{live}/Tails.module", new_squash + "\n")
  $vm.execute_successfully("mount -o remount,ro #{medium}")
  assert_equal(
    old_squashes + [new_squash],
    installed_squashes,
    'Implementation error, alert the test suite maintainer!'
  )
  $vm.execute_successfully(
    "sed --regexp-extended -i '1s/^\S+ /#{version}/' /etc/amnesia/version"
  )
  $vm.execute_successfully(
    "sed -i 's/^TAILS_VERSION_ID=.*/TAILS_VERSION_ID=#{version}/' " \
    '/etc/amnesia/version'
  )
end

Then /^the Upgrader considers the system as up-to-date$/ do
  try_for(120, delay: 10) do
    $vm.execute_successfully(
      'systemctl --user status tails-upgrade-frontend.service',
      user: LIVE_USER
    )
    up_to_date_regexp = 'tails-upgrade-frontend-wrapper\[[0-9]+\]: ' \
                        'The system is up-to-date'
    $vm.execute_successfully(
      "journalctl | grep -q -E '#{up_to_date_regexp}'"
    )
  end
end

def upgrader_trusted_signing_subkeys
  $vm.execute_successfully(
    'sudo -u tails-upgrade-frontend ' \
    'gpg --batch --list-keys --with-colons ' + TAILS_SIGNING_KEY
  ).stdout.split("\n")
     .select { |line| /^sub:/.match(line) }
     .map { |line| line[/^sub:.:\d+:\d+:(?<subkeyid>[A-F0-9]+):/, 'subkeyid'] }
end

Given /^the signing key used by the Upgrader is outdated$/ do
  upgrader_trusted_signing_subkeys.each do |subkeyid|
    $vm.execute_successfully(
      'sudo -u tails-upgrade-frontend ' \
      "gpg --batch --yes --delete-keys '#{subkeyid}!'"
    )
  end
  assert_equal(0, upgrader_trusted_signing_subkeys.length)
end

Given /^a current signing key is available on our website$/ do
  # We already check this via features/keys.feature so let's not bother here
  # ⇒ this step is only here to improve the Gherkin scenario.
  true
end

Then /^(?:no|only the (.+)) SquashFS delta is installed$/ do |version|
  expected_squashes = [default_squash]
  expected_squashes << "#{version}.squashfs" if version
  assert_equal(
    expected_squashes,
    installed_squashes,
    'Unexpected .squashfs files encountered'
  )
end

Then /^the label of the system partition on "([^"]+)" is "([^"]+)"$/ do |name, label|
  assert($vm.running?)
  disk_dev = $vm.disk_dev(name)
  part_dev = disk_dev + '1'
  check_disk_integrity(name, disk_dev, 'gpt')
  check_part_integrity(name, part_dev, 'filesystem', 'vfat', part_label: label)
end

Then /^the system partition on "([^"]+)" is an EFI system partition$/ do |name|
  assert($vm.running?)
  disk_dev = $vm.disk_dev(name)
  part_dev = disk_dev + '1'
  check_disk_integrity(name, disk_dev, 'gpt')
  check_part_integrity(name, part_dev, 'filesystem', 'vfat',
                       part_type: ESP_GUID)
end

Then /^the FAT filesystem on the system partition on "([^"]+)" is at least (\d+)(.+) large$/ do |name, size, unit|
  # Let's use bytes all the way:
  wanted_size = convert_to_bytes(size.to_i, unit)

  disk_dev = $vm.disk_dev(name)
  part_dev = disk_dev + '1'

  udisks_info = $vm.execute_successfully(
    "udisksctl info --block-device #{part_dev}"
  ).stdout
  partition_size = parse_udisksctl_info(udisks_info)[
    'org.freedesktop.UDisks2.Partition'
  ]['Size'].to_i

  # Partition size:
  assert(
    partition_size >= wanted_size,
    "FAT partition is too small: #{partition_size} is less than #{wanted_size}"
  )

  # -B 1 forces size to be expressed in bytes rather than (1K) blocks:
  fs_size = $vm.execute_successfully(
    "df --output=size -B 1 '/lib/live/mount/medium'"
  ).stdout.split("\n")[1].to_i
  assert(fs_size >= wanted_size,
         "FAT filesystem is too small: #{fs_size} is less than #{wanted_size}")
end

Then /^the UUID of the FAT filesystem on the system partition on "([^"]+)" was randomized$/ do |name|
  disk_dev = $vm.disk_dev(name)
  part_dev = disk_dev + '1'

  # Get the UUID from the block area:
  udisks_info = $vm.execute_successfully(
    "udisksctl info --block-device #{part_dev}"
  ).stdout
  fs_uuid = parse_udisksctl_info(
    udisks_info
  )['org.freedesktop.UDisks2.Block']['IdUUID']

  static_uuid = 'A690-20D2'
  assert(fs_uuid != static_uuid,
         "FS UUID on #{name} wasn't randomized, it's still: #{fs_uuid}")
end

Then /^the label of the FAT filesystem on the system partition on "([^"]+)" is "([^"]+)"$/ do |name, label|
  disk_dev = $vm.disk_dev(name)
  part_dev = disk_dev + '1'

  # Get FS label from the block area:
  udisks_info = $vm.execute_successfully(
    "udisksctl info --block-device #{part_dev}"
  ).stdout
  fs_label = parse_udisksctl_info(
    udisks_info
  )['org.freedesktop.UDisks2.Block']['IdLabel']

  assert(label == fs_label,
         "FS label on #{part_dev} is #{fs_label} " \
         "instead of the expected #{label}")
end

Then /^the system partition on "([^"]+)" has the expected flags$/ do |name|
  disk_dev = $vm.disk_dev(name)
  part_dev = disk_dev + '1'

  # Look at the flags from the partition area:
  udisks_info = $vm.execute_successfully(
    "udisksctl info --block-device #{part_dev}"
  ).stdout
  flags = parse_udisksctl_info(
    udisks_info
  )['org.freedesktop.UDisks2.Partition']['Flags']

  # See SYSTEM_PARTITION_FLAGS in create-usb-image-from-iso: 0xd000000000000005,
  # displayed in decimal (14987979559889010693) in udisksctl's output:
  expected_flags = 0xd000000000000005
  assert(flags == expected_flags.to_s,
         "Got #{flags} as partition flags on #{part_dev} (for #{name}), " \
         "instead of the expected #{expected_flags}")
end

Given /^I install a Tails USB image to the (\d+) MiB disk with GNOME Disks$/ do |size_in_MiB_of_destination_disk|
  # GNOME Disks displays devices sizes in GB, with 1 decimal digit precision
  size_in_GB_of_destination_disk = convert_from_bytes(
    convert_to_bytes(size_in_MiB_of_destination_disk.to_i, 'MiB'),
    'GB'
  ).round(1).to_s
  debug_log('Expected size of destination disk: ' +
            size_in_GB_of_destination_disk)

  step 'I start "Disks" via GNOME Activities Overview'
  disks = gnome_disks_app
  destination_disk_label_regexp = /^#{size_in_GB_of_destination_disk} GB Drive/
  disks.children(roleName: 'table cell')
       .find { |row| destination_disk_label_regexp.match(row.name) }
       .grabFocus
  @screen.wait('GnomeDisksDriveMenuButton.png', 5).click
  disks.child('Restore Disk Image…',
              roleName:    'push button',
              showingOnly: true)
       .click
  restore_dialog = disks.child('Restore Disk Image',
                               roleName:    'dialog',
                               showingOnly: true)
  # Open the file chooser
  @screen.press('Enter')
  select_disk_image_dialog = disks.child('Select Disk Image to Restore',
                                         roleName:    'file chooser',
                                         showingOnly: true)
  @screen.paste(
    @usb_image_path,
    app: :gtk_file_chooser
  )
  sleep 2 # avoid ENTER being eaten by the auto-completion system
  @screen.press('Enter')
  try_for(10) do
    !select_disk_image_dialog.showing
  end
  # Clicking this button using Dogtail works, but afterwards GNOME
  # Disks becomes inaccessible.
  restore_dialog.child('Start Restoring…',
                       roleName:    'push button',
                       showingOnly: true).grabFocus
  @screen.press('Return')
  disks.child('Information', roleName: 'alert', showingOnly: true)
       .child('Restore', roleName: 'push button', showingOnly: true)
       .grabFocus
  @screen.press('Return')
  # Wait until the restoration job is finished
  job = disks.child('Job', roleName: 'label', showingOnly: true)
  try_for(120) do
    !job.showing
  end
end

Given /^I set all Greeter options to non-default values$/ do
  # We sleep between each option to give the UI time to update,
  # otherwise we might detect the + button or language entry before it
  # has been readjusted, so while we try to click it, it moves so we
  # miss it.
  step 'I disable the Unsafe Browser'
  sleep 2
  step 'I disable networking in Tails Greeter'
  sleep 2
  step 'I disable MAC spoofing in Tails Greeter'
  sleep 2
  # Administration password needs to be done last because its image has blue background (selected)
  # while the others have no such background.
  step 'I set an administration password'
  sleep 2

  # We should change language, too, but we'll not: in fact, changing the language would change labels in the
  # UI, so we would need to keep images (see #19420) in both languages, making the test suite harder to
  # maintain.
  # The "I log in to a new session" step can change language at the very last moment, which is a good
  # workaround to the problem.
end

Then /^all Greeter options are set to (non-)?default values$/ do |non_default|
  settings = $vm.execute_successfully(
    'grep -h "^TAILS_" /var/lib/gdm3/settings/persistent/tails.* | ' \
    'grep -v "^TAILS_.*PASSWORD" | LC_ALL=C sort'
  ).stdout
  if non_default
    expected = <<~EXPECTED
      TAILS_FORMATS=de_DE
      TAILS_LOCALE_NAME=de_DE
      TAILS_MACSPOOF_ENABLED=false
      TAILS_NETWORK=false
      TAILS_UNSAFE_BROWSER_ENABLED=false
      TAILS_XKBLAYOUT=de
      TAILS_XKBMODEL=pc105
      TAILS_XKBVARIANT=
    EXPECTED
    $vm.execute_successfully(
      'grep "^TAILS_USER_PASSWORD=\'.\+\'$" ' \
      '/var/lib/gdm3/settings/persistent/tails.password'
    )
    $vm.execute_successfully(
      'grep "^TAILS_PASSWORD_HASH_FUNCTION=SHA512$" ' \
      '/var/lib/gdm3/settings/persistent/tails.password'
    )
  else
    expected = <<~EXPECTED
      TAILS_FORMATS=en_US
      TAILS_LOCALE_NAME=en_US
      TAILS_MACSPOOF_ENABLED=true
      TAILS_NETWORK=true
      TAILS_UNSAFE_BROWSER_ENABLED=true
      TAILS_XKBLAYOUT=us
      TAILS_XKBMODEL=pc105
      TAILS_XKBVARIANT=
    EXPECTED
    assert(!$vm.file_exist?('/var/lib/gdm3/settings/persistent/tails.password'))
  end
  assert_equal(expected, settings)
end

Then /^(no )?persistent Greeter options were restored$/ do |no|
  $language, $lang_code = get_greeter_language
  # Our Dogtail wrapper code automatically translates strings to $language
  settings_restored = greeter
                      .child?('Settings were loaded from the persistent storage.',
                              roleName:    'label',
                              showingOnly: true)
  if no
    assert(!settings_restored)
  else
    assert(settings_restored)
  end
end

Then /^the Tails Persistent Storage behave tests pass$/ do
  $vm.execute_successfully('/usr/lib/python3/dist-packages/tps/configuration/behave-tests/run-tests.sh')
end

When /^I give the Persistent Storage on drive "([^"]+)" its own UUID$/ do |name|
  # Rationale: udisks cannot unlock 2 devices with the same UUID.
  dev = $vm.persistent_storage_dev_on_disk(name)
  uuid = SecureRandom.uuid
  $vm.execute_successfully("cryptsetup luksUUID --uuid #{uuid} #{dev}")
end

When /^I create a file in the Persistent directory$/ do
  unless $vm.file_exist?('/home/amnesia/Persistent')
    step 'I create a directory "/home/amnesia/Persistent"'
  end
  step 'I write a file "/home/amnesia/Persistent/foo" with contents "foo"'
end

Then /^the file I created was copied to the Persistent Storage$/ do
  file = '/live/persistence/TailsData_unlocked/Persistent/foo'
  step "the file \"#{file}\" exists"
  step "the file \"#{file}\" has the content \"foo\""
end

Then /^the file I created does not exist on the Persistent Storage$/ do
  file = '/live/persistence/TailsData_unlocked/Persistent/foo'
  step "the file \"#{file}\" does not exist"
end

Then /^the file I created in the Persistent directory exists$/ do
  file = '/home/amnesia/Persistent/foo'
  step "the file \"#{file}\" exists"
  step "the file \"#{file}\" has the content \"foo\""
end

Then /^the Persistent directory does not exist$/ do
  step 'the directory "/home/amnesia/Persistent" does not exist'
end

When /^I delete the data of the Persistent Folder feature$/ do
  step 'I start "Persistent Storage" via GNOME Activities Overview'

  def persistent_folder_delete_button(**opts)
    persistent_storage_main_frame.child(
      'Delete Persistent Folder data',
      roleName: 'push button', showingOnly: true, **opts
    )
  end

  # We can't use the click action here because this button causes a
  # modal dialog to be run via gtk_dialog_run() which causes the
  # application to hang when triggered via a ATSPI action. See
  # https://gitlab.gnome.org/GNOME/gtk/-/issues/1281
  persistent_folder_delete_button.grabFocus
  @screen.press('Return')
  confirm_deletion_dialog = persistent_storage_frontend.child(
    'Warning', roleName: 'alert'
  )
  confirm_deletion_dialog.button('Delete Data').click

  # Wait for the delete data button to disappear
  try_for(10) do
    persistent_folder_delete_button(retry: false)
  rescue Dogtail::Failure
    # The button couldn't be found, which is what we want
    true
  else
    false
  end
  @screen.press('alt', 'F4')
end

Then /^the Welcome Screen tells me that the Persistent Folder feature couldn't be activated$/ do
  assert greeter.child('Failed to activate some features of the Persistent Storage: Persistent Folder.\n.*',
                       roleName:    'label',
                       showingOnly: true)
end

Then /^the Persistent Storage settings tell me that the Persistent Folder feature couldn't be activated$/ do
  step 'I start "Persistent Storage" via GNOME Activities Overview'

  persistent_folder_row = persistent_storage_frontend
                          .child('Activate Persistent Folder').parent
  assert persistent_folder_row
    .child(description: 'Activation failed', showingOnly: true)
end
