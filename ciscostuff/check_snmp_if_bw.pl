#!/usr/local/bin/perl

# nagios: +epn

=pod

=head1 NAME 

check_snmp_if_bw_util.pl - Check bandwidth utilization for an interface on
a device that implements IF-MIB.

=head1 SYNOPSIS

Check bandwidth % utilization on an interface on a device that supports the
IF-MIB.  Bandwidth utilization is checked by both in bits/second and out
bits/second.  Maximum bandwidth will be taken from the IF-MIB::ifSpeed
OID unless the maximum speed for the interface is specified using the
--max-speed argument to the script.  The name of the interface to check
must be passed in using the --interface argument to the script.

This script expects the interface being checked to be up and in full duplex
mode; if the interface is in half-duplex mode, use the --half-duplex switch
to indicate that.  If the interface is down or in the wrong mode, the
script will exit with a CRITICAL level alert.  If you wish to not have the
script check duplex because the device you are querying does not support
the ETHERLIKE-MIB, just pass in the --no-duplex-check switch.

Warning and critical thresholds can be specified using the following format:

metric,<op>,number:metric,<op>,number

Where metric is one of:
* in_util
* out_util

and <op> is one of
* lt - <
* lte - <=
* gt - >
* gte - >=

Example:

--warning 'in_util,gt,90:out_util,gt,90' --critical 'out_util,gt,95'

Multiple thresholds specified with ':' will be OR'd; if any of the 
passed in threshold checks is true, the script will alert.  The most
critical alert status becomes the alert level for the script.

The script will also output perfdata for in and out utilization.

Example call and output:

./check_snmp_if_bw.pl --hostname myrouter --interface FastEthernet0/1 --max-spee
d 10m --warn 'in_util,gt,90:out_util,gt,90' --critical 'out_util,gt,95' --max-sp
eed 10m
SNMP-IF-BW-UTIL WARN - IN UTIL (93% > 90%), OK - OUT UTIL 85% | 'in_util'=93%;90;95;
0;100 'out_util'=85%;90;95;0;100

=cut

