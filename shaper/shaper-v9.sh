#!/bin/bash

###############
# SHAPER V9.0 #
#  2015/07/03 #
###############

###############
# RELEASE NOTES
# - iptables-save and restore to avoid regeneration of tables at every boot
# - redirection upon quota hit
# - reset <ip> now also resets stats to avoid inconsistencies
# - optional quota_block parameter introduce
# - interface with web frontend
# - authentication on web frontend
# - updated admin interface
# - new user interface
# - bug on banremove fixed
# - added cleanup of expired ban rules
# - var names fixed accross this script and the frontend
# - updated frontend to show graph of the day
# - updated frontend to include all script actions
# - added monitor tool to start the script based on web frontend actions
# - fixed ban table being flushed
# - fixed timezone, all based on epoch
###############

#use following arguments
#init - sets up tc, forwarding & nat, using conf file default
#init <quota> - sets up tc, forwarding & nat, with specified quota in MiB
#halt - destroys all tc, forwarding & nat
#start - sets quotas with config file value
#stop - stops quota
#reset - sets all counters to zero for quotas
#reset <ip> - sets all counters and quota to zero for the given ip
#info - info on current setup. warning : outputs the whole iptables ruleset
#banlist - list of banned ip addresses
#banadd <ip> <duration> - block all traffic for the given ip for the default duration or a given duration in hours (optional)
#banremove <ip> - block all traffic for the given ip
#quickstats - generate stats of the day until now to get top users for web backend
#resetstats - resets quickstats - used for not accounting the free for all night slot
#cron - recurring tasks (update of blocked IP addresses, fetch queue of actions from web interface)

#config file
source /root/shaper/shaper.conf

#beginning of script - DO NOT MODIFY UNLESS YOU KNOW WHAT YOU'RE DOING
if [ "$#" -ge 1 ]; then
        ARG="$1"
fi

#check all necessary variables are initiated. see shaper.conf for use.
VARIABLES="\$IFLAN \$IFWAN \$LINESPEED \$QUOTA_THROTTLE \$QUOTA_BLOCK \$QUOTA_START \$QUOTA_STOP \$MAXIP \$LAN \$SUBS \$MASK \$BAN_DURATION \$HOSTN \$MUNINGRP"
for CHECK_VAR in $VARIABLES
do
	eval CHECK_VAR_VAL=$CHECK_VAR
	if [ -z "${CHECK_VAR_VAL}" ]; then
		echo "[shaper] error : ${CHECK_VAR} variable not set."
		#exit 3
	fi
done


#DO NOT MODIFY
#guaranteed and burst speed for non quota depleted users
RATE_OK=$[ 45 * ${LINESPEED} / 100]
BURST_OK=$[ 100 * ${LINESPEED} / 100]
#guaranteed and burst speed for vpn users
RATE_VPN=$[ 45 * ${LINESPEED} / 100]
BURST_VPN=$[ 100 * ${LINESPEED} / 100]
#guaranteed and burst speed for quota depleted users, 10%
RATE_KO=$[ 5 * ${LINESPEED} / 100]
BURST_KO=$[ 90 * ${LINESPEED} / 100]
#guaranteed and burst speed for quota depleted users, 10%
RATE_BULK=$[ 5 * ${LINESPEED} / 100]
BURST_BULK=$[ 100 * ${LINESPEED} / 100]
#non quota depleted cumulated guaranteed bandwidth
RATE=$[ ${RATE_OK} + ${RATE_VPN} ]
RATE_LOW=$[ ${RATE_KO} + ${RATE_BULK} ]
#sum of all RATE_* must not exceed 100%

#convert quota in bytes
QUOTA_THROTTLE=$[ ${QUOTA_THROTTLE} * 1000000 ]
QUOTA_BLOCK=$[ ${QUOTA_BLOCK} * 1000000 ]
#QUOTA_BLOCK=$[ ${QUOTA_BLOCK} - ${QUOTA_THROTTLE} ]

echo ${QUOTA_THROTTLE}
echo ${QUOTA_BLOCK}

if [ "$ARG" = "init" ]; then
	#update web front end with update config
	QUOTA_THROTTLE_MB=$[ ${QUOTA_THROTTLE} / 1000000 ]
	QUOTA_BLOCK_MB=$[ ${QUOTA_BLOCK} / 1000000 ]
