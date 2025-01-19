#
# Sysconfig.pm: system configuration for sbuild
# Copyright © 2007-2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Sysconfig;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT_OK);

    @ISA = qw(Exporter);

    @EXPORT_OK = qw($version $release_date $compat_mode %paths %programs);
}

our $version = "0.88.2";
our $release_date = "17 December 2024";
our $compat_mode = 0;

# Paths
my $prefix = "/usr";
my $exec_prefix = "${prefix}";
# Depend on prefix
my $includedir = "${prefix}/include";
my $localstatedir = "/var";
my $sharedstatedir = "${prefix}/com";
my $sysconfdir = "/etc";
# Depend on exec_prefix
my $bindir = "${exec_prefix}/bin";
my $libdir = "${prefix}/lib/x86_64-linux-gnu";
my $libexecdir = "${exec_prefix}/libexec";
my $sbindir = "${exec_prefix}/sbin";
# Data directories
my $datarootdir = "${prefix}/share";
my $datadir = "${datarootdir}";
my $localedir = "${datarootdir}/locale";
my $mandir = "${prefix}/share/man";

our %paths = (
    'PREFIX' => $prefix,
    'EXEC_PREFIX' => $exec_prefix,
    'INCLUDEDIR' => $includedir,
    'LOCALSTATEDIR' => $localstatedir,
    'SHAREDSTATEDIR' => $sharedstatedir,
    'SYSCONFDIR' => $sysconfdir,
    'BINDIR' => $bindir,
    'LIBDIR' => $libdir,
    'LIBEXECDIR' => $libexecdir,
    'SBINDIR' => $sbindir,
    'DATAROOTDIR' => $datarootdir,
    'DATADIR' => $datadir,
    'LOCALEDIR' => $localedir,
    'MANDIR' => $mandir,
    'BUILDD_CONF' => "/etc/buildd/buildd.conf",
    'BUILDD_SYSCONF_DIR' => "/etc/buildd",
    'SBUILD_CONF' => "/etc/sbuild/sbuild.conf",
    'SBUILD_DATA_DIR' => "/usr/share/sbuild",
    'SBUILD_LIBEXEC_DIR' => "/usr/libexec/sbuild",
    'SBUILD_LOCALSTATE_DIR' => "$localstatedir/lib/sbuild",
    'SBUILD_SYSCONF_DIR' => "/etc/sbuild",
    'SCHROOT_CONF' => "/etc/schroot/schroot.conf",
    'SCHROOT_SYSCONF_DIR' => "/etc/schroot"
);

1;
