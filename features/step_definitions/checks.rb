Then /^the included OpenPGP keys are valid for the next (\d+) months?$/ do |months|
  assert_all_keys_are_valid_for_n_months(:OpenPGP, Integer(months))
end

Then /^the keys trusted by APT are valid for the next (\d+) months$/ do |months|
  assert_all_keys_are_valid_for_n_months(:APT, Integer(months))
end

def assert_all_keys_are_valid_for_n_months(type, months)
  assert([:OpenPGP, :APT].include?(type))
  assert(months.is_a?(Integer))

  ignored_keys = []

  cmd  = type == :OpenPGP ? 'gpg'     : 'apt-key adv'
  user = type == :OpenPGP ? LIVE_USER : 'root'
  keys = $vm.execute_successfully(
    "#{cmd} --batch --with-colons --fingerprint --list-key", user: user
  ).stdout
            .scan(/^fpr:::::::::([A-Z0-9]+):$/)
            .flatten
            .reject { |fpr| ignored_keys.include?(fpr) }

  invalid = keys.reject do |fpr|
    key_valid_for_n_months?(type, fpr, months)
  end
  assert(invalid.empty?,
         "The following #{type} key(s) will not be valid " \
         "in #{months} months: #{invalid.join(', ')}")
end

def check_key_valid(line, months)
  # line comes from gpg --list-keys (don't use --with-colons)
  expiry = line.scan(/\[expire[ds]: ([0-9-]*)\]/)
  return true if expiry.empty?

  expiration_date = Date.parse(expiry.flatten.first)
  valid = ((expiration_date << months.to_i) > DateTime.now)
  valid
end

def get_subkey_use(line)
  # useful to check if a subkey can be used for signing, for example
  # returns a string such as "SEA" (sign+encrypt+authenticate) or "S", etc.
  uses = line.scan(/\d\d\d\d-\d\d-\d\d \[([SEAC]+)\]/).flatten.first

  uses.split('').sort
end

def key_valid_for_n_months?(type, fingerprint, months)
  # we define a check to be valid:
  #  - only if the master key is valid
  #  - only if either:
  #    - there are no subkeys at all
  #    - at least one relevant subkey is valid
  #
  # any subkey is relevant if type == :OpenPGP
  # only signing keys are relevant if type == :APT
  #
  # Please note that this is not truly perfect: for example, if a OpenPGP key
  # has only its encryption subkey valid, but its signing subkey is expired,
  # this should give an error but will not.

  assert([:OpenPGP, :APT].include?(type))
  assert(months.is_a?(Integer))

  cmd  = type == :OpenPGP ? 'gpg'     : 'apt-key adv'
  user = type == :OpenPGP ? LIVE_USER : 'root'
  list_options = '--list-options show-unusable-subkeys'

  key_description = $vm.execute_successfully(
    "#{cmd} --batch  #{list_options} --list-key #{fingerprint}", user: user
  ).stdout.split("\n")

  masterkey = key_description.grep(/^pub\b/)
  subkeys = key_description.grep(/^sub\b/)

  unless check_key_valid(masterkey.first, months)
    debug_log("Masterkey not valid: #{masterkey}")
    return false
  end

  return true if subkeys.empty?

  valid_subkeys = subkeys.filter do |subkey_line|
    if type == :APT && !get_subkey_use(subkey_line).include?('S')
      # we don't care about non-signing key
      return false
    end

    if check_key_valid(subkey_line, months)
      true
    else
      debug_log("subkey not valid: #{subkey_line}")
      false
    end
  end

  !valid_subkeys.empty?
end

Then /^the live user has been setup by live\-boot$/ do
  assert_vmcommand_success(
    $vm.execute('test -e /var/lib/live/config/user-setup'),
    'live-boot failed its user-setup'
  )
  actual_username = $vm.execute('. /etc/live/config/username.conf; ' \
                                'echo $LIVE_USERNAME').stdout.chomp
  assert_equal(LIVE_USER, actual_username)
end

Then /^the live user is a member of only its own group and "(.*?)"$/ do |groups|
  expected_groups = groups.split(' ') << LIVE_USER
  actual_groups = $vm.execute("groups #{LIVE_USER}").stdout.chomp.sub(
    /^#{LIVE_USER} : /, ''
  ).split(' ')
  unexpected = actual_groups - expected_groups
  missing = expected_groups - actual_groups
  assert_equal(0, unexpected.size,
               "live user in unexpected groups #{unexpected}")
  assert_equal(0, missing.size,
               "live user not in expected groups #{missing}")
end

Then /^the live user owns its home directory which has strict permissions$/ do
  home = "/home/#{LIVE_USER}"
  assert_vmcommand_success(
    $vm.execute("test -d #{home}"),
    "The live user's home doesn't exist or is not a directory"
  )
  owner = $vm.execute("stat -c %U:%G #{home}").stdout.chomp
  perms = $vm.execute("stat -c %a #{home}").stdout.chomp
  assert_equal("#{LIVE_USER}:#{LIVE_USER}", owner)
  assert_equal('700', perms)
end

