#!/usr/bin/perl
# Testing specifically how COLD and OLD work

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use MemcachedTest;
use Data::Dumper qw/Dumper/;

my $ext_path;
my $ext_path2;
my $ext_path3;

if (!supports_extstore()) {
    plan skip_all => 'extstore not enabled';
    exit 0;
}

$ext_path = "/tmp/extstore1.$$";
$ext_path2 = "/tmp/extstore2.$$";
$ext_path3 = "/tmp/extstore3.$$";

my $server = new_memcached("-m 256 -U 0 -o ext_page_size=8,ext_wbuf_size=2,ext_threads=1,ext_io_depth=2,ext_item_size=512,ext_item_age=0,ext_recache_rate=10000,ext_max_frag=0.9,ext_path=$ext_path:64m:default,ext_path=$ext_path2:64m:coldcompact,ext_path=$ext_path3:64m:old,slab_automove=1,ext_max_sleep=100000,hot_lru_pct=40,warm_lru_pct=40");
my $sock = $server->sock;

sub watch_compact {
    my $watcher = $server->new_sock;

    print $watcher "watch sysevents\n";
    my $res = <$watcher>;
    is($res, "OK\r\n", "watcher enabled");

    my $fragcount = 20;
    while (my $log = <$watcher>) {
        chomp $log;
        if ($log =~ m/type=compact_fraginfo/) {
            $fragcount--;
        } else {
            $fragcount = 20;
        }
        last if $fragcount < 1;
    }
}

my $value;
my $lvalue;
{
    my @chars = ("C".."Z");
    for (1 .. 20000) {
        $value .= $chars[rand @chars];
    }
    for (1 .. 15000) {
        $lvalue .= $chars[rand @chars];
    }
}

my $COLDC = 4;
my $OLD = 5;
{
    my $free_before = summarize_buckets(mem_stats($sock, ' extstore'));
    my $keycount = 1200;
    for (1 .. $keycount) {
        print $sock "set nfoo$_ 0 0 20000 noreply\r\n$value\r\n";
        print $sock "set lfoo$_ 0 0 20000 noreply\r\n$value\r\n";
    }
    # wait for a flush
    wait_ext_flush($sock);

    # ensure we didn't overflow into the new tiered buckets.
    my $free_now = summarize_buckets(mem_stats($sock, ' extstore'));
    is($free_now->[$COLDC], 8, "all COLDCOMPACT buckets are currently free");
    is($free_now->[$OLD], 8, "all OLD buckets are currently free");

    # ping all of the nfoo*'s so we get some LRU shuffle.
    for (1 .. $keycount) {
        print $sock "get nfoo$_\r\n";
        my $rline = scalar <$sock>;
        if ($rline eq "END\r\n") {
            fail("get nfoo$_ resulted in a miss");
        } elsif ($rline =~ m/^VALUE/) {
            my $body = scalar <$sock>;
            if ($body ne "$value\r\n") {
                fail("get nfoo$_ resulted in bad data: $body");
            } else {
                # END follows body
                my $end = scalar <$sock>;
                if ($end ne "END\r\n") {
                    fail("get nfoo$_ missing END: $end");
                }
            }
        }
    }

    # fill some more junk then check where data got pushed to.
    $keycount = 6000;
    for (1 .. $keycount) {
        print $sock "set kfoo$_ 0 0 20000 noreply\r\n$value\r\n";
    }
    wait_ext_flush($sock);
    # Wait for compaction to run before we try to load more data.
    watch_compact();
    $keycount = 6000;
    for (1 .. $keycount) {
        print $sock "set zfoo$_ 0 0 20000 noreply\r\n$value\r\n";
    }
    wait_ext_flush($sock);
    # Wait for compaction to settle again: important on slow systems.
    watch_compact();

    my $free_after = summarize_buckets(mem_stats($sock, ' extstore'));
    my $stats = mem_stats($sock);
    is($stats->{evictions}, 0, 'no RAM evictions');
    cmp_ok($stats->{extstore_page_allocs}, '>', 0, 'at least one page allocated');
    cmp_ok($stats->{extstore_page_evictions}, '>', 0, 'at least one page evicted');
    cmp_ok($stats->{extstore_objects_written}, '>', $keycount / 2, 'some objects written');
    cmp_ok($stats->{extstore_bytes_written}, '>', length($value) * 2, 'some bytes written');
    cmp_ok($stats->{get_extstore}, '>', 0, 'one object was fetched');
    cmp_ok($stats->{extstore_objects_read}, '>', 0, 'one object read');
    cmp_ok($stats->{extstore_bytes_read}, '>', length($value), 'some bytes read');
    cmp_ok($stats->{extstore_page_reclaims}, '>', 1, 'at least two pages reclaimed');
    cmp_ok($stats->{extstore_compact_rescues}, '>', 1, 'at least two compact rescues');
    cmp_ok($stats->{extstore_compact_resc_cold}, '>', 5, 'compact rescues to COLDCOMPACT');
    cmp_ok($stats->{extstore_compact_resc_old}, '>', 5, 'compact rescues to OLD');

    cmp_ok($free_before->[$COLDC], '>', $free_after->[$COLDC], 'fewer free coldcompact pages');
    cmp_ok($free_before->[$OLD], '>', $free_after->[$OLD], 'fewer free old pages');

}

sub summarize_buckets {
    my $s = shift;
    my @buks = ();
    my $is_free = 0;
    my $x = 0;
    while (exists $s->{$x . ':version'}) {
        #my $fb = $s->{$x . ':free_bucket'};
        #print STDERR "BYTES: [$x:$fb] ", $s->{$x . ':bytes'}, "\n";
        my $is_used = $s->{$x . ':version'};
        if ($is_used == 0) {
            # version of 0 means the page is free.
            $buks[$s->{$x . ':free_bucket'}]++;
        }
        $x++;
    }
    return \@buks;
}

done_testing();

END {
    unlink $ext_path if $ext_path;
    unlink $ext_path2 if $ext_path2;
    unlink $ext_path3 if $ext_path3;
}
