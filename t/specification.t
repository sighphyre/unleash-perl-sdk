use strict;
use warnings;

use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";

my $has_mojo = eval {
    require Mojo::Promise;
    require Mojo::IOLoop;
    1;
};
if (!$has_mojo) {
    plan skip_all => "Mojolicious is required for client specification tests";
}

require Srv::SDK;
Srv::SDK->import();

if ($ENV{SKIP_CLIENT_SPEC}) {
    plan skip_all => "set SKIP_CLIENT_SPEC=0 (or unset) to run client specification tests";
}

my $spec_dir = File::Spec->catdir($FindBin::Bin, '..', 'client-specification', 'specifications');
my $index_file = File::Spec->catfile($spec_dir, 'index.json');

if (!-f $index_file) {
    plan skip_all => "client-specification/specifications/index.json not found";
}

{
    package SpecUA;
    sub new { return bless {}, shift }
    sub get {
        my ($self, $url, $headers, $cb) = @_;
        my $tx = bless { status => 304, body => q{}, etag => undef }, 'SpecTx';
        $cb->($self, $tx) if defined $cb && ref($cb) eq 'CODE';
        return $tx;
    }
    sub post {
        my ($self, $url, $headers, $json_kw, $payload, $cb) = @_;
        my $tx = bless { status => 202, body => q{}, etag => undef }, 'SpecTx';
        $cb->($self, $tx) if defined $cb && ref($cb) eq 'CODE';
        return $tx;
    }
}

{
    package SpecTx;
    sub result {
        my ($self) = @_;
        return bless {
            status => $self->{status},
            body   => $self->{body},
            etag   => $self->{etag},
        }, 'SpecResult';
    }
}

{
    package SpecResult;
    sub is_success {
        my ($self) = @_;
        return (($self->{status} || 0) >= 200 && ($self->{status} || 0) < 300) ? 1 : 0;
    }
    sub code {
        my ($self) = @_;
        return $self->{status};
    }
    sub body {
        my ($self) = @_;
        return $self->{body};
    }
    sub headers {
        my ($self) = @_;
        return bless { etag => $self->{etag} }, 'SpecHeaders';
    }
}

{
    package SpecHeaders;
    sub header {
        my ($self, $name) = @_;
        return $self->{etag} if $name eq 'ETag';
        return undef;
    }
}

sub _load_json_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    return decode_json($json);
}

sub _normalize_scalar {
    my ($value) = @_;
    if (ref($value) =~ /Boolean$/) {
        return $value ? 1 : 0;
    }
    return $value;
}

sub _normalize_variant {
    my ($variant) = @_;
    return _normalize_scalar($variant) if ref($variant) ne 'HASH';

    my %copy = %{$variant};
    if (exists $copy{featureEnabled} && !exists $copy{feature_enabled}) {
        $copy{feature_enabled} = delete $copy{featureEnabled};
    }
    if (exists $copy{payload} && !defined $copy{payload}) {
        delete $copy{payload};
    }

    for my $k (keys %copy) {
        if (ref($copy{$k}) eq 'HASH') {
            my %nested = %{ _normalize_variant($copy{$k}) };
            $copy{$k} = \%nested;
        } elsif (ref($copy{$k}) eq 'ARRAY') {
            my @arr = map { ref($_) eq 'HASH' ? _normalize_variant($_) : _normalize_scalar($_) } @{ $copy{$k} };
            $copy{$k} = \@arr;
        } else {
            $copy{$k} = _normalize_scalar($copy{$k});
        }
    }

    return \%copy;
}

sub _build_bootstrapped_sdk {
    my ($state, $spec_name) = @_;

    my $state_json = encode_json($state);
    my $backup_dir = tempdir(CLEANUP => 1);

    my $sdk = Srv::SDK->new(
        unleash_url             => 'http://localhost:4242/api',
        api_key                 => 'spec-test-key',
        app_name                => "spec-$spec_name",
        state_backup_dir        => $backup_dir,
        fetch_features_interval => 0,
        send_metrics_interval   => 0,
        bootstrap_function      => sub { return $state_json; },
        ua                      => SpecUA->new(),
    );

    $sdk->initialize();
    Mojo::IOLoop->one_tick() for 1..3;
    return $sdk;
}

sub _safe_label {
    my ($label) = @_;
    $label = '' if !defined $label;
    $label =~ s/[^\x20-\x7E]/?/g;
    return $label;
}

my $spec_index = _load_json_file($index_file);

for my $spec_file (@{$spec_index}) {
    my $spec_data = _load_json_file(File::Spec->catfile($spec_dir, $spec_file));
    my $spec_name = $spec_data->{name} || $spec_file;
    my $state = $spec_data->{state} || {};
    my $tests = $spec_data->{tests} || [];
    my $variant_tests = $spec_data->{variantTests} || [];

    subtest $spec_name => sub {
        my $sdk = _build_bootstrapped_sdk($state, $spec_name);

        for my $test (@{$tests}) {
            my $toggle_name = $test->{toggleName};
            my $context = $test->{context};
            my $expected = _normalize_scalar($test->{expectedResult}) ? 1 : 0;
            my $actual = $sdk->is_enabled($toggle_name, $context);
            is($actual, $expected, _safe_label($test->{description}));
        }

        for my $test (@{$variant_tests}) {
            my $toggle_name = $test->{toggleName};
            my $context = $test->{context};
            my $expected = _normalize_variant($test->{expectedResult});
            my $actual = _normalize_variant($sdk->get_variant($toggle_name, $context));
            is_deeply($actual, $expected, _safe_label($test->{description}));
        }

        $sdk->shutdown();
    };
}

done_testing();