#	QUOTA_BLOCK_MB=$[ ${QUOTA_BLOCK_MB} + ${QUOTA_THROTTLE_MB} ]
	LINESPEED_BPS=$[ ${LINESPEED} * 1000 ]
	echo "<?php \$host=\"${HOSTN}\"; \$muningrp=\"${MUNINGRP}\"; \$quota_throttle=\"${QUOTA_THROTTLE_MB}\"; \$quota_block=\"${QUOTA_BLOCK_MB}\"; \$default_ban=\"${BAN_DURATION}\"; \$linespeed=\"${LINESPEED_BPS}\"; \$quota_start=\"${QUOTA_START}\"; \$quota_stop=\"${QUOTA_STOP}\"; ?>" > ${RES_TARGET}/include.php
	#create file with rights so the web frontend can modify it
	rm -f ${ADM_TARGET}/_interface_shaper.txt
	touch ${ADM_TARGET}/_interface_shaper.txt
	chown www-data:www-data ${ADM_TARGET}/_interface_shaper.txt

	#check the configuration file is older than the saved rules. if not, then saved rules are outdated and shall be deleted.
	#also checks if the shaper has been updated since last generation of set of rules.
	if [ "/root/shaper/_iptables-save" -ot "/root/shaper/shaper.conf" ] || [ "/root/shaper/_iptables-save" -ot "/root/shaper/shaper" ]
	then
		rm /root/shaper/_iptables-save
                echo "[shaper] outdated iptables tables deleted."
	fi

	#if iptables tables have already been created and saved, then restore tables. if not, generate and save them.
	if [ -s "/root/shaper/_iptables-save" ]
	then
                /sbin/iptables-restore < /root/shaper/_iptables-save
                echo "[shaper] iptables tables restored."
	else
		#enable nat
		/sbin/iptables -t nat -A POSTROUTING -o ${IFWAN} -j MASQUERADE
		#forward traffic to local dns cache
#disabled because of performance issues
		/usr/sbin/pdnsd-ctl empty-cache
