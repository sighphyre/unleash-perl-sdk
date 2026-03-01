package Srv::SDK;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use POSIX qw(strftime);
use Mojo::Promise;
use Mojo::IOLoop;
use Srv::Scheduler;
use Srv::SDK::FetchFeatures;
use Srv::SDK::SendMetrics;
use Srv::SDK::Register;

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
    my $bootstrap_function = $args{bootstrap_function};
    die 'bootstrap_function must be a coderef'
        if defined $bootstrap_function && ref($bootstrap_function) ne 'CODE';
    my $custom_strategies = $args{custom_strategies};
    $custom_strategies = {} if !defined $custom_strategies;
    die 'custom_strategies must be a hash reference'
        if ref($custom_strategies) ne 'HASH';

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
        bootstrap_function       => $bootstrap_function,
        custom_strategies        => $custom_strategies,
        supported_strategies     => $supported_strategies,
        features_url             => _build_features_url($unleash_url),
        metrics_url              => _build_metrics_url($unleash_url),
        register_url             => _build_register_url($unleash_url),
        ua                       => $args{ua} || Mojo::UserAgent->new(),
        etag                     => undef,
        fetch_features_scheduler => undef,
        send_metrics_scheduler   => undef,
        fetch_features_task      => undef,
        send_metrics_task        => undef,
        register_task            => undef,
        _fetch_in_flight         => 0,
        _metrics_in_flight       => 0,
        _register_in_flight      => 0,
        _startup_hydration_started => 0,
        _startup_winner          => undef,
        poller_running           => 0,
    }, $class;

    $self->{fetch_features_task} = Srv::SDK::FetchFeatures->new(sdk => $self);
    $self->{send_metrics_task} = Srv::SDK::SendMetrics->new(sdk => $self);
    $self->{register_task} = Srv::SDK::Register->new(sdk => $self);
    $self->{engine}->register_custom_strategies($self->{custom_strategies});

    if ($self->{fetch_features_interval} > 0) {
        $self->{fetch_features_scheduler} = Srv::Scheduler->new(
            name     => 'fetch_features',
            interval => $self->{fetch_features_interval},
            task     => sub { $self->{fetch_features_task}->run() },
        );
    }
    if ($self->{send_metrics_interval} > 0) {
        $self->{send_metrics_scheduler} = Srv::Scheduler->new(
            name     => 'send_metrics',
            interval => $self->{send_metrics_interval},
            task     => sub { $self->{send_metrics_task}->run() },
        );
    }

    return $self;
}

sub is_enabled {
    my ($self, $toggle_name, $context, $fallback) = @_;

    die 'toggle_name is required' if !defined $toggle_name || $toggle_name eq q{};
    die 'fallback must be a coderef' if defined $fallback && ref($fallback) ne 'CODE';

    my $enabled = $self->_is_enabled_raw($toggle_name, $context);

    if (!defined $enabled) {
        return $fallback ? ($fallback->() ? 1 : 0) : 0;
    }

    my $enabled_bool = $enabled ? 1 : 0;
    $self->{engine}->count_toggle($toggle_name, $enabled_bool);

    return $enabled_bool;
}

sub get_variant {
    my ($self, $toggle_name, $context, $fallback) = @_;

    die 'toggle_name is required' if !defined $toggle_name || $toggle_name eq q{};
    die 'fallback must be a coderef' if defined $fallback && ref($fallback) ne 'CODE';

    my $variant = $self->{engine}->get_variant($toggle_name, $context || {});

    if (defined $variant) {
        my $feature_enabled = _variant_feature_enabled($variant);
        my $variant_name = _variant_name($variant);
        $self->{engine}->count_toggle($toggle_name, $feature_enabled);
        $self->{engine}->count_variant($toggle_name, $variant_name);
        return $variant;
    }

    my $enabled = $self->_is_enabled_raw($toggle_name, $context);
    my $feature_enabled = defined $enabled ? ($enabled ? 1 : 0) : 0;
    my $resolved_variant = $fallback
        ? $fallback->()
        : {
            name           => 'disabled',
            payload        => undef,
            enabled        => 0,
            featureEnabled => $feature_enabled,
        };

    my $variant_name = _variant_name($resolved_variant);
    if (defined $enabled) {
        $self->{engine}->count_toggle($toggle_name, $feature_enabled);
    }
    $self->{engine}->count_variant($toggle_name, $variant_name);

    return $resolved_variant;
}

sub initialize {
    my ($self) = @_;

    return if $self->{poller_running};
    require Mojo::IOLoop;

    my $fetch_timer_id;
    my $metrics_timer_id;

    $self->_start_startup_hydration();

    if ($self->{fetch_features_scheduler}) {
        $fetch_timer_id = $self->{fetch_features_scheduler}->start();
    }
    if ($self->{send_metrics_scheduler}) {
        $metrics_timer_id = $self->{send_metrics_scheduler}->start();
    }
    Mojo::IOLoop->next_tick(sub { $self->{register_task}->run() });

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
    return $self->{fetch_features_task}->run();
}

