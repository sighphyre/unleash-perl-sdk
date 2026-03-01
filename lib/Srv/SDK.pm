package Srv::SDK;

use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Basename qw(dirname);
use File::Spec;

our $VERSION = '0.01';

BEGIN {
    if (!eval { require Yggdrasil::Engine; 1 }) {
        my $project_root = File::Spec->catdir(dirname(__FILE__), '..', '..');
        my $fallback_lib = File::Spec->catdir(
            $project_root, '..', '..', 'yggdrasil-bindings', 'perl-engine', 'lib'
        );

        push @INC, $fallback_lib if -d $fallback_lib;
        require Yggdrasil::Engine;
    }
}

sub new {
    my ($class, %args) = @_;

    require Mojo::IOLoop;

    my $polling_interval = $args{polling_interval};
    $polling_interval = 15 if !defined $polling_interval;
    die 'polling_interval must be a positive number' if $polling_interval <= 0;

    my $self = bless {
        engine           => Yggdrasil::Engine->new(),
        polling_interval => $polling_interval + 0,

        _poll_timer_id   => undef,

        _poll_in_flight  => 0,

        poller_running   => 0,
    }, $class;

    return $self;
}

sub is_enabled {
    my ($self, $toggle_name, $context, $fallback) = @_;

    die 'toggle_name is required' if !defined $toggle_name || $toggle_name eq q{};
    die 'fallback must be a coderef' if defined $fallback && ref($fallback) ne 'CODE';

    my $enabled = $self->{engine}->is_enabled($toggle_name, $context || {});

    if (!defined $enabled) {
        return $fallback ? ($fallback->() ? 1 : 0) : 0;
    }

    return $enabled ? 1 : 0;
}

sub initialize {
    my ($self) = @_;

    return if $self->{poller_running};

    my $interval = $self->{polling_interval};

    $self->{_poll_timer_id} = Mojo::IOLoop->recurring(
        $interval => sub { $self->_poll_once }
    );

    $self->{poller_running} = 1;
    return $self->{_poll_timer_id};
}

sub shutdown {
    my ($self) = @_;

    return if !$self->{poller_running};

    if (defined $self->{_poll_timer_id}) {
        Mojo::IOLoop->remove($self->{_poll_timer_id});
        $self->{_poll_timer_id} = undef;
    }

    $self->{poller_running}  = 0;
    $self->{_poll_in_flight} = 0;

    return;
}

sub DESTROY {
    my ($self) = @_;
    $self->shutdown();
    return;
}

sub _poll_once {
    my ($self) = @_;

    return if $self->{_poll_in_flight};
    $self->{_poll_in_flight} = 1;

    print "hello\n";

    $self->{_poll_in_flight} = 0;

    return;
}

1;