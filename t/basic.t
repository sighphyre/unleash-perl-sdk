use strict;
use warnings;

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";

my $has_mojo = eval {
    require Mojo::Promise;
    require Mojo::IOLoop;
    1;
};
if (!$has_mojo) {
    plan skip_all => "Mojolicious is required for SDK tests";
}

require Srv::SDK;
Srv::SDK->import();

my $unleash_url = $ENV{UNLEASH_URL} || 'http://localhost:4242/api';
my $api_key = $ENV{UNLEASH_API_KEY} || 'test-api-key';

{
    package TestUA;
    sub new {
        my ($class, %args) = @_;
        return bless {
            get_calls      => [],
            get_responses  => $args{get_responses} || [],
            post_calls     => [],
            post_responses => $args{post_responses} || [],
        }, $class;
    }
    sub get {
        my ($self, $url, $headers, $cb) = @_;
        push @{ $self->{get_calls} }, { url => $url, headers => $headers };
        my $resp = shift @{ $self->{get_responses} } || {
            status => 200,
            body   => '{"version":2,"features":[],"segments":[]}',
            etag   => undef,
        };
        my $tx = bless {
            body   => $resp->{body},
            status => $resp->{status},
            etag   => $resp->{etag},
        }, 'TestTx';
        if (defined $cb && ref($cb) eq 'CODE') {
            $cb->($self, $tx);
        }
        return $tx;
    }
    sub post {
        my ($self, $url, $headers, $json_kw, $payload, $cb) = @_;
        push @{ $self->{post_calls} }, {
            url      => $url,
            headers  => $headers,
            json_kw  => $json_kw,
            payload  => $payload,
        };

        my $resp = shift @{ $self->{post_responses} } || {
            status => 202,
            body   => q{},
            etag   => undef,
        };
        my $tx = bless {
            body   => $resp->{body},
            status => $resp->{status},
            etag   => $resp->{etag},
        }, 'TestTx';

        if (defined $cb && ref($cb) eq 'CODE') {
            $cb->($self, $tx);
        }
        return $tx;
    }
}

{
    package TestTx;
    sub result {
        my ($self) = @_;
        return bless {
            body   => $self->{body},
            status => $self->{status},
            etag   => $self->{etag},
        }, 'TestResult';
    }
}

{
    package TestResult;
    sub is_success {
        my ($self) = @_;
        return (($self->{status} || 0) >= 200 && ($self->{status} || 0) < 300) ? 1 : 0;
    }
    sub body {
        my ($self) = @_;
        return $self->{body};
    }
    sub code {
        my ($self) = @_;
        return $self->{status};
    }
    sub headers {
        my ($self) = @_;
        return bless { etag => $self->{etag} }, 'TestHeaders';
    }
}

{
    package TestHeaders;
    sub header {
        my ($self, $name) = @_;
        return $self->{etag} if $name eq 'ETag';
        return undef;
    }
}

