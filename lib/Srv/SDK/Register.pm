package Srv::SDK::Register;

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

    return if $sdk->{_register_in_flight};
    $sdk->{_register_in_flight} = 1;

    my $request = {
        appName         => $sdk->{app_name},
        instanceId      => $sdk->{instance_id},
        connectionId    => $sdk->{connection_id},
        sdkVersion      => $Srv::SDK::SDK_NAME . ':' . $Srv::SDK::VERSION,
        strategies      => $sdk->{supported_strategies},
        started         => $sdk->_utc_now_iso8601(),
        interval        => $sdk->{send_metrics_interval},
        platformName    => 'perl',
        platformVersion => $],
    };

    eval {
        $sdk->{ua}->post(
            $sdk->{register_url} => {
                Authorization => $sdk->{api_key},
                'Content-Type' => 'application/json',
            } => json => $request => sub {
                my ($ua, $tx) = @_;
                eval {
                    my $result = $tx->result;
                    my $status = $result->code || 'unknown';
                    if ($status != 200 && $status != 202) {
                        warn "register request failed with status $status\n";
                    }
                    1;
                } or do {
                    my $err = $@ || 'unknown error';
                    warn "register request failed: $err";
                };

                $sdk->{_register_in_flight} = 0;
                return;
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "register request failed: $err";
        $sdk->{_register_in_flight} = 0;
    };

    return;
}

1;
