#!/usr/bin/perl
#
# Copyright (c) 2015 Mellanox Technologies. All rights reserved.
#
# This Software is licensed under one of the following licenses:
#
# 1) under the terms of the "Common Public License 1.0" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/cpl.php.
#
# 2) under the terms of the "The BSD License" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/bsd-license.php.
#
# 3) under the terms of the "GNU General Public License (GPL) Version 2" a
#    copy of which is available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/gpl-license.php.
#
# Licensee has the right to choose one of the above licenses.
#
# Redistributions of source code must retain the above copyright
# notice and one of the license notices.
#
# Redistributions in binary form must reproduce both the above copyright
# notice, one of the license notices in the documentation
# and/or other materials provided with the distribution.

use strict;
use File::Basename;
use File::Path;
use File::Find;
use File::Copy;
use File::Compare;
use Cwd;
use Term::ANSIColor qw(:constants);
$ENV{"LANG"} = "C";

my $setpci = 'setpci';
my $lspci = 'lspci';

my $PCI_CAP_ID_EXP       = "0x10";     # PCI Express
my $PCI_EXP_LNKSTA       = "0x12";     # Link Status
my $PCI_EXP_LNKSTA_WIDTH = "0x03f0";   # Negotiated Link Width
my $PCI_EXP_LNKSTA_SPEED = "0x000f";   # Negotiated Link Speed
my $PCI_EXP_LNKCAP       = "0xc";      # Link Capabilities
my $PCI_EXP_LNKCAP_WIDTH = "0x003f0";  # Maximum Link Width
my $PCI_EXP_LNKCAP_SPEED = "0x0000f";  # Maximum Link Speed
my $PREREQUISIT = "172";

sub non_root_user() {
    return $<;
}

sub check_root_user() {
    if (non_root_user()) {
        print RED "Only root can run $0", RESET "\n";
        exit $PREREQUISIT;
    }
}

sub clean_path {
    my $file = shift @_;

    # remove trailing '/'
    $file =~ s/\/$//;

    # remove double '//'
    while ($file =~ /\/\//) {
        $file =~ s/\/\//\//g;
    }

    return $file;
}

sub hexSum
{
        my $a = shift @_;
        my $b = shift @_;

        $a = hex "$a";
        $b = hex "$b";

        my $val = sprintf("%x", $a + $b);
}

# type: can be one of: W, B, L (see setpci man pages)
sub pci_read
{
        my $dev = shift @_;
        my $offset = shift @_;
        my $type = shift @_;

        my $val = `$setpci -s $dev ${offset}.${type}`;
        chomp $val;
        my $res = $? >> 8;
        my $sig = $? & 127;
        if ($sig or $res or $res =~ /Unaligned/i) {
                $val = "Failed to read!";
        }
        return $val;
}

# get offset of PCI Express Capability structure
# (element in a linked list)
sub pci_find_pcie_cap_structure
{
        my $dev = shift @_;

        my $offset = pci_read($dev, '0x34', 'B');
        if ($offset =~ /ff/) {
                return -1;
        }
        while (hex($offset)) {
                my $id = pci_read($dev, ${offset}, 'B');
                if (hex "$id" == hex $PCI_CAP_ID_EXP) {
                        return $offset;
                }
                if ($id =~ /Fail|ff/) {
                        return -1;
                }
                $offset = hexSum($offset, 1);
                $offset = pci_read($dev, ${offset}, 'B');
        }

        return 0;
}

sub pci_get_lnksta
{
        my $dev = shift @_;
        my $cap_offset = shift @_;

        my $offset = hexSum($cap_offset, $PCI_EXP_LNKSTA);
        return pci_read($dev, $offset, 'W');
}

sub pci_get_lnkcap
{
        my $dev = shift @_;
        my $cap_offset = shift @_;

        my $offset = hexSum($cap_offset, $PCI_EXP_LNKCAP);
        return pci_read($dev, $offset, 'W');
}

sub pci_get_link_width
{
        my $dev = shift @_;
        my $cap_offset = shift @_;

        my $lnksta = pci_get_lnksta($dev, $cap_offset);
        return ((hex $lnksta) & (hex $PCI_EXP_LNKSTA_WIDTH )) >> 4;
}

sub pci_get_link_width_cap
{
        my $dev = shift @_;
        my $cap_offset = shift @_;

        my $lnkcap = pci_get_lnkcap($dev, $cap_offset);
        return ((hex $lnkcap) & (hex $PCI_EXP_LNKCAP_WIDTH )) >> 4;
}

