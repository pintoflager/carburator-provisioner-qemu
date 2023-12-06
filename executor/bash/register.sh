#!/usr/bin/env bash

# ATTENTION: Supports only client nodes, pointless to read role from $1
if [[ $1 == "server" ]]; then
    carburator log error \
        "Provisioners register only on client nodes. Package configuration error."
    exit 120
fi

if ! carburator has program qemu-system-x86_64; then
    carburator log warn "Missing qemu-system-x86_64 on client machine."

    carburator prompt yes-no \
        "Should we try to install qemu?" \
        --yes-val "Yes try to install with a script" \
        --no-val "No, I'll install everything"; exitcode=$?

    if [[ $exitcode -ne 0 ]]; then
      exit 120
    fi

    # TODO: Untested below.
    carburator log warn \
      "Missing required program Qemu. Trying to install it before proceeding..."

    if carburator has program apt; then
        sudo apt-get -y update
        sudo apt-get -y install qemu qemu-kvm

    elif carburator has program pacman; then
        sudo pacman update
        sudo pacman -Sy qemu qemu-kvm

    elif carburator has program yum; then
        sudo yum makecache --refresh
        sudo yum -y install qemu-kvm

    elif carburator has program dnf; then
        sudo dnf makecache --refresh
        sudo dnf -y install @virtualization

    else
        carburator log error \
            "Unable to detect package manager from client node linux"
        exit 120
    fi
else
    carburator log success "Qemu found from the client"
fi

if ! carburator has program cloud-localds; then
    carburator log warn "Missing cloud-localds on client machine."

    carburator prompt yes-no \
        "Should we try to install cloud-localds?" \
        --yes-val "Yes try to install with a script" \
        --no-val "No, I'll install everything"; exitcode=$?

    if [[ $exitcode -ne 0 ]]; then
      exit 120
    fi
else
    carburator log success \
      "Localhost version of cloud init (cloud-localds) found from the client"
    exit 0
fi

# TODO: Untested below.
carburator log warn \
  "Missing required program cloud-localds. Trying to install it before proceeding..."

if carburator has program apt; then
    sudo apt-get -y update
    sudo apt-get -y install cloud-utils

elif carburator has program pacman; then
    sudo pacman update
    sudo pacman -Sy cloud-utils

elif carburator has program yum; then
    sudo yum makecache --refresh
    sudo yum install cloud-utils

elif carburator has program dnf; then
    sudo dnf makecache --refresh
    sudo dnf install cloud-utils -y

else
    carburator log error \
        "Unable to detect package manager from client node linux"
    exit 120
fi