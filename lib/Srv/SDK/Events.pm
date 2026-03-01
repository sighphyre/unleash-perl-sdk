package Srv::SDK::Events;

use strict;
use warnings;

sub emit_ready_once {
    my ($sdk) = @_;
    return if $sdk->{_ready_emitted};
    $sdk->{_ready_emitted} = 1;
    $sdk->emit('ready');
    return;
}

sub emit_error {
    my ($sdk, $message) = @_;
    $message = 'unknown fetch error' if !defined $message || $message eq q{};
    warn "$message\n";
    $sdk->emit('error', $message) if $sdk->can('has_subscribers') && $sdk->has_subscribers('error');
    return;
}

sub emit_impression_event {
    my ($sdk, %args) = @_;

    my $feature_name = $args{feature_name};
    return if !defined $feature_name || $feature_name eq q{};

    my $should_emit = 0;
    eval {
        $should_emit = $sdk->{engine}->should_emit_impression_event($feature_name) ? 1 : 0;
        1;
    } or do {
        return;
    };
    return if !$should_emit;

    my %event = (
        featureName => $feature_name,
        context     => $args{context} || {},
        enabled     => $args{enabled} ? 1 : 0,
    );
    $event{variant} = $args{variant} if defined $args{variant};

    $sdk->emit('impression', \%event);
    return;
}

1;
