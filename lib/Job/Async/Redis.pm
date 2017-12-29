package Job::Async::Redis;

use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

Job::Async::Redis - L<Net::Async::Redis> backend for L<Job::Async>

=head1 SYNOPSIS

=head1 DESCRIPTION

The system can be configured to select a performance/reliability tradeoff
as follows. Please note that clients and workers B<must> be configured to
use the same mode - results are undefined if you try to mix clients and
workers using different modes. If it works, don't rely on it.

=head2 Operational modes

=head3 simple mode

Jobs are submitted by serialising as JSON and pushing to a Redis list
as a queue.

Workers retrieve jobs from queue, and send the results via pubsub.

Multiple queues can be used for priority handling - the client can route
based on the job data.

=head2 recoverable mode

As with simple mode, queues are used for communication between the
clients and workers. However, these queues contain only the job ID.

Actual job data is stored in a hash key, and once the worker completes
the result is also stored here.

Job completion will trigger a L<Net::Redis::Async::Commands/publish>
notification, allowing clients to listen for completion.

Multiple queues can be used, as with C<simple> mode.

=head2 reliable mode

Each worker uses L<Net::Async::Redis::Commands/brpoplpush> to await job IDs
posted to a single queue.

Job details are stored in a hash key, as with the C<recoverable> approach.

When a worker starts on a job, the ID is atomically moved to an in-process queue,
and this is used to track whether workers are still valid.

Only one queue is allowed per worker, due to limitations of the 
L<Net::Async::Redis::Commands/brpoplpush> implementation as described in
L<this issue|https://github.com/antirez/redis/issues/1785>.

=cut

use Job::Async::Worker::Redis;
use Job::Async::Client::Redis;

our %MODES = (
    simple      => 1,
    recoverable => 1,
    reliable    => 1
);

1;

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org>

=head1 LICENSE

Copyright Tom Molesworth 2016-2017. Licensed under the same terms as Perl itself.

