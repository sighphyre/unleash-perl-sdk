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
    my $impact_metrics;
    eval {
        $metrics_bucket = $sdk->{engine}->get_metrics();
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "send_metrics get_metrics failed: $err";
        $sdk->{_metrics_in_flight} = 0;
        return;
    };

    eval {
        $impact_metrics = $sdk->{engine}->collect_impact_metrics();
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "send_metrics collect_impact_metrics failed: $err";
        $impact_metrics = undef;
    };

    if (!_has_metrics_data($metrics_bucket) && !_has_metrics_data($impact_metrics)) {
        $sdk->{_metrics_in_flight} = 0;
        return;
    }

    my $metrics_request = {
        appName      => $sdk->{app_name},
        instanceId   => $sdk->{instance_id},
        connectionId => $sdk->{connection_id},
        bucket       => $metrics_bucket,
    };
    if (_has_metrics_data($impact_metrics)) {
        $metrics_request->{impactMetrics} = $impact_metrics;
    }

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
                        if (_has_metrics_data($impact_metrics)) {
                            eval { $sdk->{engine}->restore_impact_metrics($impact_metrics); 1; }
                                or do {
                                    my $restore_err = $@ || 'unknown error';
                                    warn "send_metrics restore_impact_metrics failed: $restore_err";
                                };
                        }
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
        if (_has_metrics_data($impact_metrics)) {
            eval { $sdk->{engine}->restore_impact_metrics($impact_metrics); 1; }
                or do {
                    my $restore_err = $@ || 'unknown error';
                    warn "send_metrics restore_impact_metrics failed: $restore_err";
                };
        }
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