{
    package TestEngine;
    sub new {
        my ($class, %args) = @_;
        return bless {
            take_state_calls => [],
            metrics_values   => $args{metrics_values} || [],
            impact_values    => $args{impact_values} || [],
            enabled_values   => $args{enabled_values} || [],
            variant_values   => $args{variant_values} || [],
            should_emit_map  => $args{should_emit_map} || {},
            count_calls      => [],
            count_variant_calls => [],
            registered_custom_strategies => [],
            restored_impact_metrics => [],
            defined_counters  => [],
            incremented_counters => [],
            defined_gauges    => [],
            set_gauges        => [],
            defined_histograms => [],
            observed_histograms => [],
        }, $class;
    }
    sub is_enabled {
        my ($self) = @_;
        return shift @{ $self->{enabled_values} };
    }
    sub take_state {
        my ($self, $state_json) = @_;
        push @{ $self->{take_state_calls} }, $state_json;
        return;
    }
    sub get_metrics {
        my ($self) = @_;
        return shift @{ $self->{metrics_values} };
    }
    sub collect_impact_metrics {
        my ($self) = @_;
        return shift @{ $self->{impact_values} };
    }
    sub restore_impact_metrics {
        my ($self, $metrics) = @_;
        push @{ $self->{restored_impact_metrics} }, $metrics;
        return;
    }
    sub get_variant {
        my ($self) = @_;
        return shift @{ $self->{variant_values} };
    }
    sub count_toggle {
        my ($self, $toggle_name, $enabled) = @_;
        push @{ $self->{count_calls} }, {
            toggle_name => $toggle_name,
            enabled     => $enabled,
        };
        return;
    }
    sub count_variant {
        my ($self, $toggle_name, $variant_name) = @_;
        push @{ $self->{count_variant_calls} }, {
            toggle_name  => $toggle_name,
            variant_name => $variant_name,
        };
        return;
    }
    sub register_custom_strategies {
        my ($self, $strategies) = @_;
        push @{ $self->{registered_custom_strategies} }, $strategies;
        return;
    }
    sub should_emit_impression_event {
        my ($self, $toggle_name) = @_;
        return $self->{should_emit_map}{$toggle_name} ? 1 : 0;
    }
    sub define_counter {
        my ($self, $name, $help_text) = @_;
        push @{ $self->{defined_counters} }, { name => $name, help_text => $help_text };
        return;
    }
    sub inc_counter {
        my ($self, $name, $value, $labels) = @_;
        push @{ $self->{incremented_counters} }, { name => $name, value => $value, labels => $labels };
        return;
    }
    sub define_gauge {
        my ($self, $name, $help_text) = @_;
        push @{ $self->{defined_gauges} }, { name => $name, help_text => $help_text };
        return;
    }
    sub set_gauge {
        my ($self, $name, $value, $labels) = @_;
        push @{ $self->{set_gauges} }, { name => $name, value => $value, labels => $labels };
        return;
    }
    sub define_histogram {
        my ($self, $name, $help_text, $buckets) = @_;
        push @{ $self->{defined_histograms} }, { name => $name, help_text => $help_text, buckets => $buckets };
        return;
    }
    sub observe_histogram {
        my ($self, $name, $value, $labels) = @_;
        push @{ $self->{observed_histograms} }, { name => $name, value => $value, labels => $labels };
        return;
    }
}

my $ua = TestUA->new(
    get_responses => [
        {
            status => 200,
            body   => '{"version":2,"features":[],"segments":[]}',
            etag   => '"76d8bb0e:526:v1"',
        },
        {
            status => 304,
            body   => q{},
            etag   => undef,
        },
    ],
    post_responses => [
        {
            status => 202,
            body   => q{},
            etag   => undef,
        },
    ],
);
my $backup_dir = tempdir(CLEANUP => 1);
my $engine = TestEngine->new(
    metrics_values => [
        { toggles => { demo_toggle => { yes => 1, no => 0 } } },
        {},
    ],
    impact_values => [
        [
            {
                name    => 'purchases',
                type    => 'counter',
                samples => [ { labels => { appName => 'unleash-perl-app-test' }, value => 1 } ],
            },
        ],
        [],
    ],
    enabled_values => [
        undef,
        undef,
        undef,
    ],
);
my $hydrated_backup_file = File::Spec->catfile($backup_dir, 'startup-hydrate-app-perl-sdk.json');
open my $hydrated_fh, '>', $hydrated_backup_file or die "failed to seed hydration file: $!";
print {$hydrated_fh} '{"version":2,"features":[{"name":"seeded"}],"segments":[]}';
close $hydrated_fh;

my $ua_hydrated = TestUA->new(
    get_responses => [
        { status => 304, body => q{}, etag => undef },
    ],
);
my $engine_hydrated = TestEngine->new();
my $sdk_hydrated = Srv::SDK->new(
    unleash_url        => $unleash_url,
    api_key            => $api_key,
    app_name           => 'startup-hydrate-app',
    state_backup_dir   => $backup_dir,
    bootstrap_function => sub {
        return '{"version":2,"features":[{"name":"bootstrapped"}],"segments":[]}';
    },
    ua                 => $ua_hydrated,
    engine             => $engine_hydrated,
);
$sdk_hydrated->_start_startup_hydration();
Mojo::IOLoop->one_tick();
Mojo::IOLoop->one_tick();
is(
    scalar @{ $engine_hydrated->{take_state_calls} },
    1,
    'startup hydration uses first successful source',
);
is(
    $engine_hydrated->{take_state_calls}[0],
    '{"version":2,"features":[{"name":"bootstrapped"}],"segments":[]}',
    'bootstrap can win startup race and hydrate engine',
);

