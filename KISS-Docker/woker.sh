#!/bin/bash

export local_registry="/registry" # Local registry that plays the role of Dockerhub.
export woker_workDir="/var/lib/woker" # Similar to /var/lib/docker.
export woker_imageDir="/var/lib/woker/image" # Similar to /var/lib/docker/image, where docker stores images' layers.
export woker_containersDir="/var/lib/woker/containers" # Similar to /var/lib/docker/containers, where docker stores containers' infos.

##################################################################################################
##                                          INIT                                                ##
##################################################################################################
function woker_init_host () {
    sudo apt update -y -qq
    sudo apt install -y -qq debootstrap jq btrfs-progs curl iproute2 iptables libcgroup-dev cgroup-tools util-linux coreutils nginx 

    # Check if woker workingDirs exist
        sudo mkdir -p /var/lib/woker/image
        sudo mkdir -p /var/lib/woker/containers

    # Check if config template exists
    if [ ! -e "./config.v2.json.tpl" ]; then
        echo "Please make sure to copy the config template 'config.v2.json.tpl'!"
        exit -1
    fi

    # Check the file that holds the list of containers 
    if [ ! -e "$woker_containersDir/list" ]; then
         echo "ContainerName ContainerID" >> $woker_containersDir/list
    fi    
    # Check if bridge woker0 (similar to docker0 bridge) exists, otherwise create it.
    if [ ! -d "/sys/class/net/woker0/bridge" ]; then
        echo "Bridge woker0 doesn't exist, let's create it!"
        sudo ip link add woker0 type bridge
        sudo ip addr add 180.10.0.1/24 dev woker0
        sudo ip link set woker0 up
    else
        echo "Bridge woker0 exists!"
    fi
}

function woker_init_container () {

sudo chroot $1 bash <<"EOT"
 apt update -y
 apt install -y debootstrap btrfs-progs curl iproute2 iptables util-linux coreutils nginx
 rm /var/www/html/index.nginx-debian.html
 echo "Welcome from Jail!" >> /var/www/html/index.html
EOT
}

##################################################################################################
##                                          Networking                                          ##
##################################################################################################

function woker_container_net_config (){

     sudo ip link add $(echo "veth-$1") type veth peer name $(echo "veth-$1-br")
     sudo ip link set dev $(echo "veth-$1-br") up
     sudo ip link set $(echo "veth-$1-br") master woker0

     # The following should be executed when unshare process is running 
     sudo ip link set $(echo "veth-$1") netns $1
     sudo ip netns exec $1 ip addr add 180.10.0.$(( $RANDOM%100 ))/24 dev $(echo "veth-$1")

     # Enable all network interfaces
     sudo ip link set dev $(echo "veth-$1-br") up
     sudo ip link set dev woker0 up
     sudo ip netns exec $1 ip link set dev lo up
     sudo ip netns exec $1 ip link set dev $(echo "veth-$1") up


     # Add route to container to reach host"
     sudo ip netns exec $1 ip route add default via 180.10.0.1
}

##################################################################################################
##                                          Cgroups                                             ##
##################################################################################################

function woker_container_cgroups () {
	cgcreate -g "cpu,memory:/$1"
	: "${WOKER_CPU_SHARE:=512}" && cgset -r cpu.shares="$WOKER_CPU_SHARE" "$1"
	: "${WOKER_MEM_LIMIT:=512}" && cgset -r memory.limit_in_bytes="$((WOKER_MEM_LIMIT * 1000000))" "$1"
}
##################################################################################################
##                                          WOKER PS                                            ##
##################################################################################################
# A functionality similar to "docker ps". Used to list running containers.

function woker_ps () {
    woker_help_ps
    # Check the file that holds the list of containers 
    if [ ! -e "$woker_containersDir/list" ]; then
         echo "ContainerName ContainerID" >> $woker_containersDir/list
    fi    
    cat $woker_containersDir/list
}

