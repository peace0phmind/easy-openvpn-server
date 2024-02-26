#!/bin/bash
set -e
set -x

if [ "$EUID" -ne 0 ]; then
  echo "Error: please run as root!"
  exit 1
fi

if [[ ! (-f "$SNAP_USER_DATA/internal.firewall-control-connected" && -f "$SNAP_USER_DATA/internal.network-control-connected") ]]; then
  echo "Error: please connect interfaces"
  sleep infinity
fi

get_snap_parameter() {
  PARAMETER=$1

  # Using snap get command to fetch the parameter value
  VALUE=$(snapctl get $PARAMETER)

  # Echo the value, which can be captured by a caller
  echo $VALUE
}

DEV_MODE=$(get_snap_parameter "dev-mode")

if [[ "$DEV_MODE" == "tun" ]]; then
  for var in "$@"; do
    if [[ "$found" == true ]]; then
      CONFIG_FILE="$var"
      # echo "true $CONFIG_FILE"
      break
    fi
    if [[ "$var" == "--config" ]]; then
      found=true
    fi
  done

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: please generate config"
    sleep infinity
  fi

  regex="^server\s+(.*)\s+(.*)"
  while IFS= read -r line; do
    # echo $line
    if [[ "$line" =~ $regex ]]; then
      TUNNEL_ADDRESS="${BASH_REMATCH[1]}"
      TUNNEL_NETMASK="${BASH_REMATCH[2]}"
      echo "ip ${TUNNEL_ADDRESS}"
      echo "nm ${TUNNEL_NETMASK}"
    fi
  done <"$CONFIG_FILE"

  iptables -t nat -A POSTROUTING -s $TUNNEL_ADDRESS/$TUNNEL_NETMASK -j MASQUERADE -m comment --comment "generated by easy-openvpn-server"

  regex="^server-ipv6\s+(.*)\s*"
  while IFS= read -r line; do
    # echo $line
    if [[ "$line" =~ $regex ]]; then
      TUNNEL_NETWORK_6="${BASH_REMATCH[1]}"
      echo "ipv6 network: ${TUNNEL_NETWORK_6}"
    fi
  done <"$CONFIG_FILE"

  # Note: see ipv6.md for more info on why we're using MASQUERADE NAT.
  ip6tables -t nat -A POSTROUTING -s $TUNNEL_NETWORK_6 -j MASQUERADE -m comment --comment "generated by easy-openvpn-server"

  ORIG_FORWARD_VALUE=$(sysctl net.ipv4.ip_forward -b)
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv6.conf.all.forwarding=1
  # https://strugglers.net/~andy/blog/2011/09/04/linux-ipv6-router-advertisements-and-forwarding/
  sysctl -w net.ipv6.conf.all.accept_ra=2

  function cleanup_tun {
    echo Cleaning up...
    #sysctl -w net.ipv4.ip_forward=${ORIG_FORWARD_VALUE}
    iptables -t nat -D POSTROUTING -s $TUNNEL_ADDRESS/$TUNNEL_NETMASK -j MASQUERADE -m comment --comment "generated by easy-openvpn-server"
    ip6tables -t nat -D POSTROUTING -s $TUNNEL_NETWORK_6 -j MASQUERADE -m comment --comment "generated by easy-openvpn-server"
  }
  trap cleanup_tun EXIT

else
  BRIDGE_NAME=$(get_snap_parameter "bridge-name")
  TAP_LIST=$(get_snap_parameter "tap-list")
  TAP_ETH_NAME=$(get_snap_parameter "tap-eth-name")
  TAP_ETH_IP=$(get_snap_parameter "tap-eth-ip")
  TAP_ETH_NETMASK=$(get_snap_parameter "tap-eth-netmask")
  TAP_ETH_BROADCAST=$(get_snap_parameter "tap-eth-broadcast")

  # Define Bridge Interface
  br=$BRIDGE_NAME

  # Define list of TAP interfaces to be bridged,
  # for example tap="tap0 tap1 tap2".
  tap=$TAP_LIST

  # Define physical ethernet interface to be bridged
  # with TAP interface(s) above.
  eth=$TAP_ETH_NAME
  eth_ip=$TAP_ETH_IP
  eth_netmask=$TAP_ETH_NETMASK
  eth_broadcast=$TAP_ETH_BROADCAST

  for t in $tap; do
    openvpn --mktun --dev $t
  done

  brctl addbr $br
  brctl addif $br $eth

  for t in $tap; do
    brctl addif $br $t
  done

  for t in $tap; do
    ifconfig $t 0.0.0.0 promisc up
  done

  ifconfig $eth 0.0.0.0 promisc up

  ifconfig $br $eth_ip netmask $eth_netmask broadcast $eth_broadcast

  function cleanup_tap {
    echo Cleaning up...
    # Define Bridge Interface
    br=$BRIDGE_NAME

    # Define list of TAP interfaces to be bridged together
    tap=$TAP_LIST

    ifconfig $br down
    brctl delbr $br

    for t in $tap; do
      openvpn --rmtun --dev $t
    done

    ifconfig $eth $eth_ip
  }
  trap cleanup_tap EXIT
fi

# Execute normally instead of with exec so our trap works correctly.
$@
