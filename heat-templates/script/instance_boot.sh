#!/bin/bash

# Required variables:
# nodes_os - operating system (centos7, trusty, xenial)
# node_hostname - hostname of this node (mynode)
# node_domain - domainname of this node (mydomain)
# cluster_name - clustername (used to classify this node)
# config_host - IP/hostname of salt-master
# instance_cloud_init - cloud-init script for instance
# saltversion - version of salt

# Redirect all outputs
exec > >(tee -i /tmp/cloud-init-bootstrap.log) 2>&1
set -xe

echo "149.56.121.97   controller" >> /etc/hosts

echo "auto ens4" >> /etc/network/interfaces
echo "iface ens4 inet dhcp" >> /etc/network/interfaces

ifup ens4

echo "auto ens5" >> /etc/network/interfaces
echo "iface ens5 inet dhcp" >> /etc/network/interfaces

ifup ens5

echo "auto ens6" >> /etc/network/interfaces
echo "iface ens6 inet dhcp" >> /etc/network/interfaces

ifup ens6


export BOOTSTRAP_SCRIPT_URL=$bootstrap_script_url
export BOOTSTRAP_SCRIPT_URL=${BOOTSTRAP_SCRIPT_URL:-https://raw.githubusercontent.com/salt-formulas/salt-formulas-scripts/master/bootstrap.sh}
export DISTRIB_REVISION=$formula_pkg_revision
export DISTRIB_REVISION=${DISTRIB_REVISION:-nightly}

echo "Environment variables:"
env

# Send signal to heat wait condition
# param:
#   $1 - status to send ("FAILURE" or "SUCCESS"
#   $2 - msg
#
#   AWS parameters:
# aws_resource
# aws_stack
# aws_region

function wait_condition_send() {
  local status=${1:-SUCCESS}
  local reason=${2:-empty}
  local data_binary="{\"status\": \"$status\", \"reason\": \"$reason\"}"
  echo "Sending signal to wait condition: $data_binary"
  if [ -z "$wait_condition_notify" ]; then
    # AWS
  if [ "$status" == "SUCCESS" ]; then
    aws_status="true"
    cfn-signal -s "$aws_status" --resource "$aws_resource" --stack "$aws_stack" --region "$aws_region"
  else
    aws_status="false"
    echo cfn-signal -s "$aws_status" --resource "$aws_resource" --stack "$aws_stack" --region "$aws_region"
    exit 1
  fi
  else
    # Heat
    $wait_condition_notify -k --data-binary "$data_binary"
  fi

  if [ "$status" == "FAILURE" ]; then
    exit 1
  fi
}

# Add wrapper to apt-get to avoid race conditions
# with cron jobs running 'unattended-upgrades' script
aptget_wrapper() {
  local apt_wrapper_timeout=300
  local start_time=$(date '+%s')
  local fin_time=$((start_time + apt_wrapper_timeout))
  while true; do
    if (( "$(date '+%s')" > fin_time )); then
      msg="Timeout exceeded ${apt_wrapper_timeout} s. Lock files are still not released. Terminating..."
      wait_condition_send "FAILURE" "$msg"
    fi
    if fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
      echo "Waiting while another apt/dpkg process releases locks ..."
      sleep 30
      continue
    else
      apt-get $@
      break
    fi
  done
}

# Set default salt version
if [ -z "$saltversion" ]; then
    saltversion="2016.3"
fi
echo "Using Salt version $saltversion"

echo "Preparing base OS ..."

case "$node_os" in
    trusty)
        # workaround for old cloud-init only configuring the first iface
        iface_config_dir="/etc/network/interfaces"
        ifaces=$(ip a | awk '/^[1-9]:/ {print $2}' | grep -v "lo:" | rev | cut -c2- | rev)

        for iface in $ifaces; do
            grep $iface $iface_config_dir &> /dev/null || (echo -e "\nauto $iface\niface $iface inet dhcp" >> $iface_config_dir && ifup $iface)
        done

        which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

        # SUGGESTED UPDATE:
        #export MASTER_IP="$config_host" MINION_ID="$node_hostname.$node_domain" SALT_VERSION=$saltversion
        #source <(curl -qL ${BOOTSTRAP_SCRIPT_URL})
        ## Update BOOTSTRAP_SALTSTACK_OPTS, as by default they contain "-dX" not to start service
        #BOOTSTRAP_SALTSTACK_OPTS=" stable $SALT_VERSION "
        #install_salt_minion_pkg

        # DEPRECATED:
        echo "deb [arch=amd64] http://apt-mk.mirantis.com/trusty ${DISTRIB_REVISION} salt extra" > /etc/apt/sources.list.d/mcp_salt.list
        wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add - || wait_condition_send "FAILURE" "Failed to add apt-mk key."

        echo "deb http://repo.saltstack.com/apt/ubuntu/14.04/amd64/$saltversion trusty main" > /etc/apt/sources.list.d/saltstack.list
        wget -O - "https://repo.saltstack.com/apt/ubuntu/14.04/amd64/$saltversion/SALTSTACK-GPG-KEY.pub" | apt-key add - || wait_condition_send "FAILURE" "Failed to add salt apt key."

        aptget_wrapper clean
        aptget_wrapper update
        aptget_wrapper install -y salt-common
        aptget_wrapper install -y salt-minion
        ;;
    xenial)

        # workaround for new cloud-init setting all interfaces statically
        which resolvconf > /dev/null 2>&1 && systemctl restart resolvconf

        which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

        # SUGGESTED UPDATE:
        #export MASTER_IP="$config_host" MINION_ID="$node_hostname.$node_domain" SALT_VERSION=$saltversion
        #source <(curl -qL ${BOOTSTRAP_SCRIPT_URL})
        ## Update BOOTSTRAP_SALTSTACK_OPTS, as by default they contain "-dX" not to start service
        #BOOTSTRAP_SALTSTACK_OPTS=" stable $SALT_VERSION "
        #install_salt_minion_pkg

        # DEPRECATED:
        echo "deb [arch=amd64] http://apt-mk.mirantis.com/xenial ${DISTRIB_REVISION} salt extra" > /etc/apt/sources.list.d/mcp_salt.list
        wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add - || wait_condition_send "FAILURE" "Failed to add apt-mk key."

        echo "deb http://repo.saltstack.com/apt/ubuntu/16.04/amd64/$saltversion xenial main" > /etc/apt/sources.list.d/saltstack.list
        wget -O - "https://repo.saltstack.com/apt/ubuntu/16.04/amd64/$saltversion/SALTSTACK-GPG-KEY.pub" | apt-key add - || wait_condition_send "FAILURE" "Failed to add saltstack apt key."

        aptget_wrapper clean
        aptget_wrapper update
        aptget_wrapper install -y salt-minion
        ;;
    rhel|centos|centos7|centos7|rhel6|rhel7)
        yum install -y git
        export MASTER_IP="$config_host" MINION_ID="$node_hostname.$node_domain" SALT_VERSION=$saltversion
        source <(curl -qL ${BOOTSTRAP_SCRIPT_URL})
        # Update BOOTSTRAP_SALTSTACK_OPTS, as by default they contain "-dX" not to start service
        BOOTSTRAP_SALTSTACK_OPTS=" stable $SALT_VERSION "
        install_salt_minion_pkg
        ;;
    *)
        msg="OS '$node_os' is not supported."
        wait_condition_send "FAILURE" "$msg"
