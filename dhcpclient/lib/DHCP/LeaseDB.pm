package DHCP::LeaseDB;
use strict;
use warnings;
use Storable qw(store retrieve);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;
    my $self = {
        file   => $args{file} || '/var/db/dhclient.leases',
        leases => {},
    };
    bless $self, $class;

    # Load existing leases
    $self->_load_all();

    return $self;
}

sub save_lease {
    my ($self, $lease) = @_;

    return unless $lease && $lease->{interface};

    # Store in memory
    $self->{leases}{$lease->{interface}} = $lease;

    # Persist to disk
    eval {
        store($self->{leases}, $self->{file});
    };

    return $@ ? 0 : 1;
}

sub load_lease {
    my ($self, $interface) = @_;
    return $self->{leases}{$interface};
}

sub is_expired {
    my ($self, $lease) = @_;

    return 1 unless $lease;
    return 1 unless $lease->{acquired_at} && $lease->{lease_time};

    my $expires_at = $lease->{acquired_at} + $lease->{lease_time};
    return time() > $expires_at;
}

sub renewal_time {
    my ($self, $lease) = @_;
    return unless $lease && $lease->{acquired_at} && $lease->{lease_time};

    # T1 = 50% of lease time
    return $lease->{acquired_at} + int($lease->{lease_time} * 0.5);
}

sub rebind_time {
    my ($self, $lease) = @_;
    return unless $lease && $lease->{acquired_at} && $lease->{lease_time};

    # T2 = 87.5% of lease time
    return $lease->{acquired_at} + int($lease->{lease_time} * 0.875);
}

sub delete_lease {
    my ($self, $interface) = @_;
    delete $self->{leases}{$interface};

    eval {
        store($self->{leases}, $self->{file});
    };

    return $@ ? 0 : 1;
}

sub all_leases {
    my $self = shift;
    return values %{$self->{leases}};
}

sub _load_all {
    my $self = shift;

    return unless -f $self->{file};

    eval {
        $self->{leases} = retrieve($self->{file});
    };

    # Reset on load failure
    $self->{leases} = {} if $@;
}

1;

__END__

=head1 NAME

DHCP::LeaseDB - Persistent lease database for DHCP client

=head1 SYNOPSIS

    use DHCP::LeaseDB;

    my $db = DHCP::LeaseDB->new(file => '/var/db/dhclient.leases');

    # Save lease
    $db->save_lease({
        interface   => 'em0',
        ip          => '192.168.1.100',
        subnet      => '255.255.255.0',
        gateway     => '192.168.1.1',
        dns         => '8.8.8.8',
        lease_time  => 3600,
        acquired_at => time(),
    });

    # Load lease
    my $lease = $db->load_lease('em0');

    # Check expiration
    if ($db->is_expired($lease)) {
        print "Lease expired\n";
    }

    # Renewal times
    my $t1 = $db->renewal_time($lease);   # 50%
    my $t2 = $db->rebind_time($lease);    # 87.5%

=head1 DESCRIPTION

Manages persistent storage of DHCP leases using Storable format.
Supports multiple interfaces, expiration checking, and renewal timing.

=head1 METHODS

=over 4

=item new(file => $path)

Create lease database. Loads existing leases from file.

=item save_lease($lease_hashref)

Save lease to database and persist to disk.

=item load_lease($interface)

Load lease for interface.

=item is_expired($lease)

Check if lease has expired.

=item renewal_time($lease)

Calculate T1 renewal time (50% of lease).

=item rebind_time($lease)

Calculate T2 rebind time (87.5% of lease).

=item delete_lease($interface)

Remove lease from database.

=item all_leases()

Return all leases.

=back

=head1 AUTHOR

DHCP Client Project

=cut
