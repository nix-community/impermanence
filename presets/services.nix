{ systemConfig, lib }:

let
  inherit (systemConfig) services;
  dataDirGen = svc: { "${svc}".directories = [ services."${svc}".dataDir ]; };
  stateDirGen = svc: { "${svc}".directories = [ services."${svc}".stateDirGen ]; };
in
{
  prometheus.directories = [ ("/var/lib/" + services.prometheus.stateDir) ];
  prometheus-pushgateway = {
    option = services.prometheus.pushgateway.enable;
    directories = [ ("/var/lib/" + services.prometheus.pushgateway.stateDir) ];
  };
  prometheus-exporters-py-air-control = {
    option = services.prometheus.exporters.py-air-control.enable;
    directories = [ ("/var/lib/" + services.prometheus.exporters.py-air-control.stateDir) ];
  };
  # bitcoind # Uses attrset of submodules
  # bepasty # Uses attrset of submodules
  # errbot # Uses attrset of submodules
  # buildkite # Uses attrset of submodules
  # blockbook-frontend # Uses attrset of submodules
  minio.directories = services.minio.dataDir; # is a list already
  nextcloud.directories = [ services.nextcloud.datadir ];
  exhibitor.directories = [ services.exhibitor.zkDataDir ];
  restic-server = {
    option = services.restic.server.enable;
    directories = [ services.restic.server.dataDir ];
  };
  calibre-web.directories = [ ("/var/lib/" + services.calibre-web.dataDir) ];
  #patroni.directories = [ services.patroni.postgresqlDataDir ]; # Can conflict with Postgresql if left at default
  lighthouse-beacon = {
    option = services.lighthouse.beacon.enable;
    directories = [ services.lighthouse.beacon.directories ];
  };
  lighthouse-validator = {
    option = services.lighthouse.beacon.enable;
    directories = [ services.lighthouse.validator.directories ];
  };
  tor.directories = [ services.tor.settings.DataDirectory ];
  peertube.directories = services.peertube.dataDirs; # is a list already
  # hadoop # Uses attset of submodules
  # dokuwiki-sites # Uses attrset of submodules
  # invoiceplane-sites # Uses attrset of submodules
  charybdis.directories = [ ("/var/lib/" + services.charybdis.statedir) ];
  # dokuwiki
  # invoiceplane
  # thanos
  journalbeat.directories = [ ("/var/lib/" + services.journalbeat.stateDir) ];
  factorio.directories = [ ("/var/lib/" + services.factorio.stateDirName) ];
  wiki-js.directories = [ ("/var/lib/" + services.wiki-js.stateDirectoryName) ];
  jupyterhub.directories = [ ("/var/lib/" + services.jupyterhub.stateDirectory) ];
  gotify.directories = [ ("/var/lib/" + services.gotify.stateDirectoryName) ];
  documize.directories = [ ("/var/lib/" + services.documize.stateDirectoryName) ];
} // builtins.foldl' (val: col: val // (dataDirGen col)) {} [
  "postgresql"
  "loki"
  "grafana"
  "mysql"
  "mpd"
  "plex"
  "nats"
  "nzbhydra2"
  "teamspeak3"
  "znc"
  "sks"
  "ombi"
  "kubo"
  "etcd"
  "ergo"
  "mxisd"
  "grocy"
  "cfssl"
  "caddy"
  "boinc"
  "amule"
  "zammad"
  "sonarr"
  "radarr"
  "netbox"
  "mopidy"
  "monero"
  "lidarr"
  "kibana"
  "hydron"
  "galene"
  "deluge"
  "zerobin"
  "vmagent"
  "traefik"
  "serviio"
  "quassel"
  "prosody"
  "patroni"
  "owncast"
  "monetdb"
  "jackett"
  "awstats"
  "terraria"
  "tautulli"
  "rtorrent"
  "rabbitmq"
  "oxidized"
  "logstash"
  "jirafeau"
  "influxdb"
#  "graphite" # Doesn't have `enable` option
  "gitolite"
  "freshrss"
  "collectd"
  "zookeeper"
  "syncthing"
  "softether"
  "sickbeard"
  "paperless"
  "mosquitto"
  "mediatomb"
  "kapacitor"
  "duplicati"
  "bookstack"
  "taskserver"
  "slimserver"
#  "kubernetes" # Doesn't have `enable` option
  "headphones"
  "healthchecks"
  "foundationdb"
  "wasabibackend"
  "elasticsearch"
  "archisteamfarm"
  "pict-rs"
  "zigbee2mqtt"
  "snipe-it"
  "bee-clef"
  "rss-bridge"
  "unifi-video"
  "riemann-dash"
  "restya-board"
  "trilium-server"
  "matrix-synapse"
  "etebase-server"
  "minecraft-server"
  "hbase-standalone"
  "deliantra-server"
  #"crossfire-server" # Only if it's non-default
] // builtins.foldl' (val: col: val // (stateDirGen col)) {} [
  "unit"
  "tcsd"
  "gogs"
  "komga"
  "gitea"
  "gollum"
  "galene"
  "varnish"
  "unbound"
  "supybot"
  "redmine"
  "pleroma"
  "portunus"
  "peerflix"
  "dolibarr"
  "octoprint"
  "moonraker"
  "jmusicbot"
  "heartbeat"
  "writefreely"
  "privacyidea"
  "hledger-web"
  "deliantra-server"
  "crossfire-server"
]
