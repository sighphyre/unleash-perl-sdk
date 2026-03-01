package Srv::SDK::StateBackup;

use strict;
use warnings;
use File::Spec;

sub build_state_backup_file {
    my ($dir, $app_name) = @_;
    my $safe_app_name = $app_name;
    $safe_app_name =~ s{[^A-Za-z0-9._-]}{_}g;
    return File::Spec->catfile($dir, $safe_app_name . '-perl-sdk.json');
}

sub backup_state_json {
    my ($sdk, $state_json) = @_;

    my $path = $sdk->{state_backup_file};
    my $dir = $sdk->{state_backup_dir};

    if (!-d $dir) {
        warn "state backup directory does not exist: $dir\n";
        return;
    }

    my $fh;
    if (!open $fh, '>', $path) {
        warn "failed to write state backup file $path: $!\n";
        return;
    }

    print {$fh} $state_json;
    close $fh;
    return;
}

sub read_state_from_backup {
    my ($sdk) = @_;

    my $path = $sdk->{state_backup_file};
    return undef if !-f $path;

    my $fh;
    if (!open $fh, '<', $path) {
        warn "failed to read state backup file $path: $!\n";
        return undef;
    }

    my $state_json = do { local $/; <$fh> };
    close $fh;
    return undef if !defined $state_json || $state_json eq q{};

    return "$state_json";
}

1;
