package Srv::SDK::SendMetrics;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $sdk = $args{sdk};
    die 'sdk is required' if !defined $sdk;
    return bless { sdk => $sdk }, $class;
}

sub run {
    my ($self) = @_;
    my $sdk = $self->{sdk};

    return if $sdk->{_metrics_in_flight};
    $sdk->{_metrics_in_flight} = 1;

    my $metrics_bucket;
    eval {
        $metrics_bucket = $sdk->{engine}->get_metrics();
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "send_metrics get_metrics failed: $err";
        $sdk->{_metrics_in_flight} = 0;
        return;
    };

    if (!_has_metrics_data($metrics_bucket)) {
        $sdk->{_metrics_in_flight} = 0;
        return;
    }

    my $metrics_request = {
        appName      => $sdk->{app_name},
        instanceId   => $sdk->{instance_id},
        connectionId => $sdk->{connection_id},
        bucket       => $metrics_bucket,
    };

    eval {
        $sdk->{ua}->post(
            $sdk->{metrics_url} => {
                Authorization => $sdk->{api_key},
                'Content-Type' => 'application/json',
            } => json => $metrics_request => sub {
                my ($ua, $tx) = @_;
                eval {
                    my $result = $tx->result;
                    if (!$result->is_success) {
                        my $status = $result->code || 'unknown';
                        warn "send_metrics request failed with status $status\n";
                    }
                    1;
                } or do {
                    my $err = $@ || 'unknown error';
                    warn "send_metrics request failed: $err";
                };

                $sdk->{_metrics_in_flight} = 0;
                return;
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "send_metrics request failed: $err";
        $sdk->{_metrics_in_flight} = 0;
    };

    return;
}

sub _has_metrics_data {
    my ($value) = @_;

    return 0 if !defined $value;
    if (ref($value) eq 'HASH') {
        return scalar keys %{$value} ? 1 : 0;
    }
    if (ref($value) eq 'ARRAY') {
        return scalar @{$value} ? 1 : 0;
    }
    return $value ? 1 : 0;
}

1;
