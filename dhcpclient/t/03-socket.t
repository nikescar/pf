#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Socket tests require root - skip if not root
if ($> != 0) {
    plan skip_all => 'Socket tests require root privileges (run with doas)';
} else {
    plan tests => 9;
}

use Net::DHCP::Packet;
use Net::DHCP::Constants;

# Test 1: Module loads
BEGIN { use_ok('DHCP::Socket') }

# Test 2: Create socket
my $sock = DHCP::Socket->new(
    interface => 'lo0',  # Use loopback for testing
    timeout   => 5,
);
isa_ok($sock, 'DHCP::Socket', 'Socket object created');

# Test 3: Socket is ready
ok($sock->is_ready(), 'Socket is ready');

# Test 4: Broadcast enabled
ok($sock->has_broadcast(), 'Broadcast flag enabled');

# Test 5: Timeout set
is($sock->timeout(), 5, 'Timeout configured');

# Test 6: Send packet (mock DISCOVER)
my $discover = Net::DHCP::Packet->new(
    Op     => BOOTREQUEST(),
    Htype  => 1,
    Hlen   => 6,
    Xid    => 12345,
    Flags  => 0x8000,
    Chaddr => 'AABBCCDDEEFF',
    DHO_DHCP_MESSAGE_TYPE() => DHCPDISCOVER(),
);

my $sent = $sock->send_packet($discover);
ok($sent, 'Packet sent successfully');

# Test 7: Receive with timeout (should timeout on loopback)
my $packet = $sock->receive_packet(timeout => 1);
ok(!defined($packet) || ref($packet) eq 'Net::DHCP::Packet',
   'Receive returns undef or packet');

# Test 8: Error handling - invalid interface
my $bad_sock = eval { DHCP::Socket->new(interface => 'nonexistent999') };
ok($@, 'Invalid interface produces error');

# Test 9: Close socket
ok($sock->close(), 'Socket closed successfully');

done_testing();
