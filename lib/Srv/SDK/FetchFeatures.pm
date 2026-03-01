package Srv::SDK::FetchFeatures;

use strict;
use warnings;
use Mojo::Promise;

sub new {
    my ($class, %args) = @_;
    my $sdk = $args{sdk};
    die 'sdk is required' if !defined $sdk;
    return bless { sdk => $sdk }, $class;
}

sub run {
    my ($self) = @_;
    my $sdk = $self->{sdk};

    return if $sdk->{_fetch_in_flight};
    $sdk->{_fetch_in_flight} = 1;

    eval {
        my %headers = (
            Authorization => $sdk->{api_key},
        );
        if (defined $sdk->{etag} && $sdk->{etag} ne q{}) {
            $headers{'If-None-Match'} = $sdk->{etag};
        }

        $sdk->{ua}->get(
            $sdk->{features_url} => \%headers => sub {
                my ($ua, $tx) = @_;
                eval {
                    my $result = $tx->result;
                    my $status = $result->code || 'unknown';

                    if ($status == 304) {
                        # State unchanged.
                    } elsif (!$result->is_success) {
                        $sdk->_emit_error("fetch_features request failed with status $status");
                    } else {
                        my $state_json = $result->body;
                        $state_json = q{} if !defined $state_json;
                        my $new_etag = $result->headers->header('ETag');
                        $sdk->_handle_successful_fetch_state("$state_json", $new_etag);
                    }
                    1;
                } or do {
                    my $err = $@ || 'unknown error';
                    $sdk->_emit_error("fetch_features request failed: $err");
                };

                $sdk->{_fetch_in_flight} = 0;
                return;
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $sdk->_emit_error("fetch_features request failed: $err");
        $sdk->{_fetch_in_flight} = 0;
    };

    return;
}

sub fetch_state_p {
    my ($self) = @_;
    my $sdk = $self->{sdk};

    my $p = Mojo::Promise->new;

    eval {
        my %headers = (
            Authorization => $sdk->{api_key},
        );
        if (defined $sdk->{etag} && $sdk->{etag} ne q{}) {
            $headers{'If-None-Match'} = $sdk->{etag};
        }

        $sdk->{ua}->get(
            $sdk->{features_url} => \%headers => sub {
                my ($ua, $tx) = @_;
                eval {
                    my $result = $tx->result;
                    my $status = $result->code || 'unknown';

                    if ($status == 304) {
                        $p->resolve({ status => 304 });
                    } elsif (!$result->is_success) {
                        $p->resolve({ status => $status, error => "fetch_features request failed with status $status" });
                    } else {
                        $p->resolve({
                            status     => $status,
                            state_json => $result->body,
                            etag       => $result->headers->header('ETag'),
                        });
                    }
                    1;
                } or do {
                    my $err = $@ || 'unknown error';
                    $p->resolve({ error => "fetch_features request failed: $err" });
                };
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $p->resolve({ error => "fetch_features request failed: $err" });
    };

    return $p;
}

1;
