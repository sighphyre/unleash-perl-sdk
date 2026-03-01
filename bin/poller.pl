#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json);

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
        my $enabled = $sdk->is_enabled($toggle_name, { userId => 1 }, sub { 0 });
        my $variant = $sdk->get_variant($toggle_name, { userId => 1 });
        my $variant_name = (ref($variant) eq 'HASH' && defined $variant->{name})
            ? $variant->{name}
            : 'unknown';
        my $variant_feature_enabled = (ref($variant) eq 'HASH' && exists $variant->{featureEnabled})
            ? ($variant->{featureEnabled} ? 'true' : 'false')
            : 'false';
        my $variant_enabled = (ref($variant) eq 'HASH' && exists $variant->{enabled})
            ? ($variant->{enabled} ? 'true' : 'false')
            : 'false';
        my $variant_payload = (ref($variant) eq 'HASH' && exists $variant->{payload})
            ? encode_json($variant->{payload})
            : 'null';
        print "is_enabled($toggle_name) = ", ($enabled ? 'true' : 'false'), "\n";
        print "get_variant($toggle_name) = $variant_name",
            " featureEnabled=$variant_feature_enabled",
            " enabled=$variant_enabled",
            " payload=$variant_payload\n";
    }
);

Mojo::IOLoop->start;
