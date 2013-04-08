package AnyEvent::Task;

use common::sense;

our $VERSION = '0.750';


1;


__END__

=encoding utf-8

=head1 NAME

AnyEvent::Task - Client/server-based asynchronous worker pool

=head1 SYNOPSIS 1: PASSWORD HASHING

=head2 Server

    use AnyEvent::Task::Server;
    use Authen::Passphrase::BlowfishCrypt;

    my $dev_urandom;
    my $server = AnyEvent::Task::Server->new(
                   listen => ['unix/', '/tmp/anyevent-task.socket'],
                   setup => sub {
                     open($dev_urandom, "/dev/urandom") || die "open urandom: $!";
                   },
                   interface => {
                     hash => sub {
                       my ($plaintext) = @_;
                       read($dev_urandom, my $salt, 16) == 16 || die "bad read from urandom";
                       return Authen::Passphrase::BlowfishCrypt->new(cost => 10,
                                                                     salt => $salt,
                                                                     passphrase => $plaintext)
                                                               ->as_crypt;

                     },
                     verify => sub {
                       my ($crypted, $plaintext) = @_;
                       return Authen::Passphrase::BlowfishCrypt->from_crypt($crypted)
                                                               ->match($plaintext);
                     },
                   },
                 );

    $server->run; # or AE::cv->recv


=head2 Client

    use AnyEvent::Task::Client;

    my $client = AnyEvent::Task::Client->new(
                   connect => ['unix/', '/tmp/anyevent-task.socket'],
                 );

    my $checkout = $client->checkout( timeout => 5, );

    my $cv = AE::cv;

    $checkout->hash('secret',
      sub {
        my ($checkout, $crypted) = @_;

        print "Hashed password is $crypted\n";

        $checkout->verify($crypted, 'secret',
          sub {
            my ($checkout, $result) = @_;
            print "Verify result is $result\n";
            $cv->send;
          });
      });

    $cv->recv;

=head2 Output

    Hashed password is $2a$10$NwTOwxmTlG0Lk8YZMT29/uysC9RiZX4jtWCx.deBbb2evRjCq6ovi
    Verify result is 1




=head1 SYNOPSIS 2: DBI


=head2 Server

    use AnyEvent::Task::Server;
    use DBI;

    my $dbh;

    AnyEvent::Task::Server->new(
      listen => ['unix/', '/tmp/anyevent-task.socket'],
      setup => sub {
        $dbh = DBI->connect("dbi:SQLite:dbname=/tmp/junk.sqlite3","","",{ RaiseError => 1, });
      },
      interface => sub {
        my ($method, @args) = @_;
        $dbh->$method(@args);
      },
    )->run;

=head2 Client

    use AnyEvent::Task::Client;

    my $client = AnyEvent::Task::Client->new(
                   connect => ['unix/', '/tmp/anyevent-task.socket'],
                 );

    my $dbh = $client->checkout;

    my $cv = AE::cv;

    $dbh->do(q{ CREATE TABLE user(username TEXT PRIMARY KEY, email TEXT); },
      sub { });

    ## Requests will queue up on the checkout and execute in order:

    $dbh->do(q{ INSERT INTO user (username, email) VALUES (?, ?) },
             undef, 'jimmy',
                    'jimmy@example.com',
      sub { });

    $dbh->selectrow_hashref(q{ SELECT * FROM user }, sub {
      my ($dbh, $user) = @_;
      print "username: $user->{username}, email: $user->{email}\n";
      $cv->send;
    });

    $cv->recv;

=head2 Output

    username: jimmy, email: jimmy@example.com



=head1 DESCRIPTION

B<WARNING:> The above client examples don't implement error handling. See the L<ERROR HANDLING> section for details on how to add this.

The synopsis makes this module sounds much more complicated than it actually is. Worker processes are forked off by a server when a client needs one, and the client can communicate with many workers using asynchronous communication. 

Another way of saying it is that L<AnyEvent::Task> is a fork-on-demand but persistent-worker server (L<AnyEvent::Task::Server>) combined with an asynchronous interface to a request queue and pooled-worker client (L<AnyEvent::Task::Client>).

