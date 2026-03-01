#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Srv::SDK;

my $sdk = Srv::SDK->new();
my $enabled = $sdk->is_enabled('demo_toggle', {}, sub { 0 });

print "is_enabled = ", ($enabled ? 'true' : 'false'), "\n";
