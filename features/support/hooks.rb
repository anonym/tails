require 'fileutils'
require 'rb-inotify'
require 'time'
require 'tmpdir'

# Run once, before any feature
AfterConfiguration do |config|
  # Reorder the execution of some features. As we progress through a
  # run we accumulate more and more snapshots and hence use more and
  # more disk space, but some features will leave nothing behind
  # and/or possibly use large amounts of disk space temporarily for
  # various reasons. By running these first we minimize the amount of
  # disk space needed.
  prioritized_features = [
    # Features not using snapshots but using large amounts of scratch
    # space for other reasons:
    'features/untrusted_partitions.feature',
    # Features using temporary snapshots:
    'features/root_access_control.feature',
    'features/time_syncing.feature',
    'features/tor_bridges.feature',
    # Features using large amounts of scratch space for other reasons:
    'features/erase_memory.feature',
    # This feature needs the almost biggest snapshot (USB install,
    # excluding persistence) and will create yet another disk and
    # install Tails on it. This should be the peak of disk usage.
    'features/usb_install.feature',
    # This feature uses a few temporary snapshots, a network-enabled
    # snapshot, and a large disk.
    'features/additional_software_packages.feature',
    # This feature needs a copy of the ISO and creates a new disk.
    'features/usb_upgrade.feature',
    # This feature needs a very big snapshot (USB install with persistence)
    # and another, network-enabled snapshot.
    'features/emergency_shutdown.feature',
  ]
  feature_files = config.feature_files
  # The &-intersection is specified to keep the element ordering of
  # the *left* operand.
  intersection = prioritized_features & feature_files
  unless intersection.empty?
    feature_files -= intersection
    feature_files = intersection + feature_files
    config.define_singleton_method(:feature_files) { feature_files }
  end

  # Used to keep track of when we start our first @product feature, when
  # we'll do some special things.
  $started_first_product_feature = false

  if File.exist?($config['TMPDIR'])
    unless File.directory?($config['TMPDIR'])
      raise "Temporary directory '#{$config['TMPDIR']}' exists but is not a " \
            'directory'
    end
    unless File.owned?($config['TMPDIR'])
      raise "Temporary directory '#{$config['TMPDIR']}' must be owned by the " \
            'current user'
    end
    FileUtils.chmod(0o755, $config['TMPDIR'])
  else
    begin
      FileUtils.mkdir_p($config['TMPDIR'])
    rescue Errno::EACCES => e
      raise "Cannot create temporary directory: #{e}"
    end
  end
end

# Common
########

After do
  @after_scenario_hooks.each(&:call) if @after_scenario_hooks
  @after_scenario_hooks = []
end

BeforeFeature('@product', '@source') do |feature|
  raise "Feature #{feature.file} is tagged both @product and @source, " \
        'which is an impossible combination'
end

at_exit do
  $vm.destroy_and_undefine if $vm
  if $virt
    unless KEEP_SNAPSHOTS
      VM.remove_all_snapshots
      $vmstorage.clear_pool
    end
    $vmnet.destroy_and_undefine
    $virt.close
  end
  # The artifacts directory is empty (and useless) if it contains
  # nothing but the mandatory . and ..
  FileUtils.rmdir(ARTIFACTS_DIR) if Dir.entries(ARTIFACTS_DIR).size <= 2
end

# For @product tests
####################

def add_after_scenario_hook(&block)
  @after_scenario_hooks ||= []
  @after_scenario_hooks << block
end

def save_failure_artifact(type, path)
  $failure_artifacts << [type, path]
end

def save_journal(path)
  File.open("#{path}/systemd.journal", 'w') do |file|
    $vm.execute('journalctl -a --no-pager > /tmp/systemd.journal')
    file.write($vm.file_content('/tmp/systemd.journal'))
  end
  save_failure_artifact('Systemd journal', "#{path}/systemd.journal")
rescue Exception => e
  info_log('Exception thrown while trying to save the journal: ' \
           "#{e.class.name}: #{e}")
end

