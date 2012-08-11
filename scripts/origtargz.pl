#!/usr/bin/perl
#
# origtargz: fetch the orig tarball of a Debian package from various sources,
# and unpack it
# Copyright (C) 2012  Christoph Berg <myon@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 NAME

origtargz - fetch the orig tarball of a Debian package from various sources, and unpack it

=head1 SYNOPSIS

=over

=item B<origtargz> [B<--unpack>[=B<no>|B<once>|B<yes>]]

=item B<origtargz> B<--help>

=back

=head1 DESCRIPTION

B<origtargz> downloads the orig tarball of a Debian package, and optionally
unpacks it into the current directory. The version number to be used is
determined from B<debian/changelog>. The main use for B<origtargz> is with
debian-dir-only repository checkouts. It should be invoked from the top level
directory of an unpacked Debian source package.

Various download locations are tried. First, an existing file is looked for.
Then, B<apt-get source> is tried when B<apt-cache showsrc> reports a matching
version. Finally, B<uscan --download-current-version> is tried.

When asked to unpack the orig tarball, B<origtargz> will remove all files and
directories from the current directory, except the debian directory, and the
VCS repository directories. Some files outside debian/ which are often stored
in VCS even for debian-dir-only repositories are also preserved (.bzr-builddeb,
.gitignore, .hgignore).

The default behavior is to unpack the orig tarball on the first invocation of
B<origtargz> in a debian-dir-only checkout.

=head1 OPTIONS

=over

=item B<-u>, B<--unpack>[=B<no>|B<once>|B<yes>]

Unpack the downloaded orig tarball to the current directory, replacing
everything except the debian directory. Valid choices are:

=over

=item B<no>

Do not unpack the orig tarball.

=item B<once> (default when --unpack is not used)

If the current directory contains only a debian directory (and possibly some
dotfiles), unpack the orig tarball. This is the default behavior.

=item B<yes> (default for --unpack without argument)

Always unpack the orig tarball. Existing files are removed, except for debian/
and VCS files. Preserved are: B<.bzr .bzrignore .bzr-builddeb .git .gitignore
.hg .hgignore .svn>.

=back

=back

=cut

#=head1 CONFIGURATION VARIABLES
#
#The two configuration files F</etc/devscripts.conf> and
#F<~/.devscripts> are sourced by a shell in that order to set
#configuration variables. Command line options can be used to override
#configuration file settings. Environment variable settings are ignored
#for this purpose. The currently recognised variables are:

=head1 SEE ALSO

B<debcheckout>(1).

=head1 AUTHOR

B<origtargz> and this manpage have been written by Christoph Berg
<I<myon@debian.org>>.

=cut

# option parsing

use strict;
use warnings;
use File::Temp qw/tempdir/;
use Getopt::Long qw(:config gnu_getopt);
use Pod::Usage;

my $unpack = 'once'; # default when --unpack is not used

GetOptions(
	"help|h" => sub { pod2usage({-exitval => 0, -verbose => 1}); },
	"unpack|u:s" => \$unpack,
) or pod2usage({-exitval => 3});

$unpack = 'yes' if (defined $unpack and $unpack eq ''); # default for --unpack without argument
pod2usage({-exitval => 3}) if (@ARGV > 0 or $unpack !~ /^(no|once|yes)$/);

# get package name and version number

my ($package, $version, $origversion, $fileversion);

open F, "debian/changelog" or die "debian/changelog: $!\n";
my $line = <F>;
close F;
unless ($line =~ /^(\S+) \((\S+)\)/) {
	die "could not parse debian/changelog:1: $line";
}
($package, $version) = ($1, $2);
die "Version $version contains no dash, unable to download orig.tar.* file for native packages\n"
	unless ($version =~ /-/);
$origversion = $version;
$origversion =~ s/(.*)-.*/$1/; # strip everything from the last dash
$fileversion = $origversion;
$fileversion =~ s/^\d+://; # strip epoch

