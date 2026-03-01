package Srv::SDK::StartupHydration;

use strict;
use warnings;
use Mojo::IOLoop;
use Mojo::Promise;
use Srv::SDK::Bootstrap;
use Srv::SDK::StateBackup;

sub start_startup_hydration {
    my ($sdk) = @_;

    return if $sdk->{_startup_hydration_started};
    $sdk->{_startup_hydration_started} = 1;

    my $http_p = $sdk->{fetch_features_task}->fetch_state_p();
    my $bootstrap_p = Mojo::Promise->new;
    my $backup_p = Mojo::Promise->new;

    Mojo::IOLoop->next_tick(sub { $bootstrap_p->resolve(Srv::SDK::Bootstrap::read_state_from_bootstrap($sdk)) });
    Mojo::IOLoop->next_tick(sub { $backup_p->resolve(Srv::SDK::StateBackup::read_state_from_backup($sdk)) });

    $http_p->then(sub {
        my ($res) = @_;
        if (ref($res) ne 'HASH') {
            $sdk->_emit_error('startup fetch failed to resolve');
            return;
        }
        if (defined $res->{error} && $res->{error} ne q{}) {
            $sdk->_emit_error("startup fetch failed: $res->{error}");
            return;
        }
        return if ($res->{status} || 0) == 304;
        if (($res->{status} || 0) != 200) {
            $sdk->_emit_error("startup fetch failed with status " . ($res->{status} || 'unknown'));
            return;
        }
        my $state_json = $res->{state_json};
        return if !defined $state_json || $state_json eq q{};

        # HTTP wins if it is first, but also supersedes backup/bootstrap when they won first.
        $sdk->{_startup_winner} = 'http' if !defined $sdk->{_startup_winner};
        handle_successful_fetch_state($sdk, "$state_json", $res->{etag});
        $sdk->{_startup_winner} = 'http';
        return;
    })->catch(sub {
        my ($err) = @_;
        $sdk->_emit_error("startup http hydration failed: $err");
    });

    $bootstrap_p->then(sub {
        my ($state_json) = @_;
        return if !defined $state_json || $state_json eq q{};
        return if defined $sdk->{_startup_winner} && $sdk->{_startup_winner} eq 'http';
        return if defined $sdk->{_startup_winner} && $sdk->{_startup_winner} eq 'bootstrap';

        # Bootstrap first discards backup, but HTTP still continues.
        $sdk->{engine}->take_state("$state_json");
        $sdk->{_startup_winner} = 'bootstrap';
        return;
    })->catch(sub {
        my ($err) = @_;
        warn "startup bootstrap hydration failed: $err\n";
    });

    $backup_p->then(sub {
        my ($state_json) = @_;
        return if !defined $state_json || $state_json eq q{};
        return if defined $sdk->{_startup_winner} && $sdk->{_startup_winner} eq 'http';
        return if defined $sdk->{_startup_winner} && $sdk->{_startup_winner} eq 'bootstrap';
        return if defined $sdk->{_startup_winner} && $sdk->{_startup_winner} eq 'backup';

        # Backup first hydrates, then bootstrap/http may still update later.
        $sdk->{engine}->take_state("$state_json");
        $sdk->{_startup_winner} = 'backup';
        return;
    })->catch(sub {
        my ($err) = @_;
        warn "startup backup hydration failed: $err\n";
    });

    return;
}

sub handle_successful_fetch_state {
    my ($sdk, $state_json, $etag) = @_;
    return if !defined $state_json || $state_json eq q{};

    $sdk->{etag} = $etag if defined $etag && $etag ne q{};
    $sdk->{engine}->take_state("$state_json");
    Srv::SDK::StateBackup::backup_state_json($sdk, "$state_json");
    $sdk->_emit_ready_once();
    return;
}

1;
