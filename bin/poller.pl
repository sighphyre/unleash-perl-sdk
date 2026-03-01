#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../.local/lib/perl5";

use Srv::SDK;

$| = 1;

my $sdk = Srv::SDK->new(polling_interval => 1);
$sdk->initialize();

Mojo::IOLoop->start;
