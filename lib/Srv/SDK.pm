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
        toggle_name => $args{toggle_name} || 'sdk_mechanics_check',
        engine      => Yggdrasil::Engine->new(),
    }, $class;

    return $self;
}

sub is_enabled {
    my ($self, $context) = @_;

    my $enabled = $self->{engine}->is_enabled($self->{toggle_name}, $context || {});
    return $enabled ? 1 : 0;
}

1;