sub download_origtar ()
{
	# look for an existing file

	if (my @f = glob "../${package}_$fileversion.orig.tar.*") {
		print "Using existing $f[0]\n";
		return $f[0];
	}

	# TODO: try other well-known file locations (../upstream/ ?) and move file in place

	# TODO: try pristine-tar

	# try apt-get source

	open S, "apt-cache showsrc '$package' |";
	my @showsrc;
	{
		local $/;
		@showsrc = <S>;
	}
	close S;

	my $bestsrcversion;
	foreach my $src (@showsrc) {
		$src =~ /^Package: (.*)/m or next;
		next if ($1 ne $package); ; # should never trigger, but who knows
		$src =~ /^Version: (.*)/m or next;
		my $srcversion = $1;
		my $srcorigversion = $srcversion;
		$srcorigversion =~ s/(.*)-.*/$1/; # strip everything from the last dash
		print "Looking at $package $srcversion, interpreted as $srcorigversion\n";

		if ($srcorigversion eq $origversion) { # loop through all matching versions
			$bestsrcversion = $srcversion;
			last if ($srcversion eq $version); # break if exact match
		}
	}

	if ($bestsrcversion) {
		print "Trying apt-get source $package=$bestsrcversion ...\n";
		system "cd .. && apt-get source --only-source --download-only '$package=$bestsrcversion'";
	}

	if (my @f = glob "../${package}_$fileversion.orig.tar.*") {
		return $f[0];
	}

	# try uscan

	if (-f "debian/watch") {
		print "Trying uscan --download-current-version ...\n";
		system "uscan --download-current-version\n";
	}

	if (my @f = glob "../${package}_$fileversion.orig.tar.*") {
		return $f[0];
	}

	print "Could not find any location for ${package}_$fileversion.orig.tar.*\n";
	return undef;
}

sub clean_checkout ()
{
	# delete all files except debian/, our VCS checkout, and some files
	# often in VCS outside debian/ even in debian-dir-only repositories
	opendir DIR, '.' or die "opendir: $!";
	my @rm;
	while (my $file = readdir DIR) {
		next if ($file eq '.' or $file eq '..');
		next if ($file eq 'debian');
		next if ($file =~ /^(\.bzr|\.git|\.hg|\.svn|CVS)$/);
		if ($file =~ /^(\.bzr(ignore|-builddeb)|\.gitignore|\.hgignore)$/) {
			print "Notice: not deleting $file (likely to come from VCS checkout)\n";
			next;
		}
		push @rm, $file;
	}
	close DIR;
	system ('rm', '-rf', @rm);
}

sub unpack_tarball ($)
{
	my $origtar = shift;
	my $tmpdir = File::Temp->newdir(DIR => ".", CLEANUP => 1);

	print "Unpacking $origtar\n";

	# unpack
	chdir $tmpdir or die "chdir $tmpdir: $!";
	system ('tar', 'xf', "../$origtar");
	if ($? >> 8) {
		print STDERR "tar xf $origtar failed\n";
		return 0;
	}
	chdir '..';

	# figure out which directory was created
	my @dirs = glob "$tmpdir/*/";
	unless (@dirs) {
		print STDERR "tar xf $origtar did not create any directory\n";
		return 0;
	}
	my $directory = $dirs[0];
	chop $directory;

	# move all files over, except the debian directory
	opendir DIR, $directory or die "opendir $directory: $!";
	foreach my $file (readdir DIR) {
		if ($file eq 'debian') {
			system ('rm', '-rf', "$directory/$file");
			next;
		} elsif ($file eq '.' or $file eq '..') {
			next;
		}
		unless (rename "$directory/$file", "$file") {
			print STDERR "rename $directory/$file $file: $!\n";
			return 0;
		}
	}
	closedir DIR;
	rmdir $directory;

	return 1;
}

my $origtar = download_origtar;
exit 1 unless ($origtar);

if ($unpack eq 'once') {
	my @files = glob '*'; # ignores dotfiles
	if (@files == 1) { # this is debian/, we have already opened debian/changelog
		unpack_tarball ($origtar) or exit 1;
	}
} elsif ($unpack eq 'yes') {
	clean_checkout;
	unpack_tarball ($origtar) or exit 1;
}

exit 0;
