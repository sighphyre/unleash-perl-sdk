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
    sub new {
        my ($class, %args) = @_;
        return bless {
            calls     => [],
            responses => $args{responses} || [],
        }, $class;
    }
    sub get {
        my ($self, $url, $headers, $cb) = @_;
        push @{ $self->{calls} }, { url => $url, headers => $headers };
        my $resp = shift @{ $self->{responses} } || {
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
    sub new { bless { take_state_calls => [] }, shift }
    sub is_enabled { return undef }
    sub take_state {
        my ($self, $state_json) = @_;
        push @{ $self->{take_state_calls} }, $state_json;
        return;
    }
}

my $ua = TestUA->new(
    responses => [
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
);
my $engine = TestEngine->new();
my $sdk = Srv::SDK->new(
    unleash_url => $unleash_url,
    api_key     => $api_key,
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

my $polling_sdk = Srv::SDK->new(
    polling_interval => 1,
    unleash_url      => $unleash_url . '/',
    api_key          => $api_key,
    ua               => $ua,
    engine           => $engine,
);
my $timers = $polling_sdk->initialize();
ok(ref($timers) eq 'HASH', 'initialize returns scheduler timer ids');
ok(defined $timers->{fetch_features}, 'initialize starts fetch_features scheduler');
ok(defined $timers->{send_metrics}, 'initialize starts send_metrics scheduler');
$polling_sdk->shutdown();
pass('shutdown stops in-process poller');

$sdk->_fetch_features_once();
$sdk->_fetch_features_once();
is(scalar @{ $ua->{calls} }, 2, 'fetch_features performs GET requests');
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
ok(
    !exists $ua->{calls}[0]{headers}{'If-None-Match'},
    'first fetch does not send If-None-Match',
);
is(
    $ua->{calls}[1]{headers}{'If-None-Match'},
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

done_testing();