# Due to Tails' Tor enforcement, we only allow contacting hosts that
# are Tor nodes, located on the LAN, or allowed for some operational reason.
# However, when we try to verify that only such hosts are contacted we have
# a problem -- we run all Tor nodes (via Chutney) *and* LAN hosts (used on
# some tests) on the same host, the one running the test suite. Hence we
# need to always explicitly track which nodes are allowed or not.
#
# Warning: when a host is added via this function, it is only added
# for the current scenario. As such, if this is done before saving a
# snapshot, it will not remain after the snapshot is loaded.
def add_extra_allowed_host(ipaddr, port)
  @extra_allowed_hosts ||= []
  @extra_allowed_hosts << { address: ipaddr, port: port }
end

BeforeFeature('@product') do
  images = { 'ISO' => TAILS_ISO, 'IMG' => TAILS_IMG }
  images.each do |type, path|
    if path.nil?
      raise "No Tails #{type} image specified, and none could be found " \
            'in the current directory'
    end

    unless File.exist?(path)
      raise "The specified Tails #{type} image '#{path}' does not exist"
    end

    # Workaround: when libvirt takes ownership of the ISO/IMG image it may
    # become unreadable for the live user inside the guest in the
    # host-to-guest share used for some tests.

    unless File.world_readable?(path)
      if File.owned?(path)
        File.chmod(0o644, path)
      else
        raise "warning: the Tails #{type} image must be world readable " \
              'or be owned by the current user to be available inside ' \
              'the guest VM via host-to-guest shares, which is required ' \
              'by some tests'
      end
    end
  end
  unless File.exist?(OLD_TAILS_ISO)
    raise "The specified old Tails ISO image '#{OLD_TAILS_ISO}' does not exist"
  end
  unless File.exist?(OLD_TAILS_IMG)
    raise "The specified old Tails IMG image '#{OLD_TAILS_IMG}' does not exist"
  end

  unless $started_first_product_feature
    $virt = Libvirt.open('qemu:///system')
    VM.remove_all_snapshots unless KEEP_SNAPSHOTS
    $vmnet = VMNet.new($virt, VM_XML_PATH)
    $vmstorage = VMStorage.new($virt, VM_XML_PATH)
    $started_first_product_feature = true
  end
  ensure_chutney_is_running
end

AfterFeature('@product') do
  unless KEEP_SNAPSHOTS
    checkpoints.each do |name, vals|
      VM.remove_snapshot(name) if vals[:temporary] && VM.snapshot_exists?(name)
    end
  end
  $vmstorage.list_volumes.each do |vol_name|
    next if vol_name == '__internal'

    $vmstorage.delete_volume(vol_name)
  end
end

# Cucumber Before hooks are executed in the order they are listed, and
# we want this hook to always run first, so it must always be the
# *first* Before hook matching @product listed in this file.
Before('@product') do |scenario|
  $failure_artifacts = []
  if $config['CAPTURE']
    video_name = sanitize_filename("#{scenario.name}.mkv")
    @video_path = "#{ARTIFACTS_DIR}/#{video_name}"
    capture = IO.popen([ffmpeg,
                        '-f', 'x11grab',
                        '-s', '1024x768',
                        '-r', '15',
                        '-i', "#{$config['DISPLAY']}.0",
                        '-an',
                        '-c:v', 'libx264',
                        '-y',
                        @video_path,
                        err: ['/dev/null', 'w'],])
    @video_capture_pid = capture.pid
  end
  if $config['IMAGE_BUMPING_MODE']
    @screen = ImageBumpingScreen.new
  else
    @screen = Screen.new
  end
  # English will be assumed if this is not overridden
  $language = ''
  @os_loader = 'MBR'
  @sudo_password = 'asdf'
  @persistence_password = 'asdf'
  # See comment for add_extra_allowed_host() above.
  @extra_allowed_hosts ||= []
end

