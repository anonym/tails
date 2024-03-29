require 'fileutils'
require 'resolv'
require 'yaml'
require "#{Dir.pwd}/features/support/helpers/misc_helpers.rb"

TRUE_VALUES = ['1', 'y', 'yes', 'true']
def config_bool(name)
  value = $config[name]

  if value.nil?
    return false
  end

  if value.is_a?(TrueClass) || value.is_a?(FalseClass)
    return value
  end

  # It's not a boolean so we assume it's a string
  TRUE_VALUES.include?(value.downcase)
end

# These files deal with options like some of the settings passed
# to the `run_test_suite` script, and "secrets" like credentials
# (passwords, SSH keys) to be used in tests.
CONFIG_DIR = "#{Dir.pwd}/features/config".freeze
DEFAULTS_CONFIG_FILE = "#{CONFIG_DIR}/defaults.yml".freeze
LOCAL_CONFIG_FILE = "#{CONFIG_DIR}/local.yml".freeze
LOCAL_CONFIG_DIRS_FILES_GLOB = "#{CONFIG_DIR}/*.d/*.yml".freeze

assert File.exist?(DEFAULTS_CONFIG_FILE)
$config = YAML.safe_load(File.read(DEFAULTS_CONFIG_FILE))
config_files = Dir.glob(LOCAL_CONFIG_DIRS_FILES_GLOB).sort
config_files << LOCAL_CONFIG_FILE if File.exist?(LOCAL_CONFIG_FILE)
config_files.each do |config_file|
  yaml_struct = YAML.safe_load(File.read(config_file)) || {}
  unless yaml_struct.instance_of?(Hash)
    raise "Local configuration file '#{config_file}' is malformed"
  end

  $config.merge!(yaml_struct)
end
# Options passed to the `run_test_suite` script will always take
# precedence. The way we import these keys is only safe for values
# with types boolean or string. If we need more, we'll have to invoke
# YAML's type autodetection on ENV some how.
$config.merge!(ENV)

# Export TMPDIR back to the environment for subprocesses that we start
# (e.g. guestfs). Note that this export will only make a difference if
# TMPDIR wasn't already set and --tmpdir wasn't passed, i.e. only when
# we use the default.
ENV['TMPDIR'] = $config['TMPDIR']

# Dynamic constants initialized through the environment or similar,
# e.g. options we do not want to be configurable through the YAML
# configuration files.
DEBUG_LOG_PSEUDO_FIFO = "#{$config['TMPDIR']}/debug_log_pseudo_fifo".freeze
DISPLAY = ENV['DISPLAY']
GIT_DIR = ENV['PWD']
KEEP_CHUTNEY = !ENV['KEEP_CHUTNEY'].nil?
KEEP_SNAPSHOTS = !ENV['KEEP_SNAPSHOTS'].nil?
DISABLE_CHUTNEY = !ENV['DISABLE_CHUTNEY'].nil?
LATE_PATCH = ENV['LATE_PATCH']
EARLY_PATCH = !ENV['EARLY_PATCH'].nil?
EXTRA_BOOT_OPTIONS = ENV['EXTRA_BOOT_OPTIONS']
LIVE_USER = cmd_helper(
  '. config/chroot_local-includes/etc/live/config.d/username.conf; ' \
  'echo ${LIVE_USERNAME}'
).chomp
TAILS_ISO = ENV['TAILS_ISO']
TAILS_IMG = TAILS_ISO.sub(/\.iso/, '.img')
OLD_TAILS_ISO = ENV['OLD_TAILS_ISO'] || TAILS_ISO
OLD_TAILS_IMG = OLD_TAILS_ISO.sub(/\.iso/, '.img')
TIME_AT_START = Time.now
loop do
  ARTIFACTS_DIR = $config['TMPDIR'] + '/run-' +
                  sanitize_filename(TIME_AT_START.to_s) + '-' +
                  [
                    'git',
                    sanitize_filename(describe_git_head,
                                      replacement: '-'),
                    current_short_commit,
                  ].reject(&:empty?).join('_') + '-' +
                  random_alnum_string(6)
  unless File.exist?(ARTIFACTS_DIR)
    FileUtils.mkdir_p(ARTIFACTS_DIR)
    break
  end
end
OPENCV_IMAGE_PATH = "#{Dir.pwd}/features/images/".freeze
OPENCV_MIN_SIMILARITY = 0.9

# Constants that are statically initialized.
LIBVIRT_DOMAIN_NAME = 'TailsToaster'.freeze
LIBVIRT_DOMAIN_UUID = '203552d5-819c-41f3-800e-2c8ef2545404'.freeze
LIBVIRT_NETWORK_NAME = 'TailsToasterNet'.freeze
LIBVIRT_NETWORK_UUID = 'f2305af3-2a64-4f16-afe6-b9dbf02a597e'.freeze
MISC_FILES_DIR = "#{Dir.pwd}/features/misc_files".freeze
SERVICES_EXPECTED_ON_ALL_IFACES =
  [
    ['cups-browsed', '0.0.0.0', '631'],
    ['cupsd', '*', '631'],
    ['dhclient', '0.0.0.0', '68'],
    ['onion-grater', '0.0.0.0', '951'],
    ['tor', '10.200.1.1', '9050'],
  ].freeze
# OpenDNS
SOME_DNS_SERVER = '208.67.222.222'.freeze
RTL_LANGUAGES = ['Arabic', 'Persian'].freeze
VM_XML_PATH = "#{Dir.pwd}/features/domains".freeze

TAILS_SIGNING_KEY = cmd_helper(
  ". #{Dir.pwd}/config/variables; echo ${TAILS_SIGNING_KEY_FP}"
).tr(' ', '').chomp
WEBM_VIDEO_URL = 'https://tails.net/lib/test_suite/test.webm'.freeze

# EFI System Partition
ESP_GUID = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'.freeze

# Fedora connectivity check server, used by tails-get-network-time
CONNECTIVITY_CHECK_HOSTNAME = 'fedoraproject.org'.freeze
CONNECTIVITY_CHECK_HOSTS = Resolv.getaddresses(CONNECTIVITY_CHECK_HOSTNAME)
CONNECTIVITY_CHECK_ALLOWED_NODES = (CONNECTIVITY_CHECK_HOSTS.map do |ip|
  { address: ip, port: 80 }
end).freeze

LAN_WEB_SERVER_DATA_DIR = "#{$config['TMPDIR']}/lan-web-server".freeze
