#!/usr/bin/perl -Tw
use strict;
use Irssi::TextUI;
use vars qw($VERSION %IRSSI);

$VERSION = "0.9.2";
%IRSSI = (
	authors 	=> "whiz",
	contact 	=> "whiz\@iki.fi",
	name 		=> "uutiset-ticker",
	description 	=> "follows requested channel and adds new events upon your choice to statusbar item",
);

# TODO
#######################################
# - ability to cache news while you are away, show them again when you arent away any longer
# - configurable layout, we need formatting
# - faster(?) showing rate for old news
# - rename finnish variable names to english, also statusbar item (doh! i should have done it earlier)
# - multiple news channels /uutiset add name channel nick ignore or something..
# - save archive/queue to disk if irssi crashes or something
# - save settings to disk, make better help
#######################################


# Changelog
#######################################
# 0.9.2	2005-12-18
#	- cleaned up get channel topic scripts.. put them into one function instead of copying same
#	  code multiple times
#
# 0.9.1	2005-12-18
#	- codez whined that I dont have /help command, so I added one.
#	- added command to empty archive
#
# 0.9	2005-12-18
#	- finally rotating things from the archive if no new news is provided, added settings to 
#	  enable/disable this
#	- added option to add topic into rotation of archive
#
# 0.8.2	2005-12-18
#	- topic didnt update if someone changed the channels topic, fixed it, it should work now.
#
# 0.8.1	2005-12-17
#	- fixed that annoying bug about news disappearing too fast
#
# 0.8	2005-12-17
#	- added archive for already published news
#	- added /uutiset archive|queue command to access uutiset queue and archive
#	- added enable/disable switch to archive, also added archive max size
#	- archive removes older news if max-size is reached
#	- still there is no use for archived news, maybe in 0.9
#
# 0.7	2005-12-17
#	- cleaned variables, now settings are in hashtable inside script
#	- now you should be able to make this script listen more than one channel
#	- made a debug function to clean things up
#	- massive rewrite of debug messages (mostly fin->en translations)
#
# 0.6	2005-12-17
#	- added some new variables to be set through /set, debugging and ability to leave
#	  last shown news last in statusbar. This disables the showing of the topic
#
# 0.5	2005-12-17
#	- updates channel topic when changing window, not only when timer is triggered
#	- refreshes statusbar item also when new news is found, not only when timer triggers it
#
# 0.4	2005-12-16
#	- shows current channel topic in statusbar item if there arent any news
#	  in the queue
#
# 0.3	2005-12-16
#	- more configurable, added all settings to be configured through /set
#
# 0.2	2005-12-16
#	- added timers, now it updates statusbar item every 15 seconds
#	- it has now a cache so that when news is picked up from #uutiset
#	  it adds it to cache and shows it when cache is emptied
#
# 0.1 	2005-12-15
#	- statusbar item, updating it when match found from channel #uutiset
#######################################

my @uutisjono;
my @uutisarchive;
my $uutinen = "";
my $topikki = 1;
my $timeout;
my $archive_current = 0;
my %settings;

Irssi::settings_add_int('misc', 'uutiset_ticker_refresh_rate', 15);
Irssi::settings_add_int('misc', 'uutiset_ticker_fallback_topic', 1);
Irssi::settings_add_int('misc', 'uutiset_ticker_debug', 0);
Irssi::settings_add_int('misc', 'uutiset_ticker_archive', 0);
Irssi::settings_add_int('misc', 'uutiset_ticker_archive_rotate_when_idle', 0);
Irssi::settings_add_int('misc', 'uutiset_ticker_archive_rotate_show_topic', 1);
Irssi::settings_add_int('misc', 'uutiset_ticker_archive_size', 60);
Irssi::settings_add_str('misc', 'uutiset_ticker_channel', "\#uutiset");
Irssi::settings_add_str('misc', 'uutiset_ticker_nick', "uutiset");
Irssi::settings_add_str('misc', 'uutiset_ticker_ignore', "^http");


sub setup {
	&debug("Setting script up timer and reloading statusbar item");
	$settings{"refresh_rate"} = 1 if $settings{"refresh_rate"} < 1;
	my $time = ($settings{"refresh_rate"}*1000);
	Irssi::timeout_remove($timeout);
	&reload();
	$timeout = Irssi::timeout_add($time, 'reload' , undef);
}


sub statusbar {
	my ($item, $get_size_only) = @_;
	$item->default_handler($get_size_only, undef, $uutinen, 1);
}

sub getchantopic {
	my $name = Irssi::active_win()->{active}->{name} || "(status)";
	my $channel = Irssi::Irc::Server->channel_find($name);
	return $channel->{topic};
}

sub reload { 
	if (!@uutisjono && $settings{"fallback_topic"}) {
		&debug("news queue is empty, getting window name instead");
		$uutinen = &getchantopic();
		$topikki = 1;
	} elsif (!@uutisjono && @uutisarchive && !$settings{"fallback_topic"} && $settings{"archive_rotate"}) {
		$uutinen = &getfromarchive();

	} else {
		&debug("there is things in news queue, getting them");
		$uutinen = pop(@uutisjono) || $uutinen;
		&archive($uutinen) if $uutinen ne "";
		$topikki = 0;
	}
	&debug("reloaded statusbar item");
	&debug("popped news from queue: $uutinen");
	Irssi::statusbar_items_redraw("uutiset");
}

sub window_changed {
	if (!@uutisjono && $topikki == 1 && $settings{"fallback_topic"}) {
		&debug("someone set us the bo.. ups, I mean window changed, updating topic");
		$uutinen = &getchantopic();
		Irssi::statusbar_items_redraw("uutiset");
		$topikki = 1;
	}
}

