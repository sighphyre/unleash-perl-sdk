use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Srv::SDK;

my $sdk = Srv::SDK->new();
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

my $polling_sdk = Srv::SDK->new(polling_interval => 1);
my $timers = $polling_sdk->initialize();
ok(ref($timers) eq 'HASH', 'initialize returns scheduler timer ids');
ok(defined $timers->{fetch_features}, 'initialize starts fetch_features scheduler');
ok(defined $timers->{send_metrics}, 'initialize starts send_metrics scheduler');
$polling_sdk->shutdown();
pass('shutdown stops in-process poller');

done_testing();
