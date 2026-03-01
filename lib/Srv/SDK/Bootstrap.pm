package Srv::SDK::Bootstrap;

use strict;
use warnings;

sub read_state_from_bootstrap {
    my ($sdk) = @_;

    return undef if !defined $sdk->{bootstrap_function};

    my $state_json;
    eval {
        $state_json = $sdk->{bootstrap_function}->();
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "failed to get bootstrap state: $err";
        return undef;
    };

    return undef if !defined $state_json || $state_json eq q{};
    return "$state_json";
}

1;