sub datetime {
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
	$mon++;
	$hour = "0".$hour if ($hour < 10);
	$min = "0".$min if ($min < 10);
	$sec = "0".$sec if ($sec < 10);
	return "$hour:$min:$sec";
}

sub detect_news {
        my ($server, $data, $nick, $mask, $target) = @_;
	if ($target =~ /$settings{"ticker_channel"}/i && $nick =~ /$settings{"ticker_nick"}/i ) {
		&debug("right channel found: ".$settings{"ticker_channel"}.", right nick found: ".$settings{"ticker_nick"});
		return 1 if ($data =~ /$settings{"ticker_ignore"}/);

		my $uutiset_jonossa = scalar @uutisjono;
		&debug("number of news in queue $uutiset_jonossa");

		unshift (@uutisjono, &datetime()." ".$data);
		&debug("added to queue: $data");

		if ($uutiset_jonossa == 0 && $topikki != 0) {
			&debug("queue is empty, showing new news immediately");
			&setup();
		} 

	}
        return 1;
}

sub debug {
	my ($debug_message) = @_;
	Irssi::print($IRSSI{"name"}.": ".$debug_message)  if $settings{"debug"};
}

sub setup_changed {
	&debug("someone called /set, getting newly set variables to scripts inner settings hashtable");
	$settings{"refresh_rate"} = Irssi::settings_get_int("uutiset_ticker_refresh_rate");
	$settings{"fallback_topic"} = Irssi::settings_get_int("uutiset_ticker_fallback_topic") ? 1 : 0;
	$settings{"debug"} = Irssi::settings_get_int("uutiset_ticker_debug") ? 1 : 0;
	$settings{"archive"} = Irssi::settings_get_int("uutiset_ticker_archive") ? 1 : 0;
	$settings{"archive_rotate"} = Irssi::settings_get_int("uutiset_ticker_archive_rotate_when_idle") ? 1 : 0;
	$settings{"archive_rotate_show_topic"} = Irssi::settings_get_int("uutiset_ticker_archive_rotate_show_topic") ? 1 : 0;
	$settings{"archive_size"} = Irssi::settings_get_int("uutiset_ticker_archive_size") || 10;
	$settings{"ticker_channel"} = Irssi::settings_get_str("uutiset_ticker_channel");
	$settings{"ticker_nick"} = Irssi::settings_get_str("uutiset_ticker_nick");
	$settings{"ticker_ignore"} = Irssi::settings_get_str("uutiset_ticker_ignore");

	$settings{"fallback_topic"} = 0 if $settings{"archive_rotate"};

	&setup;
}

sub archive {
	my ($uutinen) = @_;
	return if !$settings{"archive"};
	unshift (@uutisarchive, $uutinen);
	&debug("added current news to archive");
	while (@uutisarchive > $settings{"archive_size"}) {
		my $removed_uutinen = pop(@uutisarchive);
		&debug("removed $removed_uutinen from archive");
	}

}

sub getfromarchive {
	$archive_current = 0 if $archive_current > @uutisarchive;
	my $archived_uutinen = "";
	my $archive_count = 0;	
	&debug("accessing archive, going through saved messages");
	foreach my $archived (@uutisarchive) {
		$archived_uutinen = $archived if $archive_count == $archive_current;
		$archive_count++;
	}
	$archive_current++;
	if ($archived_uutinen eq "" && $settings{"archive_rotate_show_topic"}) {
		&debug("showing channel topic when in the end of archive");
		$archived_uutinen = &getchantopic();
	}

	$archived_uutinen = $uutinen if $archived_uutinen eq "";

	return $archived_uutinen;
}

sub cmd_uutiset {
	my ($cmd) = @_;
	Irssi::print(".-uutiset---------");
	if ($cmd eq "queue") { foreach my $uutinen (@uutisjono) { Irssi::print("| ".$uutinen); } Irssi::print("| count: ".@uutisjono); }
	elsif ($cmd eq "archive") { foreach my $uutinen (@uutisarchive) { Irssi::print("| ".$uutinen); } Irssi::print("| count: ".@uutisarchive); }

	elsif ($cmd eq "add_a_to_q") { push(@uutisjono, @uutisarchive); Irssi::print("| added archive to end of queue"); }
	elsif ($cmd eq "reset_archive") { undef @uutisarchive; Irssi::print("| archive is now empty"); }
	elsif ($cmd eq "help") { Irssi::print("| SEVO"); }
	else {
		Irssi::print("| /uutiset queue - prints current news in output queue");
		Irssi::print("| /uutiset archive - prints news in archive");
		Irssi::print("| /uutiset reset_archive - resets archive");
		Irssi::print("| /uutiset add_a_to_q - adds archive to end of queue");
		Irssi::print("| ");
		Irssi::print("| archive not in use") if !$settings{"archive"};
		Irssi::print("| archive is enabend (max size ".$settings{"archive_size"}.")") if $settings{"archive"};
	}
	Irssi::print("'-----------------");

}

&setup;
&setup_changed;

Irssi::print($IRSSI{"name"}." v".$VERSION." loaded (type '/uutiset help' for help)");
# statusbar item
Irssi::statusbar_item_register('uutiset','{sb $0-}', 'statusbar');

# bind ourself to message public signal and other signals
Irssi::signal_add_last('message public', 'detect_news');
Irssi::signal_add("setup changed", "setup_changed");
Irssi::signal_add("window changed", "window_changed");
Irssi::signal_add("channel topic changed", "window_changed");

# bind a commands for us
Irssi::command_bind('uutiset',\&cmd_uutiset);
