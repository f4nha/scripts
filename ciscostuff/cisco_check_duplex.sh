#!/bin/bash
#
#
# Cisco Half-duplex Nagios Check
#
# by TiagoF ;)
# snmpwalk -Os -c streamuk -v2c 192.168.15.11 1.3.6.1.2.1.10.7.2.1.19 | grep -i "halfDuplex" | wc -l


HOST=$1
MIB="1.3.6.1.2.1.10.7.2.1.19"
CHECK=`/usr/bin/snmpwalk -Os -c streamuk -v2c $HOST $MIB | grep -i "halfDuplex" | wc -l`

if [ $CHECK -gt 0 ]; then
	echo "NOT OK - HalfDuplex interface detected"
        exit 2
fi

if [ $CHECK -eq 0 ]; then
        echo "OK - All interfaces FullDuplex"
        exit 0
fi