my $sdk = Srv::SDK->new(
    unleash_url => $unleash_url,
    api_key     => $api_key,
    app_name    => 'unleash-perl-app-test',
    instance_id => '11111111-1111-4111-8111-111111111111',
    state_backup_dir => $backup_dir,
    supported_strategies => [qw/default gradualRolloutUserId/],
    ua          => $ua,
    engine      => $engine,
);
is(
    $sdk->is_enabled('missing_toggle', {}, sub { 1 }),
    1,
    'is_enabled uses fallback for missing toggle (undef)',
);

is(
    $sdk->is_enabled('missing_toggle', {}, sub { 0 }),
    0,
    'fallback can return false',
);

is(
    $sdk->is_enabled('missing_toggle', {}),
    0,
    'missing toggle without fallback defaults to false',
);
is(
    scalar @{ $engine->{count_calls} },
    0,
    'is_enabled does not count metrics when result is undef',
);

my $engine_counting = TestEngine->new(
    enabled_values => [1, 0],
);
my $sdk_counting = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'counting-test-app',
    state_backup_dir => $backup_dir,
    ua               => $ua,
    engine           => $engine_counting,
);
is($sdk_counting->is_enabled('flag_on', {}, sub { 0 }), 1, 'returns true when engine returns true');
is($sdk_counting->is_enabled('flag_off', {}, sub { 1 }), 0, 'returns false when engine returns false');
is(scalar @{ $engine_counting->{count_calls} }, 2, 'count_toggle called for defined is_enabled results');
is($engine_counting->{count_calls}[0]{toggle_name}, 'flag_on', 'count_toggle called with first toggle name');
is($engine_counting->{count_calls}[0]{enabled}, 1, 'count_toggle enabled=1 for true result');
is($engine_counting->{count_calls}[1]{toggle_name}, 'flag_off', 'count_toggle called with second toggle name');
is($engine_counting->{count_calls}[1]{enabled}, 0, 'count_toggle enabled=0 for false result');

my $cat_strategy = sub {
    my ($parameters, $context) = @_;
    return 0 if ref($parameters) ne 'HASH' || ref($context) ne 'HASH';
    return ($context->{sound} || q{}) eq ($parameters->{sound} || q{}) ? 1 : 0;
};
my $engine_custom = TestEngine->new();
my $sdk_custom = Srv::SDK->new(
    unleash_url       => $unleash_url,
    api_key           => $api_key,
    app_name          => 'custom-strategy-test-app',
    state_backup_dir  => $backup_dir,
    custom_strategies => {
        amIACat => $cat_strategy,
    },
    ua                => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine            => $engine_custom,
);
is(
    scalar @{ $engine_custom->{registered_custom_strategies} },
    1,
    'constructor registers custom strategies on engine',
);
ok(
    exists $engine_custom->{registered_custom_strategies}[0]{amIACat},
    'registered custom strategy includes expected key',
);
is(
    ref($engine_custom->{registered_custom_strategies}[0]{amIACat}),
    'CODE',
    'registered custom strategy value is preserved',
);
eval {
    Srv::SDK->new(
        unleash_url       => $unleash_url,
        api_key           => $api_key,
        custom_strategies => ['invalid'],
        ua                => TestUA->new(),
        engine            => TestEngine->new(),
    );
    1;
};
like($@, qr/custom_strategies must be a hash reference/, 'invalid custom_strategies input is rejected');

my $engine_variant = TestEngine->new(
    variant_values => [
        { name => 'green', payload => undef, enabled => 1, featureEnabled => 1 },
        undef,
        undef,
        undef,
    ],
    enabled_values => [
        1,
        undef,
        0,
    ],
);
my $sdk_variant = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'variant-test-app',
    state_backup_dir => $backup_dir,
    ua               => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => $engine_variant,
);

my $existing_variant = $sdk_variant->get_variant('variant_flag', {}, sub { { name => 'unused' } });
is($existing_variant->{name}, 'green', 'get_variant returns engine variant when present');
is(scalar @{ $engine_variant->{count_calls} }, 1, 'existing variant increments count_toggle');
is($engine_variant->{count_calls}[0]{enabled}, 1, 'existing variant count_toggle uses feature enabled state');
is(scalar @{ $engine_variant->{count_variant_calls} }, 1, 'existing variant increments count_variant');
is($engine_variant->{count_variant_calls}[0]{variant_name}, 'green', 'existing variant count_variant uses variant name');

