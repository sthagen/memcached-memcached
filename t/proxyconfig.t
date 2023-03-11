#!/usr/bin/env perl

# NOTE: These tests cover the act of reloading the configuration; changing
# backends, pools, routes, etc. It doesn't cover ensuring the code of the main
# file changes naturally, which is fine: there isn't any real way that can
# fail and it can be covered specifically in a different test file.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Carp qw(croak);
use MemcachedTest;
use IO::Select;
use IO::Socket qw(AF_INET SOCK_STREAM);

# TODO: possibly... set env var to a generated temp filename before starting
# the server so we can pass that in?
my $modefile = "/tmp/proxyconfigmode.lua";

if (!supports_proxy()) {
    plan skip_all => 'proxy not enabled';
    exit 0;
}

# Set up some server sockets.
sub mock_server {
    my $port = shift;
    my $srv = IO::Socket->new(
        Domain => AF_INET,
        Type => SOCK_STREAM,
        Proto => 'tcp',
        LocalHost => '127.0.0.1',
        LocalPort => $port,
        ReusePort => 1,
        Listen => 5) || die "IO::Socket: $@";
    return $srv;
}

# Put a version command down the pipe to ensure the socket is clear.
# client version commands skip the proxy code
sub check_version {
    my $ps = shift;
    print $ps "version\r\n";
    like(<$ps>, qr/VERSION /, "version received");
}

sub write_modefile {
    my $cmd = shift;
    open(my $fh, "> $modefile") or die "Couldn't overwrite $modefile: $!";
    print $fh $cmd;
    close($fh);
}

sub wait_reload {
    my $w = shift;
    like(<$w>, qr/ts=(\S+) gid=\d+ type=proxy_conf status=start/, "reload started");
    like(<$w>, qr/ts=(\S+) gid=\d+ type=proxy_conf status=done/, "reload completed");
}

my @mocksrvs = ();
diag "making mock servers";
for my $port (11511, 11512, 11513) {
    my $srv = mock_server($port);
    ok(defined $srv, "mock server created");
    push(@mocksrvs, $srv);
}

diag "testing failure to start";
write_modefile("invalid syntax");
eval {
    my $p_srv = new_memcached('-o proxy_config=./t/proxyconfig.lua -l 127.0.0.1', 11510);
};
ok($@ && $@ =~ m/Failed to connect/, "server successfully not started");

write_modefile('return "none"');
my $p_srv = new_memcached('-o proxy_config=./t/proxyconfig.lua -l 127.0.0.1', 11510);
my $ps = $p_srv->sock;
$ps->autoflush(1);

# Create a watcher so we can monitor when reloads complete.
my $watcher = $p_srv->new_sock;
print $watcher "watch proxyevents\n";
is(<$watcher>, "OK\r\n", "watcher enabled");

{
    # test with stubbed main routes.
    print $ps "mg foo v\r\n";
    is(scalar <$ps>, "SERVER_ERROR no mg route\r\n", "no mg route loaded");
}

# Load some backends
{
    write_modefile('return "start"');

    $p_srv->reload();
    wait_reload($watcher);
}

my @mbe = ();
# A map of where keys route to for worker IO tests later
my %keymap = ();
my $keycount = 100;
{
    # set up server backend sockets.
    for my $msrv ($mocksrvs[0], $mocksrvs[1], $mocksrvs[2]) {
        my $be = $msrv->accept();
        $be->autoflush(1);
        ok(defined $be, "mock backend created");
        push(@mbe, $be);
    }

    my $s = IO::Select->new();

    for my $be (@mbe) {
        $s->add($be);
        like(<$be>, qr/version/, "received version command");
        print $be "VERSION 1.0.0-mock\r\n";
    }

    # Try sending something.
    my $cmd = "mg foo v\r\n";
    print $ps $cmd;
    my @readable = $s->can_read(0.25);
    is(scalar @readable, 1, "only one backend became readable");
    my $be = shift @readable;
    is(scalar <$be>, $cmd, "metaget passthrough");
    print $be "EN\r\n";
    is(scalar <$ps>, "EN\r\n", "miss received");

    # Route a bunch of keys and map them to backends.
    for my $key (0 .. $keycount) {
        print $ps "mg /test/$key\r\n";
        my @readable = $s->can_read(0.25);
        is(scalar @readable, 1, "only one backend became readable");
        my $be = shift @readable;
        for (0 .. 2) {
            if ($be == $mbe[$_]) {
                $keymap{$key} = $_;
            }
        }
        is(scalar <$be>, "mg /test/$key\r\n", "got mg passthrough");
        print $be "EN\r\n";
        is(scalar <$ps>, "EN\r\n", "miss received");
    }
}