##################################################################################################
##                                          WOKER INSPECT                                       ##
##################################################################################################
# A functionality similar to "docker inspect --format '{{.State.Pid}}' container_id". 
# Used to retrieve the PID of a running container to use it for an EXEC/DELETE operation.

function woker_inspect () {
    woker_help_inspect
    read CONID
    echo "PID of container $CONID is:" $(cat $woker_containersDir/$CONID/config.v2.json | jq -r '.State.Pid' )
}

##################################################################################################
##                                          WOKER BUILD                                         ##
##################################################################################################
# A functionality that downloads the container's filesystem in $woker_containersDir.

function woker_build () {
    echo "Download the container's filesystem .."
    sudo debootstrap --variant=minbase bionic $1
}


##################################################################################################
##                                          WOKER PULL                                          ##
##################################################################################################
# A functionality that retrieve a specific container's image from the local registry, decompress 
# it and put it in $woker_imageDir.

function woker_pull () {
    echo "docker pull"
}

##################################################################################################
##                                          WOKER PUSH                                          ##
##################################################################################################
# A functionality that compress a container's filesystem and save it in the local registry.

function woker_push () {
    echo "docker push"
}

##################################################################################################
##                                          WOKER UNSHARE                                       ##
##################################################################################################

function woker_unshare () {
    # Launch the container 
    sudo mount -t proc /proc $1/proc

    echo $$ > /sys/fs/cgroup/memory/$2/cgroup.procs
    echo $$ > /sys/fs/cgroup/cpu/$2/cgroup.procs

    mkfifo in
    unshare -fmuip --mount-proc \
                --net=/var/run/netns/$2 \
                chroot $1  /bin/sh -c "/bin/mount -t proc proc /proc && bash" < in &
}
##################################################################################################
##                                          WOKER RUN                                           ##
##################################################################################################
# A functionality that runs a container.

function woker_run () {
    woker_help_run
    read container_name
    export uuid="$(shuf -i 42002-42254 -n 1)"
    echo "Create container $container_name with an ID=$uuid .."
    woker_init_host

    # Check if container already exists
    [ -d "$woker_containersDir/$uuid" ] && echo "Container already exists!" && exit -1

    woker_build "$woker_containersDir/$uuid/$container_name"
    woker_init_container "$woker_containersDir/$uuid/$container_name"
    sudo ip netns add $uuid

    # Create/Configure the container's cgroup
    woker_container_cgroups $uuid

    woker_unshare $woker_containersDir/$uuid/$container_name $uuid 


    # Retrieve the container's infos and save them in config.v2.json file
    cp ./config.v2.json.tpl $woker_containersDir/$uuid/config.v2.json

    PID=$(jobs -l | cut -d' ' -f2)
    
    echo "PID: $PID"
    sed -i "s/myContainerID/$uuid/g" $woker_containersDir/$uuid/config.v2.json
    sed -i "s/myContainerPID/$PID/g" $woker_containersDir/$uuid/config.v2.json
    
    cat $woker_containersDir/$uuid/config.v2.json
    echo "$container_name   $uuid" >> $woker_containersDir/list
    # Configure the container network
    woker_container_net_config $uuid 

}

##################################################################################################
##                                          WOKER EXEC                                          ##
##################################################################################################
# A functionality that exec into a running container.
# nsenter --target container_pid --mount --uts --ipc --net --pid 

function woker_exec () {
     woker_help_exec
     echo "Container's PID"
     read CONPID
     echo "Container's ID"
     read ID
     echo "Container's name"
     read NAME
     nsenter --pid=/proc/$CONPID/ns/pid \
		unshare \
			--fork \
			--pid \
			--net=/var/run/netns/$ID \
			--mount-proc=$woker_containersDir/$ID/$NAME/proc \
			chroot $woker_containersDir/$ID/$NAME bash
}

##################################################################################################
##                                          WOKER DELETE                                        ##
##################################################################################################
# A functionality that deletes a container.