Then /^no unexpected services are listening for network connections$/ do
  $vm.execute_successfully('ss -ltupn').stdout.chomp.split("\n").each do |line|
    splitted = line.split(/[[:blank:]]+/)
    proto = splitted[0]
    next unless ['tcp', 'udp'].include?(proto)

    laddr, lport = splitted[4].split(':')
    proc = /users:\(\("([^"]+)"/.match(splitted[6])[1]
    # Services listening on loopback is not a threat
    if /127(\.[[:digit:]]{1,3}){3}/.match(laddr).nil?
      if SERVICES_EXPECTED_ON_ALL_IFACES.include?([proc, laddr, lport]) ||
         SERVICES_EXPECTED_ON_ALL_IFACES.include?([proc, laddr, '*'])
        puts "Service '#{proc}' is listening on #{laddr}:#{lport} " \
             'but has an exception'
      else
        raise "Unexpected service '#{proc}' listening on #{laddr}:#{lport}"
      end
    end
  end
end

Then /^the support documentation page opens in Tor Browser$/ do
  if $language == 'German'
    expected_title = 'Tails - Hilfe & Support'
    expected_heading = 'Die Dokumentation durchsuchen'
  else
    expected_title = 'Tails - Support'
    expected_heading = 'Search the documentation'
  end
  step "\"#{expected_title}\" has loaded in the Tor Browser"
  browser_name = $language == 'German' ? 'Tor-Browser' : 'Tor Browser'
  separator = $language == 'German' ? '-' : '—'
  try_for(60, delay: 3) do
    page_has_heading("#{expected_title} #{separator} #{browser_name}", expected_heading)
  end
end

Given /^I plug and mount a USB drive containing a sample PNG$/ do
  @png_dir = share_host_files(Dir.glob("#{MISC_FILES_DIR}/*.png"))
end

def mat2_show(file_in_guest)
  $vm.execute_successfully("mat2 --show '#{file_in_guest}'",
                           user: LIVE_USER).stdout
end

Then /^MAT can clean some sample PNG file$/ do
  Dir.glob("#{MISC_FILES_DIR}/*.png").each do |png_on_host|
    png_name = File.basename(png_on_host)
    png_on_guest = "/home/#{LIVE_USER}/#{png_name}"
    cleaned_png_on_guest = "/home/#{LIVE_USER}/#{png_name}".sub(/[.]png$/,
                                                                '.cleaned.png')
    step "I copy \"#{@png_dir}/#{png_name}\" to \"#{png_on_guest}\" " \
         "as user \"#{LIVE_USER}\""
    raw_check_cmd = 'grep --quiet --fixed-strings --text ' \
                    "'Created with GIMP'"
    assert_vmcommand_success($vm.execute(raw_check_cmd + " '#{png_on_guest}'",
                                         user: LIVE_USER),
                             'The comment is not present in the PNG')
    check_before = mat2_show(png_on_guest)
    assert(check_before.include?("Metadata for #{png_on_guest}"),
           "MAT failed to see that '#{png_on_host}' is dirty")
    $vm.execute_successfully("mat2 '#{png_on_guest}'", user: LIVE_USER)
    check_after = mat2_show(cleaned_png_on_guest)
    assert(check_after.include?('No metadata found'),
           "MAT failed to clean '#{png_on_host}'")
    assert($vm.execute(raw_check_cmd + " '#{cleaned_png_on_guest}'",
                       user: LIVE_USER).failure?,
           'The comment is still present in the PNG')
    $vm.execute_successfully("rm '#{png_on_guest}'")
  end
end

def get_seccomp_status(process)
  assert($vm.process_running?(process), "Process #{process} not running.")
  pid = $vm.pidof(process)[0]
  status = $vm.file_content("/proc/#{pid}/status")
  status.match(/^Seccomp:\s+([0-9])/)[1].chomp.to_i
end

def get_apparmor_status(pid)
  apparmor_status = $vm.file_content("/proc/#{pid}/attr/current").chomp
  if apparmor_status.include?(')')
    # matches something like     /usr/sbin/cupsd (enforce)
    # and only returns what's in the parentheses
    apparmor_status.match(/[^\s]+\s+\((.+)\)$/)[1].chomp
  else
    apparmor_status
  end
end

Then /^Tor is (not )?confined with Seccomp$/ do |not_confined|
  expected_sandbox_status = not_confined.nil? ? 1 : 0
  sandbox_status = $vm.execute_successfully(
    '/usr/local/lib/tor_variable get --type=conf Sandbox'
  ).stdout.to_i
  assert_equal(expected_sandbox_status, sandbox_status,
               'Tor says that the sandbox is ' +
               (sandbox_status == 1 ? 'enabled' : 'disabled'))
  # tor's Seccomp status will always be 2 (filter mode), even with
  # "Sandbox 0", but let's still make sure that is the case.
  seccomp_status = get_seccomp_status('tor')
  assert_equal(2, seccomp_status,
               'Tor is not confined with Seccomp in filter mode')
end

Then /^the running process "(.+)" is confined with AppArmor in (complain|enforce) mode$/ do |process, mode|
  assert($vm.process_running?(process), "Process #{process} not running.")
  pid = $vm.pidof(process)[0]
  assert_equal(mode, get_apparmor_status(pid))
end

Then /^the Tor Status icon tells me that Tor is( not)? usable$/ do |not_usable|
  picture = not_usable ? 'TorStatusNotUsable' : 'TorStatusUsable'
  @screen.wait("#{picture}.png", 10)
end