# Test backend table arguments and per-backend time overrides
my @holdbe = (); # avoid having the backends immediately disconnect and pollute log lines.
{
    # This should create three new backend sockets
    write_modefile('return "betable"');
    $p_srv->reload();
    wait_reload($watcher);

    # sleep a short time; b1 should have a very short timeout and the
    # others are long.
    select(undef, undef, undef, 0.5);

    my $s = IO::Select->new();
    for my $msrv (@mocksrvs) {
        $s->add($msrv);
    }
    my @readable = $s->can_read(0.25);
    # All three backends should have changed despite having the same label,
    # host, and port arguments.
    is(scalar @readable, 3, "all listeners became readable");

    like(<$watcher>, qr/ts=(\S+) gid=\d+ type=proxy_backend error=timeout name=\S+ port=11511/, "one backend timed out connecting");

    for my $msrv (@readable) {
        my $be = $msrv->accept();
        ok(defined $be, "mock backend accepted");
        like(<$be>, qr/version/, "received version command");
        print $be "VERSION 1.0.0-mock\r\n";
        push(@holdbe, $be);
    }

    # reload again and ensure no sockets become readable
    $p_srv->reload();
    wait_reload($watcher);
    @readable = $s->can_read(0.5);
    is(scalar @readable, 0, "no new sockets");
}

# Disconnect the existing sockets
@mbe = ();
@holdbe = ();
@mocksrvs = ();
$watcher = $p_srv->new_sock;
# Reset the watcher and let logs die off.
sleep 1;
print $watcher "watch proxyevents\n";
is(<$watcher>, "OK\r\n", "watcher enabled");

{
    # re-create the mock servers so we get clean connects, the previous
    # backends could be reconnecting still.
    for my $port (11514, 11515, 11516) {
        my $srv = mock_server($port);
        ok(defined $srv, "mock server created");
        push(@mocksrvs, $srv);
    }

    write_modefile('return "noiothread"');
    $p_srv->reload();
    wait_reload($watcher);

    my $s = IO::Select->new();
    for my $msrv (@mocksrvs) {
        $s->add($msrv);
    }
    my @readable = $s->can_read(0.25);
    # All three backends should become readable with new sockets.
    is(scalar @readable, 3, "all listeners became readable");

    my @bepile = ();
    my $bes = IO::Select->new(); # selector just for the backend sockets.
    # Each backend should create one socket per worker thread.
    for my $msrv (@readable) {
        my @temp = ();
        for (0 .. 3) {
            my $be = $msrv->accept();
            ok(defined $be, "mock backend accepted");
            like(<$be>, qr/version/, "received version command");
            print $be "VERSION 1.0.0-mock\r\n";
            $bes->add($be);
            push(@temp, $be);
        }
        for (0 .. 2) {
            if ($mocksrvs[$_] == $msrv) {
                $bepile[$_] = \@temp;
            }
        }
    }

    # clients round robin onto different worker threads, so we can test the
    # key dist on different offsets.
    my @cli = ();
    for (0 .. 2) {
        my $p = $p_srv->new_sock;

        for my $key (0 .. $keycount) {
            print $p "mg /test/$key\r\n";
            @readable = $bes->can_read(0.25);
            is(scalar @readable, 1, "only one backend became readable");
            my $be = shift @readable;
            # find which listener this be belongs to
            for my $x (0 .. 2) {
                for (@{$bepile[$x]}) {
                    if ($_ == $be) {
                        cmp_ok($x, '==', $keymap{$key}, "key routed to correct listener: " . $keymap{$key});
                    }
                }
            }

            is(scalar <$be>, "mg /test/$key\r\n", "got mg passthrough");
            print $be "EN\r\n";
            is(scalar <$p>, "EN\r\n", "miss received");
        }

        # hold onto the sockets just in case.
        push(@cli, $p);
    }

}

# TODO:
# remove backends
# do dead sockets close?
# adding user stats
# changing user stats
# adding backends with the same label don't create more connections
# total backend counters
# change top level routes mid-request
#  - send the request to backend
#  - issue and wait for reload
#  - read from backend and respond, should use the original code still.
#  - could also read from backend and then do reload/etc.

done_testing();

END {
    unlink $modefile;
}
