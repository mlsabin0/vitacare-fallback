#!/bin/bash

# Remove o link simbólico dinâmico do resolv.conf
rm /etc/resolv.conf

# Cria um novo arquivo estático com os servidores DNS do Google
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf