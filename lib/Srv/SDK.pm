package Srv::SDK;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use POSIX qw(strftime);
use Srv::Scheduler;

our $VERSION = '0.01';
our $SDK_NAME = 'unleash-perl-sdk';

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

    my $unleash_url = $args{unleash_url};
    die 'unleash_url is required' if !defined $unleash_url || $unleash_url eq q{};

    my $api_key = $args{api_key};
    die 'api_key is required' if !defined $api_key || $api_key eq q{};
    die 'connection_id cannot be set by caller' if exists $args{connection_id};

    my $polling_interval = $args{polling_interval};
    $polling_interval = 15 if !defined $polling_interval;
    die 'polling_interval must be a positive number' if $polling_interval <= 0;

    my $fetch_features_interval = $args{fetch_features_interval};
    $fetch_features_interval = $polling_interval if !defined $fetch_features_interval;
    die 'fetch_features_interval must be a non-negative number' if $fetch_features_interval < 0;

    my $send_metrics_interval = $args{send_metrics_interval};
    $send_metrics_interval = $polling_interval if !defined $send_metrics_interval;
    die 'send_metrics_interval must be a non-negative number' if $send_metrics_interval < 0;
    my $app_name = $args{app_name};
    $app_name = 'unleash-perl-app' if !defined $app_name || $app_name eq q{};
    my $instance_id = $args{instance_id};
    $instance_id = _generate_uuid() if !defined $instance_id || $instance_id eq q{};
    my $state_backup_dir = $args{state_backup_dir};
    $state_backup_dir = '/tmp' if !defined $state_backup_dir || $state_backup_dir eq q{};
    my $supported_strategies = $args{supported_strategies};
    $supported_strategies = [] if !defined $supported_strategies;
    if (ref($supported_strategies) eq 'HASH') {
        $supported_strategies = [ sort keys %{$supported_strategies} ];
    }
    die 'supported_strategies must be an arrayref or hashref'
        if ref($supported_strategies) ne 'ARRAY';

    require Mojo::UserAgent;

    my $self = bless {
        engine                   => $args{engine} || Yggdrasil::Engine->new(),
        polling_interval         => $polling_interval + 0,
        fetch_features_interval  => $fetch_features_interval + 0,
        send_metrics_interval    => $send_metrics_interval + 0,
        unleash_url              => $unleash_url,
        api_key                  => $api_key,
        app_name                 => $app_name,
        instance_id              => $instance_id,
        connection_id            => _generate_uuid(),
        state_backup_dir         => $state_backup_dir,
        state_backup_file        => _build_state_backup_file($state_backup_dir, $app_name),
        supported_strategies     => $supported_strategies,
        features_url             => _build_features_url($unleash_url),
        metrics_url              => _build_metrics_url($unleash_url),
        register_url             => _build_register_url($unleash_url),
        ua                       => $args{ua} || Mojo::UserAgent->new(),
        etag                     => undef,
        fetch_features_scheduler => undef,
        send_metrics_scheduler   => undef,
        _fetch_in_flight         => 0,
        _metrics_in_flight       => 0,
        _register_in_flight      => 0,
        poller_running           => 0,
    }, $class;

    if ($self->{fetch_features_interval} > 0) {
        $self->{fetch_features_scheduler} = Srv::Scheduler->new(
            name     => 'fetch_features',
            interval => $self->{fetch_features_interval},
            task     => sub { $self->_fetch_features_once() },
        );
    }
    if ($self->{send_metrics_interval} > 0) {
        $self->{send_metrics_scheduler} = Srv::Scheduler->new(
            name     => 'send_metrics',
            interval => $self->{send_metrics_interval},
            task     => sub { $self->_send_metrics_once() },
        );
    }

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

    my $enabled_bool = $enabled ? 1 : 0;
    $self->{engine}->count_toggle($toggle_name, $enabled_bool);

    return $enabled_bool;
}

sub initialize {
    my ($self) = @_;

    return if $self->{poller_running};
    require Mojo::IOLoop;

    my $fetch_timer_id;
    my $metrics_timer_id;

    if ($self->{fetch_features_scheduler}) {
        $fetch_timer_id = $self->{fetch_features_scheduler}->start();
        Mojo::IOLoop->next_tick(sub { $self->_fetch_features_once() });
    }
    if ($self->{send_metrics_scheduler}) {
        $metrics_timer_id = $self->{send_metrics_scheduler}->start();
    }
    Mojo::IOLoop->next_tick(sub { $self->_register_client_once() });

    $self->{poller_running} = 1;
    return {
        fetch_features => $fetch_timer_id,
        send_metrics   => $metrics_timer_id,
    };
}

