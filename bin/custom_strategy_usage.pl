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
my $toggle_name = $ENV{UNLEASH_TOGGLE_NAME} || 'custom_strategy_toggle';
my $eval_interval = exists $ENV{UNLEASH_EVAL_INTERVAL} ? $ENV{UNLEASH_EVAL_INTERVAL} : 1;


# To make this work, create a custom strategy in Unleash with the name "exampleStrategy" and add a parameter named "sound".
# Add the strategy to a toggle name "custom_strategy_toggle" and set the parameter "sound" to "meow".
my $example_strategy = sub {
    my ($parameters, $context) = @_;
    return 0 if ref($parameters) ne 'HASH' || ref($context) ne 'HASH';
    return 0 if !exists $parameters->{sound} || !exists $context->{sound};
    return $context->{sound} eq $parameters->{sound} ? 1 : 0;
};

my $sdk = Srv::SDK->new(
    fetch_features_interval => 1,
    send_metrics_interval   => 1,
    unleash_url             => $unleash_url,
    api_key                 => $api_key,
    custom_strategies       => {
        exampleStrategy => $example_strategy,
    },
);
$sdk->initialize();

Mojo::IOLoop->recurring(
    $eval_interval => sub {
        my $enabled = $sdk->is_enabled(
            $toggle_name,
            {
                userId => 1,
                sound  => 'meow',
            },
            sub { 0 }
        );
        print "is_enabled($toggle_name, custom strategy) = ", ($enabled ? 'true' : 'false'), "\n";
    }
);

Mojo::IOLoop->start;
