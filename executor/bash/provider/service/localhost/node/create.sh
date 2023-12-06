#!/usr/bin/env bash

carburator log info "Invoking localhost Qemu server provisioner..."

resource="node"
resource_dir="$INVOCATION_PATH/cloudinit"
data_dir="$PROVISIONER_PATH/providers/localhost"
cloudinit_sourcedir="$data_dir/$resource"

# Resource data paths
# TODO: this must be pointless as we know all the players here?
node_out="$data_dir/$resource.json"

# Make sure cloudinit resource dir exist.
mkdir -p "$resource_dir"

root_pubkey=$(carburator get env ROOT_SSH_PUBKEY -p .exec.env)

if [[ -z $root_pubkey ]]; then
    carburator log error \
        "Unable to find path to root public SSH key from .exec.env"
    exit 120
fi

# Copy cloudinit files from package to execution dir.
# This way files can be modified and package update won't overwrite
# the changes.
while read -r j2_tpl_file; do
	file=$(basename "$j2_tpl_file")

	cp -n "$j2_tpl_file" "$resource_dir/$file"
done < <(find "$cloudinit_sourcedir" -maxdepth 1 -iname '*.j2')

# Make sure we got the metadata template from sources.
if [[ ! -e $resource_dir/metadata.yaml.j2 || ! -e $resource_dir/userdata.yaml.j2 ]]; then
	carburator log error \
		"Missing required templates for node OS image generation."
	exit 120
fi

if [[ ! -e $resource_dir/userdata.yaml ]]; then
	# Run templater for userdata which is the same for all nodes.
	pw=$(carburator fn random-pass -sl 15)
	pubkey=$(head -n 1 "$root_pubkey")
	pwau=$(carburator get toml defaults.ssh_password_auth boolean \
		-p "$PROJECT_ROOT/project.toml")

	carburator fn tpl "$resource_dir/userdata.yaml.j2" \
		-k "password=$pw" \
		-k "root_pubkey=$pubkey" \
		-k "pw_auth=$pwau"
fi

# Recommended to have empty vendor data file
touch "$resource_dir/vendor-data"

# Set nodes array as servers config source.
provisioner_call() {
	node_len=$(carburator get json nodes array -p .exec.json | wc -l)

	if [[ -z $node_len || $node_len -lt 1 ]]; then
		carburator log error "Could not load nodes from .exec.json"
		exit 120
	fi

	# Download, build and run OS images.
	for (( i=0; i<node_len; i++ )); do
		name=$(carburator get json "nodes.$i.hostname" string -p .exec.json)
		image=$(carburator get json "nodes.$i.os.img" string -p .exec.json)

		if [[ -z $image ]]; then
			carburator log error \
				"Node with index '$i' is missing OS img field."
			exit 120
		fi

		# Each node needs metadata file
		if [[ ! -e $resource_dir/metadata-$name.yaml ]]; then
			uuid=$(carburator fn uuid)

			carburator fn tpl "$resource_dir/metadata.yaml.j2" \
				-k "iid=$uuid" \
				-k "hostname=$name"
		fi

		# Well download the image if we don't have it.
		file="${image##*/}"

		if [[ ! -e $1/$file ]]; then
			wget -P "$1/" "$image"
		fi

		# Build local cloud init os image.
		cloud-localds -i "seed-$name.img" "$1/userdata.yaml" "$1/metadata.yaml"
		exitcode=$?

		if [[ $exitcode -gt 0 ]]; then
			carburator log error \
				"Failed to build OS image from '$file'"
			exit 120
		fi

		# Respect the plan if there's one.
		plan=$(carburator get json "nodes.$i.plan.name" string -p .exec.json)

		if [[ $plan == "1" ]]; then
			cpu="cpus=1,maxcpus=1"
			ram="2G"
		elif [[ $plan == "2" ]]; then
			cpu="cpus=2,maxcpus=2"
			ram="2G"
		elif [[ $plan == "2" ]]; then
			cpu="cpus=2,maxcpus=2"
			ram="4G"
		elif [[ $plan == "2" ]]; then
			cpu="cpus=4,maxcpus=4"
			ram="6G"
		else
			cpu="host"
			ram="4G"
		fi

		qemu-system-x86_64 \
			-machine accel=kvm,type=q35 \
			-smp "$cpu" \
			-m "$ram" \
			-nographic \
			-device "virtio-net-pci,netdev=net0" \
			-netdev "user,id=net0,hostfwd=tcp::2222-:22" \
			-drive "if=virtio,format=qcow2,file=$1/$file" \
			-drive "if=virtio,format=raw,file=seed-$name.img"
	done
}

provisioner_call "$resource_dir"; exitcode=$?

if [[ $exitcode -eq 0 ]]; then
	carburator log success \
		"Server nodes created successfully with Qemu."

	len=$(carburator get json node.value array -p "$node_out" | wc -l)
	for (( i=0; i<len; i++ )); do
		# Easiest way to find the right node is with it's UUID
		node_uuid=$(carburator get json "node.value.$i.labels.uuid" string -p "$node_out")

		name=$(carburator get json "node.value.$i.name" string -p "$node_out")
		carburator log info "Locking node '$name' provisioner to Qemu..."
		carburator node lock-provisioner qemu --node-uuid "$node_uuid"

		# TODO:
		#
		# We have to define the CIDR block we use.
		# register-block value could be suffixed with /32 as well but lets leave a
		# reminder how to use the --cidr flag.
		ipv4=$(carburator get json "node.value.$i.ipv4" string -p "$node_out")

		# Register block and extract first (and the only) ip from it.
		if [[ -n $ipv4 && $ipv4 != null ]]; then
			carburator log info \
				"Extracting IPv4 address blocks from node '$name' IP..."

			address_block_uuid=$(carburator register net-block "$ipv4" \
				--extract \
				--ip "$ipv4" \
				--uuid \
				--provider localhost \
				--cidr 32) || exit 120

			# Point address to node.
			carburator node address \
				--node-uuid "$node_uuid" \
				--address-uuid "$address_block_uuid"
		fi

		# TODO: each ipv6 address a full /64 block so let's register that then.
		ipv6_block=$(carburator get json "node.value.$i.ipv6_block" string -p "$node_out")
		
		# Register block and the IP that Hetzner has set up for the node.
		if [[ -n $ipv6_block && $ipv6_block != null ]]; then
			carburator log info \
				"Extracting IPv6 address blocks from node '$name' IP..."

			ipv6=$(carburator get json "node.value.$i.ipv6" string -p "$node_out")

			# This is the other way to handle the address block registration.
			# register-block value has /cidr.
			address_block_uuid=$(carburator register net-block "$ipv6_block" \
				--uuid \
				--extract \
				--provider localhost \
				--ip "$ipv6") || exit 120

			# Point address to node.
			carburator node address \
				--node-uuid "$node_uuid" \
				--address-uuid "$address_block_uuid" || exit 120
		fi
	done

	carburator log success "IP address blocks registered."
elif [[ $exitcode -eq 110 ]]; then
	carburator log error \
		"Qemu provisioner failed with exitcode $exitcode, allow retry..."
	exit 110
else
	carburator log error \
		"Qemu provisioner failed with exitcode $exitcode"
	exit 120
fi