sub shutdown {
    my ($self) = @_;

    return if !$self->{poller_running};

    $self->{fetch_features_scheduler}->stop() if $self->{fetch_features_scheduler};
    $self->{send_metrics_scheduler}->stop() if $self->{send_metrics_scheduler};

    $self->{poller_running}   = 0;
    $self->{_fetch_in_flight} = 0;
    $self->{_metrics_in_flight} = 0;
    $self->{_register_in_flight} = 0;

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

    eval {
        my %headers = (
            Authorization => $self->{api_key},
        );
        if (defined $self->{etag} && $self->{etag} ne q{}) {
            $headers{'If-None-Match'} = $self->{etag};
        }

        $self->{ua}->get(
            $self->{features_url} => \%headers => sub {
                my ($ua, $tx) = @_;
                eval {
                    my $result = $tx->result;
                    my $status = $result->code || 'unknown';

                    if ($status == 304) {
                        # State unchanged.
                    } elsif (!$result->is_success) {
                        warn "fetch_features request failed with status $status\n";
                    } else {
                        my $new_etag = $result->headers->header('ETag');
                        $self->{etag} = $new_etag if defined $new_etag && $new_etag ne q{};
                        my $state_json = $result->body;
                        $state_json = q{} if !defined $state_json;
                        $self->{engine}->take_state("$state_json");
                        $self->_backup_state_json("$state_json");
                    }
                    1;
                } or do {
                    my $err = $@ || 'unknown error';
                    warn "fetch_features request failed: $err";
                };

                $self->{_fetch_in_flight} = 0;
                return;
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "fetch_features request failed: $err";
        $self->{_fetch_in_flight} = 0;
    };

    return;
}

sub _send_metrics_once {
    my ($self) = @_;

    return if $self->{_metrics_in_flight};
    $self->{_metrics_in_flight} = 1;

    my $metrics_bucket;
    eval {
        $metrics_bucket = $self->{engine}->get_metrics();
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "send_metrics get_metrics failed: $err";
        $self->{_metrics_in_flight} = 0;
        return;
    };

    if (!_has_metrics_data($metrics_bucket)) {
        $self->{_metrics_in_flight} = 0;
        return;
    }

    my $metrics_request = {
        appName      => $self->{app_name},
        instanceId   => $self->{instance_id},
        connectionId => $self->{connection_id},
        bucket       => $metrics_bucket,
    };

    eval {
        $self->{ua}->post(
            $self->{metrics_url} => {
                Authorization => $self->{api_key},
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

                $self->{_metrics_in_flight} = 0;
                return;
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "send_metrics request failed: $err";
        $self->{_metrics_in_flight} = 0;
    };

    return;
}

sub _register_client_once {
    my ($self) = @_;

    return if $self->{_register_in_flight};
    $self->{_register_in_flight} = 1;

    my $request = {
        appName        => $self->{app_name},
        instanceId     => $self->{instance_id},
        connectionId   => $self->{connection_id},
        sdkVersion     => $SDK_NAME . ':' . $VERSION,
        strategies     => $self->{supported_strategies},
        started        => _utc_now_iso8601(),
        interval       => $self->{send_metrics_interval},
        platformName   => 'perl',
        platformVersion => $],
    };

    eval {
        $self->{ua}->post(
            $self->{register_url} => {
                Authorization => $self->{api_key},
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

                $self->{_register_in_flight} = 0;
                return;
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "register request failed: $err";
        $self->{_register_in_flight} = 0;
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

sub _build_metrics_url {
    my ($unleash_url) = @_;

    $unleash_url =~ s{/$}{};
    return $unleash_url . '/client/metrics';
}

sub _build_register_url {
    my ($unleash_url) = @_;

    $unleash_url =~ s{/$}{};
    return $unleash_url . '/client/register';
}

sub _utc_now_iso8601 {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

sub _build_state_backup_file {
    my ($dir, $app_name) = @_;
    my $safe_app_name = $app_name;
    $safe_app_name =~ s{[^A-Za-z0-9._-]}{_}g;
    return File::Spec->catfile($dir, $safe_app_name . '-perl-sdk.json');
}

sub _backup_state_json {
    my ($self, $state_json) = @_;

    my $path = $self->{state_backup_file};
    my $dir = $self->{state_backup_dir};

    if (!-d $dir) {
        warn "state backup directory does not exist: $dir\n";
        return;
    }

    my $fh;
    if (!open $fh, '>', $path) {
        warn "failed to write state backup file $path: $!\n";
        return;
    }

    print {$fh} $state_json;
    close $fh;
    return;
}

sub _generate_uuid {
    my @bytes = map { int(rand(256)) } 1..16;
    $bytes[6] = ($bytes[6] & 0x0f) | 0x40;
    $bytes[8] = ($bytes[8] & 0x3f) | 0x80;

    return sprintf(
        '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x',
        @bytes
    );
}

sub _build_features_url {
    my ($unleash_url) = @_;

    $unleash_url =~ s{/$}{};
    return $unleash_url . '/client/features';
}

1;
