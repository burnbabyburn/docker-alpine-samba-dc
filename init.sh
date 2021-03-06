#!/bin/sh

#set -e
set -x

#Todo:
#Keytab erzeugen:  net ads keytab create ${SAMBA_DEBUG_OPTION} und kerberos method = secrets and keytab
#Drop privileges
#https://medium.com/@mccode/processes-in-containers-should-not-run-as-root-2feae3f0df3b

appSetup () {

	# Set variables
	DOMAIN=${DOMAIN:-SAMDOM.LOCAL}
	DOMAINUSER=${DOMAINUSER:-Administrator}
	DOMAINPASS=${DOMAINPASS:-youshouldsetapassword}
	JOIN=${JOIN:-false}
	JOINSITE=${JOINSITE:-NONE}
	MULTISITE=${MULTISITE:-false}
	NOCOMPLEXITY=${NOCOMPLEXITY:-false}
	INSECURELDAP=${INSECURELDAP:-false}
	DNSFORWARDER=${DNSFORWARDER:-NONE}
	HOSTIP=${HOSTIP:-NONE}
	TLS=${TLS:-true}
	LOGS=${LOGS:-false}
	
	SCHEMA_LAPS=${SCHEMA_LAPS:-true}
	RFC2307=${RFC2307:-true}
	
	NTPSERVERLIST=${NTPSERVERLIST:-0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org}

	#Change if hostname includes DNS/DOMAIN SUFFIX e.g. host.example.com - it should only display host
	NETBIOS_NAME=${NETBIOS_NAME:-$(hostname)}

	MSCHAPV2=${MSCHAPV2:-true}
	DEBUG=${DEBUG:-false}
	DEBUGLEVEL=${DEBUGLEVEL:-0}

	#Posix
	LDOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    UDOMAIN=$(echo "$LDOMAIN" | tr '[:lower:]' '[:upper:]')
    URDOMAIN=$(echo "$UDOMAIN" | cut -d "." -f1)

	# Otherwise ldbmodify etc. would fail
	export LDB_MODULES_PATH=/usr/lib/samba/ldb/

	# Min Counter Values for NIS Attributes. Set in docker-compose if you want a different start
	# IT does nothing on DCs as they shall not use idmap settings.
	# Using the same Start and stop values on members however gets the RFC2307 attributs (NIS) rights
	# idmap config {{ URDOMAIN }} : range = {{ IDMIN }}-{{ IDMAX }} 
	IMAP_ID_START=${IMAP_UID_START:-10000}
	IMAP_UID_START=${IMAP_UID_START:-$IMAP_ID_START}
	IMAP_GID_START=${IMAP_GID_START:-$IMAP_ID_START}
	#DN for LDIF
	LDAPDN=""
	IFS='.'
	for dn in ${LDOMAIN}; do
		LDAPDN="${LDAPDN},DC=$dn"
	done
	IFS=''
	# If multi-site, we need to connect to the VPN before joining the domain
	if [ $(echo "$MULTISITE" | tr '[:upper:]' '[:lower:]') = "true" ]; then
		/usr/sbin/openvpn --config /docker.ovpn &
		VPNPID=$!
		echo "Sleeping 30s to ensure VPN connects ($VPNPID)";
		sleep 30
	fi

	#Remove unused supervisor config
	rm /etc/supervisord.conf

	# Set host ip option
	if [ "$RFC2307" = "true" ]; then
		RFC_OPTION="--use-rfc2307"
	else
		RFC_OPTION=""
	fi

		if [ "$HOSTIP" != "NONE" ]; then
		HOSTIP_OPTION="--host-ip=${HOSTIP}"
	else
		HOSTIP_OPTION=""
	fi

	if [ "$DEBUG" = "true" ]; then
		SAMBA_DEBUG_OPTION="-d $DEBUGLEVEL"
		SAMBADAEMON_DEBUG_OPTION="-d $DEBUGLEVEL"
		#NTP_DEBUG_OPTION="-D $DEBUGLEVEL"
	else
		SAMBA_DEBUG_OPTION=""
		NTP_DEBUG_OPTION=""
		SAMBADAEMON_DEBUG_OPTION=""
	fi
	
	sed -e "s:{{ SAMBADAEMON_DEBUG_OPTION }}:$SAMBADAEMON_DEBUG_OPTION:" -i /etc/supervisor/conf.d/supervisord.conf

	if [ ! -d /etc/samba/external/ ]; then
		mkdir /etc/samba/external
	fi

	if [ $(echo "$LOGS" | tr '[:upper:]' '[:lower:]') = "true" ]; then
	{
		echo ""
		echo "[logging]"
		echo "    default = FILE:/var/log/samba/krb5libs.log"
		echo "    kdc = FILE:/var/log/samba/krb5kdc.log"
		echo "    admin_server = FILE:/var/log/samba/kadmind.log"
	} >> /etc/krb5.conf
	fi

	sed -e "s:{{ UDOMAIN }}:$UDOMAIN:" \
		-e "s:{{ LDOMAIN }}:$LDOMAIN:" \
		-e "s:{{ NETBIOS_NAME }}:$NETBIOS_NAME:" \
	-i /etc/krb5.conf

	# If the finished file isn't there, this is brand new, we're not just moving to a new container
	if [ ! -f /etc/samba/external/smb.conf ]; then
		if [[ -f /etc/samba/smb.conf ]]; then
			mv /etc/samba/smb.conf /etc/samba/smb.conf.orig
		fi

		if [ $(echo "$JOIN" | tr '[:upper:]' '[:lower:]') = "true" ]; then
			if [[ ${JOINSITE} == "NONE" ]]; then
				samba-tool domain join ${LDOMAIN} DC -U${URDOMAIN}\\${DOMAINUSER} --password=${DOMAINPASS} --dns-backend=SAMBA_INTERNAL ${SAMBA_DEBUG_OPTION}
			else
				samba-tool domain join ${LDOMAIN} DC -U${URDOMAIN}\\${DOMAINUSER} --password=${DOMAINPASS} --dns-backend=SAMBA_INTERNAL --site=${JOINSITE} ${SAMBA_DEBUG_OPTION}
			fi
		else
			samba-tool domain provision ${RFC_OPTION} --domain=${URDOMAIN} --realm=${UDOMAIN} --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass=${DOMAINPASS} ${HOSTIP_OPTION} ${SAMBA_DEBUG_OPTION}
			
			if [[ ! -d /var/lib/samba/sysvol/"$LDOMAIN"/Policies/PolicyDefinitions/ ]]; then
				mkdir -p /var/lib/samba/sysvol/"$LDOMAIN"/Policies/PolicyDefinitions/en-US
				mkdir /var/lib/samba/sysvol/"$LDOMAIN"/Policies/PolicyDefinitions/de-DE
			fi

			if [[ "$RFC2307" == "true" ]]; then
				GID_DOM_USER=$((IMAP_GID_START))
				GID_DOM_ADMIN=$((IMAP_GID_START+1))
				GID_DOM_COMPUTERS=$((IMAP_GID_START+2))
				GID_DOM_DC=$((IMAP_GID_START+3))
				GID_DOM_GUEST=$((IMAP_GID_START+4))
				GID_SCHEMA=$((IMAP_GID_START+5))
				GID_ENTERPRISE=$((IMAP_GID_START+6))
				GID_GPO=$((IMAP_GID_START+7))
				GID_RDOC=$((IMAP_GID_START+8))
				GID_DNSUPDATE=$((IMAP_GID_START+9))
				GID_ENTERPRISE_RDOC=$((IMAP_GID_START+10))
				GID_DNSADMIN=$((IMAP_GID_START+11))
				GID_ALLOWED_RDOC=$((IMAP_GID_START+12))
				GID_DENIED_RDOC=$((IMAP_GID_START+13))
				GID_RAS=$((IMAP_GID_START+14))
				GID_CERT=$((IMAP_GID_START+15))

				UID_KRBTGT=$((IMAP_UID_START))
				UID_GUEST=$((IMAP_UID_START+1))
				UID_ADMINISTRATOR=$((IMAP_UID_START+2))

				#Next Counter value uesd by ADUC for NIS Extension GID and UID
				IMAP_GID_END=$((IMAP_GID_START+16))
				IMAP_UID_END=$((IMAP_UID_START+3))

				sed -e "s: {{ LDAPDN }}:$LDAPDN:g" \
					-e "s:{{ NETBIOS }}:$(echo "$URDOMAIN" | tr '[:upper:]' '[:lower:]'):g" \
					-e "s:{{ GID_DOM_USER }}:$GID_DOM_USER:g" \
					-e "s:{{ GID_DOM_ADMIN }}:$GID_DOM_ADMIN:g" \
					-e "s:{{ GID_DOM_COMPUTERS }}:$GID_DOM_COMPUTERS:g" \
					-e "s:{{ GID_DOM_DC }}:$GID_DOM_DC:g" \
					-e "s:{{ GID_DOM_GUEST }}:$GID_DOM_GUEST:g" \
					-e "s:{{ GID_SCHEMA }}:$GID_SCHEMA:g" \
					-e "s:{{ GID_ENTERPRISE }}:$GID_ENTERPRISE:g" \
					-e "s:{{ GID_GPO }}:$GID_GPO:g" \
					-e "s:{{ GID_RDOC }}:$GID_RDOC:g" \
					-e "s:{{ GID_DNSUPDATE }}:$GID_DNSUPDATE:g" \
					-e "s:{{ GID_ENTERPRISE_RDOC }}:$GID_ENTERPRISE_RDOC:g" \
					-e "s:{{ GID_DNSADMIN }}:$GID_DNSADMIN:g" \
					-e "s:{{ GID_ALLOWED_RDOC }}:$GID_ALLOWED_RDOC:g" \
					-e "s:{{ GID_DENIED_RDOC }}:$GID_DENIED_RDOC:g" \
					-e "s:{{ GID_RAS }}:$GID_RAS:g" \
					-e "s:{{ GID_CERT }}:$GID_CERT:g" \
					-e "s:{{ UID_KRBTGT }}:$UID_KRBTGT:g" \
					-e "s:{{ UID_GUEST }}:$UID_GUEST:g" \
					-e "s:{{ UID_ADMINISTRATOR }}:$UID_ADMINISTRATOR:g" \
					-e "s:{{ IMAP_UID_END }}:$IMAP_UID_END:g" \
					-e "s:{{ IMAP_GID_END }}:$IMAP_GID_END:g" \
				/root/ldif/RFC_Domain_User_Group.ldif.j2 > /root/ldif/RFC_Domain_User_Group.ldif

				ldbmodify -H /var/lib/samba/private/sam.ldb /root/ldif/RFC_Domain_User_Group.ldif
			fi

			if [[ "$SCHEMA_LAPS" == "true" ]]; then
			sed -e "s: {{ LDAPDN }}:$LDAPDN:g" \
			/root/ldif/laps-1.ldif.j2 > /root/ldif/laps-1.ldif

			sed -e "s: {{ LDAPDN }}:$LDAPDN:g" \
			/root/ldif/laps-2.ldif.j2 > /root/ldif/laps-2.ldif

			ldbadd -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true /root/ldif/laps-1.ldif
			ldbmodify -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true /root/ldif/laps-2.ldif
			fi

			if [[ $(echo "$NOCOMPLEXITY" | tr '[:upper:]' '[:lower:]') == "true" ]]; then
				samba-tool domain passwordsettings set --complexity=off ${SAMBA_DEBUG_OPTION}
				samba-tool domain passwordsettings set --history-length=0 ${SAMBA_DEBUG_OPTION}
				samba-tool domain passwordsettings set --min-pwd-age=0 ${SAMBA_DEBUG_OPTION}
				samba-tool domain passwordsettings set --max-pwd-age=0 ${SAMBA_DEBUG_OPTION}
			fi
		fi

		#Prevent https://wiki.samba.org/index.php/Samba_Member_Server_Troubleshooting => SeDiskOperatorPrivilege can't be set
		if [ ! -f /etc/samba/user.map ]; then
		echo '!'"root = ${DOMAIN}\\Administrator" > /etc/samba/user.map
		sed -i "/\[global\]/a \
username map = /etc/samba/user.map\
		" /etc/samba/smb.conf
		touch /etc/samba/user.map
		fi

		#Someone writes bullish to this file
		sed -i '/dns forwarder =/d' /etc/samba/smb.conf
		
		if [[ $DNSFORWARDER != "NONE" ]]; then
			sed -i "/\[global\]/a \
				\\\tdns forwarder = ${DNSFORWARDER}\
				" /etc/samba/smb.conf
		fi
		
		if [ $(echo "$TLS" | tr '[:upper:]' '[:lower:]') = "true" ]; then
#		openssl dhparam -out /var/lib/samba/private/tls/dh.key 2048 
		sed -i "/\[global\]/a \
tls enabled  = yes\\n\
tls keyfile  = /var/lib/samba/private/tls/key.pem\\n\
tls certfile = /var/lib/samba/private/tls/cert.pem\\n\
#tls cafile   = /var/lib/samba/private/tls/chain.pem\\n\
tls cafile   = /var/lib/samba/private/tls/ca.pem\\n\
#tls dh params file = /var/lib/samba/private/tls/dh.key\\n\
#tls crlfile   = /etc/samba/tls/crl.pem\\n\
#tls verify peer = ca_and_name\
		" /etc/samba/smb.conf

		# Prevent downgrade attacks to md5
		sed -i "/\[global\]/a \
reject md5 clients = yes\
		" /etc/samba/smb.conf
		
		

		fi
		if [ $(echo "$MSCHAPV2" | tr '[:upper:]' '[:lower:]') = "true" ]; then
		sed -i "/\[global\]/a \
ntlm auth = mschapv2-and-ntlmv2-only\
		" /etc/samba/smb.conf
		fi
		sed -i "/\[global\]/a \
wins support = yes\\n\
# Template settings for login shell and home directory\\n\
template shell = /bin/bash\\n\
template homedir = /home/%U\\n\
load printers = no\\n\
printing = bsd\\n\
printcap name = /dev/null\\n\
disable spoolss = yes\
		" /etc/samba/smb.conf
		
		if [ $(echo "$LOGS" | tr '[:upper:]' '[:lower:]') = "true" ]; then
			sed -i "/\[global\]/a \
log file = /var/log/samba/%m.log\\n\
max log size = 10000\\n\
log level = 1\
			" /etc/samba/smb.conf
		fi
		if [ $(echo "$INSECURELDAP" | tr '[:upper:]' '[:lower:]') = "true" ]; then
			sed -i "/\[global\]/a \
ldap server require strong auth = no\
			" /etc/samba/smb.conf
		fi

		# Once we are set up, we'll make a file so that we know to use it if we ever spin this up again
		cp -f /etc/samba/smb.conf /etc/samba/external/smb.conf
	else
		cp -f /etc/samba/external/smb.conf /etc/samba/smb.conf
	fi
  
	if [[ $(echo "$MULTISITE" | tr '[:upper:]' '[:lower:]') == "true" ]]; then
	  if [[ -n $VPNPID ]]; then
	    kill $VPNPID	
	  fi
	{
      echo ""
	  echo "[program:openvpn]"
	  echo "command=/usr/sbin/openvpn --config /docker.ovpn"
	} >> /etc/supervisor/conf.d/supervisord.conf
	fi

  DCs=$(echo "$NTPSERVERLIST" | tr " " "\n")
  NTPSERVER=""
  for DC in $DCs
  do
    NTPSERVER="$NTPSERVER server ${DC}    iburst\n"
  done

  sed -e "s/{{ NTPSERVER }}/$NTPSERVER/" \
  -i /etc/chrony/chrony.conf

	  # Own socket
	  mkdir -p /var/lib/samba/ntp_signd/
	  chown root:chrony /var/lib/samba/ntp_signd/
	  chmod 750 /var/lib/samba/ntp_signd/

	appFirstStart
}

appFirstStart () {
     mkdir -p /var/log/supervisor/
	/usr/bin/supervisord -c "/etc/supervisor/supervisord.conf"
	net rpc rights grant "$URDOMAIN\Domain Admins" SeDiskOperatorPrivilege -U"$URDOMAIN\$DOMAINUSER%DOMAINPASS" ${DEBUG_OPTION}
}

appStart () {
	/usr/bin/supervisord
}

case "$1" in
	start)
		if [ -f /etc/samba/external/smb.conf ]; then
			cp /etc/samba/external/smb.conf /etc/samba/smb.conf
			appStart
		else
			echo "Config file is missing."
		fi
		;;
	setup)
		# If the supervisor conf isn't there, we're spinning up a new container
		if [[ -f /etc/samba/external/smb.conf ]]; then
			appStart
		else
			appSetup
		fi
		;;
esac

exit 0