Both client and server are of course built with L<AnyEvent> because it's awesome. However, workers can't use AnyEvent (yet).

A server is started with C<< AnyEvent::Task::Server->new >>. This should at least be passed the C<listen> and C<interface> arguments. Keep the returned server object around for as long as you want the server to be running. C<interface> is the code that should handle each request. See the interface section below for its specification. A C<setup> coderef can be passed in to run some code when a new worker is forked. A C<checkout_done> coderef can be passed in to run some code whenever a checkout is released (see below).

A client is started with C<< AnyEvent::Task::Client->new >>. You only need to pass C<connect> to this. Keep the returned client object around as long as you wish the client to be connected.

After both the server and client are initialised, each process must enter AnyEvent's "main loop" in some way, possibly just C<< AE::cv->recv >>.

In the client process, you may call the C<checkout> method on the client object. This checkout object can be used to run code on a remote worker process in a non-blocking manner. The C<checkout> method doesn't require any arguments, but C<timeout> is recommended.

You can treat a checkout object as an object that proxies its method calls to a worker process or a function that does the same. You pass the arguments to these method calls as an argument to the checkout object, followed by a callback as the last argument. This callback will be called once the worker process has returned the results. This callback will normally be passed two arguments, the checkout object and the return value. In the event of an exception thrown, an error is raised in the dynamic context of the callback (see the L<ERROR HANDLING> section).




=head1 DESIGN

Each client maintains a "pool" of connections to worker processes. Every time a checkout is issued, it is placed into a first-come, first-serve queue. Once a worker process becomes available, it is associated with that checkout until that checkout is garbage collected which in perl means as soon as it is no longer needed. Each checkout also maintains a queue of requests, so that as soon as this worker process is allocated, the requests are filled also on a first-come, first-served basis.

C<timeout> can be passed as a keyword argument to C<checkout>. Once a request is queued up on that checkout, a timer of C<timout> seconds (default is 30, undef means infinity) is started. If the request completes during this timeframe, the timer is cancelled. If the timer expires, the worker connection is terminated and an exception is thrown in the dynamic context of the callback (see the L<ERROR HANDLING> section).

Note that since timeouts are associated with a checkout, the client process can be started before the server and as long as the server is started within C<timeout> seconds, no requests will be lost. The client will continually try to acquire worker processes until a server is available, and once one is available it will attempt to fill all queued checkouts.

Because of checkout queuing, the maximum number of worker processes a client will attempt to obtain can be limited with the C<max_workers> argument when creating a client object. If there are more live checkouts than C<max_workers>, the remaining checkouts will have to wait until one of the other workers becomes available. Because of timeouts, some checkouts may never be serviced if the system can't handle the load (the timeout error should be handled to indicate the service is temporarily unavailable).

The C<min_workers> argument can be used to pre-fork "hot-standby" worker processes when creating the client. The default is 2 though note that this may change to 0 in the future.





=head1 STARTING THE SERVER

Often you will want to start the client and server as completely separate processes as indicated in the synopsis.

Technically, running the server and the client in the same process is possible but is highly discouraged since the server will C<fork()> when the client desires a worker process. In this case, all descriptors in use by the client would be duped into the worker process and the worker may have to close these extra descriptors. Also, forking a busy client may be memory-inefficient.

Since it's more of a bother than it's worth to run the server and the client in the same process, there is an alternate server constructor, C<AnyEvent::Task::Server::fork_task_server> for when you'd like to run both. It can be passed the same arguments as the regular C<new> constructor:

    ## my ($keepalive_pipe, $pid) =
    AnyEvent::Task::Server::fork_task_server(
      listen => ['unix/', '/tmp/anyevent-task.socket'],
      interface => sub {
                         return "Hello from PID $$";
                       },
    );

The only differences between this and the regular constructor is that this will fork a process which becomes the server, and that it will install a "keep-alive" pipe between the server and the client. This keep-alive pipe will be used by the server to detect when its parent the client process exits.

If C<AnyEvent::Task::Server::fork_task_server> is called in a void context, then the reference to this keep-alive pipe is pushed onto C<@AnyEvent::Task::Server::children_sockets>. Otherwise, the keep-alive pipe and the server's PID are returned. Closing the pipe will terminate the server gracefully. C<kill> the PID to terminate it immediately.

