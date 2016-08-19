#!/bin/bash

pass='p13m4t'
pass2='piematerial'
hosts=$(cat /root/cisco/ips_all)

for i in $hosts ; do
echo $i
/usr/bin/expect <<EOF > /dev/null
	set timeout 10
	spawn telnet $i
		expect "*assword:"
		send "$pass\n"
		expect ">"
			send "enable\n"
			expect "Password:"
			send "$pass\n"
				log_file /root/cisco/test.txt
				expect "#"
				send "sh spanning-tree summary | inc Root bridge for\r"
				expect "#"
				log_file
		send "exit\r"
EOF
done