#		/sbin/iptables -t nat -A PREROUTING -i ${IFLAN} -p udp --destination-port 53 -j REDIRECT --to-port 53
#		/sbin/iptables -t nat -A PREROUTING -i ${IFLAN} -p tcp --destination-port 53 -j REDIRECT --to-port 53
		#enable forwarding
		echo "1" > /proc/sys/net/ipv4/ip_forward
		#create table for blocked request types
		/sbin/iptables -N BLOCK
		#create table for banned ip address, meant to be populated with banned IP addresses only
		/sbin/iptables -N BAN

		#create ip rules tables structure
		for SUB in $SUBS
		do
			/sbin/iptables -N ${SUB}
			for ADR in `seq 1 $MAXIP`
			do
				/sbin/iptables -N ${SUB}.${ADR}
			done
		done

		#take argument as new quota
		if [ $2 ]; then
			QUOTA_THROTTLE=$2
			QUOTA_THROTTLE=$[ ${QUOTA_THROTTLE} * 1000000 ]
		fi
		#remove simple forwarding rules
		/sbin/iptables -F FORWARD
		#add total vpn marking rules
		for VPN_SUB in $VPN_IP
		do
			/sbin/iptables -A FORWARD -i ${IFWAN} -s ${VPN_SUB} -j MARK --set-mark 3
			/sbin/iptables -A FORWARD -i ${IFLAN} -d ${VPN_SUB} -j MARK --set-mark 2
		done

		#add forward rules for blocked requests and banned ip addresses
		/sbin/iptables -A FORWARD -i ${IFLAN} -j BLOCK
		/sbin/iptables -A FORWARD -i ${IFLAN} -j BAN

		#block bittorrent traffic during daytime
	        /sbin/iptables -A BLOCK -i ${IFLAN} -m string --string "GET /scrape?info_hash=" --algo bm -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP
		/sbin/iptables -A BLOCK -i ${IFLAN} -m string --string "GET /scrape.php?info_hash=" --algo bm -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP
		/sbin/iptables -A BLOCK -i ${IFLAN} -m string --string "GET /scrape?passkey=" --algo bm -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP
		/sbin/iptables -A BLOCK -i ${IFLAN} -m string --string "GET /scrape.php?passkey=" --algo bm -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP

		#set quota before throttling
		for SUB in $SUBS
		do
			for ADR in `seq 1 $MAXIP`
			do
				#add per IP rules
				#track bittorrent activity during daytime
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m string --string "GET /announce?info_hash=" --algo bm -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m string --string "GET /announce.php?info_hash=" --algo bm -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP
				#daytime if within quota, then apply default class
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m quota --quota $QUOTA_THROTTLE -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -m state --state RELATED,ESTABLISHED -m quota --quota $QUOTA_THROTTLE -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
				#daytime out of quota traffic
				if [ $QUOTA_BLOCK -eq 0 ] ; then
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 4
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -m state --state RELATED,ESTABLISHED -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 5
				else
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m quota --quota $QUOTA_BLOCK -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 4
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -m state --state RELATED,ESTABLISHED -m quota --quota $QUOTA_BLOCK -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 5
					#add the ACCEPT rules as MARK comes back to FORWARD
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m mark --mark 4 -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -m mark --mark 5 -m state --state RELATED,ESTABLISHED -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP
					/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j DROP
				fi
				#tag web traffic as normal traffic at night
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -p tcp --match multiport --source-port 80,443 -m time --timestart $QUOTA_STOP --timestop $QUOTA_START -j MARK --set-mark 6
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -p tcp --match multiport --destination-port 80,443 -m time --timestart $QUOTA_STOP --timestop $QUOTA_START -j MARK --set-mark 7
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -m mark --mark 6 -m state --state RELATED,ESTABLISHED -m time --timestart $QUOTA_STOP --timestop $QUOTA_START -j ACCEPT
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m mark --mark 7 -m time --timestart $QUOTA_STOP --timestop $QUOTA_START -j ACCEPT
				#nighttime default bulk traffic
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFLAN} -s ${SUB}.${ADR} -m time --timestart $QUOTA_STOP --timestop $QUOTA_START -j MARK --set-mark 8
				/sbin/iptables -A ${SUB}.${ADR} -i ${IFWAN} -d ${SUB}.${ADR} -m state --state RELATED,ESTABLISHED -m time --timestart $QUOTA_STOP --timestop $QUOTA_START -j MARK --set-mark 9
				#forward rules in sub table
				/sbin/iptables -A ${SUB} -i ${IFLAN} -s ${SUB}.${ADR} -j ${SUB}.${ADR}
				/sbin/iptables -A ${SUB} -i ${IFWAN} -d ${SUB}.${ADR} -m state --state RELATED,ESTABLISHED -j ${SUB}.${ADR}
			done
		done
		/sbin/iptables-save > /root/shaper/_iptables-save
		echo "[shaper] iptables tables saved."
	fi
	#prio : lower value means higher priority
	/sbin/tc qdisc add dev ${IFWAN} root handle 2: htb default 112
	/sbin/tc class add dev ${IFWAN} parent 2: classid 2:1 htb rate ${LINESPEED}Kbit ceil ${LINESPEED}Kbit
	/sbin/tc class add dev ${IFWAN} parent 2:1 classid 2:11 htb rate ${RATE}Kbit ceil ${LINESPEED}Kbit prio 0
	/sbin/tc class add dev ${IFWAN} parent 2:1 classid 2:13 htb rate ${RATE_LOW}Kbit ceil ${LINESPEED}Kbit prio 5
	/sbin/tc class add dev ${IFWAN} parent 2:11 classid 2:111 htb rate ${RATE_VPN}Kbit ceil ${BURST_VPN}Kbit prio 0
	/sbin/tc class add dev ${IFWAN} parent 2:11 classid 2:112 htb rate ${RATE_OK}Kbit ceil ${BURST_OK}Kbit prio 7
	/sbin/tc class add dev ${IFWAN} parent 2:13 classid 2:131 htb rate ${RATE_KO}Kbit ceil ${BURST_KO}Kbit prio 5
	/sbin/tc class add dev ${IFWAN} parent 2:13 classid 2:132 htb rate ${RATE_BULK}Kbit ceil ${BURST_BULK}Kbit prio 4
	/sbin/tc filter add dev ${IFWAN} parent 2: protocol ip handle 2 fw flowid 2:111
	/sbin/tc filter add dev ${IFWAN} parent 2: protocol ip handle 6 fw flowid 2:112
	/sbin/tc filter add dev ${IFWAN} parent 2: protocol ip handle 4 fw flowid 2:131
	/sbin/tc filter add dev ${IFWAN} parent 2: protocol ip handle 8 fw flowid 2:132

	/sbin/tc qdisc add dev ${IFLAN} root handle 1: htb default 112
	/sbin/tc class add dev ${IFLAN} parent 1: classid 1:1 htb rate ${LINESPEED}Kbit ceil ${LINESPEED}Kbit
	/sbin/tc class add dev ${IFLAN} parent 1:1 classid 1:11 htb rate ${RATE}Kbit ceil ${LINESPEED}Kbit prio 0
	/sbin/tc class add dev ${IFLAN} parent 1:1 classid 1:13 htb rate ${RATE_LOW}Kbit ceil ${LINESPEED}Kbit prio 5
	/sbin/tc class add dev ${IFLAN} parent 1:11 classid 1:111 htb rate ${RATE_VPN}Kbit ceil ${BURST_VPN}Kbit prio 0
	/sbin/tc class add dev ${IFLAN} parent 1:11 classid 1:112 htb rate ${RATE_OK}Kbit ceil ${BURST_OK}Kbit prio 7
	/sbin/tc class add dev ${IFLAN} parent 1:13 classid 1:131 htb rate ${RATE_KO}Kbit ceil ${BURST_KO}Kbit prio 5
	/sbin/tc class add dev ${IFLAN} parent 1:13 classid 1:132 htb rate ${RATE_BULK}Kbit ceil ${BURST_BULK}Kbit prio 4
	/sbin/tc filter add dev ${IFLAN} parent 1: protocol ip handle 3 fw flowid 1:111
	/sbin/tc filter add dev ${IFLAN} parent 1: protocol ip handle 7 fw flowid 1:112
	/sbin/tc filter add dev ${IFLAN} parent 1: protocol ip handle 5 fw flowid 1:131
	/sbin/tc filter add dev ${IFLAN} parent 1: protocol ip handle 9 fw flowid 1:132

	QUOTA_DISP=$[ ${QUOTA_THROTTLE} / 1000000 ]
	echo "[shaper] shaper initiated with ${QUOTA_DISP}MiB quota."
