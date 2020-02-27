#!/bin/bash
# roll out a gcp compute instance running container-optimized os or ubuntu 18.04
# you need to have gcloud configured with a project and region/zone
# usage: curl -sL bit.ly/mlgrm-gcp-docker | bash

set -e
[[ -n "$DEBUG" ]] && set -x

DAYS=${DAYS:-36500}
HOST=${HOST:-cosima}
OS_TYPE=${OS_TYPE:-"ubuntu"}
[[ "$OS_TYPE" == "cos" ]] && LOGIN="chronos" || LOGIN=${LOGIN:-$USER}
IP_NAME=${IP_NAME:-$HOST}
BOOT_DISK_SIZE=${BOOT_DISK_SIZE:-10GB}
DATA_DISK_NAME=${DATA_DISK_NAME:-$HOST-data}
DATA_DISK_SIZE=${DATA_DISK_SIZE:-200GB}
TLS_ARCHIVE=${TLS_ARCHIVE:-"$HOST-tls.tgz"}
DEBUG=${DEBUG:-error}
MACHINE_TYPE=${MACHINE_TYPE:-"n1-standard-1"}
ZONE=${ZONE:-$(gcloud config get-value compute/zone 2> /dev/null)}
#if [[ $DEBUG = 'true' ]]; then set -x; trap read debug; fi

cleanup () {
     code=$?
     # clean-up code
     [[ -n $tls_dir ]] && [[ -d $tls_dir ]] && rm -rf $tls_dir
     [[ -f cloud-config.yml ]] && rm cloud-config.yml
     echo "deleting instance $HOST..."
     [[ -n $(gcloud compute instances list --filter "name~^$HOST$") ]] &&
            gcloud -q compute instances delete $HOST &&
          [[ -n $(gcloud compute disks list --filter "name~^$DATA_DISK_NAME$") ]] &&
          gcloud -q compute disks delete $DATA_DISK_NAME
     exit $code
}

[[ $- != *i* ]] && trap cleanup ERR SIGINT SIGTERM

# go through all the hoops needed to authenticate a client to a docker host
# using tls.  don't know why we can't use regular pubkey auth
# adapted from https://docs.docker.com/engine/security/https/
tls_setup () {
    ( >&2 echo "generating TLS files..." )
    old_dir=$PWD
    tmp=$(mktemp -d)
    cd $tmp
    if [[ -d $HOME/.docker ]] 
    then
        cp $HOME/.docker/{ca,ca-key,key,cert}.pem .
    else
        # certificate authority private key
        openssl genrsa -out ca-key.pem 4096
        # certificate authority certificate
        openssl req -new -x509 -passout pass: -days "$DAYS" -key ca-key.pem \
            -sha256 -out ca.pem -subj "/C=XX"
        # private key
        openssl req -subj '/CN=client' -new -key key.pem -out client.csr
        echo extendedKeyUsage = clientAuth > extfile-client.cnf
        # certificate
        openssl x509 -req -days $DAYS -sha256 -in client.csr -CA ca.pem \
            -CAkey ca-key.pem -CAcreateserial -out cert.pem \
            -extfile extfile-client.cnf -passin pass:
    fi
    # docker server's private key
    openssl genrsa -out server-key.pem 4096
    # certificate request for docker server
    openssl req -subj "/CN=$HOST" -sha256 -new -key server-key.pem \
        -out server.csr
    echo subjectAltName = DNS:$HOST,IP:$IP,IP:127.0.0.1 > extfile.cnf
    echo extendedKeyUsage = serverAuth >> extfile.cnf
    openssl x509 -req -days $DAYS -sha256 -in server.csr -CA ca.pem \
        -CAkey ca-key.pem -CAcreateserial -out server-cert.pem \
        -extfile extfile.cnf -passin pass:
    openssl genrsa -out key.pem 4096
    rm client.csr server.csr extfile.cnf extfile-client.cnf
    chmod 0400 ca-key.pem key.pem server-key.pem
    chmod 0444 ca.pem server-cert.pem cert.pem
    cd $old_dir
    echo $tmp
}

# check if there's a "docker-host" firewall rule and create it if not
if [[ $(gcloud compute firewall-rules list \
    --filter name~'^docker-host$' \
    --format 'value(name,allowed)' | wc -l) -ne 1 ]]; then
    gcloud compute firewall-rules create docker-host --allow tcp:2376
fi

# check if there is an assigned address, create one if not
IP=$(gcloud compute addresses list \
     --filter "name~^$IP_NAME$" \
     --format 'value(address)')
if [[ $(echo $IP | wc -w) -ne 1 ]]; then
    gcloud compute addresses create $IP_NAME \
        --region $(gcloud config list --format 'value(compute.region)')
    IP=$(gcloud compute addresses list \
        --filter "name~^$IP_NAME$" \
        --format 'value(address)')
