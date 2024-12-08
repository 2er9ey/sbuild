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
use File::Path qw(make_path);
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

sub find_tarball {
    my $self           = shift;
    my ($chroot)       = @_;
    my $tarball        = undef;
    my $xdg_cache_home = $self->get_conf('HOME') . "/.cache/sbuild";
    if (length($ENV{'XDG_CACHE_HOME'})) {
        $xdg_cache_home = $ENV{'XDG_CACHE_HOME'} . '/sbuild';
    }
    if (opendir my $dh, $xdg_cache_home) {
        while (defined(my $file = readdir $dh)) {
            next if $file eq '.' || $file eq '..';
            my $path = "$xdg_cache_home/$file";
            if (-z $path) {
                print STDERR "I: ignoring $path (zero size)\n";
                next;
            }
            if ($file =~ /^$chroot\.t.+$/) {
                $tarball = $path;
                last;
            }
        }
        closedir $dh;
    }
    return $tarball;
}

sub chroot_tarball_if_too_old {
    my $self   = shift;
    my $chroot = shift;
    if ($chroot =~ '/') {
        # if the user passed a tarball explicitly, never update it
        return undef;
    }
    my $tarball = $self->find_tarball($chroot);
    if (!defined($tarball)) {
        # We end up here if the user added the --chroot option but there
        # was no associated tarball found. Create a new tarball using the
        # chroot name.
        my $xdg_cache_home = $self->get_conf('HOME') . "/.cache/sbuild";
        if (length($ENV{'XDG_CACHE_HOME'})) {
            $xdg_cache_home = $ENV{'XDG_CACHE_HOME'} . '/sbuild';
        }
        $tarball = "$xdg_cache_home/$chroot.tar";
    }

    my $max_age = $self->get_conf('UNSHARE_MMDEBSTRAP_MAX_AGE');
    if (!-e $tarball) {
        print STDERR "I: Chroot Tarball $tarball does not exist yet\n";
        if ($max_age < 0) {
            print STDERR "I: Not updating it due to negative maximum age\n";
            return undef;
        }
        return $tarball;
    }
    # negative max-age indicates to never update
    # if an existing tarball is too young, don't update
    my $age = time - (stat($tarball))[9];
    if ($max_age >= 0 && $age >= $max_age) {
        my $config_path = '~/.config/sbuild/config.pl';
        if (length($ENV{'XDG_CONFIG_HOME'})) {
            $config_path = $ENV{'XDG_CONFIG_HOME'} . '/sbuild/config.pl';
        }
        print STDERR "I: Existing chroot tarball is too old ("
          . (
            sprintf '%.2f >= %.2f',
            ($age / 60 / 60 / 24),
            ($max_age / 60 / 60 / 24)) . " days):\n";
        print STDERR ("I: Change the maximum age by setting "
              . "\$unshare_mmdebstrap_max_age (in seconds)\n"
              . "I: in your $config_path or disable it by "
              . "setting it to a negative value.\n");
        return $tarball;
    }
    return undef;
}

# from List/MoreUtils/PP.pm
sub natatime ($@) {
    my $n    = shift;
    my @list = @_;
    return sub { return splice @list, 0, $n; }
}

