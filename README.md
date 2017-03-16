# traffic_shaper
Traffic Shaper is a set of scripts to be run on a Linux 2.6.x machine to shape traffic based on IP source, throttle heavy consummers and block abusers.
This repo goal is to share an implementation of iptables combined with tc_ng (traffic shaper ng), as the documentation is obscure.
It is known the rule set can get massive if the ip client subnets are large, however the performance and memory footprint stays low as 3 C classes ranges can be transparently handled.

This system runs on several large residences in countries where bandwidth is a limited ressources, for around 400 homes, accounting 500GiB-1TiB per day.

Note : Linux module Quota is broken in kernel 3+, as the iptables rules still match when quota is reached.
