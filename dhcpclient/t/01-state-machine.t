#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 10;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Test 1: Module loads
BEGIN { use_ok('DHCP::StateMachine') }

# Test 2: Create new state machine
my $sm = DHCP::StateMachine->new();
isa_ok($sm, 'DHCP::StateMachine', 'StateMachine object created');

# Test 3: Initial state is INIT
is($sm->state(), 'INIT', 'Initial state is INIT');

# Test 4: Valid state transition INIT -> DISCOVER
ok($sm->transition_to('DISCOVER'), 'Transition INIT -> DISCOVER succeeds');
is($sm->state(), 'DISCOVER', 'State is now DISCOVER');

# Test 5: Valid state transition DISCOVER -> OFFER
ok($sm->transition_to('OFFER'), 'Transition DISCOVER -> OFFER succeeds');
is($sm->state(), 'OFFER', 'State is now OFFER');

# Test 6: Invalid state transition should fail
ok(!$sm->transition_to('RENEW'), 'Invalid transition OFFER -> RENEW fails');
is($sm->state(), 'OFFER', 'State unchanged after invalid transition');

# Test 7: State timeout tracking
$sm->set_timeout(30);
is($sm->timeout(), 30, 'Timeout set correctly');

done_testing();
