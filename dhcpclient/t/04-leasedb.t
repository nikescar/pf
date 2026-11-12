#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 12;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);

# Test 1: Module loads
BEGIN { use_ok('DHCP::LeaseDB') }

# Test 2: Create lease database
my ($fh, $tmpfile) = tempfile();
close($fh);

my $db = DHCP::LeaseDB->new(file => $tmpfile);
isa_ok($db, 'DHCP::LeaseDB', 'LeaseDB object created');

# Test 3: Save lease
my $lease = {
    interface   => 'em0',
    ip          => '192.168.1.100',
    subnet      => '255.255.255.0',
    gateway     => '192.168.1.1',
    dns         => '8.8.8.8',
    broadcast   => '192.168.1.255',
    lease_time  => 3600,
    acquired_at => time(),
};

ok($db->save_lease($lease), 'Lease saved successfully');

# Test 4: Load lease
my $loaded = $db->load_lease('em0');
ok($loaded, 'Lease loaded');
is($loaded->{ip}, '192.168.1.100', 'Lease IP correct');
is($loaded->{gateway}, '192.168.1.1', 'Lease gateway correct');

# Test 5: Check lease expiration
ok(!$db->is_expired($loaded), 'Fresh lease not expired');

# Test 6: Expired lease detection
$loaded->{acquired_at} = time() - 7200;  # 2 hours ago
$loaded->{lease_time} = 3600;            # 1 hour lease
ok($db->is_expired($loaded), 'Old lease detected as expired');

# Test 7: Renewal time calculation (T1 = 50%)
my $renew_time = $db->renewal_time($lease);
is($renew_time, $lease->{acquired_at} + 1800, 'Renewal time at 50%');

# Test 8: Rebind time calculation (T2 = 87.5%)
my $rebind_time = $db->rebind_time($lease);
is($rebind_time, $lease->{acquired_at} + 3150, 'Rebind time at 87.5%');

# Test 9: Multiple interface support
my $lease2 = { %$lease, interface => 'em1', ip => '192.168.2.100' };
ok($db->save_lease($lease2), 'Second interface lease saved');

my $em1_lease = $db->load_lease('em1');
is($em1_lease->{ip}, '192.168.2.100', 'Interface isolation works');

# Cleanup
unlink($tmpfile);

done_testing();
