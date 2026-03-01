#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../.local/lib/perl5";

use Mojo::IOLoop;
use Srv::SDK;

$| = 1;

my $unleash_url = $ENV{UNLEASH_URL} || 'http://localhost:4242/api';
my $api_key = $ENV{UNLEASH_API_KEY} || 'default:development.unleash-insecure-api-token';
my $toggle_name = $ENV{UNLEASH_TOGGLE_NAME} || 'demo_toggle';
my $default_polling_interval = exists $ENV{UNLEASH_POLLING_INTERVAL} ? $ENV{UNLEASH_POLLING_INTERVAL} : 1;
my $fetch_features_interval = exists $ENV{UNLEASH_FETCH_FEATURES_INTERVAL}
    ? $ENV{UNLEASH_FETCH_FEATURES_INTERVAL}
    : $default_polling_interval;
my $send_metrics_interval = exists $ENV{UNLEASH_SEND_METRICS_INTERVAL}
    ? $ENV{UNLEASH_SEND_METRICS_INTERVAL}
    : $default_polling_interval;
my $eval_interval = exists $ENV{UNLEASH_EVAL_INTERVAL} ? $ENV{UNLEASH_EVAL_INTERVAL} : 1;

my $sdk = Srv::SDK->new(
    fetch_features_interval => $fetch_features_interval,
    send_metrics_interval   => $send_metrics_interval,
    unleash_url             => $unleash_url,
    api_key                 => $api_key,
);
$sdk->initialize();

Mojo::IOLoop->recurring(
    $eval_interval => sub {
        my $enabled = $sdk->is_enabled($toggle_name, {}, sub { 0 });
        print "is_enabled($toggle_name) = ", ($enabled ? 'true' : 'false'), "\n";
    }
);

Mojo::IOLoop->start;