Since the C<fork_task_server> constructor forks and requires using AnyEvent in both the parent and child processes, it is important that you not install any AnyEvent watchers before calling it. The usual caveats about forking AnyEvent applications apply (see AnyEvent docs).





=head1 INTERFACE

There are two formats possible for the C<interface> option when creating a server. The first (and most general) is a coderef. This coderef will be passed the list of arguments that were sent when the checkout was called in the client process (without the trailing callback of course).

As described above, you can use a checkout object as a coderef or as an object with methods. If the checkout is invoked as an object, the method name is prepended to the arguments passed to C<interface>:

    interface => sub {
      my ($method, @args) = @_;
    },

If the checkout is invoked as a coderef, method is omitted:

    interface => sub {
      my (@args) = @_;
    },

The second format possible for C<interface> is a hash ref. This is a simple method dispatch feature where the method invoked on the checkout object is the key used to lookup to which coderef to run in the worker:

    interface => {
      method1 => sub {
        my (@args) = @_;
      },
      method2 => sub {
        my (@args) = @_;
      },
    },

Note that since the protocol between the client and the worker process is JSON-based, all arguments and return values must be serializable to JSON. This includes most perl scalars like strings, a limited range of numerical types, and hash/list constructs with no cyclical references.

A future backwards compatible RPC protocol may use L<Storable> or something else, although note that you can already serialise an object with Storable manually, send the resulting string over the existing protocol, and then deserialise it in the worker.








=head1 LOGGING

Because workers run in a separate process, they can't directly use logging contexts in the client process. That is why this module is integrated with L<Log::Defer>.

A L<Log::Defer> object is created on demand in the worker process and once the worker is done an operation, any messages in the object will be extracted and sent back to the client. The client then merges this into its main Log::Defer object that was passed in when creating the checkout.

In your server code, use L<AnyEvent::Task::Logger>. It exports the function C<logger> which returns a L<Log::Defer> object:

    use AnyEvent::Task::Server;
    use AnyEvent::Task::Logger;

    AnyEvent::Task::Server->new(
      listen => ['unix/', '/tmp/anyevent-task.socket'],
      interface => sub {
        logger->info('about to compute some operation');
        {
          my $timer = logger->timer('computing some operation');
          select undef,undef,undef, 1; ## sleep for 1 second
        }
      },
    )->run;


Note: Portable server code should not call C<sleep> because on some systems it will interfere with the recoverable worker timeout feature implemented with C<SIGALRM>.


In your client code, pass a L<Log::Defer> object in when you create a checkout:

    use AnyEvent::Task::Client;
    use Log::Defer;

    my $client = AnyEvent::Task::Client->new(
                   connect => ['unix/', '/tmp/anyevent-task.socket'],
                 );

    my $log_defer_object = Log::Defer->new(sub {
                                             my $msg = shift;
                                             use Data::Dumper; ## or whatever
                                             print Dumper($msg);
                                           });

    $log_defer_object->info('going to compute some operation in a worker');

    my $checkout = $client->checkout(log_defer_object => $log_defer_object);

    my $cv = AE::cv;

    $checkout->(sub {
      $log_defer_object->info('finished some operation');
      $cv->send;
    });

    $cv->recv;


When run, the above client will print something like this:


    $VAR1 = {
          'start' => '1363232705.96839',
          'end' => '1.027309',
          'logs' => [
                      [
                        '0.000179',
                        30,
                        'going to compute some operation in a worker'
                      ],
                      [
                        '0.023881061050415',
                        30,
                        'about to compute some operation'
                      ],
                      [
                        '1.025965',
                        30,
                        'finished some operation'
                      ]
                    ],
          'timers' => {
                        'computing some operation' => [
                                                        '0.024089061050415',
                                                        '1.02470206105041'
                                                      ]
                      }
        };




=head1 ERROR HANDLING

If you expected some operation to throw an exception, in a synchronous program you might wrap it in C<eval> like this:

    my $crypted;

    eval {
      $crypted = hash('secret');
    };

    if ($@) {
      say "hash failed: $@";
    } else {
      say "hashed password is $crypted";
    }

