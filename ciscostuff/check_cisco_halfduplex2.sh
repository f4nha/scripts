#!/bin/bash

result_Ok=1
result_Critical=2
result_Warning=0
result_exit_Ok=0
result_exit_Warning=1
result_exit_Critical=2
result=0

ipaddr=$1

#id='USER'
pass='p13m4t'
pass2='piematerial'

rm -f /tmp/half-duplex-$ipaddr.txt

/usr/bin/expect <<EOF > /dev/null
set timeout 10
spawn telnet $ipaddr
expect "Password:"
send "$pass2\n"
sleep 1
	expect ">"
	send "enable\n"
	expect "Password:"
	send "$pass\n"
	sleep 1
		expect "#"
		log_file /tmp/half-duplex-$ipaddr.txt
		send "sh interfaces status | i connected(.*)half\r"
		expect "#"
		log_file
	send "exit\r"
EOF

result=`cat /tmp/half-duplex-$ipaddr.txt | grep half | wc -l`

if [ $result -gt $result_Ok ]; then
	echo `cat /tmp/half-duplex-$ipaddr.txt | grep Gi | awk '{print $1}'` | sed '/^$/d'
	echo `cat /tmp/half-duplex-$ipaddr.txt | grep Fa | awk '{print $1}'` | sed '/^$/d'
	exit $result_exit_Critical
fi

if [ $result -eq $result_Ok ]; then
	echo "OK"
	exit $result_exit_Ok
fi

if [ $result -eq $result_Warning ]; then
        exit $result_exit_Warning
fi
