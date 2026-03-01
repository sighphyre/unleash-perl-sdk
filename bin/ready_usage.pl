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
my $eval_interval = exists $ENV{UNLEASH_EVAL_INTERVAL} ? $ENV{UNLEASH_EVAL_INTERVAL} : 1;

my $sdk = Srv::SDK->new(
    fetch_features_interval => 1,
    send_metrics_interval   => 1,
    unleash_url             => $unleash_url,
    api_key                 => $api_key,
);

print "Waiting for ready event...\n";

$sdk->on(
    ready => sub {
        print "ready received\n";
        Mojo::IOLoop->recurring(
            $eval_interval => sub {
                my $enabled = $sdk->is_enabled($toggle_name, { userId => 1 }, sub { 0 });
                print "is_enabled($toggle_name) = ", ($enabled ? 'true' : 'false'), "\n";
            }
        );
    }
);

$sdk->initialize();
Mojo::IOLoop->start;