sub pci_get_link_speed
{
        my $dev = shift @_;
        my $cap_offset = shift @_;

        my $lnksta = pci_get_lnksta($dev, $cap_offset);
        my $speed = ((hex $lnksta) & (hex $PCI_EXP_LNKSTA_SPEED ));
        # PCIe Gen1 = 2.5GT/s signal-rate per lane with 8/10 encoding    = 0.25GB/s data-rate per lane
        # PCIe Gen2 = 5  GT/s signal-rate per lane with 8/10 encoding    = 0.5 GB/s data-rate per lane
        # PCIe Gen3 = 8  GT/s signal-rate per lane with 128/130 encoding = 1   GB/s data-rate per lane
        # PCIe Gen4 = 16 GT/s signal-rate per lane with 128/130 encoding = 2   GB/s data-rate per lane
        if ( $speed eq "1" ) {
            return "2.5GT/s";
        } elsif ( $speed eq "2" ) {
            return "5GT/s";
        } elsif ( $speed eq "3" ) {
            return "8GT/s";
        } elsif ( $speed eq "4" ) {
            return "16GT/s";
        } else {
            return "Unknown";
        }
}

sub check_pcie_link
{
        for my $devid ( `$lspci -d 15b3: 2>/dev/null | cut -d" " -f"1"` ) {
            chomp $devid;

            my $hdr = pci_find_pcie_cap_structure($devid);
            if ("$hdr" eq "-1") {
                next;
            }
            my $link_width = pci_get_link_width($devid, $hdr);
            if ("$link_width" eq "0") {
                next;
            }
            my $link_width_cap = pci_get_link_width_cap($devid, $hdr);

            print "Device ($devid):\n";
            print "\t" . `$lspci -s $devid`;

            print "\tLink Width: x${link_width}";
            if ("$link_width" ne "$link_width_cap") {
                print YELLOW " ( WARNING - device supports x${link_width_cap} )";
                print RESET "";
            }
            print "\n";

            my $link_speed = pci_get_link_speed($devid, $hdr);
            print "\tPCI Link Speed: $link_speed\n";
            print "\n";
        }
}

sub size_to_netmask($) {
	my $size = shift;
	my $bit = (2** (32 - $size)) - 1;
	my ($full_mask) = unpack("N", pack("C4", 255,255,255,255));
	my $netmask  = join('.', unpack("C4", pack("N", ($full_mask ^ $bit))));

	return $netmask;
}

sub get_net_config($$$)
{
    my $interface = shift;
    my $ifcfg = shift;
    my $DISTRO = shift;

    my $cmd = "ip address show $interface";
    open(IP, "$cmd |") or die "Failed to run $cmd: $!";
    while (<IP>) {
        next unless (m/ inet /);
	my ($ig_inet, $inet, $ig_brd, $brd, $ignored) = split ' ';
	my ($inet_ip, $net_size) = split '/', $inet;
        $ifcfg->{$interface}{'IPADDR'} = $inet_ip;
        $ifcfg->{$interface}{'BROADCAST'} = $brd;
        $ifcfg->{$interface}{'NETMASK'} = size_to_netmask($net_size);
        if ($DISTRO =~ /RHEL6|RHEL7|POWERKVM|EULEROS2.0SP[235]|BCLINUX7|ALIOS/) {
            $ifcfg->{$interface}{'NM_CONTROLLED'} = "yes";
            $ifcfg->{$interface}{'TYPE'} = "InfiniBand";
        }
    }
    close(IP);
}

sub debian_version() {
	open(DEB_VER, "/etc/debian_version")
		or die("Failed to open /etc/debian_version: $!");
	my $version = <DEB_VER>;
	chomp $version;
	if ($version !~ /^[1-9]/) {
		$version = 0; # e.g.: Debian Testing / Unstable
	}
	return $version;
}

{
	# This scope is needed to allow os_release to keep state between
	# calls.
	# FIXME: once we remove support for ancient OSes (XenServer 6.5
	# and the likes, this should be replaced with 'state' and this
	# scope could be removed.

	# The state:
	my $initialized = 0;
	my %os_release = ();

	sub os_release($) {
		my $param = shift;

		if (not $initialized) {
			open(OS_RELEASE, "/etc/os-release")
				or die("Failed to open /etc/os-release: $!");
			while (<OS_RELEASE>) {
				my ($key, $val) = split(/[=]/, $_, 2);
				chomp $val;
				$val =~ s/^"(.*)"/$1/;
				$os_release{$key} = $val;
			}
			$initialized = 1;
			close(OS_RELEASE);
			# Debian does not provide minor version numbers here.
			# Get them elsewhere:
			if($os_release{"ID"} eq "debian") {
				$os_release{"VERSION_ID"} = debian_version();
			}
		}
		if (exists $os_release{$param}) {
			return $os_release{$param};
		}
		return undef;
	}
}

#:# PackagesSubdirectory MLNX_LIBS

1;
