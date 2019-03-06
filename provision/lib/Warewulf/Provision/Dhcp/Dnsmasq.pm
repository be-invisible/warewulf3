# Copyright (c) 2019 Stephan Weinberger <sweinberger@ubimet.com>
#

package Warewulf::Provision::Dhcp::Dnsmasq;

use Warewulf::ACVars;
use Warewulf::Logger;
use Warewulf::Provision;
use Warewulf::Provision::Dhcp;
use Warewulf::DataStore;
use Warewulf::Network;
use Warewulf::SystemFactory;
use Warewulf::Util;
use Warewulf::Provision::Tftp;
use Socket;

our @ISA = ('Warewulf::Provision::Dhcp');

=head1 NAME

Warewulf::Provision::Dhcp::Dnsmasq - Warewulf's Dnsmasq interface.

=head1 ABOUT


=head1 SYNOPSIS

    use Warewulf::Provision::Dhcp::Dnsmasq;

    my $obj = Warewulf::Provision::Dhcp::Dnsmasq->new();


=head1 METHODS

=over 12

=cut

=item new()

The new constructor will create the object that references configuration the
stores.

=cut

sub
new($$)
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = ();

    $self = {};

    bless($self, $class);

    return $self->init(@_);
}


sub
init()
{
    my $self = shift;
    my $config = Warewulf::Config->new("provision.conf");

    my @files = ('/etc/dnsmasq.conf');

    if (my $file = $config->get("dhcpd config file")) {
        &dprint("Using the DHCPD configuration file as defined by provision.conf\n");
        if ($file =~ /^([a-zA-Z0-9_\-\.\/]+)$/) {
            $self->set("FILE", $1);
        } else {
            &eprint("Illegal characters in path: $file\n");
        }

    }

    if (! $self->get("FILE")) {
        # Check if /etc/dnsmasq.d/ exists
        if (-d "/etc/dnsmasq.d") {
            $self->set("FILE", "/etc/dnsmasq.d/warewulf.conf");
        }
    }

    if (! $self->get("FILE")) {
        # Else look to see if we can find an existing dnsmasq.conf file
        foreach my $file (@files) {
            if ($file =~ /^([a-zA-Z0-9_\-\.\/]+)$/) {
                my $file_clean = $1;
                if (-f $file_clean) {
                    $self->set("FILE", $file_clean);
                    &dprint("Found DHCPD configuration file: $file_clean\n");
                }
            } else {
                &eprint("Illegal characters in path: $file\n");
            }
        }
    }

    return($self);
}


=item restart()

Restart the DHCP service

=cut

sub
restart()
{

    my $system = Warewulf::SystemFactory->new();

    if (!$system->chkconfig("dnsmasq", "on")) {
        &eprint($system->output() ."\n");
    }
    if (! $system->service("dnsmasq", "restart")) {
        &eprint($system->output() ."\n");
    }

}

=item persist()

This will update the DHCP file.

=cut

