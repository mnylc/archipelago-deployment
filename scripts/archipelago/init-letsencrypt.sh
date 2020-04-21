#!/bin/bash

# This will setup a letsencrypt/certbot valid certificate given a REAL domain name you own.
# If you don't own one, you can use a self signed cert like this
# openssl req -x509 -newkey rsa:4096 -nodes -out cert.pem -keyout key.pem -days 365

# How does this work?
# Basically this is a script that generates a 
# -self signed cert so NGNINX can start (because of the need of having an SSL cert)
# -Restarts the container and then calls the certbot with manual option
# and real domain data. After some questions
# it will give you a hash
# you go an create a stub empty file with that name at persistent/certbot/www/ (use touch)
# Certbot/ngnix will check if the file exists and can be accessed remotely. If so
# you are good to go and SSL will be enabled.
# Many ways this could not work! But..
# - make sure your SSL (443) and /Port (80) are open on your Firewall
# - The file Certbot needs is actually created. You can check if visible before letting cerbot go for it
# - Always use the staging option because if you fail over and over, Letsencryp will block you for a day (or hours)

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

# Defaults for arguments
domains=(play.archipelago.nyc)

email="your@domain.org" # Adding a valid address is strongly recommended
staging=1 #1 if you're testing your setup to avoid hitting request limits

# let's fetch arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --domain=*)
      domain="${1#*=}"
      ;;
    --email=*)
      email="${1#*=}"
      ;;
    --staging=*)
      staging="${1#*=}"
      ;;
    *)
      printf "***************************\n"
      printf "* Error: Invalid argument.*\n"
      printf "***************************\n"
      exit 1
  esac
  shift
done


rsa_key_size=4096
data_path="./persistent/certbot"

if [ -d "$data_path" ]; then
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

echo "### Creating dummy certificate for $domains ..."
path="/etc/letsencrypt/live/$domains"
mkdir -p "$data_path/conf/live/$domains"
docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:1024 -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo


echo "### Starting nginx ..."
docker-compose up --force-recreate -d web
echo

echo "### Deleting dummy certificate for $domains ..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo


echo "### Requesting Let's Encrypt certificate for $domains ..."
#Join $domains to -d args
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --manual \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot

echo "### Now its a good time to restart your docker ensemble"

docker-compose exec web nginx -s reload


