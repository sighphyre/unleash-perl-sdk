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
my $eval_interval = exists $ENV{UNLEASH_EVAL_INTERVAL} ? $ENV{UNLEASH_EVAL_INTERVAL} : 1;

my $sdk = Srv::SDK->new(
    fetch_features_interval => 1,
    send_metrics_interval   => 1,
    unleash_url             => $unleash_url,
    api_key                 => $api_key,
);

$sdk->on(
    impression => sub {
        my ($sdk, $event) = @_;
        my $context = encode_json($event->{context} || {});
        my $variant = exists $event->{variant} ? $event->{variant} : 'none';
        print "impression feature=$event->{featureName}",
            " enabled=", ($event->{enabled} ? 'true' : 'false'),
            " variant=$variant",
            " context=$context\n";
    }
);

print "Waiting for ready event...\n";
$sdk->on(
    ready => sub {
        print "ready received\n";
        Mojo::IOLoop->recurring(
            $eval_interval => sub {
                my $enabled = $sdk->is_enabled($toggle_name, { userId => 1 }, sub { 0 });
                my $variant = $sdk->get_variant($toggle_name, { userId => 1 });
                my $variant_name = (ref($variant) eq 'HASH' && defined $variant->{name})
                    ? $variant->{name}
                    : 'unknown';

                print "is_enabled($toggle_name) = ", ($enabled ? 'true' : 'false'), "\n";
                print "get_variant($toggle_name) = $variant_name\n";
            }
        );
    }
);

$sdk->initialize();
Mojo::IOLoop->start;
