use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Srv::SDK;

my $unleash_url = $ENV{UNLEASH_URL} || 'http://localhost:4242/api';
my $api_key = $ENV{UNLEASH_API_KEY} || 'test-api-key';

{
    package TestUA;
    sub new { bless { calls => [] }, shift }
    sub get {
        my ($self, $url, $headers) = @_;
        push @{ $self->{calls} }, { url => $url, headers => $headers };
        return bless {}, 'TestTx';
    }
}

{
    package TestTx;
    sub result { return bless {}, 'TestResult' }
}

{
    package TestResult;
    sub is_success { return 1 }
}

my $ua = TestUA->new();
my $sdk = Srv::SDK->new(
    unleash_url => $unleash_url,
    api_key     => $api_key,
    ua          => $ua,
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

my $polling_sdk = Srv::SDK->new(
    polling_interval => 1,
    unleash_url      => $unleash_url . '/',
    api_key          => $api_key,
    ua               => $ua,
);
my $timers = $polling_sdk->initialize();
ok(ref($timers) eq 'HASH', 'initialize returns scheduler timer ids');
ok(defined $timers->{fetch_features}, 'initialize starts fetch_features scheduler');
ok(defined $timers->{send_metrics}, 'initialize starts send_metrics scheduler');
$polling_sdk->shutdown();
pass('shutdown stops in-process poller');

$sdk->_fetch_features_once();
is(scalar @{ $ua->{calls} }, 1, 'fetch_features performs one GET request');
is(
    $ua->{calls}[0]{url},
    ($unleash_url =~ s{/$}{}r) . '/client/features',
    'fetch_features uses /client/features endpoint',
);
is(
    $ua->{calls}[0]{headers}{Authorization},
    $api_key,
    'fetch_features passes api_key as Authorization header',
);

done_testing();