sub
persist()
{
    my $self = shift;
    my $sysconfdir = &Warewulf::ACVars::get("sysconfdir");
    my $datastore = Warewulf::DataStore->new();
    my $netobj = Warewulf::Network->new();
    my $config = Warewulf::Config->new("provision.conf");
    my $devname = $config->get("network device");
    my $ipaddr = $config->get("ip address") // $netobj->ipaddr($devname);
    my $netmask = $config->get("ip netmask") // $netobj->netmask($devname);
    my $network = $config->get("ip network") // $netobj->network($devname);
    my $tftpdir = Warewulf::Provision::Tftp->new()->tftpdir();
    my $config_template;
    my $dnsmasq_contents;
    my %seen;

    if (! $self->get("FILE")) {
        &dprint("No configuration file present, so no Dnsmasq configuration to persist\n");
        return undef;
    }

    if (! &uid_test(0)) {
        &iprint("Not updating Dnsmasq configuration: user not root\n");
        return undef;
    }


    if (! $ipaddr or ! $netmask or ! $network) {
        &wprint("Could not configure Dnsmasq, check 'network device' or 'ip address/netmask/network' configuration!\n");
        return undef;
    }


    if (-f "$sysconfdir/warewulf/dnsmasq-template.conf") {
        open(DNSMASQ, "$sysconfdir/warewulf/dnsmasq-template.conf");
        while($line = <DNSMASQ>) {
            $config_template .= $line;
        }
        close DNSMASQ;
    } else {
        &eprint("Template not found: $sysconfdir/warewulf/dnsmasq-template.conf\n");
        return(1);
    }

    $config_template =~ s/\%{IPADDR}/$ipaddr/g;
    $config_template =~ s/\%{NETWORK}/$network/g;
    $config_template =~ s/\%{NETMASK}/$netmask/g;
    $config_template =~ s/\%{TFTPROOT}/$tftpdir/g;

    &dprint("Creating Dnsmasq configuration file header\n");
    $dnsmasq_contents .= "# Dnsmasq Configuration written by Warewulf. Do not edit this file, rather\n";
    $dnsmasq_contents .= "# edit the template: $sysconfdir/warewulf/dnsmasq-template.conf\n";
    $dnsmasq_contents .= "\n";

    $dnsmasq_contents .= $config_template;

    $dnsmasq_contents .= "\n";

    &dprint("Iterating through nodes\n");

    foreach my $n ($datastore->get_objects("node")->get_list("fqdn", "domain", "cluster", "name")) {
        my $hostname = $n->nodename() || "undef";
        my $nodename = $n->name() || "undef";
        my $db_id = $n->id();
        if (! $n->enabled()) {
            &dprint("Node $hostname disabled. Skipping.\n");
            next;
        }
        if (! $db_id) {
            &eprint("No DB ID associated with this node object object: $hostname/$nodename:$n\n");
            next;
        }
        &dprint("Evaluating node: $nodename (object ID: $db_id)\n");
        $dnsmasq_contents .= "   # Evaluating Warewulf node: $nodename (DB ID:$db_id)\n";
        $nodename =~ s/\./_/g;
        my @bootservers = $n->get("bootserver");
        if (! @bootservers or scalar(grep { $_ eq $ipaddr} @bootservers)) {
            my $clustername = $n->cluster();
            my $domainname = $n->domain();
            my $pxelinux_file = $n->pxelinux();
            my $master_ipv4_addr;
            my $domain;

            if ($n->get("master")) {
                my $master_ipv4_bin = $n->get("master");
                $master_ipv4_addr = $netobj->ip_unserialize($master_ipv4_bin);
            } else {
                $master_ipv4_addr = $ipaddr;
            }

            if ($clustername) {
                if ($domain) {
                    $domain .= ".";
                }
                $domain .= $clustername;
            }
            if ($domainname) {
                if ($domain) {
                    $domain .= ".";
                }
                $domain .= $domainname;
            }

            foreach my $devname ($n->netdevs_list()) {
                my @hwaddrs = $n->hwaddr($devname);
                my $hwprefix = $n->hwprefix($devname);
                my $node_ipaddr = $n->ipaddr($devname);
                my $node_netmask = $n->netmask($devname) || $netmask;
                my $node_gateway = $n->gateway($devname);

                my $node_testnetwork = $netobj->calc_network($node_ipaddr, $node_netmask);

                if (! @hwaddrs) {
                    &iprint("Skipping Dnsmasq config for $nodename-$devname (no defined HWADDR)\n");
                    $dnsmasq_contents .= "   # Skipping $nodename-$devname: No defined HWADDR\n";
                    next;
                }

                if (! $node_ipaddr) {
                    &iprint("Skipping Dnsmasq config for $nodename-$devname (no defined IPADDR)\n");
                    $dnsmasq_contents .= "   # Skipping $nodename-$devname: No defined IPADDR\n";
                    next;
                }

                if ($node_testnetwork ne $network) {
                    &iprint("Skipping Dndmasq config for $nodename-$devname (on a different network)\n");
                    $dnsmasq_contents .= "   # Skipping $nodename-$devname: Not on boot network ($node_testnetwork)\n";
                    next;
                }

                if (exists($seen{"NODESTRING"}) and exists($seen{"NODESTRING"}{"$nodename-$devname"})) {
                    my $redundant_node = $seen{"NODESTRING"}{"$nodename-$devname"};
                    $dnsmasq_contents .= "   # Skipping $nodename-$devname: duplicate nodename-netdev\n";
                    &iprint("Skipping DHCP redundant entry for $nodename-$devname (already seen in $redundant_node)\n");
                    next;
                }
                if (exists($seen{"HWADDR"})) {
                    my $redundant_hwaddr;
                    foreach my $hwaddr (@hwaddrs) {
                        if (exists($seen{"HWADDR"}{"$hwaddr"})) {
                            $redundant_hwaddr = $hwaddr;
                        }
                    }
                    if ($redundant_hwaddr) {
                        my $redundant_node = $seen{"HWADDR"}{"$redundant_hwaddr"};
                        $dhcpd_contents .= "   # Skipping $nodename-$devname: duplicate HWADDR (@hwaddrs)\n";
                        &iprint("Skipping DHCP config for $nodename-$devname (HWADDR already seen in $redundant_node)\n");
                        next;
                    }
                }
                if (exists($seen{"IPADDR"}) and exists($seen{"IPADDR"}{"$node_ipaddr"})) {
                    my $redundant_node = $seen{"IPADDR"}{"$node_ipaddr"};
                    $dnsmasq_contents .= "   # Skipping $nodename-$devname: duplicate IPADDR ($node_ipaddr)\n";
                    &iprint("Skipping DHCP config for $nodename-$devname (IPADDR $node_ipaddr already seen in $redundant_node)\n");
                    next;
                }

                if ($nodename and $node_ipaddr and @hwaddrs) {
                    &dprint("Adding a host entry for: $nodename-$devname\n");

                    $dnsmasq_contents .= sprintf("dhcp-host=%s,%s,%s\n",
                        join(',', @hwaddrs), $hostname, $node_ipaddr);

                    $seen{"NODESTRING"}{"$nodename-$devname"} = "$nodename-$devname";
                    foreach my $hwaddr (@hwaddrs) {
                        $seen{"HWADDR"}{"$hwaddr"} = "$nodename-$devname";
                    }
                    $seen{"IPADDR"}{"$node_ipaddr"} = "$nodename-$devname";

                } else {
                    $dnsmasq_contents .= "   # Skipping $nodename-$devname: insufficient configuration\n";
                    &dprint("Skipping node $nodename-$devname: insufficient information\n");
                }
            }
        }
    }

    if ( 1 ) { # Eventually be smart about if this gets updated.
        my ($digest1, $digest2);
        my $system = Warewulf::SystemFactory->new();

        if ($self->get("FILE") and -f $self->get("FILE")) {
            $digest1 = digest_file_hex_md5($self->{"FILE"});
        }
        &iprint("Writing Dnsmasq configuration\n");
        &dprint("Opening file ". $self->get("FILE") ." for writing\n");
        if (! open(FILE, ">". $self->get("FILE"))) {
            &eprint("Could not open ". $self->get("FILE") ." for writing: $!\n");
            return();
        }

        print FILE $dnsmasq_contents;

        close FILE;
        $digest2 = digest_file_hex_md5($self->get("FILE"));
        if (! $digest1 or $digest1 ne $digest2) {
            &dprint("Restarting Dnsmasq service\n");
            if (! $system->service("dnsmasq", "restart")) {
                my $output = $system->output();
                if ( $output ) {
                    &eprint("$output\n");
                } else {
                    &eprint("There was an error restarting the Dnsmasq service\n");
                }
            }
        } else {
            &dprint("Not restarting Dnsmasq service\n");
        }
    } else {
        &iprint("Not updating Dnsmasq configuration: files are current\n");
    }

    return();
}

=back

=head1 SEE ALSO

Warewulf::Provision::Dhcp

=head1 COPYRIGHT

Copyright (c) 2001-2003 Gregory M. Kurtzer

Copyright (c) 2003-2011, The Regents of the University of California,
through Lawrence Berkeley National Laboratory (subject to receipt of any
required approvals from the U.S. Dept. of Energy).  All rights reserved.

=cut


1;
