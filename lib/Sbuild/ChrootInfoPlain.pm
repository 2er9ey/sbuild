#
# ChrootInfo.pm: chroot utility library for sbuild
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootInfoPlain;

use Sbuild::ChrootInfo;
use Sbuild::ChrootPlain;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ChrootInfo);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    return $self;
}

sub get_info {
    my $self = shift;
    my $chroot = shift;

    $chroot =~ /(\S+):(\S+)/;
    my ($namespace, $chrootname) = ($1, $2);

    my $info = undef;

    if (exists($self->get('Chroots')->{$namespace}) &&
	defined($self->get('Chroots')->{$namespace}) &&
	exists($self->get('Chroots')->{$namespace}->{$chrootname})) {
	$info = $self->get('Chroots')->{$namespace}->{$chrootname}
    }

    return $info;
}

sub get_info_all {
    my $self = shift;

    my $chroots = {};
    # All sudo chroots are in the chroot namespace.
    my $namespace = "chroot";
    $chroots->{$namespace} = "/";

    $self->set('Chroots', $chroots);
}

sub _create {
    my $self = shift;
    my $chroot_id = shift;

    my $chroot =  Sbuild::ChrootPlain->new($self->get('Config'), '/');
    $self->set('Split', 0);

    return $chroot;
}

1;
