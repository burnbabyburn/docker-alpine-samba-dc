FROM alpine:latest

# Install
RUN apk add --no-cache samba-dc samba-dc-libs supervisor chrony krb5 ldb-tools \
    && rm -rf /etc/samba/* \
	&& apk add --no-cache samba-winbind-clients

# Persist the configuration, data and log directories
VOLUME ["/samba"]

# Expose ports
EXPOSE 37/udp \
       53 \
       88 \
       135/tcp \
       137/udp \
       138/udp \
       139 \
       389 \
       445 \
       464 \
       636/tcp \
       1024-5000/tcp \
       3268/tcp \
       3269/tcp

COPY init.sh /root/init.sh
RUN chmod +x /root/init.sh
COPY ldif/ /root/ldif/
COPY /etc /etc/

CMD /root/init.sh setup