my $fallback_variant_enabled = $sdk_variant->get_variant(
    'missing_variant_enabled',
    {},
    sub { { name => 'from-fallback', payload => undef, enabled => 1, featureEnabled => 1 } }
);
is($fallback_variant_enabled->{name}, 'from-fallback', 'fallback variant returned when engine variant missing');
is(scalar @{ $engine_variant->{count_calls} }, 2, 'fallback path counts toggle when toggle exists');
is($engine_variant->{count_calls}[1]{enabled}, 1, 'fallback path count_toggle uses is_enabled state');
is(scalar @{ $engine_variant->{count_variant_calls} }, 2, 'fallback path counts variant');
is($engine_variant->{count_variant_calls}[1]{variant_name}, 'from-fallback', 'fallback path uses fallback variant name');

my $fallback_variant_missing = $sdk_variant->get_variant(
    'missing_variant_toggle_missing',
    {},
    sub { { name => 'missing-toggle-fallback', payload => undef, enabled => 0, featureEnabled => 0 } }
);
is($fallback_variant_missing->{name}, 'missing-toggle-fallback', 'fallback still returned when toggle missing');
is(scalar @{ $engine_variant->{count_calls} }, 2, 'toggle count not incremented when is_enabled is undef');
is(scalar @{ $engine_variant->{count_variant_calls} }, 3, 'variant count increments when toggle missing');
is($engine_variant->{count_variant_calls}[2]{variant_name}, 'missing-toggle-fallback', 'missing toggle still counts fallback variant name');

my $default_variant = $sdk_variant->get_variant('missing_variant_default', {});
is($default_variant->{name}, 'disabled', 'default fallback variant name is disabled');
ok(!defined $default_variant->{payload}, 'default fallback payload is null/undef');
is($default_variant->{enabled}, 0, 'default fallback enabled is false');
is($default_variant->{featureEnabled}, 0, 'default fallback featureEnabled mirrors is_enabled');
is(scalar @{ $engine_variant->{count_calls} }, 3, 'default fallback counts toggle when is_enabled is defined');
is($engine_variant->{count_calls}[2]{enabled}, 0, 'default fallback count_toggle uses is_enabled state');
is(scalar @{ $engine_variant->{count_variant_calls} }, 4, 'default fallback counts variant');
is($engine_variant->{count_variant_calls}[3]{variant_name}, 'disabled', 'default fallback variant name counted as disabled');

my $engine_ready_http = TestEngine->new();
my $sdk_ready_http = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'ready-http-test-app',
    state_backup_dir => $backup_dir,
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    ua               => TestUA->new(
        get_responses => [
            {
                status => 200,
                body   => '{"version":2,"features":[{"name":"ready_http"}],"segments":[]}',
                etag   => '"ready-http-etag"',
            },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => $engine_ready_http,
);
my $ready_http_count = 0;
$sdk_ready_http->on(ready => sub { $ready_http_count++; });
$sdk_ready_http->initialize();
Mojo::IOLoop->one_tick() for 1..3;
is($ready_http_count, 1, 'ready emitted when initial HTTP fetch succeeds');
$sdk_ready_http->shutdown();

my $engine_ready_no_http = TestEngine->new();
my $sdk_ready_no_http = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'ready-no-http-test-app',
    state_backup_dir => $backup_dir,
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    bootstrap_function => sub {
        return '{"version":2,"features":[{"name":"bootstrap_only"}],"segments":[]}';
    },
    ua               => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => $engine_ready_no_http,
);
my $ready_no_http_count = 0;
$sdk_ready_no_http->on(ready => sub { $ready_no_http_count++; });
$sdk_ready_no_http->initialize();
Mojo::IOLoop->one_tick() for 1..3;
is($ready_no_http_count, 0, 'ready is not emitted by bootstrap or backup without HTTP success');
$sdk_ready_no_http->shutdown();

my $engine_ready_late = TestEngine->new();
my $sdk_ready_late = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'ready-late-http-test-app',
    state_backup_dir => $backup_dir,
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    ua               => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef }, # startup
            {
                status => 200,
                body   => '{"version":2,"features":[{"name":"late_http"}],"segments":[]}',
                etag   => '"late-http-etag"',
            },
            {
                status => 200,
                body   => '{"version":2,"features":[{"name":"late_http_2"}],"segments":[]}',
                etag   => '"late-http-etag-2"',
            },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => $engine_ready_late,
);
my $ready_late_count = 0;
$sdk_ready_late->on(ready => sub { $ready_late_count++; });
$sdk_ready_late->initialize();
Mojo::IOLoop->one_tick() for 1..3;
is($ready_late_count, 0, 'ready not emitted when startup HTTP fetch does not succeed');
$sdk_ready_late->_fetch_features_once();
is($ready_late_count, 1, 'ready emitted on subsequent successful HTTP fetch');
$sdk_ready_late->_fetch_features_once();
is($ready_late_count, 1, 'ready emitted only once');
$sdk_ready_late->shutdown();

