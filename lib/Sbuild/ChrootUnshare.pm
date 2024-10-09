#
# ChrootUnshare.pm: chroot library for sbuild
# Copyright © 2018      Johannes Schauer Marin Rodrigues <josch@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Sbuild::ChrootUnshare;

use strict;
use warnings;

use English;
use Sbuild::Utility;
use File::Temp qw(mkdtemp tempfile);
use File::Copy;
use Cwd qw(abs_path);
use Sbuild qw(shellescape);

BEGIN {
    use Exporter ();
    use Sbuild::Chroot;
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf, $chroot_id);
    bless($self, $class);

    return $self;
}

sub begin_session {
    my $self = shift;
    my $chroot = $self->get('Chroot ID');

    return 0 if !defined $chroot;

    my $namespace = undef;
    if ($chroot =~ m/^(chroot|source):(.+)$/) {
	$namespace = $1;
	$chroot = $2;
    }

    my $tarball = undef;
    if ($chroot =~ '/') {
	if (! -e $chroot) {
	    print STDERR "Chroot $chroot does not exist\n";
	    return 0;
	}
	$tarball = abs_path($chroot);
    } else {
	my $xdg_cache_home = $self->get_conf('HOME') . "/.cache/sbuild";
	if (defined($ENV{'XDG_CACHE_HOME'})) {
	    $xdg_cache_home = $ENV{'XDG_CACHE_HOME'} . '/sbuild';
	}

	if (opendir my $dh, $xdg_cache_home) {
	    while (defined(my $file = readdir $dh)) {
		next if $file eq '.' || $file eq '..';
		my $path = "$xdg_cache_home/$file";
		# FIXME: support directory chroots
		#if (-d $path) {
		#    if ($file eq $chroot) {
		#	$tarball = $path;
		#	last;
		#    }
		#} else {
		    if ($file =~ /^$chroot\.t.+$/) {
			$tarball = $path;
			last;
		    }
		#}
	    }
	    closedir $dh;
	}

	if (!defined($tarball)) {
	    print STDERR "Unable to find $chroot in $xdg_cache_home\n";
	    return 0;
	}
    }

    my @idmap = read_subuid_subgid;

    # sanity check
    if (   scalar(@idmap) != 2
        || $idmap[0][0] ne 'u'
        || $idmap[1][0] ne 'g'
        || length $idmap[0][1] == 0
        || length $idmap[0][2] == 0
        || length $idmap[1][1] == 0
        || length $idmap[1][2] == 0)
    {
        printf STDERR "invalid idmap\n";
        return 0;
    }

    $self->set('Uid Gid Map', \@idmap);

    my @cmd;
    my $exit;

    if(!test_unshare) {
	print STDERR "E: unable to to unshare\n";
	return 0;
    }

    my $rootdir = mkdtemp($self->get_conf('UNSHARE_TMPDIR_TEMPLATE'));

    @cmd = (
        'unshare',
        # comment to guide perltidy line wrapping
        '--map-user',   '0',
        '--map-group',  '0',
        '--map-users',  "$idmap[0][2],1,1",
        '--map-groups', "$idmap[1][2],1,1",
        'chown',        '1:1', $rootdir
    );
    if ($self->get_conf('DEBUG')) {
	printf STDERR "running @cmd\n";
    }
    system(@cmd);
    $exit = $? >> 8;
    if ($exit) {
	print STDERR "bad exit status ($exit): @cmd\n";
	return 0;
    }

    if (! -e $tarball) {
	print STDERR "$tarball does not exist, check \$unshare_tarball config option\n";
	return 0;
    }

    # The tarball might be in a location where it cannot be accessed by the
    # user from within the unshared namespace
    if (! -r $tarball) {
	print STDERR "$tarball is not readable\n";
	return 0;
    }

    print STDOUT "Unpacking $tarball to $rootdir...\n";
    @cmd = (
        "/usr/libexec/sbuild-usernsexec", (map { join ":", @{$_} } @idmap),
        "--",                      'tar',
        '--exclude=./dev/urandom', '--exclude=./dev/random',
        '--exclude=./dev/full',    '--exclude=./dev/null',
        '--exclude=./dev/console', '--exclude=./dev/zero',
        '--exclude=./dev/tty',     '--exclude=./dev/ptmx',
        '--directory',             $rootdir,
        '--extract'
    );
    push @cmd, get_tar_compress_options($tarball);

    if ($self->get_conf('DEBUG')) {
	printf STDERR "running @cmd\n";
    }
    my $pid = open(my $out, '|-', @cmd);
    if (!defined($pid)) {
	print STDERR "Can't fork: $!\n";
	return 0;
    }
    if (copy($tarball, $out) != 1) {
	print STDERR "copy() failed: $!\n";
	return 0;
    }
    close($out);
    $exit = $? >> 8;
    if ($exit) {
	print STDERR "bad exit status ($exit): @cmd\n";
	return 0;
    }

    $self->set('Session ID', $rootdir);

    $self->set('Location', '/sbuild-unshare-dummy-location');

    $self->set('Session Purged', 1);

    # if a source type chroot was requested, then we need to memorize the
    # tarball location for when the session is ended
    if (defined($namespace) && $namespace eq "source") {
	$self->set('Tarball', $tarball);
    }

    return 0 if !$self->_setup_options();

    return 1;
}

