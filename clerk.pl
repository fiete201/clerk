#!/usr/bin/env perl

binmode(STDOUT, ":utf8");
use v5.10;
use warnings;
use strict;
use utf8;
use Config::Simple;
use DDP;
use Data::Dumper;
use Data::MessagePack;
use File::Basename;
use File::Path qw(make_path);
use File::Slurper 'read_binary';
use File::stat;
use Getopt::Std;
use HTTP::Date;
use IO::Select;
use IPC::Run qw( timeout start );
use List::Util qw(any);
use Net::MPD;
use autodie;

$ENV{TMUX_TMPDIR}='/tmp/clerk/tmux';
my $tmux_config='/etc/clerk/tmux.conf';
make_path($ENV{TMUX_TMPDIR}) unless(-d $ENV{TMUX_TMPDIR});

my $config_file = $ENV{'HOME'} . "/.config/clerk/clerk.conf";

if ($ENV{CLERK_CONF}) {
	$config_file = $ENV{CLERK_CONF};
}

# read configuration file
my $cfg = new Config::Simple(filename=>"$config_file");

my $general_cfg = $cfg->param(-block=>"General");
my $mpd_host = $general_cfg->{mpd_host};
my $db_file = $general_cfg->{database};
my $backend = $general_cfg->{backend};
my $chunksize = $general_cfg->{chunksize};

my $columns_cfg = $cfg->param(-block=>"Columns");
my $albumartist_l = $columns_cfg->{albumartist_l};
my $album_l = $columns_cfg->{album_l};
my $date_l = $columns_cfg->{date_l};
my $title_l = $columns_cfg->{title_l};
my $track_l = $columns_cfg->{track_l};
my $artist_l = $columns_cfg->{artist_l};

if ($ENV{CLERK_BACKEND}) {
	$backend = $ENV{CLERK_BACKEND};
}