But in an asynchronous program, typically C<hash> would initiate some kind of asynchronous operation and then return immediately. The error might come back at any time in the future, in which case you need a way to map the exception that is thrown back to your original context.

AnyEvent::Task accomplishes this mapping with L<Callback::Frame>.

Callback::Frame lets you preserve error handlers (and C<local> variables) across asynchronous callbacks. Callback::Frame is not tied to AnyEvent::Task, AnyEvent or any other async framework and can be used with almost all most callback-based libraries.

However, when using AnyEvent::Task, libraries that you use in the client must be L<AnyEvent> compatible. This restriction obviously does not apply to your server code (that being one of the main purposes of AnyEvent::Task -- accessing blocking resources from an asynchronous program).

As an example usage of Callback::Frame, here is how we would handle errors thrown from a worker process running the C<hash> method in an asychronous client program:

    use Callback::Frame;

    frame(code => sub {

      $client->checkout->hash('secret', sub {
        my ($checkout, $crypted) = @_;
        say "Hashed password is $crypted";
      });

    }, catch => sub {

      my $back_trace = shift;
      say "Error is: $@";
      say "Full back-trace: $back_trace";

    })->(); ## <-- frame is created and then executed

Of course if C<hash> is something like a bcrypt hash function it is very unlikely to raise an exception so maybe it's a bad example. Or maybe it's a really good example: In addition to errors that occur while running your callbacks, L<AnyEvent::Task> uses L<Callback::Frame> to throw errors if the worker process times out, so if the bcrypt work factor is really cranked up it might hit the default 30 second time limit.



=head2 Reforking of workers after errors

If a worker throws an error, the client receives the error but the worker process stays running. As long as the client has a reference to the checkout, it can still be used to communicate with that worker so you can access error states, rollback transactions, or clean-up something.

Once the checkout is released however, by default the worker will be shutdown instead of returning to the client's worker pool as in the normal case where no errors were thrown. This can be prevented by setting the C<dont_refork_after_error> option in the client options. This only really matters if your C<setup> routines take a long time and errors are being thrown frequently.

There are exceptions to returning workers that threw errors back into the worker pool: workers that have thrown fatal errors such as loss of connection or hung worker timeout errors. These errors are stored in the checkout and for as long as the checkout exists, any operations on it will return the stored fatal error. The worker connection is closed and a new worker process is forked.



=head2 Rationale for Callback::Frame

Why not just call the callback but set C<$@> to indicate an error has occurred? This is the approach taken with L<AnyEvent::DBI> and L<AnyEvent::Worker> for example but I believe the L<Callback::Frame> interface is superior to this. The problem is that exceptions are supposed to be an out-of-band message and code that doesn't handle them will have the exceptions bubbled up, usually to a top-level error handler. Invoking the callback when an error occurs forces exceptions to be handled in-band.

Why not just have AnyEvent::Task expose an error callback? I believe Callback::Frame is superior to this also: With error callbacks you still have to write error handler callbacks everywhere an error might be thrown instead of having a single "catch-all" top-level error handler.

Callback::Frame provides an error handler stack so you can have nested error handlers (similar to nested C<eval>s). This is useful when you wish to have a top-level "bail-out" error handler and also nested error handlers that know how to retry or recover from an error in an async sub-operation.

Callback::Frame helps you maintain the dynamic state (error handlers and dynamic variables) installed for a single connection. In other words, any errors that occur while servicing that connection will be able to be caught by an error handler specific to that connection. This lets you send an error response and also collect all associated log messages in a Log::Defer object specific to that connection.

Callback::Frame is designed to be easily used with libraries that don't know about Callback::Frame. C<fub> is a shortcut for C<frame> with just the C<code> argument. Instead of passing C<sub { ... }> into libraries you can pass in C<fub { ... }>. When invoked, this wrapped callback will first re-establish any error handlers that you installed with C<frame> and then run your actual callback code. Error callbacks should be populated with C<fub { die "..." }> . It's important that all callbacks be created with C<fub> (or C<frame>) even if you don't expect them to fail so that the dynamic context is preserved for nested callbacks that might.






=head1 COMPARISON WITH HTTP