my $engine_impression = TestEngine->new(
    enabled_values => [
        1, # is_enabled -> emit
        0, # is_enabled -> no emit
        0, # get_variant fallback path -> is_enabled
    ],
    variant_values => [
        { name => 'blue', enabled => 1, featureEnabled => 1 },
        undef,
    ],
    should_emit_map => {
        impression_enabled          => 1,
        impression_variant          => 1,
        impression_fallback_variant => 1,
        impression_no_emit          => 0,
    },
);
my $sdk_impression = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'impression-test-app',
    state_backup_dir => $backup_dir,
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    ua               => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => $engine_impression,
);
my @impressions;
$sdk_impression->on(impression => sub {
    my ($sdk, $payload) = @_;
    push @impressions, $payload;
});

$sdk_impression->is_enabled('impression_enabled', { userId => 123 });
$sdk_impression->get_variant('impression_variant', { sessionId => 'abc' });
$sdk_impression->get_variant(
    'impression_fallback_variant',
    { userId => 999 },
    sub { { name => 'fallback-red', enabled => 0, featureEnabled => 0 } },
);
$sdk_impression->is_enabled('impression_no_emit', { userId => 321 });

is(scalar @impressions, 3, 'impression event emitted only when should_emit_impression_event is true');
is($impressions[0]{featureName}, 'impression_enabled', 'is_enabled impression includes feature name');
is_deeply($impressions[0]{context}, { userId => 123 }, 'is_enabled impression includes context');
is($impressions[0]{enabled}, 1, 'is_enabled impression includes enabled state');
ok(!exists $impressions[0]{variant}, 'is_enabled impression does not include variant');

is($impressions[1]{featureName}, 'impression_variant', 'get_variant impression includes feature name');
is($impressions[1]{enabled}, 1, 'get_variant impression includes enabled state');
is($impressions[1]{variant}, 'blue', 'get_variant impression includes variant name');

is($impressions[2]{featureName}, 'impression_fallback_variant', 'fallback get_variant impression includes feature name');
is($impressions[2]{enabled}, 0, 'fallback get_variant impression includes enabled state');
is($impressions[2]{variant}, 'fallback-red', 'fallback get_variant impression includes fallback variant name');
$sdk_impression->shutdown();

my $engine_error_startup = TestEngine->new();
my $sdk_error_startup = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'error-startup-test-app',
    state_backup_dir => $backup_dir,
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    ua               => TestUA->new(
        get_responses => [
            { status => 500, body => q{}, etag => undef },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => $engine_error_startup,
);
my @startup_errors;
$sdk_error_startup->on(error => sub {
    my ($sdk, $message) = @_;
    push @startup_errors, $message;
});
$sdk_error_startup->initialize();
Mojo::IOLoop->one_tick() for 1..3;
is(scalar @startup_errors, 1, 'error emitted when startup fetch fails to resolve');
like(
    $startup_errors[0],
    qr/startup fetch failed: fetch_features request failed with status 500/,
    'startup error includes failure reason',
);
$sdk_error_startup->shutdown();

my $engine_error_late = TestEngine->new();
my $sdk_error_late = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'error-late-test-app',
    state_backup_dir => $backup_dir,
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    ua               => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef }, # startup
            { status => 503, body => q{}, etag => undef }, # subsequent
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => $engine_error_late,
);
my @late_errors;
$sdk_error_late->on(error => sub {
    my ($sdk, $message) = @_;
    push @late_errors, $message;
});
$sdk_error_late->initialize();
Mojo::IOLoop->one_tick() for 1..3;
$sdk_error_late->_fetch_features_once();
is(scalar @late_errors, 1, 'error emitted when subsequent fetch fails');
like($late_errors[0], qr/fetch_features request failed with status 503/, 'subsequent error includes failure reason');
$sdk_error_late->shutdown();

