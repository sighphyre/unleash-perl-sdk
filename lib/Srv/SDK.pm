package Srv::SDK;

use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Basename qw(dirname);
use File::Spec;
use Srv::Scheduler;

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

    my $polling_interval = $args{polling_interval};
    $polling_interval = 15 if !defined $polling_interval;
    die 'polling_interval must be a positive number' if $polling_interval <= 0;

    my $self = bless {
        engine                  => Yggdrasil::Engine->new(),
        polling_interval        => $polling_interval + 0,
        fetch_features_scheduler => undef,
        send_metrics_scheduler   => undef,
        _fetch_in_flight         => 0,
        _metrics_in_flight       => 0,
        poller_running           => 0,
    }, $class;

    $self->{fetch_features_scheduler} = Srv::Scheduler->new(
        interval => $self->{polling_interval},
        task     => sub { $self->_fetch_features_once() },
    );
    $self->{send_metrics_scheduler} = Srv::Scheduler->new(
        interval => $self->{polling_interval},
        task     => sub { $self->_send_metrics_once() },
    );

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

    my $fetch_timer_id = $self->{fetch_features_scheduler}->start();
    my $metrics_timer_id = $self->{send_metrics_scheduler}->start();

    $self->{poller_running} = 1;
    return {
        fetch_features => $fetch_timer_id,
        send_metrics   => $metrics_timer_id,
    };
}

sub shutdown {
    my ($self) = @_;

    return if !$self->{poller_running};

    $self->{fetch_features_scheduler}->stop();
    $self->{send_metrics_scheduler}->stop();

    $self->{poller_running}   = 0;
    $self->{_fetch_in_flight} = 0;
    $self->{_metrics_in_flight} = 0;

    return;
}

sub DESTROY {
    my ($self) = @_;
    $self->shutdown();
    return;
}

sub _fetch_features_once {
    my ($self) = @_;

    return if $self->{_fetch_in_flight};
    $self->{_fetch_in_flight} = 1;

    print "fetch_features\n";

    $self->{_fetch_in_flight} = 0;
    return;
}

sub _send_metrics_once {
    my ($self) = @_;

    return if $self->{_metrics_in_flight};
    $self->{_metrics_in_flight} = 1;

    print "send_metrics\n";

    $self->{_metrics_in_flight} = 0;

    return;
}

1;
