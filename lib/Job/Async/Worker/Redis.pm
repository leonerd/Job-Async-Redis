package Job::Async::Worker::Redis;

use strict;
use warnings;

use parent qw(Job::Async::Worker);

# VERSION

=head1 NAME

Job::Async::Worker::Redis - L<Net::Async::Redis> worker implementation for L<Job::Async::Worker>

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

use curry::weak;
use Syntax::Keyword::Try;

use Job::Async::Utils;
use Future::Utils qw(repeat);
use Log::Any qw($log);

use Net::Async::Redis;

=head2 incoming_job

Source for jobs received from the C<< BRPOP(LPUSH) >> queue wait.

=cut

sub incoming_job {
    my ($self) = @_;
    $self->{incoming_job} //= do {
        die 'needs to be part of a loop' unless $self->loop;
        my $src = $self->ryu->source;
        $src->each($self->curry::weak::on_job_received);
        $src
    }
}

=head2 on_job_received

Called for each job that's received.

=cut

sub on_job_received {
    my ($self, $id, $queue) = (shift, @$_);
    local @{$log->{context}}{qw(worker_id job_id queue)} = ($self->id, $id, $queue);
    $log->debugf('Received job');
    if(exists $self->{pending_jobs}{$id}) {
        $log->errorf("Already have job %s", $id);
        die 'Duplicate job ID';
    } else {
        undef $self->{pending_jobs}{$id};
    }
    my $job_count = 0 + keys %{$self->{pending_jobs}};
    $log->tracef("Current job count is %d", $job_count);
    $self->trigger;
    $self->redis->hgetall('job::' . $id)->then(sub {
        my ($items) = @_;
        local @{$log->{context}}{qw(worker_id job_id queue)} = ($self->id, $id, $queue);
        my %data = @$items;
        $self->{pending_jobs}{$id} = my $job = Job::Async::Job->new(
            data   => \%data,
            id     => $id,
            future => my $f = $self->loop->new_future,
        );
        $f->on_done(sub {
            my ($rslt) = @_;
            local @{$log->{context}}{qw(worker_id job_id)} = ($self->id, $id);
            $log->tracef("Result was %s", $rslt);
            $self->redis->multi(sub {
                my $tx = shift;
                local @{$log->{context}}{qw(worker_id job_id)} = ($self->id, $id);
                try {
                    delete $self->{pending_jobs}{$id};
                    $log->tracef('Removing job from processing queue');
                    $tx->hmset('job::' . $id, result => "$rslt");
                    $tx->publish('client::' . $data{_reply_to}, $id);
                    $tx->lrem($self->processing_queue => 1, $id);
                } catch {
                    $log->errorf("Failed due to %s", $@);
                }
            })->on_ready($self->curry::weak::trigger)
              ->on_fail(sub { warn "failed? " . shift })
              ->retain;
        });
        $f->on_ready($self->curry::weak::trigger);
        if(my $timeout = $self->timeout) {
            Future->needs_any(
                $f,
                $self->loop->timeout_future(after => $timeout)
            )->on_fail(sub {
                local @{$log->{context}}{qw(worker_id job_id)} = ($self->id, $id);
                $log->errorf("Timeout but already completed with %s", $f->state) if $f->is_ready;
                $f->fail('timeout')
            })->retain;
        }
        $self->jobs->emit($job);
        $f
    })->retain
}

sub prefix { shift->{prefix} //= 'jobs' }

=head2 pending_queues

Note that L<reliable mode|Job::Async::Redis/Operational mode - reliable> only
supports a single queue, and will fail if you attempt to start with multiple
queues defined.

=cut

sub pending_queues { @{ shift->{pending_queues} ||= [qw(pending)] } }

=head2 processing_queue

=cut

sub processing_queue { shift->{processing_queue} //= 'processing' }

=head2 start

=cut

sub start {
    my ($self) = @_;

    $self->trigger;
}

sub queue_redis {
    my ($self) = @_;
    unless($self->{queue_redis}) {
        $self->add_child(
            $self->{queue_redis} = Net::Async::Redis->new(
                uri => $self->uri,
            )
        );
        $self->{queue_redis}->connect;
    }
    return $self->{queue_redis};
}

sub redis {
    my ($self) = @_;
    unless($self->{redis}) {
        $self->add_child(
            $self->{redis} = Net::Async::Redis->new(
                uri => $self->uri,
            )
        );
        $self->{redis}->connect;
    }
    return $self->{redis};
}

sub trigger {
    my ($self) = @_;
    local @{$log->{context}}{qw(worker_id queue)} = ($self->id, my ($queue) = $self->pending_queues);
    my $pending = 0 + keys %{$self->{pending_jobs}};
    $log->tracef('Trigger called with %d pending tasks, %d max', $pending, $self->max_concurrent_jobs);
    return if $pending >= $self->max_concurrent_jobs;
    $log->tracef("Start awaiting task") unless $self->{awaiting_job};
    $self->{awaiting_job} //= $self->queue_redis->brpoplpush(
        $queue => $self->processing_queue, 0
    )->on_ready(sub {
        my $f = shift;
        delete $self->{awaiting_job};
        local @{$log->{context}}{qw(worker_id queue)} = ($self->id, $queue);
        $log->tracef('Had task from queue, pending now %d', 0 + keys %{$self->{pending_jobs}});
        try {
            my ($id, $queue, @details) = $f->get;
            $queue //= $queue;
            $self->incoming_job->emit([ $id, $queue ]);
        } catch {
            $log->errorf("Failed to retrieve and process job: %s", $@);
        }
        $self->loop->later($self->curry::weak::trigger);
    });
    return;
}

sub max_concurrent_jobs { shift->{max_concurrent_jobs} //= 1 }

sub uri { shift->{uri} }

sub configure {
    my ($self, %args) = @_;
    for my $k (qw(uri max_concurrent_jobs prefix mode processing_queue)) {
        $self->{$k} = delete $args{$k} if exists $args{$k};
    }

    if(exists $args{pending_queues}) {
        if(my $queues = $args{pending_queues}) {
            die 'Only a single queue is supported in reliable mode' if $self->mode eq 'reliable' and @$queues > 1;
            $self->{pending_queues} = $queues;
        } else {
            delete $self->{pending_queues}
        }
    }
    return $self->next::method(%args);
}

1;

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org>

=head1 LICENSE

Copyright Tom Molesworth 2016-2017. Licensed under the same terms as Perl itself.