sub chroot_auto_create {
    my $self    = shift;
    my $chroot  = shift;
    my $rootdir = shift;
    my $dist    = $self->get_conf('DISTRIBUTION');
    my $arch    = $self->get_conf('BUILD_ARCH');

    my $xdg_cache_home = $self->get_conf('HOME') . "/.cache/sbuild";
    if (length($ENV{'XDG_CACHE_HOME'})) {
        $xdg_cache_home = $ENV{'XDG_CACHE_HOME'} . '/sbuild';
    }

    # mmdebstrap chooses Essential:yes packages from the given
    # distribution, so for experimental or backports, we have to
    # pass a different dist (unstable and stable, respectively). We could
    # also pass an empty dist string but then mmdebstrap cannot anymore
    # choose the stable mirrors for us.
    my $basedist = $dist;
    if (scalar(@{ $self->get_conf('UNSHARE_MMDEBSTRAP_DISTRO_MANGLE') })) {
        if (
            scalar(@{ $self->get_conf('UNSHARE_MMDEBSTRAP_DISTRO_MANGLE') })
            % 2 != 0) {
            print STDERR
              "W: length of UNSHARE_MMDEBSTRAP_DISTRO_MANGLE is uneven\n";
        }
        my $it = natatime 2,
          @{ $self->get_conf('UNSHARE_MMDEBSTRAP_DISTRO_MANGLE') };
        while (my ($k, $v) = $it->()) {
            if ($dist !~ m/$k/) {
                next;
            }
            # 'my worst Perl line ever' Stefano Zacchiroli 2008
            # 'I'm sorry' Johannes Schauer Marin Rodrigues 2024
            ($basedist = $dist) =~ s/$k/"qq{$v}"/ee;
            print STDERR ("I: Applied base distribution name mangle rule "
                  . "s/$k/$v/ turning \"$dist\" into \"$basedist\"\n");
            last;
        }
    }

    my @commonargs = (
        "mmdebstrap",   "--variant=buildd",
        "--arch=$arch", "--skip=output/mknod",
        "--format=tar", $basedist,
    );
    my $extraargs = [];
    {
        my $ea_conf = $self->get_conf('UNSHARE_MMDEBSTRAP_EXTRA_ARGS');
        next if !defined $ea_conf;
        # more specific entries overwrite less specific entries
        foreach my $arg ("*", $dist, "$dist-$arch", $chroot) {
            next if !defined $arg;
            next if !exists ${$ea_conf}{$arg};
            next if ref(${$ea_conf}{$arg}) ne "ARRAY";
            $extraargs = ${$ea_conf}{$arg};
        }
    }

    if ($self->get_conf('UNSHARE_MMDEBSTRAP_KEEP_TARBALL')) {
        # the tarball is supposed to be kept but maybe we don't need to
        # create one because the existing one is new enough

        make_path($xdg_cache_home, { error => \my $err });
        if (@$err) {
            print STDERR "W: failed to create $xdg_cache_home\n";
        }

        my $tarball = undef;
        if (defined $chroot) {
            $tarball = $self->chroot_tarball_if_too_old($chroot);
            if (!defined $tarball) {
                return $chroot;
            }
        } else {
            # chroot was not found by Sbuild::ChrootInfoUnshare, so we
            # build a new one
            $tarball = "$xdg_cache_home/$dist-$arch.tar";
            $chroot  = "$xdg_cache_home/$dist-$arch.tar";
            $self->set('Chroot ID', $chroot);
        }
        print STDERR ("I: Creating new chroot tarball:\n"
              . join(" ", (@commonargs, $tarball, @{$extraargs}))
              . "\n");

        my $exit_code = system @commonargs, $tarball, @{$extraargs};
        if ($exit_code != 0) {
            print STDERR "mmdebstrap failed\n";
            unlink $tarball;
            return undef;
        }

        print STDERR "I: Placed new chroot tarball at $tarball\n";

        return $chroot;
    }

    # UNSHARE_MMDEBSTRAP_AUTO_CREATE is true
    # UNSHARE_MMDEBSTRAP_KEEP_TARBALL is false
    #
    # This means we want to automatically create the chroot but not
    # keep the tarball.

    if (defined $chroot && !defined $self->chroot_tarball_if_too_old($chroot))
    {
        return $chroot;
    }

    # chroot was found but UNSHARE_MMDEBSTRAP_KEEP_TARBALL was
    # false so if the existing tarball is too old, don't use it
    # if Chroot ID was undefined, then Sbuild::ChrootInfoUnshare
    # was unable to find a chroot tarball and
    # UNSHARE_MMDEBSTRAP_KEEP_TARBALL is false. In that case, we
    # create a chroot environment on-demand using mmdebstrap
    {
        # we do not create a directory with mmdebstrap directly but pipe a
        # tarball to /usr/libexec/sbuild-usernsexec so that the uid range
        # chosen by mmdebstrap is independent from the uid range allocation
        # algorithm as implemented by /usr/libexec/sbuild-usernsexec

        pipe my $tar_reader, my $mm_writer;

        my $mmpid = fork();
        if ($mmpid == 0) {
            # child process
            open(STDOUT, '>&', $mm_writer) or die "cannot open STDOUT: $!";
            close $tar_reader or die "cannot close tar_reader: $!";
            my @cmdline = (@commonargs, "-", @{$extraargs});

            print STDERR ("I: Creating chroot on-demand by running:\n"
                  . join(" ", @cmdline)
                  . "\n");
            exec @cmdline;
        }
        my $tarpid = fork();
        if ($tarpid == 0) {
            # child process
            open(STDIN, '<&', $tar_reader) or die "cannot open STDIN: $!";
            close $mm_writer               or die "cannot close mm_writer: $!";
            print STDERR "I: Unpacking tarball from STDIN to $rootdir...\n";
            my @idmap   = read_subuid_subgid;
            my @cmdline = (
                "/usr/libexec/sbuild-usernsexec",
                (map { join ":", @{$_} } @idmap),
                '--', 'tar', '--directory', $rootdir, '--extract'
            );

            if ($self->get_conf('DEBUG')) {
                printf STDERR "running " . join(" ", @cmdline) . "\n";
            }

            exec @cmdline;
        }
        close($tar_reader);
        close($mm_writer);
        waitpid($mmpid, 0);
        if ($? != 0) {
            print STDERR "mmdebstrap failed\n";
            return undef;
        }
        waitpid($tarpid, 0);
        if ($? != 0) {
            print STDERR "mmdebstrap failed\n";
            return undef;
        }
    }

    $chroot = "$xdg_cache_home/$dist-$arch.tar";
    print STDERR ("I: The chroot directory at $rootdir will be removed "
          . "at the end of the build\n");
    print STDERR ("I: To avoid creating a new chroot from "
          . "scratch every time, either:\n");
    print STDERR (
            "I:  - place a chroot tarball at $chroot and update it manually, "
          . "for example by running: ");
    print STDERR (
          (join " ", @commonargs)
        . " $chroot "
          . (
            scalar @{$extraargs} > 0
            ? (join " ", @{$extraargs})
            : ""
          )
          . "\n"
    );
    my $config_path = '~/.config/sbuild/config.pl';
    if (length($ENV{'XDG_CONFIG_HOME'})) {
        $config_path = $ENV{'XDG_CONFIG_HOME'} . '/sbuild/config.pl';
    }
    print STDERR ("I:  - or let sbuild take care of this via the setting "
          . "UNSHARE_MMDEBSTRAP_KEEP_TARBALL by adding "
          . "'\$unshare_mmdebstrap_keep_tarball = 1;' to your $config_path.\n"
    );
    print STDERR ("I:  - or completely disable this behaviour via the setting "
          . "UNSHARE_MMDEBSTRAP_AUTO_CREATE by adding "
          . "'\$unshare_mmdebstrap_auto_create = 0;' to your $config_path.\n");
    print STDERR (
            "I: Refer to UNSHARE_MMDEBSTRAP_KEEP_TARBALL in sbuild.conf(5) "
          . "for more information\n");
    $chroot = $rootdir;
    $self->set('Chroot ID', $chroot);

    return $chroot;
}

