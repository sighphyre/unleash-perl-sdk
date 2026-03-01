package Srv::SDK;

use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Basename qw(dirname);
use File::Spec;

our $VERSION = '0.01';

BEGIN {
    if (!eval { require Yggdrasil::Engine; 1 }) {
        my $project_root = File::Spec->catdir(dirname(__FILE__), '..', '..');
        my $fallback_lib = File::Spec->catdir(
            $project_root, '..', '..', 'yggdrasil-bindings', 'perl-engine', 'lib'
        );

        push @INC, $fallback_lib if -d $fallback_lib;
        require Yggdrasil::Engine;
    }
}

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        engine => Yggdrasil::Engine->new(),
    }, $class;

    return $self;
}

sub is_enabled {
    my ($self, $toggle_name, $context, $fallback) = @_;

    die 'toggle_name is required' if !defined $toggle_name || $toggle_name eq q{};
    die 'fallback must be a coderef' if defined $fallback && ref($fallback) ne 'CODE';

    my $enabled = $self->{engine}->is_enabled($toggle_name, $context || {});

    if (!defined $enabled) {
        return $fallback ? ($fallback->() ? 1 : 0) : 0;
    }

    return $enabled ? 1 : 0;
}

1;