# Cucumber After hooks are executed in the *reverse* order they are
# listed, and we want this hook to always run second last, so it must always
# be the *second* After hook matching @product listed in this file --
# hooks added dynamically via add_after_scenario_hook() are supposed to
# truly be last.
After('@product') do |scenario|
  if @video_capture_pid
    # We can be incredibly fast at detecting errors sometimes, so the
    # screen barely "settles" when we end up here and kill the video
    # capture. Let's wait a few seconds more to make it easier to see
    # what the error was.
    sleep 3 if scenario.failed?
    Process.kill('INT', @video_capture_pid)
    Process.wait(@video_capture_pid)
    save_failure_artifact('Video', @video_path)
  end
  if scenario.failed?
    time_of_fail = Time.now - TIME_AT_START
    secs = '%02d' % (time_of_fail % 60)
    mins = '%02d' % ((time_of_fail / 60) % 60)
    hrs  = '%02d' % (time_of_fail / (60 * 60))
    elapsed = "#{hrs}:#{mins}:#{secs}"
    info_log("Scenario failed at time #{elapsed}")
    screenshot_path = sanitize_filename("#{scenario.name}.png")
    $vm.display.screenshot(screenshot_path)
    save_failure_artifact('Screenshot', screenshot_path)
    exception_name = scenario.exception.class.name
    case exception_name
    when 'FirewallAssertionFailedError'
      Dir.glob("#{$config['TMPDIR']}/*.pcap").each do |pcap_file|
        save_failure_artifact('Network capture', pcap_file)
      end
    when 'TorBootstrapFailure'
      save_failure_artifact('Tor logs', "#{$config['TMPDIR']}/log.tor")
      chutney_logs = sanitize_filename(
        "#{elapsed}_#{scenario.name}_chutney-data"
      )
      FileUtils.mkdir("#{ARTIFACTS_DIR}/#{chutney_logs}")
      FileUtils.rm(Dir.glob("#{$config['TMPDIR']}/chutney-data/**/control"))
      FileUtils.copy_entry(
        "#{$config['TMPDIR']}/chutney-data",
        "#{ARTIFACTS_DIR}/#{chutney_logs}"
      )
      info_log
      info_log_artifact_location(
        'Chutney logs',
        "#{ARTIFACTS_DIR}/#{chutney_logs}"
      )
    when 'TimeSyncingError'
      save_failure_artifact('Htpdate logs', "#{$config['TMPDIR']}/log.htpdate")
    end
    # Note that the remote shell isn't necessarily running at all
    # times a scenario can fail (and a scenario failure could very
    # well cause the remote shell to not respond any more, e.g. when
    # we cause a system crash), so let's collect everything depending
    # on the remote shell here:
    save_journal($config['TMPDIR']) if $vm && $vm.remote_shell_is_up?
    $failure_artifacts.sort!
    $failure_artifacts.each do |type, file|
      artifact_name = sanitize_filename(
        "#{elapsed}_#{scenario.name}#{File.extname(file)}"
      )
      artifact_path = "#{ARTIFACTS_DIR}/#{artifact_name}"
      assert(File.exist?(file))
      FileUtils.mv(file, artifact_path)
      info_log
      info_log_artifact_location(type, artifact_path)
    end
    if $config['INTERACTIVE_DEBUGGING']
      pause(
        "Scenario failed: #{scenario.name}. " \
        "The error was: #{scenario.exception.class.name}: #{scenario.exception}"
      )
    end
  elsif @video_path && File.exist?(@video_path) && !(($config['CAPTURE_ALL']))
    FileUtils.rm(@video_path)
  end
  # If we don't shut down the system under testing it will continue to
  # run during the next scenario's Before hooks, which we have seen
  # causing trouble (for instance, packets from the previous scenario
  # have failed scenarios tagged @check_tor_leaks).
  $vm.power_off if $vm
end

Before('@product', '@check_tor_leaks') do |scenario|
  @tor_leaks_sniffer = Sniffer.new(sanitize_filename(scenario.name), $vmnet)
  @tor_leaks_sniffer.capture
  add_after_scenario_hook do
    @tor_leaks_sniffer.clear
  end
end

After('@product', '@check_tor_leaks') do |scenario|
  @tor_leaks_sniffer.stop
  if scenario.passed?
    allowed_nodes = @bridge_hosts || allowed_hosts_under_tor_enforcement
    assert_all_connections(@tor_leaks_sniffer.pcap_file) do |c|
      allowed_nodes.include?({ address: c.daddr, port: c.dport })
    end
  end
end

# For @source tests
###################

# BeforeScenario
Before('@source') do
  @orig_pwd = Dir.pwd
  @git_clone = Dir.mktmpdir 'tails-apt-tests'
  Dir.chdir @git_clone
end

# AfterScenario
After('@source') do
  Dir.chdir @orig_pwd
  FileUtils.remove_entry_secure @git_clone
end
