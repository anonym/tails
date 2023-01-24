require 'packetfu'
require 'net/dns'

def looks_like_dhcp_packet?(eth_packet, protocol, sport, dport, ip_packet)
  protocol == 'udp' && sport == 68 && dport == 67 &&
    eth_packet.eth_daddr == 'ff:ff:ff:ff:ff:ff' &&
    ip_packet && ip_packet.ip_daddr == '255.255.255.255'
end

def rarp_packet?(packet)
  # Details: https://www.netometer.com/qa/rarp.html#A13
  packet.force_encoding('UTF-8').start_with?(
    "\xFF\xFF\xFF\xFF\xFF\xFFRT\x00\xAC\xDD\xEE\x805\x00\x01\b\x00\x06"
  ) && (packet[19] == "\x03" || packet[19] == "\x04")
end

# Returns the unique edges (based on protocol, source/destination
# address/port) in the graph of all network flows.
# XXX: giving up on a few worst offenders for now
# rubocop:disable Metrics/AbcSize
# rubocop:disable Metrics/BlockLength
# rubocop:disable Metrics/CyclomaticComplexity
# rubocop:disable Metrics/MethodLength
# rubocop:disable Metrics/PerceivedComplexity
def pcap_connections_helper(pcap_file, **opts)
  opts[:ignore_dhcp] = true unless opts.key?(:ignore_dhcp)
  opts[:ignore_arp] = true unless opts.key?(:ignore_arp)
  opts[:ignore_sources] ||= [$vm.vmnet.bridge_mac]
  connections = []
  packets = PacketFu::PcapFile.new.file_to_array(filename: pcap_file)
  packets.each do |p|
    if PacketFu::EthPacket.can_parse?(p)
      eth_packet = PacketFu::EthPacket.parse(p)
    elsif rarp_packet?(p)
      # packetfu cannot parse RARP, see #16825.
      next
    else
      raise FirewallAssertionFailedError,
            'Found something that is not an ethernet packet'
    end
    sport = nil
    dport = nil
    dns_question = []
    if PacketFu::IPv6Packet.can_parse?(p)
      ip_packet = PacketFu::IPv6Packet.parse(p)
      protocol = 'ipv6'
    elsif PacketFu::TCPPacket.can_parse?(p)
      ip_packet = PacketFu::TCPPacket.parse(p)
      protocol = 'tcp'
      sport = ip_packet.tcp_sport
      dport = ip_packet.tcp_dport
    elsif PacketFu::UDPPacket.can_parse?(p)
      ip_packet = PacketFu::UDPPacket.parse(p)
      protocol = 'udp'
      sport = ip_packet.udp_sport
      dport = ip_packet.udp_dport
    elsif PacketFu::ICMPPacket.can_parse?(p)
      ip_packet = PacketFu::ICMPPacket.parse(p)
      protocol = 'icmp'
    elsif PacketFu::IPPacket.can_parse?(p)
      ip_packet = PacketFu::IPPacket.parse(p)
      protocol = 'ip'
    elsif PacketFu::ARPPacket.can_parse?(p)
      ip_packet = PacketFu::ARPPacket.parse(p)
      protocol = 'arp'
    else
      raise FirewallAssertionFailedError,
            'Found something that cannot be parsed'
    end

    next if opts[:ignore_dhcp] &&
            looks_like_dhcp_packet?(eth_packet, protocol,
                                    sport, dport, ip_packet)
    next if opts[:ignore_arp] && protocol == 'arp'
    next if opts[:ignore_sources].include?(eth_packet.eth_saddr)

    if protocol == 'udp' && dport == 53
      begin
        dns_packet = Net::DNS::Packet.parse(PacketFu::Packet.parse(p).payload)
      rescue ArgumentError
        dns_packet = nil
      end
      unless dns_packet.nil? || dns_packet.question.empty?
        dns_question += dns_packet.question.map(&:qName)
      end
    end

    packet_info = {
      mac_saddr:    eth_packet.eth_saddr,
      mac_daddr:    eth_packet.eth_daddr,
      protocol:     protocol,
      sport:        sport,
      dport:        dport,
      dns_question: dns_question,
    }

    begin
      packet_info[:saddr] = ip_packet.ip_saddr
      packet_info[:daddr] = ip_packet.ip_daddr
    rescue NameError
      begin
        packet_info[:saddr] = ip_packet.ipv6_saddr
        packet_info[:daddr] = ip_packet.ipv6_daddr
      rescue NameError
        puts "We were hit by #11508. PacketFu bug? Packet info: #{ip_packet}"
        packet_info[:saddr] = nil
        packet_info[:daddr] = nil
      end
    end
    connections << packet_info
  end
  connections.uniq.map { |p| OpenStruct.new(p) }
end
# rubocop:enable Metrics/AbcSize
# rubocop:enable Metrics/BlockLength
# rubocop:enable Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/PerceivedComplexity

class FirewallAssertionFailedError < Test::Unit::AssertionFailedError
end

# These assertions are made from the perspective of the system under
# testing when it comes to the concepts of "source" and "destination".
def assert_all_connections(pcap_file,
                           message: 'Unexpected connections were made',
                           **opts, &block)
  all = pcap_connections_helper(pcap_file, **opts)
  good = all.select(&block)
  bad = all - good
  return if bad.empty?

  raise FirewallAssertionFailedError,
        "#{message}\n" +
        bad.map { |e| "  #{e}" }.join("\n")
end

def assert_no_connections(pcap_file, **opts, &block)
  assert_all_connections(pcap_file, **opts) { |*args| !block.call(*args) }
end

def assert_no_leaks(pcap_file, allowed_hosts, allowed_dns_queries, **opts)
  assert_all_connections(pcap_file, **opts) do |c|
    allowed_hosts.include?({ address: c.daddr, port: c.dport })
  end

  # yes, we could combine these two checks in a single one, and that would probably be more efficient.
  # However, we're gaining something when it comes to debugging:
  # the line number now tells you *which* check  has failed
  dns_opts = opts.clone
  dns_opts[:message] = 'Unexpected DNS queries were made'
  assert_all_connections(pcap_file, **dns_opts) do |c|
    c.dns_question.all? { |q| allowed_dns_queries.include?(q) }
  end
end

def debug_useless_dns_exceptions(pcap_file, allowed_dns_queries)
  queries_made = Set.new
  pcap_connections_helper(pcap_file).each do |c|
    queries_made += c.dns_question
  end
  queries_allowed = Set.new(allowed_dns_queries)
  useless_dns_exceptions = queries_allowed - queries_made
  unless useless_dns_exceptions.empty?
    info_log("Warning: these queries were allowed but not needed: #{useless_dns_exceptions.to_a}")
  end
end
