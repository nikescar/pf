#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 14;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Net::DHCP::Packet;
use Net::DHCP::Constants;

# Test 1: Module loads
BEGIN { use_ok('DHCP::Protocol') }

# Test 2: Create protocol handler
my $proto = DHCP::Protocol->new(interface => 'em0');
isa_ok($proto, 'DHCP::Protocol', 'Protocol object created');

# Test 3: Generate transaction ID
my $xid1 = $proto->generate_xid();
ok($xid1 > 0 && $xid1 <= 0xFFFFFFFF, 'Transaction ID in valid range');

my $xid2 = $proto->generate_xid();
isnt($xid1, $xid2, 'Transaction IDs are unique');

# Test 4: Build DISCOVER packet
my $discover = $proto->build_discover();
isa_ok($discover, 'Net::DHCP::Packet', 'DISCOVER packet created');
is($discover->op(), BOOTREQUEST(), 'DISCOVER has BOOTREQUEST op');
is($discover->getOptionValue(DHO_DHCP_MESSAGE_TYPE()), DHCPDISCOVER(), 'DISCOVER message type correct');
ok($discover->flags() & 0x8000, 'Broadcast flag set in DISCOVER');

# Test 5: Parse OFFER packet (mock)
my $offer_pkt = Net::DHCP::Packet->new(
    Op     => BOOTREPLY(),
    Xid    => $proto->xid(),
    Yiaddr => '192.168.1.100',
    Siaddr => '192.168.1.1',
    Chaddr => 'AABBCCDDEEFF',
    DHO_DHCP_MESSAGE_TYPE() => DHCPOFFER(),
    DHO_SUBNET_MASK()       => '255.255.255.0',
    DHO_ROUTERS()           => '192.168.1.1',
    DHO_DOMAIN_NAME_SERVERS() => '8.8.8.8',
    DHO_DHCP_LEASE_TIME()   => pack('N', 3600),
);

my $offer_data = $proto->parse_offer($offer_pkt);
ok($offer_data, 'OFFER parsed successfully');
is($offer_data->{ip}, '192.168.1.100', 'OFFER IP extracted');
is($offer_data->{subnet}, '255.255.255.0', 'OFFER subnet extracted');
is($offer_data->{gateway}, '192.168.1.1', 'OFFER gateway extracted');

# Test 6: Build REQUEST packet
my $request = $proto->build_request($offer_data);
isa_ok($request, 'Net::DHCP::Packet', 'REQUEST packet created');
is($request->getOptionValue(DHO_DHCP_MESSAGE_TYPE()), DHCPREQUEST(), 'REQUEST message type correct');

done_testing();
