#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../.local/lib/perl5";

use Srv::SDK;

my $unleash_url = $ENV{UNLEASH_URL} || 'http://localhost:4242/api';
my $api_key = $ENV{UNLEASH_API_KEY} || 'default:development.unleash-insecure-api-token';

my $sdk = Srv::SDK->new(
    unleash_url => $unleash_url,
    api_key     => $api_key,
);
my $enabled = $sdk->is_enabled('demo_toggle', {}, sub { 0 });

print "is_enabled = ", ($enabled ? 'true' : 'false'), "\n";
