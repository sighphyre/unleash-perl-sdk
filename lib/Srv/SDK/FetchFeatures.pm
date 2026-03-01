package Srv::SDK::FetchFeatures;

use strict;
use warnings;

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
                        warn "fetch_features request failed with status $status\n";
                    } else {
                        my $new_etag = $result->headers->header('ETag');
                        $sdk->{etag} = $new_etag if defined $new_etag && $new_etag ne q{};
                        my $state_json = $result->body;
                        $state_json = q{} if !defined $state_json;
                        $sdk->{engine}->take_state("$state_json");
                        $sdk->_backup_state_json("$state_json");
                    }
                    1;
                } or do {
                    my $err = $@ || 'unknown error';
                    warn "fetch_features request failed: $err";
                };

                $sdk->{_fetch_in_flight} = 0;
                return;
            }
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        warn "fetch_features request failed: $err";
        $sdk->{_fetch_in_flight} = 0;
    };

    return;
}

1;