sub _send_metrics_once {
    my ($self) = @_;
    return $self->{send_metrics_task}->run();
}

sub _register_client_once {
    my ($self) = @_;
    return $self->{register_task}->run();
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

sub _read_state_from_backup {
    my ($self) = @_;

    my $path = $self->{state_backup_file};
    return undef if !-f $path;

    my $fh;
    if (!open $fh, '<', $path) {
        warn "failed to read state backup file $path: $!\n";
        return undef;
    }

    my $state_json = do { local $/; <$fh> };
    close $fh;
    return undef if !defined $state_json || $state_json eq q{};

    return "$state_json";
}

sub _read_state_from_bootstrap {
    my ($self) = @_;

    return undef if !defined $self->{bootstrap_function};

    my $state_json;
    eval {
        $state_json = $self->{bootstrap_function}->();
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "failed to get bootstrap state: $err";
        return undef;
    };

    return undef if !defined $state_json || $state_json eq q{};
    return "$state_json";
}

sub _start_startup_hydration {
    my ($self) = @_;

    return if $self->{_startup_hydration_started};
    $self->{_startup_hydration_started} = 1;

    my $http_p = $self->{fetch_features_task}->fetch_state_p();
    my $bootstrap_p = Mojo::Promise->new;
    my $backup_p = Mojo::Promise->new;

    Mojo::IOLoop->next_tick(sub { $bootstrap_p->resolve($self->_read_state_from_bootstrap()) });
    Mojo::IOLoop->next_tick(sub { $backup_p->resolve($self->_read_state_from_backup()) });

    $http_p->then(sub {
        my ($res) = @_;
        return if ref($res) ne 'HASH';
        return if ($res->{status} || 0) != 200;
        my $state_json = $res->{state_json};
        return if !defined $state_json || $state_json eq q{};

        # HTTP wins if it is first, but also supersedes backup/bootstrap when they won first.
        $self->{_startup_winner} = 'http' if !defined $self->{_startup_winner};
        $self->{etag} = $res->{etag} if defined $res->{etag} && $res->{etag} ne q{};

        $self->{engine}->take_state("$state_json");
        $self->_backup_state_json("$state_json");
        $self->{_startup_winner} = 'http';
        return;
    })->catch(sub {
        my ($err) = @_;
        warn "startup http hydration failed: $err\n";
    });

    $bootstrap_p->then(sub {
        my ($state_json) = @_;
        return if !defined $state_json || $state_json eq q{};
        return if defined $self->{_startup_winner} && $self->{_startup_winner} eq 'http';
        return if defined $self->{_startup_winner} && $self->{_startup_winner} eq 'bootstrap';

        # Bootstrap first discards backup, but HTTP still continues.
        $self->{engine}->take_state("$state_json");
        $self->{_startup_winner} = 'bootstrap';
        return;
    })->catch(sub {
        my ($err) = @_;
        warn "startup bootstrap hydration failed: $err\n";
    });

    $backup_p->then(sub {
        my ($state_json) = @_;
        return if !defined $state_json || $state_json eq q{};
        return if defined $self->{_startup_winner} && $self->{_startup_winner} eq 'http';
        return if defined $self->{_startup_winner} && $self->{_startup_winner} eq 'bootstrap';
        return if defined $self->{_startup_winner} && $self->{_startup_winner} eq 'backup';

        # Backup first hydrates, then bootstrap/http may still update later.
        $self->{engine}->take_state("$state_json");
        $self->{_startup_winner} = 'backup';
        return;
    })->catch(sub {
        my ($err) = @_;
        warn "startup backup hydration failed: $err\n";
    });

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

sub _is_enabled_raw {
    my ($self, $toggle_name, $context) = @_;
    return $self->{engine}->is_enabled($toggle_name, $context || {});
}

sub _variant_name {
    my ($variant) = @_;

    if (ref($variant) eq 'HASH' && defined $variant->{name} && $variant->{name} ne q{}) {
        return $variant->{name};
    }

    return 'disabled';
}

sub _variant_feature_enabled {
    my ($variant) = @_;

    return 0 if ref($variant) ne 'HASH';
    if (exists $variant->{featureEnabled}) {
        return $variant->{featureEnabled} ? 1 : 0;
    }
    if (exists $variant->{feature_enabled}) {
        return $variant->{feature_enabled} ? 1 : 0;
    }
    if (exists $variant->{enabled}) {
        return $variant->{enabled} ? 1 : 0;
    }
    return 0;
}

1;