sub end_session {
    my $self = shift;

    return if $self->get('Session ID') eq "";

    my @idmap = read_subuid_subgid;

    if (defined($self->get('Tarball'))) {
	my ($tmpfh, $tmpfile) = tempfile("XXXXXX");
	my @program_list = ("/bin/tar", "-c", "-C", $self->get('Session ID'));
	push @program_list, get_tar_compress_options($self->get('Tarball'));
	push @program_list, './';

	print "I: Creating tarball...\n";
        open(
            my $in, '-|',
            "/usr/libexec/sbuild-usernsexec",
            (map { join ":", @{$_} } @idmap),
            "--", @program_list
        ) // die "could not exec tar";
	if (copy($in, $tmpfile) != 1 ) {
	    die "unable to copy: $!\n";
	}
	close($in) or die "Could not create chroot tarball: $?\n";

	move("$tmpfile", $self->get('Tarball'));
	chmod 0644, $self->get('Tarball');

	print "I: Done creating " . $self->get('Tarball') . "\n";
    }

    print STDERR "Cleaning up chroot (session id " . $self->get('Session ID') . ")\n"
    if $self->get_conf('DEBUG');

    # this looks like a recipe for disaster, but since we execute "rm -rf" with
    # lxc-usernsexec, we only have permission to delete the files that were
    # created with the fake root user
    my @cmd = (
        "/usr/libexec/sbuild-usernsexec",
        (map { join ":", @{$_} } @idmap),
        '--', 'rm', '-rf', $self->get('Session ID'));
    if ($self->get_conf('DEBUG')) {
	printf STDERR "running @cmd\n";
    }
    system(@cmd);
    # we ignore the exit status, because the command will fail to remove the
    # unpack directory itself because of insufficient permissions

    if(-d $self->get('Session ID') && !rmdir($self->get('Session ID'))) {
	print STDERR "unable to remove " . $self->get('Session ID') . ": $!\n";
	$self->set('Session ID', "");
	return 0;
    }

    $self->set('Session ID', "");

    return 1;
}

sub _get_exec_argv {
    my $self = shift;
    my $dir = shift;
    my $user = shift;
    my $disable_network = shift // 0;
    my $disable_setsid = shift // 0;

    # Detect whether linux32 personality might be needed
    my %personalities = (
	'armel:arm64'     => 1,
	'armhf:arm64'     => 1,
	'i386:amd64'      => 1,
	'mipsel:mips64el' => 1,
	'powerpc:ppc64'   => 1,
	's390:s390x'      => 1,
	'sparc:sparc64'   => 1,
    );
    my $linux32 = exists $personalities{($self->get_conf('BUILD_ARCH') . ':' . $self->get_conf('ARCH'))};

    my @bind_mounts = ();
    for my $entry (@{$self->get_conf('UNSHARE_BIND_MOUNTS')}) {
	push @bind_mounts, $entry->{directory}, $entry->{mountpoint};
    }

    return (
        'env',
        'PATH=' . $self->get_conf('PATH'),
        "USER=$user",
        "LOGNAME=$user",
        "/usr/libexec/sbuild-usernsexec",
        '--pivotroot',
        $linux32         ? ('--32bit') : (),
        $disable_network ? ('--nonet') : (),
        $disable_setsid  ? ('--nosetsid') : (),
        (map { join ":", @{$_} } read_subuid_subgid),
        $self->get('Session ID'),
        $user,
        $dir,
        @bind_mounts,
        '--'
    );
}

sub get_internal_exec_string {
    my $self = shift;

    return join " ", (map
	{ shellescape $_ }
	$self->_get_exec_argv('/', 'root'));
}

sub get_command_internal {
    my $self = shift;
    my $options = shift;

    # Command to run. If I have a string, use it. Otherwise use the list-ref
    my $command = $options->{'INTCOMMAND_STR'} // $options->{'INTCOMMAND'};

    my $user = $options->{'USER'};          # User to run command under
    my $dir;                                # Directory to use (optional)
    $dir = $self->get('Defaults')->{'DIR'} if
    (defined($self->get('Defaults')) &&
	defined($self->get('Defaults')->{'DIR'}));
    $dir = $options->{'DIR'} if
    defined($options->{'DIR'}) && $options->{'DIR'};

    if (!defined $user || $user eq "") {
	$user = $self->get_conf('USERNAME');
    }

    if (!defined($dir)) {
	$dir = '/';
    }

    my $disable_network = 0;
    if (defined($options->{'ENABLE_NETWORK'}) && $options->{'ENABLE_NETWORK'} == 0) {
	$disable_network = 1;
    }
    my $disable_setsid = 1;
    if (defined($options->{'SETSID'}) && $options->{'SETSID'} == 1) {
	$disable_setsid = 0;
    }

    my @cmdline = $self->_get_exec_argv($dir, $user, $disable_network, $disable_setsid);
    if (ref $command) {
	push @cmdline, @$command;
    } else {
	push @cmdline, ('/bin/sh', '-c', $command);
	$command = [split(/\s+/, $command)];
    }
    $options->{'USER'} = $user;
    $options->{'COMMAND'} = $command;
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'CHDIR'} = undef;
    $options->{'DIR'} = $dir;
}

# create users from outside the chroot so we don't need user/groupadd inside.
sub useradd {
    my $self = shift;
    my @args = @_;
    my $rootdir = $self->get('Session ID');
    return system(
        "/usr/libexec/sbuild-usernsexec",
        (map { join ":", @{$_} } read_subuid_subgid),
        "--",
        "/usr/sbin/useradd",
        "--no-log-init",
        "--prefix",
        $rootdir,
        @args
    );
}

sub groupadd {
    my $self = shift;
    my @args = @_;
    my $rootdir = $self->get('Session ID');
    return system(
        "/usr/libexec/sbuild-usernsexec",
        (map { join ":", @{$_} } read_subuid_subgid),
        "--", "/usr/sbin/groupadd", "--prefix", $rootdir, @args
    );
}

1;
