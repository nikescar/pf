package DHCP::StateMachine;
use strict;
use warnings;

# DHCP client state machine
# States: INIT -> DISCOVER -> OFFER -> REQUEST -> BOUND -> RENEW -> REBIND
# Fallback: Any state can transition to INIT on error

our $VERSION = '0.01';

# Valid state transitions
my %TRANSITIONS = (
    INIT     => ['DISCOVER'],
    DISCOVER => ['OFFER', 'INIT'],
    OFFER    => ['REQUEST', 'INIT'],
    REQUEST  => ['BOUND', 'INIT'],
    BOUND    => ['RENEW', 'REBIND', 'INIT'],
    RENEW    => ['BOUND', 'REBIND', 'INIT'],
    REBIND   => ['BOUND', 'INIT'],
);

sub new {
    my $class = shift;
    my $self = {
        state   => 'INIT',
        timeout => 0,
        history => [],
    };
    return bless $self, $class;
}

sub state {
    my $self = shift;
    return $self->{state};
}

sub transition_to {
    my ($self, $new_state) = @_;

    # Check if transition is valid
    my $current = $self->{state};
    my $valid_next = $TRANSITIONS{$current};

    return 0 unless $valid_next;
    return 0 unless grep { $_ eq $new_state } @$valid_next;

    # Record transition
    push @{$self->{history}}, {
        from => $current,
        to   => $new_state,
        time => time(),
    };

    $self->{state} = $new_state;
    return 1;
}

sub set_timeout {
    my ($self, $timeout) = @_;
    $self->{timeout} = $timeout;
}

sub timeout {
    my $self = shift;
    return $self->{timeout};
}

sub reset {
    my $self = shift;
    $self->{state} = 'INIT';
    $self->{timeout} = 0;
    $self->{history} = [];
}

sub history {
    my $self = shift;
    return @{$self->{history}};
}

1;

__END__

=head1 NAME

DHCP::StateMachine - State machine for DHCP client protocol

=head1 SYNOPSIS

    use DHCP::StateMachine;

    my $sm = DHCP::StateMachine->new();
    $sm->transition_to('DISCOVER');
    print "Current state: ", $sm->state(), "\n";

=head1 DESCRIPTION

Manages DHCP client state transitions according to RFC 2131.

Valid states: INIT, DISCOVER, OFFER, REQUEST, BOUND, RENEW, REBIND

=head1 METHODS

=over 4

=item new()

Create new state machine starting in INIT state.

=item state()

Return current state.

=item transition_to($state)

Attempt state transition. Returns 1 on success, 0 if invalid.

=item set_timeout($seconds)

Set timeout for current state.

=item timeout()

Get current timeout value.

=item reset()

Reset to INIT state, clearing history.

=item history()

Return list of state transitions.

=back

=head1 AUTHOR

DHCP Client Project

=cut
