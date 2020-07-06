FROM alpine:latest

# Install
RUN apk add --no-cache samba-dc supervisor chrony krb5

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

COPY init.sh /init.sh
COPY ldif/ /root/ldif/
COPY /etc /etc/

CMD /init.sh setup
