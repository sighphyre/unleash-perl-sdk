package Srv::Scheduler;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    require Mojo::IOLoop;

    my $interval = $args{interval};
    die 'interval is required' if !defined $interval;
    die 'interval must be a positive number' if $interval <= 0;

    my $task = $args{task};
    die 'task must be a coderef' if ref($task) ne 'CODE';

    my $self = bless {
        interval => $interval + 0,
        task     => $task,
        timer_id => undef,
        running  => 0,
    }, $class;

    return $self;
}

sub start {
    my ($self) = @_;

    return $self->{timer_id} if $self->{running};

    $self->{timer_id} = Mojo::IOLoop->recurring(
        $self->{interval} => $self->{task}
    );
    $self->{running} = 1;

    return $self->{timer_id};
}

sub stop {
    my ($self) = @_;

    return if !$self->{running};

    if (defined $self->{timer_id}) {
        Mojo::IOLoop->remove($self->{timer_id});
        $self->{timer_id} = undef;
    }

    $self->{running} = 0;
    return;
}

1;
