use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Srv::SDK;

my $sdk = Srv::SDK->new();
is($sdk->is_enabled({}), 0, 'is_enabled returns false for a disabled toggle');

done_testing();
