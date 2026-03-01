#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../.local/lib/perl5";

use Srv::SDK;

$| = 1;

my $unleash_url = $ENV{UNLEASH_URL} || 'http://localhost:4242/api';
my $api_key = $ENV{UNLEASH_API_KEY} || 'default:development.unleash-insecure-api-token';

my $sdk = Srv::SDK->new(
    polling_interval => 1,
    unleash_url      => $unleash_url,
    api_key          => $api_key,
);
$sdk->initialize();

Mojo::IOLoop->start;