Why a custom protocol, client, and server? Can't we just use something like HTTP?

It depends.

AnyEvent::Task clients send discrete messages and receive ordered, discrete replies from workers, much like HTTP. The AnyEvent::Task protocol can be extended in a backwards compatible manner like HTTP. AnyEvent::Task communication can be pipelined and possibly in the future even compressed like HTTP.

AnyEvent::Task servers (currently) all obey a very specific implementation policy: They are like CGI servers in that each process in that each process they fork is guaranteed to be handling only one connection at once so it can perform blocking operations without worrying about holding up other connections.

But since a single process can handle many requests in a row without exiting, the AnyEvent::Task server is more like a FastCGI server. The difference however is that while a client holds a checkout it is guaranteed an exclusive lock on that process. With a FastCGI server it is assumed that requests are stateless so you can't necessarily be sure you'll get the same process for two consecutive requests. In fact, if an error is thrown in the FastCGI handler you may never get the same process back again, preventing you from being able to recover from the error, retry, or at least collect process state for logging reasons.

The fundamental difference between the AnyEvent::Task protocol and HTTP is that in AnyEvent::Task the client is the dominant protocol orchestrator whereas in HTTP it is the server.

In AnyEvent::Task, the client manages the worker pool and the client decides if/when the worker process should terminate. In the normal case, a client will just return the worker to its worker pool. A worker is supposed to accept commands for as long as possible until the client dismisses it.

Client processes can be started and checkouts can be obtained before the server is even started. The client will continue to try to connect to the server to obtain worker processes until either the server starts or the checkout's timeout period lapses.

The client decides the timeout for each checkout and different clients can have different timeouts while connecting to the same server.

The client even decides how many minimum and maximum workers it requires at once. The server is really just a simple fork-on-demand server and most of the sophistication is in the asynchronous client.




=head1 SEE ALSO

L<The AnyEvent::Task github repo|https://github.com/hoytech/AnyEvent-Task>

AnyEvent::Task is integrated with L<Callback::Frame>. In order to handle exceptions in a meaningful way, you will need to use this module.

There's about a million CPAN modules that do similar things.

This module is designed to be used in a non-blocking, process-based unix program. Depending on your exact requirements you might find something else useful: L<Parallel::ForkManager>, L<Thread::Pool>, an HTTP server of some kind, &c.

If you're into AnyEvent, L<AnyEvent::DBI> and L<AnyEvent::Worker> (based on AnyEvent::DBI), and L<AnyEvent::ForkObject> send and receive commands from worker processes similar to this module. L<AnyEvent::Worker::Pool> also has an implementation of a worker pool. L<AnyEvent::Gearman> can interface with Gearman services.

If you're into POE there is L<POE::Component::Pool::DBI>, L<POEx::WorkerPool>, L<POE::Component::ResourcePool>, L<POE::Component::PreforkDispatch>, L<Cantella::Worker>, &c.



=head1 BUGS

This module is still being developed although the interface should be mostly stable.




=head1 AUTHOR

Doug Hoyte, C<< <doug@hcsw.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012-2013 Doug Hoyte.

This module is licensed under the same terms as perl itself.

=cut




__END__




PROTOCOL

Normal request:
  client -> worker
    ['do', {META}, @ARGS]
         <-
    ['ok', {META}, $RESULT]
         OR
    ['er', {META}, $ERR_MSG]


Transaction done:
  client -> worker
    ['dn', {META}]







TODO

! optionally limit number of times a worker can be checked out
  before reforking a new one to deal with leaky code

! max checkout queue size
  - start delivering fatal errors to some (at front of queue
    or back of queue though?)
  - test for this

! docs: write good error handling example

! a worker that throws an error should clear out the request queue
  in the checkout (ie in DBI example)

Make names more consistent between callback::frame backtraces and
auto-generated log::defer timers

Servers must wait() on all their children before terminating.
  Support relinquishing accept() socket during this period?

Manual termination of checkouts
  - Write test to ensure queued callbacks aren't run

Document hung_worker_timeout and SIGALRM stuff better

need tests for the following features:
  - checkout_done signal sent to worker to issue rollback or whatever
  - recovering stuff off a worker after C<SIGALRM> timeout
