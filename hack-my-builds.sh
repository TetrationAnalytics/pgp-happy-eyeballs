#!/usr/bin/env bash
set -Eeuo pipefail

echo >&2 'WARNING: this script modifies /etc/docker/daemon.json; use at your own peril'

# uses https://github.com/tianon/rawdns to install pgp-happy-eyeballs in a way that can be used for "curl|bash" in Travis builds for transparently happy eyeballs

set -x

bip="$(ip address show dev docker0 | awk '$1 == "inet" { print $2; exit }')"
[ -n "$bip" ]
ip="${bip%/*}"
[ -n "$ip" ]

uid="$(id -u)"
_sudo() {
	if [ "$uid" = '0' ]; then
		"$@"
	else
		sudo "$@"
	fi
}

_sudo sh -xec '
	mkdir -p /etc/docker
	[ -s /etc/docker/daemon.json ] || echo "{}" > /etc/docker/daemon.json
'

_sudo jq --arg bip "$bip" --arg ip "$ip" '
		.bip = $bip
		| .dns = [
			$ip,
			"1.1.1.1",
			"1.0.0.1"
		]
	' /etc/docker/daemon.json \
		| sed 's/  /\t/g' \
		| _sudo tee /etc/docker/daemon.json.rawdns \
		> /dev/null
_sudo mv /etc/docker/daemon.json.rawdns /etc/docker/daemon.json
_sudo service docker stop &> /dev/null || :
_sudo service docker start
docker version > /dev/null

# TODO figure out why sometimes doing a lookup for "build-cache.travisci.net" doesn't give me the A record!!
export squignixHostname='build-cache.travisci.net'
export squignixServerIp='10.80.1.2'

export haveSquignixContainer="$(docker container inspect squignix &> /dev/null && echo squignix || :)"

docker rm -vf rawdns &> /dev/null || :
docker run -d \
	--restart always \
	--name rawdns \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-p "$ip":53:53/tcp \
	-p "$ip":53:53/udp \
	--dns 1.1.1.1 \
	--dns 1.0.0.1 \
	-e HAS_JOSH_K_SEAL_OF_APPROVAL \
	-e squignixHostname -e squignixServerIp \
	-e haveSquignixContainer \
	tianon/rawdns sh -xec '
		cat > /rawdns.json <<-EOF
			{
		EOF

		for host in "keyserver.ubuntu.com" "pgp.mit.edu" "pool.sks-keyservers.net"; do
			cat >> /rawdns.json <<-EOF
				"$host.": { "type": "static", "cnames": [ "pgp-happy-eyeballs.docker" ], "nameservers": [ "127.0.0.1" ] },
			EOF
		done
		cat >> /rawdns.json <<-EOF
			"hkps.pool.sks-keyservers.net.": { "type": "forwarding", "nameservers": [ "1.1.1.1", "1.0.0.1" ] },
		EOF

		squignixHost=
		# if we have a squignix container, we should use it!
		if [ -n "$haveSquignixContainer" ]; then
			squignixHost="$haveSquignixContainer.docker"
		# if we seem to be on Travis, use their shared squignix instance!
		elif [ -n "$HAS_JOSH_K_SEAL_OF_APPROVAL" ] && wget --spider --quiet --output-document /dev/null --header "Host: deb.debian.org" -T 5 "http://$squignixServerIp/__squignix_health__"; then
			squignixHost="$squignixHostname"
		fi
		if [ -n "$squignixHost" ]; then
			for host in "deb.debian.org" "snapshot.debian.org" "archive.ubuntu.com" "dl-cdn.alpinelinux.org"; do
				cat >> /rawdns.json <<-EOF
					"$host.": { "type": "static", "cnames": [ "$squignixHost" ], "nameservers": [ "127.0.0.1" ] },
				EOF
			done
		fi

		cat >> /rawdns.json <<-EOF
				"docker.": { "type": "containers", "socket": "unix:///var/run/docker.sock" },
				".": { "type": "forwarding", "nameservers": [ "1.1.1.1", "1.0.0.1" ] }
			}
		EOF

		cat /rawdns.json
		exec rawdns /rawdns.json
	'
docker rm -vf pgp-happy-eyeballs &> /dev/null || :
docker run -d --name pgp-happy-eyeballs --dns 1.1.1.1 --dns 1.0.0.1 tianon/pgp-happy-eyeballs

# trust, but verify
docker run --rm tianon/network-toolbox:alpine gpg --keyserver fake.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4
docker logs rawdns
docker logs pgp-happy-eyeballs