my $polling_sdk = Srv::SDK->new(
    polling_interval => 1,
    unleash_url      => $unleash_url . '/',
    api_key          => $api_key,
    app_name         => 'polling-test-app',
    state_backup_dir => $backup_dir,
    ua               => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine           => TestEngine->new(),
);
my $timers = $polling_sdk->initialize();
ok(ref($timers) eq 'HASH', 'initialize returns scheduler timer ids');
ok(defined $timers->{fetch_features}, 'initialize starts fetch_features scheduler');
ok(defined $timers->{send_metrics}, 'initialize starts send_metrics scheduler');
$polling_sdk->shutdown();
pass('shutdown stops in-process poller');

my $disabled_polling_sdk = Srv::SDK->new(
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    unleash_url             => $unleash_url,
    api_key                 => $api_key,
    app_name                => 'disabled-polling-test-app',
    state_backup_dir        => $backup_dir,
    ua                      => TestUA->new(
        get_responses => [
            { status => 304, body => q{}, etag => undef },
        ],
        post_responses => [
            { status => 202, body => q{}, etag => undef },
        ],
    ),
    engine                  => TestEngine->new(),
);
my $disabled_timers = $disabled_polling_sdk->initialize();
ok(ref($disabled_timers) eq 'HASH', 'initialize returns timer hash when polls are disabled');
ok(!defined $disabled_timers->{fetch_features}, 'fetch_features scheduler not created when interval is 0');
ok(!defined $disabled_timers->{send_metrics}, 'send_metrics scheduler not created when interval is 0');
$disabled_polling_sdk->shutdown();
pass('shutdown is safe when polls are disabled');

$sdk->_register_client_once();
is(scalar @{ $ua->{post_calls} }, 1, 'register posts once');
is(
    $ua->{post_calls}[0]{url},
    ($unleash_url =~ s{/$}{}r) . '/client/register',
    'register uses /client/register endpoint',
);
is(
    $ua->{post_calls}[0]{headers}{Authorization},
    $api_key,
    'register passes api_key as Authorization header',
);
is(
    $ua->{post_calls}[0]{payload}{appName},
    'unleash-perl-app-test',
    'register payload includes appName',
);
is(
    $ua->{post_calls}[0]{payload}{instanceId},
    '11111111-1111-4111-8111-111111111111',
    'register payload includes instanceId',
);
like(
    $ua->{post_calls}[0]{payload}{connectionId},
    qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i,
    'register payload includes generated connectionId UUID',
);
is_deeply(
    $ua->{post_calls}[0]{payload}{strategies},
    [qw/default gradualRolloutUserId/],
    'register payload includes supported strategies',
);
is(
    $ua->{post_calls}[0]{payload}{interval},
    15,
    'register payload interval matches send metrics interval',
);
like(
    $ua->{post_calls}[0]{payload}{sdkVersion},
    qr/\Aunleash-perl-sdk:/,
    'register payload includes sdkVersion',
);
like(
    $ua->{post_calls}[0]{payload}{started},
    qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/,
    'register payload includes UTC started timestamp',
);

$sdk->_fetch_features_once();
$sdk->_fetch_features_once();
is(scalar @{ $ua->{get_calls} }, 2, 'fetch_features performs GET requests');
is(
    $ua->{get_calls}[0]{url},
    ($unleash_url =~ s{/$}{}r) . '/client/features',
    'fetch_features uses /client/features endpoint',
);
is(
    $ua->{get_calls}[0]{headers}{Authorization},
    $api_key,
    'fetch_features passes api_key as Authorization header',
);
ok(
    !exists $ua->{get_calls}[0]{headers}{'If-None-Match'},
    'first fetch does not send If-None-Match',
);
is(
    $ua->{get_calls}[1]{headers}{'If-None-Match'},
    '"76d8bb0e:526:v1"',
    'subsequent fetch sends previous ETag in If-None-Match header',
);
is(
    scalar @{ $engine->{take_state_calls} },
    1,
    'take_state called only for non-304 response',
);
is(
    $engine->{take_state_calls}[0],
    '{"version":2,"features":[],"segments":[]}',
    'fetch_features passes response body string to take_state',
);
my $backup_file = File::Spec->catfile($backup_dir, 'unleash-perl-app-test-perl-sdk.json');
ok(-f $backup_file, 'fetch_features writes state backup file');
open my $backup_fh, '<', $backup_file or die "failed to read backup file: $!";
my $backup_content = do { local $/; <$backup_fh> };
close $backup_fh;
is(
    $backup_content,
    '{"version":2,"features":[],"segments":[]}',
    'backup file stores fetched state JSON body',
);