sub begin_session {
    my $self   = shift;
    my $chroot = $self->get('Chroot ID');

    my $rootdir = mkdtemp($self->get_conf('UNSHARE_TMPDIR_TEMPLATE'));

    my $namespace = undef;
    if (defined $chroot && $chroot =~ m/^(chroot|source):(.+)$/) {
        $namespace = $1;
        $chroot    = $2;
    }

    if (!$self->get_conf('UNSHARE_MMDEBSTRAP_AUTO_CREATE') && !defined $chroot)
    {
        print STDERR ("E: unable to find chroot and "
              . "UNSHARE_MMDEBSTRAP_AUTO_CREATE is disabled\n");
        return 0;
    }

    my @idmap = read_subuid_subgid;

    # sanity check
    if (   scalar(@idmap) != 2
        || $idmap[0][0] ne 'u'
        || $idmap[1][0] ne 'g'
        || length $idmap[0][1] == 0
        || length $idmap[0][2] == 0
        || length $idmap[1][1] == 0
        || length $idmap[1][2] == 0) {
        printf STDERR "invalid idmap\n";
        return 0;
    }

    $self->set('Uid Gid Map', \@idmap);

    my @cmd;
    my $exit;

    if (!test_unshare) {
        print STDERR "E: unable to to unshare\n";
        return 0;
    }

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

    if ($self->get_conf('UNSHARE_MMDEBSTRAP_AUTO_CREATE')) {
        # in this branch we maybe are either:
        #  - creating a new chroot tarball if $chroot is undefined or
        #  - update an existing tarball or
        #  - create a temporary chroot directory
        $chroot = $self->chroot_auto_create($chroot, $rootdir);
        if (!defined $chroot) {
            print STDERR "E: auto-creating chroot failed\n";
            return 0;
        }
    }

    my $tarball = undef;
    if ($chroot =~ '/') {
        if (!-e $chroot) {
            print STDERR "Chroot $chroot does not exist\n";
            return 0;
        }
        $tarball = abs_path($chroot);
    } else {
        $tarball = $self->find_tarball($chroot);
        if (!defined($tarball)) {
            my $xdg_cache_home = $self->get_conf('HOME') . "/.cache/sbuild";
            if (length($ENV{'XDG_CACHE_HOME'})) {
                $xdg_cache_home = $ENV{'XDG_CACHE_HOME'} . '/sbuild';
            }

            print STDERR "Unable to find $chroot in $xdg_cache_home\n";
            return 0;
        }
    }

    if (-d $tarball) {
        # it's not a tarball but an existing chroot directory, so there is
        # nothing to unpack
    } elsif (!-e $tarball) {
        print STDERR
          "$tarball does not exist, check \$unshare_tarball config option\n";
        return 0;
    } else {
        # The tarball might be in a location where it cannot be accessed by the
        # user from within the unshared namespace
        if (!-r $tarball) {
            print STDERR "$tarball is not readable\n";
            return 0;
        }

        print STDERR "I: Unpacking $tarball to $rootdir...\n";
        @cmd = (
            "/usr/libexec/sbuild-usernsexec",
            (map { join ":", @{$_} } @idmap),
            '--',
            'tar',
            '--exclude=./dev/urandom',
            '--exclude=./dev/random',
            '--exclude=./dev/full',
            '--exclude=./dev/null',
            '--exclude=./dev/console',
            '--exclude=./dev/zero',
            '--exclude=./dev/tty',
            '--exclude=./dev/ptmx',
            '--directory',
            $rootdir,
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