sub check_snmp_if_bw {

    use strict;

    use FindBin;
    use lib "$FindBin::Bin/lib";

    use Nagios::Plugin::SNMP;
    use Nenm::Utils;
    
    my $USAGE = <<EOF;
Usage: %s --warning 'spec' --critical 'spec' --interface NAME \
          [--max-speed SPEC] [--half-duplex | --no-check-duplex]
EOF

    my $LABEL = 'SNMP-IF-BW-UTIL';

    my $plugin = Nagios::Plugin::SNMP->new(
        'shortname' => $LABEL,
        'usage'     => $USAGE
    );

    $plugin->add_arg(
        'spec' => 'interface|i=s',
        'help' => "--interface, -i: Name of the interface to use; use the\n" .
                  "                  description as returned by ifDescr.\n",
        'required' => 1
    );

    $plugin->add_arg(
        'spec' => 'sleep-time|S=i',
        'help' => "--sleep-time, -s: Time to sleep between samples; if not\n" .
                  "                   present, defaults to 10.\n",
        'required' => 0,
        'default' => 10
    );

    $plugin->add_arg(
        'spec' => 'half-duplex',
        'help' => "--half-duplex:     Interface should be in half-duplex,\n" .
                  "                    otherwise script expects interface\n" .
                  "                    to be in full duplex mode.",
        'required' => 0,
        'default' => 0
    );

    $plugin->add_arg(
        'spec' => 'no-duplex-check',
        'help' => "--no-duplex-check: DO not check duplex state on the\n" .
                  "                    interface; useful for devices \n" .
                  "                    that do not implement ETHERLIKE-MIB.\n",
        'required' => 0,
        'default' => 0
    );




    $plugin->add_arg(
        'spec' => 'max-speed|M=s',
        'help' => "--max-speed, -M: Maximum speed for the interface being\n" .
                  "                  checked.  Specify 'g', 'm', or 'k'\n" .
                  "                  for Gigabits, megabits, or kilobits\n" .
                  "                  per second.  If no maximum speed is\n" .
                  "                  specified, the script will use the \n" .
                  "                  value from ifSpeed.\n",
         'required' => 0,
         'default' => ''
    );

    $plugin->getopts;

    $Nenm::Utils::DEBUG = $plugin->opts->get('snmp-debug');
    
    my $SLEEP_TIME = $plugin->opts->get('sleep-time');

    my $IFDESCR = $plugin->opts->get('interface');
    $plugin->nagios_die("Missing interface to check!") unless $IFDESCR;

    my $EXPECTED_DUPLEX = '';

    if ($plugin->opts->get('no-duplex-check') == 0) {

        if ($plugin->opts->get('half-duplex') == 1) {
            $EXPECTED_DUPLEX = 'halfDuplex';
        } else {
            $EXPECTED_DUPLEX = 'fullDuplex';
        }

    }

    my %if_stats = (
        'in_util' => {qw(value 0)},
        'out_util' => {qw(value 0)}
    );

    my ($wthr, $werrs) = Nenm::Utils::parse_multi_threshold(
                             $plugin->opts->warning, \%if_stats);
    if (scalar(@$werrs) > 0) {
        $plugin->nagios_die("Invalid warning threshold specified: " .
                            join(', ', @$werrs));
    }

    my ($cthr, $cerrs) = Nenm::Utils::parse_multi_threshold(
                             $plugin->opts->critical, \%if_stats);
    if (scalar(@$cerrs) > 0) {
        $plugin->nagios_die("Invalid critical threshold specified: " .
                            join(', ', @$cerrs));
    }


    my $CRIT = $plugin->opts->get('critical');
    $plugin->nagios_die("Missing critical threshold!") unless $CRIT;

    #  Optional .. if -1, use ifSpeed for the interface.
    my $MAX_SPEED = $plugin->opts->get('max-speed');

    #  Get the index for this interface, return UNKNOWN if not found
    my $IF_IDX = get_if_index($plugin, $IFDESCR);

    if ($IF_IDX == -1) {
        $plugin->nagios_die("Could not find interface $IFDESCR in IF-MIB");
    }

    #  Check to see if the interface is up (1), if not, exit with UNKNOWN
    if (! if_is_up($plugin, $IF_IDX)) {
        $plugin->nagios_exit(CRITICAL,
                             "Interface $IFDESCR is not up, can't check!");
    }

    #  Get the duplex for the interface from ETHERLIKE-MIB, exit with
    #  critical if it is not in the expected duplex state.

    if ($plugin->opts->get('no-duplex-check') == '0') {

        my $DUPLEX = get_if_duplex($plugin, $IF_IDX);

        if ($DUPLEX eq '') {
            $plugin->nagios_die("Duplex check requested but device " .
                                "does not support Etherlike-MIB for this " .
                                "interface.  Use --no-duplex-check to " .
                                "suppress duplex check");
        }

        if ($DUPLEX ne $EXPECTED_DUPLEX) {
            $plugin->nagios_exit(CRITICAL,
                                 "Interface $IFDESCR is in $DUPLEX mode, " .
                                 "expected to see if in $EXPECTED_DUPLEX mode");
        }

    }

    #  if the user specified a max speed, translate it into bits; if they
    #  did not specify a max speed, get the max speed from the ifSpeed
    #  OID for the interface.

    my $MAX_BITS = 0;

    if ($MAX_SPEED eq '') {
        $MAX_BITS = get_if_speed($plugin, $IF_IDX);
   } else {
        $MAX_BITS = speed_spec_to_bps($plugin, $MAX_SPEED);
    }

    Nenm::Utils::debug("Retrieving traffic sample 1");
    #  Get octets in and out for the interface
    my ($IN_OCT1, $OUT_OCT1) = get_if_octets($plugin, $IF_IDX);

    #  Sleep for sleep-time seconds, sample again
    Nenm::Utils::debug("Sleep $SLEEP_TIME seconds between samples");
    sleep($SLEEP_TIME);

    Nenm::Utils::debug("Retrieving traffic sample 2");
    #  Get octets in and out for the interface
    my ($IN_OCT2, $OUT_OCT2) = get_if_octets($plugin, $IF_IDX);

    my $IN_OCT = $IN_OCT2 - $IN_OCT1;
    my $OUT_OCT = $OUT_OCT2 - $OUT_OCT1;

    #  Calculate % utilization based on bits in/out and max speed
    #  http://www.cisco.com/en/US/tech/tk648/tk362/technologies_tech_note09186a008009496e.shtml

    Nenm::Utils::debug(
        "In utilization: ($IN_OCT * 800) / ($SLEEP_TIME * $MAX_BITS)");

    $if_stats{'in_util'}->{'value'} = sprintf("%.2f", 
        ($IN_OCT * 800) / ($SLEEP_TIME * $MAX_BITS));

    Nenm::Utils::debug(
        "Out utilization: ($OUT_OCT * 800) / ($SLEEP_TIME * $MAX_BITS)");
    $if_stats{'out_util'}->{'value'} = sprintf("%.2f", 
        ($OUT_OCT * 800) / ($SLEEP_TIME * $MAX_BITS));

    my $results = Nenm::Utils::check_multi_thresholds(\%if_stats,
                                                      $wthr, $cthr, '%');
    
    my $output_label = "$LABEL $IFDESCR";

    if ($EXPECTED_DUPLEX ne '') {
        $EXPECTED_DUPLEX =~ s/^(\w+[a-z])([A-Z]\w+)$/\u$1 $2/;
        $output_label .= " ($EXPECTED_DUPLEX)";
    }

    return Nenm::Utils::output_multi_results($output_label, $results);

    #  Search for SNMP index of specified interface; if found return
    #  the integer index of the interface.  If not found, return -1.

    sub get_if_index {

        my $snmp = shift;
        my $wanted_if = lc(shift());

        my $results = $snmp->walk('.1.3.6.1.2.1.2.2.1.2');
        my $iftable = $results->{'.1.3.6.1.2.1.2.2.1.2'};
 
        Nenm::Utils::debug("Checking for IF description $wanted_if");

        my $found_idx = -1;

        for my $oid (keys %$iftable) {

            my $descr = lc($iftable->{$oid});

            Nenm::Utils::debug("Retrieved IF description $descr");

            if ($descr eq $wanted_if) {
                my $idx = ($oid =~ m/^.+\.(\d+)$/)[0];
                Nenm::Utils::debug("Found IF $wanted_if - index $idx");
                $found_idx = $idx;
                last;
            }

        }

        return $found_idx;

    }

    sub if_is_up {

        my $snmp = shift;
        my $idx = shift;

        my %states = qw(
            1 up 
            2 down
            3 testing
            4 unknown
            5 dormant
            6 notPresent
            7 lowerLayerDown
        );

        my $oid = ".1.3.6.1.2.1.2.2.1.8.$idx";
        my $results = $snmp->get($oid);
        my $status = $results->{$oid};
        
        Nenm::Utils::debug("Interface status is $states{$status}");

        return ($status == 1) ? 1 : 0;

    }

    sub get_if_duplex {

        my $snmp = shift;
        my $wanted_idx = shift;

        my %oids = qw(
            dot3StatsIndex        .1.3.6.1.2.1.10.7.2.1.1
            dot3StatsDuplexStatus .1.3.6.1.2.1.10.7.2.1.19
        );

        my %duplexes = qw(
            1 unknown
            2 halfDuplex
            3 fullDuplex
        );

        my $results = $snmp->walk($oids{'dot3StatsIndex'});
        my $ports = $results->{$oids{'dot3StatsIndex'}};
        
        my $duplex = '';

        Nenm::Utils::debug("Checking duplex on IF index $wanted_idx");

        for my $port (keys %$ports) {

            my $idx = $ports->{$port};

            if ("$idx" eq "$wanted_idx") {          

                my $eidx = ($port =~ m/^.+\.(\d+)/)[0];

                Nenm::Utils::debug("Etherlike-MIB Index for $idx: $eidx");

                my $duplex_oid = "$oids{'dot3StatsDuplexStatus'}.$eidx";
                Nenm::Utils::debug("Etherlike-MIB duplex OID: $duplex_oid");

                my $d_results = $snmp->get($duplex_oid);

                my $didx = $d_results->{$duplex_oid};
                $duplex = $duplexes{$didx};
                Nenm::Utils::debug("Etherlike-MIB Duplex $didx: $duplex");
              
                last;

            }
        }
        
        return $duplex;

    }

    sub get_if_speed {

        my $snmp = shift;
        my $idx = shift;

        my $bps = 0;

        my $oid = ".1.3.6.1.2.1.2.2.1.5.$idx";
        my $results = $snmp->get($oid);
        $bps = $results->{$oid};
        
        Nenm::Utils::debug("Interface speed is $bps");

        return $bps;

    }

    sub speed_spec_to_bps {

        my $helper = shift;
        my $spec = shift;


        my ($number, $mult) = ($spec =~ m/^(\d+)(\D*)$/)[0,1];

        if ($number eq '') {
            $helper->nagios_die("Invalid speed $spec!");
        }

        my $bps = 0;

        if ($mult eq '') {
            Nenm::Utils::debug("No multiplier, returning speed $number");
            $bps = $number;
        } else {

            if (length($mult) != 1) {
                $helper->nagios_die("Invalid speed $spec!");
            }

            $mult = lc($mult);

            if ($mult eq 'g') {
                $bps = $number * (1000 ** 3);
            } elsif ($mult eq 'm') {
                $bps = $number * (1000 ** 2);
            } elsif ($mult eq 'k') {
                $bps = $number * 1000;
            } else {
                $helper->nagios_die("Invalid multiplier in speed spec " .
                                    "$spec, valid labels are g, k, and m");
            }

        }
 
        Nenm::Utils::debug("Returning max speed ${bps} bits per second");

        return $bps;

    }

    sub get_if_octets {

        my $snmp = shift;
        my $idx = shift;

        my %oids = (
           'ifInOctets'  => ".1.3.6.1.2.1.2.2.1.10.$idx",
           'ifOutOctets' => ".1.3.6.1.2.1.2.2.1.16.$idx"
        );

        my $results = $snmp->get(values %oids);

        my $in = $results->{$oids{'ifInOctets'}};
        my $out = $results->{$oids{'ifOutOctets'}};
        
        Nenm::Utils::debug("Interface $idx: in $in, out $out");

        return ($in, $out);

    }

}

exit check_snmp_if_bw();
