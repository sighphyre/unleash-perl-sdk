package Srv::SDK;

use strict;
use warnings;
use parent 'Mojo::EventEmitter';
use File::Basename qw(dirname);
use File::Spec;
use POSIX qw(strftime);
use Mojo::Promise;
use Mojo::IOLoop;
use Srv::Scheduler;
use Srv::SDK::Events;
use Srv::SDK::Bootstrap;
use Srv::SDK::StateBackup;
use Srv::SDK::StartupHydration;
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

    my $fetch_features_interval = $args{fetch_features_interval};
    $fetch_features_interval = 15 if !defined $fetch_features_interval;
    die 'fetch_features_interval must be a non-negative number' if $fetch_features_interval < 0;

    my $send_metrics_interval = $args{send_metrics_interval};
    $send_metrics_interval = 60 if !defined $send_metrics_interval;
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

    my $self = $class->SUPER::new();
    $self->{engine} = $args{engine} || Yggdrasil::Engine->new();
    $self->{fetch_features_interval} = $fetch_features_interval + 0;
    $self->{send_metrics_interval} = $send_metrics_interval + 0;
    $self->{unleash_url} = $unleash_url;
    $self->{api_key} = $api_key;
    $self->{app_name} = $app_name;
    $self->{instance_id} = $instance_id;
    $self->{connection_id} = _generate_uuid();
    $self->{state_backup_dir} = $state_backup_dir;
    $self->{state_backup_file} = _build_state_backup_file($state_backup_dir, $app_name);
    $self->{bootstrap_function} = $bootstrap_function;
    $self->{custom_strategies} = $custom_strategies;
    $self->{supported_strategies} = $supported_strategies;
    $self->{features_url} = _build_features_url($unleash_url);
    $self->{metrics_url} = _build_metrics_url($unleash_url);
    $self->{register_url} = _build_register_url($unleash_url);
    $self->{ua} = $args{ua} || Mojo::UserAgent->new();
    $self->{etag} = undef;
    $self->{fetch_features_scheduler} = undef;
    $self->{send_metrics_scheduler} = undef;
    $self->{fetch_features_task} = undef;
    $self->{send_metrics_task} = undef;
    $self->{register_task} = undef;
    $self->{_fetch_in_flight} = 0;
    $self->{_metrics_in_flight} = 0;
    $self->{_register_in_flight} = 0;
    $self->{_startup_hydration_started} = 0;
    $self->{_startup_winner} = undef;
    $self->{_ready_emitted} = 0;
    $self->{poller_running} = 0;

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

    my $resolved_enabled;
    if (!defined $enabled) {
        $resolved_enabled = $fallback ? ($fallback->() ? 1 : 0) : 0;
    } else {
        $resolved_enabled = $enabled ? 1 : 0;
        $self->{engine}->count_toggle($toggle_name, $resolved_enabled);
    }

    $self->_emit_impression_event(
        feature_name => $toggle_name,
        context      => $context || {},
        enabled      => $resolved_enabled,
    );

    return $resolved_enabled;
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
        $self->_emit_impression_event(
            feature_name => $toggle_name,
            context      => $context || {},
            enabled      => $feature_enabled,
            variant      => $variant_name,
        );
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
    $self->_emit_impression_event(
        feature_name => $toggle_name,
        context      => $context || {},
        enabled      => $feature_enabled,
        variant      => $variant_name,
    );

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

sub define_counter {
    my ($self, $name, $help_text) = @_;
    return $self->{engine}->define_counter($name, $help_text);
}

sub inc_counter {
    my ($self, $name, $value, $labels) = @_;
    return $self->{engine}->inc_counter($name, $value, $labels);
}

sub define_gauge {
    my ($self, $name, $help_text) = @_;
    return $self->{engine}->define_gauge($name, $help_text);
}

sub set_gauge {
    my ($self, $name, $value, $labels) = @_;
    return $self->{engine}->set_gauge($name, $value, $labels);
}

sub define_histogram {
    my ($self, $name, $help_text, $buckets) = @_;
    return $self->{engine}->define_histogram($name, $help_text, $buckets);
}

sub observe_histogram {
    my ($self, $name, $value, $labels) = @_;
    return $self->{engine}->observe_histogram($name, $value, $labels);
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
    return Srv::SDK::StateBackup::build_state_backup_file($dir, $app_name);
}

sub _backup_state_json {
    my ($self, $state_json) = @_;
    return Srv::SDK::StateBackup::backup_state_json($self, $state_json);
}

sub _read_state_from_backup {
    my ($self) = @_;
    return Srv::SDK::StateBackup::read_state_from_backup($self);
}

sub _read_state_from_bootstrap {
    my ($self) = @_;
    return Srv::SDK::Bootstrap::read_state_from_bootstrap($self);
}

sub _start_startup_hydration {
    my ($self) = @_;
    return Srv::SDK::StartupHydration::start_startup_hydration($self);
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

sub _handle_successful_fetch_state {
    my ($self, $state_json, $etag) = @_;
    return Srv::SDK::StartupHydration::handle_successful_fetch_state($self, $state_json, $etag);
}

sub _emit_ready_once {
    my ($self) = @_;
    return Srv::SDK::Events::emit_ready_once($self);
}

sub _emit_error {
    my ($self, $message) = @_;
    return Srv::SDK::Events::emit_error($self, $message);
}

sub _emit_impression_event {
    my ($self, %args) = @_;
    return Srv::SDK::Events::emit_impression_event($self, %args);
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