$sdk->_send_metrics_once();
is(scalar @{ $ua->{post_calls} }, 2, 'send_metrics posts when metrics bucket has data');
is(
    $ua->{post_calls}[1]{url},
    ($unleash_url =~ s{/$}{}r) . '/client/metrics',
    'send_metrics uses /client/metrics endpoint',
);
is(
    $ua->{post_calls}[1]{headers}{Authorization},
    $api_key,
    'send_metrics passes api_key as Authorization header',
);
is(
    $ua->{post_calls}[1]{payload}{appName},
    'unleash-perl-app-test',
    'send_metrics payload includes appName',
);
is(
    $ua->{post_calls}[1]{payload}{instanceId},
    '11111111-1111-4111-8111-111111111111',
    'send_metrics payload includes provided instanceId',
);
like(
    $ua->{post_calls}[1]{payload}{connectionId},
    qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i,
    'send_metrics payload includes internal connectionId UUID',
);
is_deeply(
    $ua->{post_calls}[1]{payload}{bucket},
    { toggles => { demo_toggle => { yes => 1, no => 0 } } },
    'send_metrics payload includes get_metrics bucket',
);
is_deeply(
    $ua->{post_calls}[1]{payload}{impactMetrics},
    [
        {
            name    => 'purchases',
            type    => 'counter',
            samples => [ { labels => { appName => 'unleash-perl-app-test' }, value => 1 } ],
        },
    ],
    'send_metrics payload includes collected impact metrics',
);

$sdk->_send_metrics_once();
is(scalar @{ $ua->{post_calls} }, 2, 'send_metrics skips POST when metrics bucket is empty');

my $engine_impact_restore = TestEngine->new(
    metrics_values => [
        { toggles => { restore_case => { yes => 1, no => 0 } } },
    ],
    impact_values => [
        [
            { name => 'restore_metric', type => 'counter', samples => [ { labels => {}, value => 5 } ] },
        ],
    ],
);
my $ua_impact_restore = TestUA->new(
    post_responses => [
        { status => 500, body => q{}, etag => undef },
    ],
);
my $sdk_impact_restore = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'impact-restore-test-app',
    state_backup_dir => $backup_dir,
    fetch_features_interval => 0,
    send_metrics_interval   => 0,
    ua               => $ua_impact_restore,
    engine           => $engine_impact_restore,
);
$sdk_impact_restore->_send_metrics_once();
is(
    scalar @{ $engine_impact_restore->{restored_impact_metrics} },
    1,
    'impact metrics are restored when metrics submit fails',
);
is_deeply(
    $engine_impact_restore->{restored_impact_metrics}[0],
    [
        { name => 'restore_metric', type => 'counter', samples => [ { labels => {}, value => 5 } ] },
    ],
    'restored impact metrics payload matches collected metrics',
);

$sdk->define_counter('requests_total', 'Total requests');
$sdk->inc_counter('requests_total', 2, { appName => 'unleash-perl-app-test' });
$sdk->define_gauge('active_users', 'Active users');
$sdk->set_gauge('active_users', 42, { appName => 'unleash-perl-app-test' });
$sdk->define_histogram('latency_ms', 'Request latency', [100, 200, 500]);
$sdk->observe_histogram('latency_ms', 123.4, { appName => 'unleash-perl-app-test' });
is_deeply(
    $engine->{defined_counters}[0],
    { name => 'requests_total', help_text => 'Total requests' },
    'define_counter delegates to engine',
);
is_deeply(
    $engine->{incremented_counters}[0],
    { name => 'requests_total', value => 2, labels => { appName => 'unleash-perl-app-test' } },
    'inc_counter delegates to engine',
);
is_deeply(
    $engine->{defined_gauges}[0],
    { name => 'active_users', help_text => 'Active users' },
    'define_gauge delegates to engine',
);
is_deeply(
    $engine->{set_gauges}[0],
    { name => 'active_users', value => 42, labels => { appName => 'unleash-perl-app-test' } },
    'set_gauge delegates to engine',
);
is_deeply(
    $engine->{defined_histograms}[0],
    { name => 'latency_ms', help_text => 'Request latency', buckets => [100, 200, 500] },
    'define_histogram delegates to engine',
);
is_deeply(
    $engine->{observed_histograms}[0],
    { name => 'latency_ms', value => 123.4, labels => { appName => 'unleash-perl-app-test' } },
    'observe_histogram delegates to engine',
);

done_testing();
