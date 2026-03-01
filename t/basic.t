use strict;
use warnings;

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";

use Srv::SDK;

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
            enabled_values   => $args{enabled_values} || [],
            count_calls      => [],
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
    sub count_toggle {
        my ($self, $toggle_name, $enabled) = @_;
        push @{ $self->{count_calls} }, {
            toggle_name => $toggle_name,
            enabled     => $enabled,
        };
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

my $engine_hydrated = TestEngine->new();
my $sdk_hydrated = Srv::SDK->new(
    unleash_url      => $unleash_url,
    api_key          => $api_key,
    app_name         => 'startup-hydrate-app',
    state_backup_dir => $backup_dir,
    bootstrap_function => sub {
        return '{"version":2,"features":[{"name":"bootstrapped"}],"segments":[]}';
    },
    ua               => $ua,
    engine           => $engine_hydrated,
);
is(
    scalar @{ $engine_hydrated->{take_state_calls} },
    2,
    'constructor hydrates from backup and bootstrap function',
);
is(
    $engine_hydrated->{take_state_calls}[0],
    '{"version":2,"features":[{"name":"seeded"}],"segments":[]}',
    'backup hydration runs first',
);
is(
    $engine_hydrated->{take_state_calls}[1],
    '{"version":2,"features":[{"name":"bootstrapped"}],"segments":[]}',
    'bootstrap hydration runs after backup',
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

my $polling_sdk = Srv::SDK->new(
    polling_interval => 1,
    unleash_url      => $unleash_url . '/',
    api_key          => $api_key,
    app_name         => 'polling-test-app',
    state_backup_dir => $backup_dir,
    ua               => $ua,
    engine           => $engine,
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
    ua                      => $ua,
    engine                  => $engine,
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

$sdk->_send_metrics_once();
is(scalar @{ $ua->{post_calls} }, 2, 'send_metrics skips POST when metrics bucket is empty');

done_testing();
