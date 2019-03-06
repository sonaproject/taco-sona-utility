#!/bin/bash
# -----------------------------------------------------------------------------
# TACO/SONA recovery shell script.
#
# This scripts is used for recovering the SONA from failure.
# 1. Backup the existing SONA node configuration.
# 2. Restart the entire SONA pods including clusterman.
# 3. Restore the backuped SONA node configuration.
# 4. Configure ARP mode. (broadcast by default)
# 5. Synchronize openstack states by querying neutron server.
# 6. Reinstall all flow rules into OpenvSwitch.
# -----------------------------------------------------------------------------

SONA_PODS=("sona-onos-0" "sona-onos-1" "sona-onos-2")
CLUSTER_POD="sona-clusterman-0"
ONOS_USER="onos"
ONOS_PASSWORD="rocks"
SONA_CONF_FILE="network-cfg.json"
ARP_MODE="broadcast"

function _usage () {
cat << _EOF_
usage: $(basename "$0")
- TACO/SONA recovery shell script.
This scripts is used for recovering the SONA from failure.
1. Backup the existing SONA node configuration.
2. Restart the entire SONA pods including clusterman.
3. Restore the backuped SONA node configuration.
4. Configure ARP mode. (broadcast by default)
5. Synchronize openstack states by querying neutron server.
6. Reinstall all flow rules into OpenvSwitch.
_EOF_
}

[ "$1" = "-h" ] || [ "$1" = '-?' ] && _usage && exit 0

################################################################################
# Checks whether the SONA apps are activated.
#
# Arguments:
#   onos_ip: ONOS IP address
# Returns:
#   None
################################################################################
function check_sona_app () {
  check_str='curl -sL --user $ONOS_USER:$ONOS_PASSWORD -w "%{http_code}\\n" '
  check_str+='"http://$1:8181/onos/openstacknetworking/management/floatingips/all" '
  check_str+='-o /dev/null'
  eval $check_str
}

################################################################################
# Obtains the k8s POD IP with given POD name.
#
# Arguments:
#   pod_name: k8s POD name
# Returns:
#   pod_ip: k8s POD IP address mapped with the given POD name
################################################################################
function get_pod_ip () {
  kubectl get po $1 -o wide -n openstack | awk 'FNR == 2 {print $6}'
}

################################################################################
# Synchronizes the openstack states with SONA.
#
# Arguments:
#   onos_ip: ONOS node IP address
# Returns:
#   None
################################################################################
function sync_states () {
  curl_str='curl -s --user $ONOS_USER:$ONOS_PASSWORD -X GET '
  curl_str+='http://$1:8181/onos/openstacknetworking/management/sync/states '
  curl_str+='-o /dev/null'
  eval $curl_str
}

################################################################################
# Installs flow rules into OVS by referring to openstack states.
#
# Arguments:
#   onos_ip: ONOS node IP address
# Returns:
#   None
################################################################################
function sync_rules () {
  curl_str='curl -s --user $ONOS_USER:$ONOS_PASSWORD -X GET '
  curl_str+='http://$1:8181/onos/openstacknetworking/management/sync/rules '
  curl_str+='-o /dev/null'
  eval $curl_str
}

################################################################################
# Configs the default ARP mode.
#
# Arguments:
#   onos_ip: ONOS node IP address
#   arp_mode: ARP mode (broadcast | proxy)
# Returns:
#   None
################################################################################
function config_arp_mode () {
  curl_str='curl -s --user $ONOS_USER:$ONOS_PASSWORD -X GET '
  curl_str+='http://$1:8181/onos/openstacknetworking/management/config/arpmode/$2 '
  curl_str+='-o /dev/null'
  eval $curl_str
}

################################################################################
# Deletes k8s PODs.
#
# Arguments:
#   pod_list: space separated pod list
# Returns:
#   None
################################################################################
function delete_pod () {
  kubectl delete po $1 -n openstack
}