fi


if [ "$ARG" = "start" ]; then
	#remove default forwarding rules
	/sbin/iptables -D FORWARD -i ${IFLAN} -s ${LAN}.0/${MASK} -j ACCEPT
	/sbin/iptables -D FORWARD -i ${IFWAN} -d ${LAN}.0/${MASK} -m state --state RELATED,ESTABLISHED -j ACCEPT
	#add main subnet rules to FORWARD table
	for SUB in $SUBS
	do
		/sbin/iptables -A FORWARD -i ${IFLAN} -s ${SUB}.0/${MASK} -j ${SUB}
		/sbin/iptables -A FORWARD -i ${IFWAN} -d ${SUB}.0/${MASK} -j ${SUB}
	done
	nohup `while inotifywait -e CLOSE_WRITE /root/www/admin/_interface_shaper.txt ; do /root/shaper/shaper cron; done` &
	echo "[shaper] shaper started."
fi


if [ "$ARG" = "stop" ]; then
	#zero all counters
	/sbin/iptables -Z FORWARD
	for SUB in $SUBS
	do
		#remove per IP rules FORWARD rule link
		/sbin/iptables -D FORWARD -i ${IFLAN} -s ${SUB}.0/${MASK} -j ${SUB}
		/sbin/iptables -D FORWARD -i ${IFWAN} -d ${SUB}.0/${MASK} -j ${SUB}
		/sbin/iptables -Z ${SUB}
		for ADR in `seq 1 $MAXIP`
		do
			/sbin/iptables -Z ${SUB}.${ADR}
		done
	done
	#add simple forwarding rules - not working as too similar to previous ones
	/sbin/iptables -A FORWARD -i ${IFLAN} -s ${LAN}.0.0/${MASK} -j ACCEPT
	/sbin/iptables -A FORWARD -i ${IFWAN} -d ${LAN}.0.0/${MASK} -m state --state RELATED,ESTABLISHED -j ACCEPT
	echo "[shaper] shaper stopped."
