#!/usr/bin/env perl
# Example: Programmatic DHCP client usage
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";

use DHCP::StateMachine;
use DHCP::Protocol;
use DHCP::LeaseDB;

print "DHCP Client Library Example\n";
print "=" x 50, "\n\n";

# Example 1: State Machine
print "1. State Machine Example:\n";
my $sm = DHCP::StateMachine->new();
print "   Initial state: ", $sm->state(), "\n";

$sm->transition_to('DISCOVER');
print "   After transition: ", $sm->state(), "\n";

# Invalid transition
my $result = $sm->transition_to('RENEW');
print "   Invalid transition OFFER->RENEW: ", ($result ? "allowed" : "blocked"), "\n\n";

# Example 2: Protocol Packet Building
print "2. Protocol Example:\n";
my $proto = DHCP::Protocol->new(interface => 'em0');
my $xid = $proto->generate_xid();
print "   Transaction ID: $xid\n";

my $discover = $proto->build_discover();
print "   DISCOVER packet created: ", ref($discover), "\n";
print "   Packet length: ", length($discover->serialize()), " bytes\n\n";

# Example 3: Lease Database
print "3. Lease Database Example:\n";
my $db = DHCP::LeaseDB->new(file => '/tmp/example-dhcp.leases');

my $lease = {
    interface   => 'em0',
    ip          => '192.168.1.100',
    subnet      => '255.255.255.0',
    gateway     => '192.168.1.1',
    dns         => '8.8.8.8 8.8.4.4',
    broadcast   => '192.168.1.255',
    lease_time  => 3600,
    acquired_at => time(),
};

$db->save_lease($lease);
print "   Lease saved: $lease->{ip}\n";

my $loaded = $db->load_lease('em0');
print "   Lease loaded: $loaded->{ip}\n";
print "   Gateway: $loaded->{gateway}\n";
print "   DNS: $loaded->{dns}\n";

my $t1 = $db->renewal_time($lease);
my $t2 = $db->rebind_time($lease);
print "   Renewal time (T1): ", scalar localtime($t1), "\n";
print "   Rebind time (T2):  ", scalar localtime($t2), "\n";

my $expired = $db->is_expired($lease);
print "   Is expired: ", ($expired ? "yes" : "no"), "\n\n";

# Example 4: Full DORA simulation (without network)
print "4. DORA State Flow Simulation:\n";
$sm->reset();

my @states = qw(DISCOVER OFFER REQUEST BOUND);
foreach my $state (@states) {
    if ($sm->transition_to($state)) {
        print "   ✓ $state\n";
    } else {
        print "   ✗ $state (invalid)\n";
    }
}

print "\nExample complete! See README.md for full usage.\n";

# Cleanup
unlink('/tmp/example-dhcp.leases');