################################################################################
# Checks k8s POD status.
#
# Arguments:
#   pod_name: pod name
# Returns:
#   None
################################################################################
function check_pod_status () {
  kubectl get po $1 -n openstack | awk 'FNR == 2 {print $3}'
}

################################################################################
# Checks k8s POD existence.
#
# Arguments:
#   pod_name: pod name
# Returns:
#   None
################################################################################
function check_pod_existence () {
  kubectl get po -n openstack | grep $1 | awk '{print $1}'
}

################################################################################
# Backups openstack node configuration.
#
# Arguments:
#   onos_ip: ONOS IP address
# Returns:
#   None
################################################################################
function backup_node_config () {
  rm -rf $SONA_CONF_FILE
  curl_str='curl -s --user $ONOS_USER:$ONOS_PASSWORD -X GET '
  curl_str+='http://$1:8181/onos/openstacknode/configure '
  curl_str+='-o $SONA_CONF_FILE > /dev/null'
  eval $curl_str
}

################################################################################
# Restores openstack node configuration.
#
# Arguments:
#   onos_ip: ONOS IP address
# Returns:
#   None
################################################################################
function restore_node_config () {
  curl_str='curl -s --user $ONOS_USER:$ONOS_PASSWORD '
  curl_str+='-X POST -H "Content-Type: application/json" '
  curl_str+='http://$1:8181/onos/openstacknode/configure -d @$SONA_CONF_FILE'
  eval $curl_str
}

################################################################################
# Checks SONA node configuration backup file.
#
# Arguments:
#   None
# Returns:
#   None
################################################################################
function check_backup_file () {
  if [[ -f "$SONA_CONF_FILE" ]] && [[ -s "$SONA_CONF_FILE" ]]
  then
    return 0
  else
    return 1
  fi
}

function main () {
  pod_name_list=()
  pod_ip_list=()

  pod_name_list+=($CLUSTER_POD)

  for pod in "${SONA_PODS[@]}"; do
    pod_name_list+=($pod)
    pod_ip_list+=($(get_pod_ip $pod))
  done

  echo "== Backup SONA node configurations =="
  backup_node_config ${pod_ip_list[0]}

  echo "== Check node backup file =="
  node_res=$(check_backup_file)
  if [ $? -eq 0 ]
  then
    echo "Backup file seems OK..."
  else
    echo "Failed to backup node config file..."
    exit 1
  fi

  echo "== Purge all SONA pods =="
  for pod_name in "${pod_name_list[@]}"; do
    echo "Delete k8s pod $pod_name..."
    delete_pod "$pod_name"
  done

  echo "== Check pods status =="
  for pod in "${SONA_PODS[@]}"; do
    while true
    do
      check_existence_result=$(check_pod_existence $pod)
      if [ ! -z $check_existence_result ] && [ $check_existence_result == "$pod" ];
      then
        break
      else
        sleep 5s
      fi
    done

    while true
    do
      check_pod_result=$(check_pod_status $pod)
      if [ $check_pod_result == "Running" ];
      then
        break
      else
        sleep 5s
      fi
    done

    echo "$pod is Running!"
  done

  echo "== Check SONA app status =="
  for pod_ip in "${pod_ip_list[@]}"; do
    while true
    do
      check_sona_app_str='check_sona_app $pod_ip'
      if [ $(eval $check_sona_app_str) == "200" ];
      then
        break
      else
        sleep 5s
      fi
    done
    echo "SONA apps at $pod_ip are activated!"
  done

  echo "== Restore SONA configuration at ${pod_ip_list[0]} =="
  restore_node_config ${pod_ip_list[0]}

  echo "== Configure ARP broadcast mode at ${pod_ip_list[0]} =="
  config_arp_mode ${pod_ip_list[0]} $ARP_MODE

  echo "== Synchronize openstack states at ${pod_ip_list[0]} =="
  sync_states ${pod_ip_list[0]}

  echo "== Synchronize openflow rules at ${pod_ip_list[0]} =="
  sync_rules ${pod_ip_list[0]}

  rm -rf $SONA_CONF_FILE
  echo "Done, Bye!"
}

main