fi


if [ "$ARG" = "halt" ]; then
	#destroy tc
	/sbin/tc qdisc del dev ${IFLAN} root
	/sbin/tc qdisc del dev ${IFWAN} root
	#disable NAT
	/sbin/iptables -t nat -D POSTROUTING 1
	#remove dns forwarding
	/sbin/iptables -t nat -D PREROUTING 1
	/sbin/iptables -t nat -D PREROUTING 1
	#disable forwarding
	#echo "0" > /proc/sys/net/ipv4/ip_forward
	/sbin/iptables -F FORWARD
	#flush and delete table for blocked request types
	/sbin/iptables -F BLOCK
	/sbin/iptables -X BLOCK
	#flush and delete table for banned ip address, meant to be populated with banned IP addresses only
	/sbin/iptables -F BAN
	/sbin/iptables -X BAN

	#remove the main forward rule
	for SUB in $SUBS
	do
		/sbin/iptables -F ${SUB}
		/sbin/iptables -X ${SUB}
	done
	#then per ip rules first
	for SUB in $SUBS
	do
		for ADR in `seq 1 $MAXIP`
		do
			/sbin/iptables -F ${SUB}.${ADR}
			/sbin/iptables -X ${SUB}.${ADR}
		done
	done
	echo "[shaper] shaper halted. warning : traffic not passing through."
fi


if [ "$ARG" = "info" ]; then
	echo "current config"
	echo "line speed : ${LINESPEED}Kbps"
	echo "tree ok    : ${RATE}Kbps / ${LINESPEED}Kbps"
	echo "  quota ok : ${RATE_OK}Kbps / ${BURST_OK}Kbps"
	echo "  vpn      : ${RATE_VPN}Kbps / ${BURST_VPN}Kbps"
	echo "tree ko    : ${RATE_KO}Kbps / ${BURST_KO}Kbps"
	/sbin/iptables -nvL
	/usr/sbin/arp -na | grep $IFLAN
fi


if [ "$ARG" = "reset" ]; then
	if [ $2 ]; then
		#reset for the given IP
		IPADDR="$2"
		#to avoid grep-ing similar ip addresses. ex:avoid getting 172.18.1.10-19 1 172.18.1.1-199 when grep-ing 172.18.1.1
		#reset counters in the IP table
		/sbin/iptables -Z $IPADDR
		#reset quotas be replacing them, no choice
		/sbin/iptables -R ${IPADDR} 3 -i ${IFLAN} -s ${IPADDR} -m quota --quota $QUOTA_THROTTLE -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
		/sbin/iptables -R ${IPADDR} 4 -i ${IFWAN} -d ${IPADDR} -m state --state RELATED,ESTABLISHED -m quota --quota $QUOTA_THROTTLE -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
		if [ $QUOTA_BLOCK -gt 0 ] ; then
			/sbin/iptables -R ${IPADDR} 5 -i ${IFLAN} -s ${IPADDR} -m quota --quota $QUOTA_BLOCK -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 4
			/sbin/iptables -R ${IPADDR} 6 -i ${IFWAN} -d ${IPADDR} -m state --state RELATED,ESTABLISHED -m quota --quota $QUOTA_BLOCK -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 5
		fi
		#reset the counters of the IP in the subnet table
		NET=`echo $IPADDR | cut -d'.' -f1-3`
		RESET_ID=`/sbin/iptables --line-numbers -nvL ${NET} | grep "${IPADDR} " | cut -d' ' -f1`
		for ID in $RESET_ID
		do
			/sbin/iptables -Z ${NET} $ID
		done
		echo "[shaper] quota reset for client ${IPADDR}."
	else
		#zero for all IP
		/sbin/iptables -Z FORWARD
		for SUB in $SUBS
		do
			/sbin/iptables -Z ${SUB}
			for ADR in `seq 1 $MAXIP`
			do
				/sbin/iptables -Z ${SUB}.${ADR}
				/sbin/iptables -R ${SUB}.${ADR} 3 -i ${IFLAN} -s ${SUB}.${ADR} -m quota --quota $QUOTA_THROTTLE -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
				/sbin/iptables -R ${SUB}.${ADR} 4 -i ${IFWAN} -d ${SUB}.${ADR} -m state --state RELATED,ESTABLISHED -m quota --quota $QUOTA_THROTTLE -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j ACCEPT
				if [ $QUOTA_BLOCK -gt 0 ] ; then
					/sbin/iptables -R ${SUB}.${ADR} 5 -i ${IFLAN} -s ${SUB}.${ADR} -m quota --quota $QUOTA_BLOCK -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 4
					/sbin/iptables -R ${SUB}.${ADR} 6 -i ${IFWAN} -d ${SUB}.${ADR} -m state --state RELATED,ESTABLISHED -m quota --quota $QUOTA_BLOCK -m time --timestart $QUOTA_START --timestop $QUOTA_STOP -j MARK --set-mark 5
				fi
			done
		done
		iptables -nvL BAN
		echo "[shaper] all quotas reset."
	fi
