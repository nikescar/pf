package DHCP::Protocol;
use strict;
use warnings;
use Net::DHCP::Packet;
use Net::DHCP::Constants;

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;
    my $self = {
        interface => $args{interface} || 'em0',
        xid       => 0,
        mac       => undef,
        server_id => undef,
    };
    bless $self, $class;

    # Detect MAC address
    $self->{mac} = $self->_detect_mac($self->{interface});

    return $self;
}

sub generate_xid {
    my $self = shift;
    $self->{xid} = int(rand(0xFFFFFFFF));
    return $self->{xid};
}

sub xid {
    my $self = shift;
    return $self->{xid};
}

sub build_discover {
    my $self = shift;

    # Generate new transaction ID
    $self->generate_xid();

    my $discover = Net::DHCP::Packet->new(
        Op     => BOOTREQUEST(),
        Htype  => 1,              # Ethernet
        Hlen   => 6,
        Xid    => $self->{xid},
        Flags  => 0x8000,         # Broadcast flag
        Chaddr => $self->{mac},
        DHO_DHCP_MESSAGE_TYPE() => DHCPDISCOVER(),
        DHO_DHCP_PARAMETER_REQUEST_LIST() => [
            DHO_SUBNET_MASK(),
            DHO_ROUTERS(),
            DHO_DOMAIN_NAME_SERVERS(),
            DHO_BROADCAST_ADDRESS(),
            DHO_DHCP_LEASE_TIME(),
        ],
    );

    return $discover;
}

sub parse_offer {
    my ($self, $packet) = @_;

    return unless $packet;
    return unless $packet->getOptionValue(DHO_DHCP_MESSAGE_TYPE()) == DHCPOFFER();

    # Extract offered configuration
    my $data = {
        ip        => $packet->yiaddr(),
        server_ip => $packet->siaddr(),
        subnet    => $packet->getOptionValue(DHO_SUBNET_MASK()) || '',
        gateway   => $packet->getOptionValue(DHO_ROUTERS()) || '',
        dns       => $packet->getOptionValue(DHO_DOMAIN_NAME_SERVERS()) || '',
        broadcast => $packet->getOptionValue(DHO_BROADCAST_ADDRESS()) || '',
        lease_time => unpack('N', $packet->getOptionValue(DHO_DHCP_LEASE_TIME()) || pack('N', 3600)),
    };

    # Store server identifier for REQUEST
    $self->{server_id} = $packet->siaddr();

    return $data;
}

sub build_request {
    my ($self, $offer_data) = @_;

    my $request = Net::DHCP::Packet->new(
        Op     => BOOTREQUEST(),
        Htype  => 1,
        Hlen   => 6,
        Xid    => $self->{xid},
        Flags  => 0x8000,
        Chaddr => $self->{mac},
        DHO_DHCP_MESSAGE_TYPE() => DHCPREQUEST(),
        DHO_DHCP_REQUESTED_ADDRESS() => $offer_data->{ip},
        DHO_DHCP_SERVER_IDENTIFIER() => $self->{server_id},
    );

    return $request;
}

sub parse_ack {
    my ($self, $packet) = @_;

    return unless $packet;

    my $msg_type = $packet->getOptionValue(DHO_DHCP_MESSAGE_TYPE());

    # Handle NAK
    if ($msg_type == DHCPNAK()) {
        return { type => 'NAK' };
    }

    # Handle ACK
    return unless $msg_type == DHCPACK();

    my $data = {
        type      => 'ACK',
        ip        => $packet->yiaddr(),
        subnet    => $packet->getOptionValue(DHO_SUBNET_MASK()) || '',
        gateway   => $packet->getOptionValue(DHO_ROUTERS()) || '',
        dns       => $packet->getOptionValue(DHO_DOMAIN_NAME_SERVERS()) || '',
        broadcast => $packet->getOptionValue(DHO_BROADCAST_ADDRESS()) || '',
        lease_time => unpack('N', $packet->getOptionValue(DHO_DHCP_LEASE_TIME()) || pack('N', 3600)),
    };

    return $data;
}

sub _detect_mac {
    my ($self, $iface) = @_;

    # Try ifconfig first (OpenBSD/BSD)
    my $ifconfig = `ifconfig $iface 2>/dev/null`;
    if ($ifconfig =~ /lladdr\s+([0-9a-f:]+)/i) {
        my $mac = $1;
        $mac =~ s/://g;  # Remove colons
        return uc($mac);
    }

    # Fallback to hardcoded for testing
    return '001122334455';
}

1;

__END__

=head1 NAME

DHCP::Protocol - DHCP protocol packet handling (DORA process)

=head1 SYNOPSIS

    use DHCP::Protocol;

    my $proto = DHCP::Protocol->new(interface => 'em0');

    # Build DISCOVER
    my $discover = $proto->build_discover();

    # Parse OFFER
    my $offer_data = $proto->parse_offer($offer_packet);

    # Build REQUEST
    my $request = $proto->build_request($offer_data);

    # Parse ACK/NAK
    my $ack_data = $proto->parse_ack($ack_packet);

=head1 DESCRIPTION

Implements DHCP client protocol (RFC 2131) for DORA handshake:
- Discover: Broadcast search for DHCP servers
- Offer: Parse server configuration offers
- Request: Request specific configuration
- Acknowledgment: Parse final lease confirmation or rejection

=head1 METHODS

=over 4

=item new(interface => $if)

Create protocol handler for network interface.

=item generate_xid()

Generate new random transaction ID.

=item xid()

Get current transaction ID.

=item build_discover()

Build DHCP DISCOVER packet.

=item parse_offer($packet)

Parse DHCP OFFER, extract IP/subnet/gateway/DNS/lease.

=item build_request($offer_data)

Build DHCP REQUEST for offered configuration.

=item parse_ack($packet)

Parse DHCP ACK/NAK response.

=back

=head1 AUTHOR

DHCP Client Project

=cut