function woker_delete () {
    echo "docker rm"
}


##################################################################################################
##                                         HELP FUNCTIONS                                       ##
##################################################################################################
function woker_help () {

cat <<"EOF"
                                      .-"""-.
                                     / .===. \
                                     \/ 6 6 \/
                                     ( \___/ )
          _______________________ooo__\_____/___________________________
         /                                                              \
        | Hello there! Woker helps you Create/Run/Exec/Delete containers!|
        |                                                                |
         \____________________________________ooo_______________________/
                                     |  |  |
                                     |_ | _|
                                     |  |  |
                                     |__|__|
                                     /-'Y'-\
                                    (__/ \__)
Pick an action:
1. Run a container.
2. List all running containers.
3. Exec into a running container.
4. Delete a container.
5. Inspect the PID of a container.
6. Pull a container's image.
7. Push a container's image.
EOF

}

function woker_help_run () {

cat <<"EOF"
                                      .-"""-.
                                     / .===. \
                                     \/ 6 6 \/
                                     ( \___/ )
          _______________________ooo__\_____/___________________________
         /                                                              \
        |    Let's RUN a container for you. Please Pick a name for       |
        |                          your container!                       |
         \____________________________________ooo_______________________/
                                     |  |  |
                                     |_ | _|
                                     |  |  |
                                     |__|__|
                                     /-'Y'-\
                                    (__/ \__)
EOF

}

function woker_help_ps () {

cat <<"EOF"
                                      .-"""-.
                                     / .===. \
                                     \/ 6 6 \/
                                     ( \___/ )
          _______________________ooo__\_____/___________________________
         /                                                              \
        |      The following is the list of all running containers.      |
        |                                                                |
         \____________________________________ooo_______________________/
                                     |  |  |
                                     |_ | _|
                                     |  |  |
                                     |__|__|
                                     /-'Y'-\
                                    (__/ \__)
EOF
}

function woker_help_exec () {

cat <<"EOF"
                                      .-"""-.
                                     / .===. \
                                     \/ 6 6 \/
                                     ( \___/ )
          _______________________ooo__\_____/___________________________
         /                                                              \
        |   Let's exec into your container! What's the container's id?   |
        |                                                                |
         \____________________________________ooo_______________________/
                                     |  |  |
                                     |_ | _|
                                     |  |  |
                                     |__|__|
                                     /-'Y'-\
                                    (__/ \__)
EOF
}

function woker_help_inspect () {

cat <<"EOF"
                                      .-"""-.
                                     / .===. \
                                     \/ 6 6 \/
                                     ( \___/ )
          _______________________ooo__\_____/___________________________
         /                                                              \
        |Let's find the PID of your container! What was your container's |
        |                             id?                                |
         \____________________________________ooo_______________________/
                                     |  |  |
                                     |_ | _|
                                     |  |  |
                                     |__|__|
                                     /-'Y'-\
                                    (__/ \__)
EOF
}

function woker_help_delete () {

cat <<"EOF"
                                      .-"""-.
                                     / .===. \
                                     \/ 6 6 \/
                                     ( \___/ )
          _______________________ooo__\_____/___________________________
         /                                                              \
        |    Let's delete your container! What's the container's id?     |
        |                                                                |
         \____________________________________ooo_______________________/
                                     |  |  |
                                     |_ | _|
                                     |  |  |
                                     |__|__|
                                     /-'Y'-\
                                    (__/ \__)
EOF
}


##################################################################################################
##                                        MAIN PROGRAM                                          ##
##################################################################################################

woker_help

while :
do

read op 
case $op in
	1) woker_run
       break
	   ;;
	2) woker_ps
       break
       ;;
	3) woker_exec
       break
       ;;
	4) woker_run
       break
       ;;
	5) woker_inspect
       break
       ;;
	6) woker_pull
       break
       ;;
	7) woker_push
       break
       ;;
	*) woker_help
       ;;
esac
done