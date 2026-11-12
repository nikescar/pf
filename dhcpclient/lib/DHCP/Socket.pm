package DHCP::Socket;
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Net::DHCP::Packet;

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    my $self = {
        interface => $args{interface} || 'em0',
        timeout   => $args{timeout} || 10,
        socket    => undef,
        select    => undef,
    };
    bless $self, $class;

    # Create UDP socket
    eval {
        $self->{socket} = IO::Socket::INET->new(
            Proto     => 'udp',
            Broadcast => 1,
            LocalPort => 68,        # DHCP client port
            ReuseAddr => 1,
        ) or die "Socket creation failed: $!";

        # Create select for timeout handling
        $self->{select} = IO::Select->new($self->{socket});
    };

    if ($@) {
        die "DHCP::Socket initialization failed: $@\n";
    }

    return $self;
}

sub is_ready {
    my $self = shift;
    return defined($self->{socket}) && $self->{socket}->connected() == 0;
}

sub has_broadcast {
    my $self = shift;
    return 1;  # Always enabled in constructor
}

sub timeout {
    my $self = shift;
    return $self->{timeout};
}

sub send_packet {
    my ($self, $packet) = @_;

    return unless $packet && $self->{socket};

    # Serialize packet
    my $data = $packet->serialize();

    # Send to broadcast address on server port 67
    my $sent = $self->{socket}->send(
        $data,
        0,
        sockaddr_in(67, inet_aton('255.255.255.255'))
    );

    return $sent;
}

sub receive_packet {
    my ($self, %args) = @_;
    my $timeout = $args{timeout} || $self->{timeout};

    return unless $self->{socket};

    # Wait for data with timeout
    my @ready = $self->{select}->can_read($timeout);
    return unless @ready;

    # Receive packet
    my $data;
    my $addr = $self->{socket}->recv($data, 4096);
    return unless $addr && length($data) > 0;

    # Parse DHCP packet
    my $packet = eval { Net::DHCP::Packet->new($data) };
    return $packet;  # undef if parse failed
}

sub close {
    my $self = shift;
    if ($self->{socket}) {
        $self->{socket}->close();
        $self->{socket} = undef;
        return 1;
    }
    return 0;
}

# Import needed for sockaddr_in/inet_aton
use Socket qw(sockaddr_in inet_aton);

sub DESTROY {
    my $self = shift;
    $self->close();
}

1;

__END__

=head1 NAME

DHCP::Socket - UDP socket management for DHCP client

=head1 SYNOPSIS

    use DHCP::Socket;

    my $sock = DHCP::Socket->new(
        interface => 'em0',
        timeout   => 10,
    );

    # Send DHCP packet
    $sock->send_packet($discover_packet);

    # Receive with timeout
    my $packet = $sock->receive_packet(timeout => 5);

    $sock->close();

=head1 DESCRIPTION

Manages UDP socket for DHCP client communication:
- Binds to port 68 (DHCP client port)
- Enables broadcast for DISCOVER packets
- Sends packets to server port 67
- Receives responses with timeout

=head1 METHODS

=over 4

=item new(interface => $if, timeout => $sec)

Create DHCP socket. Dies on failure.

=item is_ready()

Returns true if socket is ready.

=item has_broadcast()

Returns true if broadcast enabled.

=item timeout()

Get configured timeout.

=item send_packet($packet)

Send DHCP packet (Net::DHCP::Packet object).

=item receive_packet(timeout => $sec)

Receive packet with timeout. Returns Net::DHCP::Packet or undef.

=item close()

Close socket.

=back

=head1 AUTHOR

DHCP Client Project

=cut