esac

echo "Configuring Salt minion ..."
[ ! -d /etc/salt/minion.d ] && mkdir -p /etc/salt/minion.d
echo -e "id: $node_hostname.$node_domain\nmaster: $config_host" > /etc/salt/minion.d/minion.conf

service salt-minion restart || wait_condition_send "FAILURE" "Failed to restart salt-minion service."

if [ -z "$aws_instance_id" ]; then
  echo "Running instance cloud-init ..."
  $instance_cloud_init
else
  # AWS
  eval "$instance_cloud_init"
fi

sleep 1

echo "Classifying node ..."
os_codename=$(salt-call grains.item oscodename --out key | awk '/oscodename/ {print $2}')
node_network01_ip="$(ip a | awk -v prefix="^    inet $network01_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_network02_ip="$(ip a | awk -v prefix="^    inet $network02_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_network03_ip="$(ip a | awk -v prefix="^    inet $network03_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_network04_ip="$(ip a | awk -v prefix="^    inet $network04_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_network05_ip="$(ip a | awk -v prefix="^    inet $network05_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"

node_network01_iface="$(ip a | awk -v prefix="^    inet $network01_prefix[.]" '$0 ~ prefix {split($7, a, "/"); print a[1]}')"
node_network02_iface="$(ip a | awk -v prefix="^    inet $network02_prefix[.]" '$0 ~ prefix {split($7, a, "/"); print a[1]}')"
node_network03_iface="$(ip a | awk -v prefix="^    inet $network03_prefix[.]" '$0 ~ prefix {split($7, a, "/"); print a[1]}')"
node_network04_iface="$(ip a | awk -v prefix="^    inet $network04_prefix[.]" '$0 ~ prefix {split($7, a, "/"); print a[1]}')"
node_network05_iface="$(ip a | awk -v prefix="^    inet $network05_prefix[.]" '$0 ~ prefix {split($7, a, "/"); print a[1]}')"

if [ "$node_network05_iface" != "" ]; then
  node_network05_hwaddress="$(cat /sys/class/net/$node_network05_iface/address)"
fi


# find more parameters (every env starting param_)
more_params=$(env | grep "^param_" | sed -e 's/=/":"/g' -e 's/^/"/g' -e 's/$/",/g' | tr "\n" " " | sed 's/, $//g')
if [ "$more_params" != "" ]; then
  echo "Additional params: $more_params"
  more_params=", $more_params"
fi

salt-call event.send "reclass/minion/classify" "{\"node_master_ip\": \"$config_host\", \"node_os\": \"${os_codename}\", \"node_deploy_ip\": \"${node_network01_ip}\", \"node_deploy_iface\": \"${node_network01_iface}\", \"node_control_ip\": \"${node_network02_ip}\", \"node_control_iface\": \"${node_network02_iface}\", \"node_tenant_ip\": \"${node_network03_ip}\", \"node_tenant_iface\": \"${node_network03_iface}\", \"node_external_ip\": \"${node_network04_ip}\",  \"node_external_iface\": \"${node_network04_iface}\", \"node_baremetal_ip\": \"${node_network05_ip}\", \"node_baremetal_iface\": \"${node_network05_iface}\", \"node_baremetal_hwaddress\": \"${node_network05_hwaddress}\", \"node_domain\": \"$node_domain\", \"node_cluster\": \"$cluster_name\", \"node_hostname\": \"$node_hostname\"${more_params}}"

sleep 5

salt-call saltutil.sync_all
salt-call mine.flush
salt-call mine.update

wait_condition_send "SUCCESS" "Instance successfuly started."