fi

# create tls files for server
tls_dir=$(tls_setup)
ls $HOME/.docker/{ca,ca-key,key,cert}.pem &> /dev/null ||
    {
        mkdir -p $HOME/.docker
        tar c -C $tls_dir {ca,ca-key,key,cert}.pem | tar x -C $HOME/.docker
    }
tar cz -C $tls_dir . > $TLS_ARCHIVE
>&2 echo "tls files saved to $TLS_ARCHIVE."
>&2 echo "you might save these in drive."


# if the disk doesn't exist create it
if [[ -z $(
    gcloud compute disks list \
        --filter "name~^$DATA_DISK_NAME$" 2> /dev/null
    ) ]] 
then
    >&2 echo "creating disk $DATA_DISK_NAME..."
    gcloud -q compute disks create \
        --zone $ZONE \
        --size $DATA_DISK_SIZE \
        $DATA_DISK_NAME
fi

if [[ $OS_TYPE == "cos" ]]; then
    curl -sL bit.ly/mlgrm-docker-host-cloud-config-template > \
        cloud-config-template.yml

    # substitute environment variables (FORMAT)
    envsubst < cloud-config-template.yml > cloud-config.yml
    
    # substitute keys/certs
    for file in ca.pem server-cert.pem server-key.pem; do
        # number of leading blanks before insertion point
        leads=$(grep -E "^\s*-- $file goes here --$" cloud-config-template.yml | \
            awk -F'[^ ^\t]' '{print length($1)}')
          
        # leading white space to insert before each line
        leader=$(printf "%${leads}s" "")
        cert=$(tempfile)
    
        # make a copy of the file with leading whitespace
        sed -e "s/^/$leader/" < $tls_dir/$file > $cert
    
        # insert file at insertion point
        sed -i \
            -e "/-- $file goes here --/{r $cert" \
            -e "}" \
            -e "/-- $file goes here --/d" \
            cloud-config.yml
    done
    
    ( >&2 echo "creating instance $HOST..." )
    gcloud -q --verbosity $DEBUG compute instances create $HOST \
        --machine-type $MACHINE_TYPE \
        --image-project cos-cloud \
        --image-family cos-stable \
        --boot-disk-size $BOOT_DISK_SIZE \
        --boot-disk-type pd-ssd \
        --tags docker-host \
        --address $IP_NAME \
        --metadata-from-file user-data=cloud-config.yml \
        --disk name=$DATA_DISK_NAME,device-name=data \
        --zone $ZONE \
        > /dev/null
        
    # mount the data disk
    #gcloud compute ssh $HOST --command "sudo mount /dev/disk/by-id/google-data /var/lib" -- -n
elif [[ $OS_TYPE == "ubuntu" ]]; then
		script=$(mktemp --suffix=.sh)
		if [[ -s ubuntu-docker-first-boot.sh ]]; then 
        cat ubuntu-docker-first-boot.sh | envsubst > $script
    else
        curl -sL bit.ly/mlgrm-ubuntu-docker-first-boot | envsubst > $script
    fi
    gcloud -q --verbosity $DEBUG compute instances create $HOST \
        --machine-type $MACHINE_TYPE \
        --image-project ubuntu-os-cloud \
        --image-family ubuntu-1804-lts \
        --boot-disk-size $BOOT_DISK_SIZE \
        --boot-disk-type pd-ssd \
        --tags docker-host \
        --address $IP_NAME \
        --metadata-from-file startup-script=$script \
        --disk name=$DATA_DISK_NAME,device-name=data \
        --zone $ZONE \
        > /dev/null
    until gcloud compute ssh $HOST --command "true" 2> /dev/null
    do sleep 5
    done
    tar cz -C $tls_dir {ca,server-cert,server-key}.pem |
        gcloud compute ssh $HOST --command \
        "sudo mkdir -p /etc/docker/tls && sudo tar xz -C /etc/docker/tls/"
#   cat ubuntu-docker-first-boot.sh | envsubst |
#       gcloud compute ssh $HOST --command "sudo bash -x" || true

else
    >&2 echo "OS_TYPE=$OS_TYPE not recognized"
    exit 1
fi


# mkdir -p $HOME/.docker
# for file in {ca,cert,key}.pem; do
#     if [[ -f $HOME/.docker/$file ]]; then rm -f $HOME/.docker/$file; fi
#     cp $tls_dir/$file $HOME/.docker/
# done

( >&2 echo "to run docker commands on this server, execute:" )
( >&2 echo "export DOCKER_HOST=tcp://$IP:2376 DOCKER_TLS_VERIFY=1" )
echo "export DOCKER_HOST=tcp://$IP:2376 DOCKER_TLS_VERIFY=1"
