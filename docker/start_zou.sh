#!/bin/bash

# create /var/run/postgresql
. /usr/share/postgresql-common/init.d-functions
create_socket_directory

service postgresql start

. /opt/zou/env/bin/activate
zou upgrade-db

service postgresql stop

echo Running Zou...
supervisord -c /etc/supervisord.conf