# open connection to MPD
my $mpd = Net::MPD->connect($ENV{MPD_HOST} // $mpd_host // 'localhost');

sub main {
	create_db();
	if ($backend eq "fzf") {
		system('tmux', 'has-session', '-t', 'music');
		if ($? != -0) {
			system('tmux', '-f', $tmux_config, 'new-session', '-s', 'music', '-n', 'albums', '-d', './clerk.pl', '-a');
			system('tmux', 'new-window', '-t', 'music', '-n', 'tracks', './clerk.pl', '-t');
	#		system('tmux', 'new-window', '-t', 'music', '-n', 'latest', './clerk_fzf', '--latest');
			system('tmux', 'new-window', '-t', 'music', '-n', 'playlists', './clerk.pl', '-l');
			system('tmux', 'new-window', '-t', 'music', '-n', 'queue', 'ncmpcpp');
		}
		system('tmux', 'attach', '-t', 'music');
	}
#	elsif ($backend eq "rofi") {
		my %options=();
		getopts("tal", \%options);

		if (defined $options{t}) {
			list_db_entries_for("Tracks");
		} elsif (defined $options{a}) {
			list_db_entries_for("Albums");
		} elsif (defined $options{l}) {
			list_playlists();
		}
}


sub create_db {
	# Get database copy and save as messagepack file, if file is either missing
	# or older than latest mpd database update.
	# get number of songs to calculate number of searches needed to copy mpd database
	my $mpd_stats = $mpd->stats();
	my $songcount = $mpd_stats->{songs};
	my $last_update = $mpd_stats->{db_update};

	if (!-f "$db_file" || stat("$db_file")->mtime < $last_update) {
		print STDERR "::: No cache found or cache file outdated\n";
		print STDERR "::: Chunksize set to $chunksize songs\n";
		my $times = int($songcount / $chunksize + 1);
		print STDERR "::: Requesting $times chunks from MPD\n";
		my @db;
		# since mpd will silently fail, if response is larger than command buffer, let's split the search.
		my $chunk_size = $chunksize;
		for (my $i=0;$i<=$songcount;$i+=$chunk_size) {
			my $endnumber = $i+$chunk_size; 
			my @temp_db = $mpd->search('filename', '', 'window', "$i:$endnumber");
			push @db, @temp_db;
		}

		# only save relevant tags to keep messagepack file small
		# note: maybe use a proper database instead? See list_album function.
		my @filtered = map { $_->{mtime} = str2time($_->{'Last-Modified'}); +{$_->%{qw/Album Artist Date AlbumArtist Title Track uri mtime/}} } @db;
		pack_msgpack(\@filtered);
	}
}

sub backend_call {
	my ($in, $fields) = @_;
	my $input;
	my $out;
	$fields //= "1,2,3";
	my %backends = (
		fzf => [ qw(fzf
			--reverse
			--no-sort
			-m
			-e
			-i
			-d
			\t
			--tabstop=4
			+s
			--ansi),
			"--with-nth=$fields"
		],
		rofi => [
			'rofi',
			'-width',
			'1300',
			'-dmenu',
			'-multi-select',
			'-i',
			'-p',
			'> '
		]
	);
	my $handle = start $backends{$backend} // die('backend not found'), \$input, \$out;
	$input = join "", (@{$in});
	finish $handle or die "No selection";
	return $out;
}

sub pack_msgpack {
	my ($filtered_db) = @_;
	my $msg = Data::MessagePack->pack($filtered_db);
	my $filename = "$db_file";
	open(my $out, '>:raw', $filename) or die "Could not open file '$filename' $!";
	print $out $msg;
	close $out;
}
	
sub unpack_msgpack {
	my $mp = Data::MessagePack->new->utf8();
	my $msgpack = read_binary("$db_file");
	my $rdb = $mp->unpack($msgpack);
	return $rdb;
}

sub do_action {
	my ($in, $context) = @_;
	my @action_items = ("Add\n", "Replace\n");
	my $action = backend_call(\@action_items);
	if ($action eq "Replace\n") {
		$mpd->clear();
	}
	my $input;
	if ($context eq "playlist") {
		chomp $in;
		$mpd->load("$in");
	} elsif ($context eq "tracks") {
		foreach my $line (split /\n/, $in) {
			my $uri = (split /[\t\n]/, $line)[-1];
			$mpd->add($uri);
		}
	}
	if ($action eq "Replace\n") {
		$mpd->play();
	}
	my @queue_cmd = ('tmux', 'findw', '-t', 'music', 'queue');
	system(@queue_cmd);
}

sub list_playlists {
	my @playlists = $mpd->list_playlists();
	my $output = formated_playlists(\@playlists);

	for (;;) {
		my $out = backend_call($output);
		do_action($out, "playlist");
	}
}

sub formated_albums {
	my ($rdb) = @_;

	my %uniq_albums;
	for my $i (@$rdb) {
		my $newkey = join "", map { lc } $i->@{qw/AlbumArtist Album Date/};
		if (!exists $uniq_albums{$newkey}) {
			my $dir = (dirname($i->{uri}) =~ s/\/CD.*$//r);
			$uniq_albums{$newkey} = {$i->%{qw/AlbumArtist Album Date mtime/}, Dir => $dir};
		} else {
			if ($uniq_albums{$newkey}->{'mtime'} < $i->{'mtime'}) {
				$uniq_albums{$newkey}->{'mtime'} = $i->{'mtime'}
			}
		}
	}

	my @albums;
	my $fmtstr = join "", map {"%-${_}.${_}s\t"} ($albumartist_l, $date_l, $album_l);
	for my $k (sort keys %uniq_albums) {
		push @albums, sprintf $fmtstr."%s\n", $uniq_albums{$k}->@{qw/AlbumArtist Date Album Dir/};

	}

	return \@albums;
}

sub formated_tracks {
	my ($rdb) = @_;
	my $fmtstr = join "", map {"%-${_}.${_}s\t"} ($track_l, $title_l, $artist_l, $album_l);
	my @tracks = map {
		sprintf $fmtstr."%-s\n", $_->@{qw/Track Title Artist Album uri/}
	} @{$rdb};

	return \@tracks;
}

sub formated_playlists {
    my ($rdb) = @_;
    my @playlists = map {
    	sprintf "%s\n", $_->{playlist}
    } @{$rdb};

    return \@playlists;
}

sub list_db_entries_for {
	my ($kind) = @_;
	die "Wrong kind" unless any {; $_ eq $kind} qw/Albums Tracks/;

	my $rdb = unpack_msgpack();
	my %fields = (Albums=> "1,2,3", Tracks => "1,2,3,4");
	my %formater = (Albums => \&formated_albums, Tracks => \&formated_tracks);

	my $output = $formater{$kind}->($rdb);
	for (;;) {
		my $out = backend_call($output, $fields{$kind});
		do_action($out, "tracks");
	}
}

main;