fi


if [ "$ARG" = "banscan" ]; then
	#list ip which have generated dropped traffic
	BAN_LIST_NEW=`/sbin/iptables -nvL | grep DROP | grep -v "0     0 DROP" | grep ${LAN} | cut -c 48-63`
	#list ip which are already in the ban list
	BAN_LIST=`/sbin/iptables -nvL BAN | grep ${LAN} | cut -c 48-63`
	#for each listed ip, see if they are in the list. if yes, no action. if not, add it with duration
	#there is probably a faster and cleaner way to do it that scales better. future optimization?
	for IP_NEW in $BAN_LIST_NEW
	do
		FOUND=0
		for IP_OLD in $BAN_LIST
		do
			#if ip found, break search
			if [ "$IP_NEW" == "$IP_OLD" ]; then
				FOUND=1
				break
			fi
		done
		#if not found, add to the list
		if [ $FOUND -eq 0 ]; then
			BAN_END=`/bin/date -u '+%Y-%m-%dT%H:%M:%S' --date="${BAN_DURATION} hours"`
			/sbin/iptables -A BAN -i ${IFLAN} -s ${IP_NEW} -m time --datestop ${BAN_END} -j DROP
			echo "[shaper] new banned IP ${IP_NEW}."
		fi
	done
fi


if [ "$ARG" = "banlist" ]; then
	/sbin/iptables -nvL BAN | grep DROP
fi


if [ "$ARG" = "banadd" ]; then
	#check we have an argument
	if [ $2 ]; then
		IP_NEW=$2
		if [ $3 ];then
			BAN_DURATION=$3
		fi
		#check if the ip is currently banned, get the rule id
		BAN_ID=`/sbin/iptables --line-numbers -nvL BAN | grep ${IP_NEW} | cut -d' ' -f1`
		#if not found add the rule
		if [ -z "$BAN_ID" ]; then
			BAN_END=`/bin/date -u '+%Y-%m-%dT%H:%M:%S' --date="${BAN_DURATION} hours"`
			/sbin/iptables -A BAN -i ${IFLAN} -s ${IP_NEW} -m time --datestop ${BAN_END} -j DROP
			IPLAN=`ifconfig ${IFLAN} | awk '{ print $2}' | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}"`
			/sbin/iptables -t nat -A PREROUTING -i ${IFLAN} -s ${IP_NEW} -p tcp -j DNAT --to-destination ${IPLAN}
			echo "[shaper] ${IP_NEW} added to ban list."
		else
			echo "[shaper] ${IP_NEW} already in the ban list."
		fi
	else
		echo "[shaper] no argument provided."
	fi
fi


