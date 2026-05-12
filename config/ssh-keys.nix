# Authorized SSH keys for all admin users in this project.
#
# Edit this file to add/remove admin keys. The keys here are deployed to:
#   - root@<host>
#   - every user listed in config/users.nix
#
# Re-deploy after editing:
#   ./scripts/deploy.sh <host> <ip>           # destructive, full re-install
# or, if the host is already up:
#   nixos-rebuild switch --flake .#<host> --target-host root@<host-ip>
#
# These keys were lifted from /wa/nix/mynix/hosts/common/ssh-keys.nix.

{
  admin = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDfdwtOGEXk4gdfw2ccxUu+ESwVuVjbTKMKgMVrqUEmEhOYNk/uON+zIFfAEbbxuuQrucfLFU5UHmqobgFOpLZ4yrPuBrv0jjCoByR/hlZ0/TTJXjzAEQZ3eaoQoI0yXdEmxsdsjLliHMiyeqj4XZS5yjD3aDXXjbIk8Mta4aOxHSfvY2JHs4TGErZKRTQpVM/spA+0IX3zDprU3pLgG9jEp1JHZmC5aeepKvyCGxgA3zthFlkgIDdYBDaJEIYIGVYj6o49W5n1qmMKrIA/uD/6LNPlmhSkLK8opPVYyLvynKd9j4g6it6RfDXcpJjjiCMUAY8XArvhTtfJV4Kr4Ztb ssh-key-2022-11-30"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7beEbYJvOz9CzKDcP5g+bF7/i+ap7y0pl9/E8IiA92aEGnDQ+n36H2imtlJfCuqP4YiOacwJglqLPCniCbKY5C+5tXx7N3u/RQ0YdQjvV0MVM3XJ3w/q5ssQVhB9jPPTEoFu7RyiO4Qt6wHngWSj4fP9w/MccsV4jQJPC5lZWR8/S5gzd5GdUTOebTtM1j2sl7W99btsRoLJOuPYUPKILe+RAz0jiFAzDJec6nRKTyNNg9G/tCm6upbHIceqYeAZqRFwqFeirrlvXpWyymTNe8rUm5CDDxObwMAf4VcXwBEt6zkp39VRxp7BrdqNBCXiFlv8mnH6q655y5evRxMMd ssh-key-2022-11-30"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDfum1bjD5kkGi+bhX1UO3a9DV/gz74luIbMxNqCuMKIqcLGUuTRQnWEondYwhlb5ZiLzdJIBS+mHb4iOUbVRiWqG1VK9DvlwASQfaQFtBvKV7p4xJ07ROqwQlhqBuCURLocAuyGplSNbPFxoD8dBtWvxhvYLQ1KX8nN4WNAwAFn0fFExWAuYc15Tx6MOkfw79P7xLxiR0zJ5Bv5xl3jgrkSWQofYZaK9QS6THSWrX9j6EQSlqsyrlRBTLAp+IOyq16W/EINkOj7jAq0pF0iNawjHDmU0XmfJOkVUNrrhNNLvYIDU4ovtwIa1pbDy2ISxFrw2UFloCdzY1zrGqo0Tez sgonzalez@emc2.gg"
  ];
}