if [ "$ARG" = "banremove" ]; then
	#check we have an argument
	if [ $2 ]; then
		IP_NEW=$2
		#check if the ip is currently banned, get the rule id
		BAN_ID=`/sbin/iptables --line-numbers -nvL BAN | grep "${IP_NEW} " | cut -d' ' -f1`
		#if found, remove the rule
		if [ -z "$BAN_ID" ]; then
			echo "[shaper] ip not currently banned."
		else
			#remove ban rule
			/sbin/iptables -D BAN ${BAN_ID}
			echo "[shaper] ${IP_NEW} removed from ban list."
		fi
		BAN_ID=`/sbin/iptables --line-numbers -t nat -nvL PREROUTING | grep "${IP_NEW} " | cut -d' ' -f1`
                if [ -n "$BAN_ID" ]; then
                        /sbin/iptables -t nat -D PREROUTING ${BAN_ID}
                fi


	else
		echo "[shaper] no argument provided."
	fi
fi


if [ "$ARG" = "resetstats" ]; then
        for SUB in $SUBS
        do
                /sbin/iptables -Z ${SUB}
        done
        echo "[shaper] quick statistics reset."
fi


if [ "$ARG" = "cron" ]; then
	#clean outdated/expired entries in BAN table
	NOW=`/bin/date '+%s'`
	#very dirty cut to get the date and time after TIME until date. crossing fingers iptables output format will not change
	BAN_DATE=`/sbin/iptables --line-numbers -nvL BAN | grep DROP | cut -c111-129`
	#same to fetch the IP address
	BAN_LIST=`/sbin/iptables -nvL BAN | grep DROP | cut -c48-64`
  	BAN_LIST=( $BAN_LIST )
	#some sting manipulation to not tokenize properly the dates
	BAN_DATE2=""
	ID="0"
	for DATE in $BAN_DATE
	do
		if [ $((ID%2)) -eq 0 ] ; then
			BAN_DATE2+=$DATE'.'
		else
			BAN_DATE2+=$DATE' '
		fi
		((ID+=1))
	done
	unset BAN_DATE
	#scan the list and remove if rules expires in the past.
	ID="0"
	for DATE in $BAN_DATE2
	do
		#compare dates while swaping the dot introduced earlier on
		if [ `/bin/date -d"${DATE/./ }" +%s` -lt $NOW ] ; then
			echo "[shaper] ${BAN_LIST[$ID]} ban rule expired"
			/root/shaper/shaper banremove ${BAN_LIST[$ID]}
		fi
		((ID+=1))
	done

	#output banned ip to files
        TEMPFILE=/tmp/cron.txt
        rm -f ${TEMPFILE}
	/sbin/iptables -xnL BAN | grep "DROP       all" | awk '{print $4","$9","$10}' > ${TEMPFILE}
	sort -nr -t' ' -k 1  ${TEMPFILE} > ${ADM_TARGET}/_ban.log
	#get batch commands from web interface
	TASKS=`sort ${ADM_TARGET}/_interface_shaper.txt | uniq -u`
	#use IFS to avoid setting a new line per argument of each command
	SFI=$IFS
	for TASK in $TASKS
	do
		IFS+=':'
		#last empty line which is an empty argument shall be avoided, will be done later. maybe
		/root/shaper/shaper ${TASK}
	done
	IFS=$SFI
	echo "" > ${ADM_TARGET}/_interface_shaper.txt
        echo "[shaper] cron tasks performed."
	ARG="quickstats"
fi


if [ "$ARG" = "quickstats" ]; then
        TEMPFILE=/tmp/log.txt
        rm -f ${TEMPFILE}
        #get the consumption per IP
        for SUB in $SUBS
        do
                /sbin/iptables -xnvL ${SUB} | awk '{printf $3" "$2" ";getline;print $2}' | grep -v "0 0" | awk '{print $1","$2+$3","$3","$2}' | grep -v "bytes" >> ${TEMPFILE}
        done
        sort -nr -t',' -k 2 ${TEMPFILE} > ${LOG_TARGET}/traffic-`date +\%Y\%m\%d`.log
        #output banned ip to files. copy paste of the code from cron to account for changes
        TEMPFILE=/tmp/cron.txt
        rm -f ${TEMPFILE}
        /sbin/iptables -xnL BAN | grep "DROP       all" | awk '{print $4","$9","$10}' > ${TEMPFILE}
        sort -nr -t' ' -k 1  ${TEMPFILE} > ${ADM_TARGET}/_ban.log

        echo "[shaper] quick statistics generated."
fi
