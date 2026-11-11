# Garage's data on a two-disk mirror, with email alerts for the disks.
#
# Single-node Garage (replication_factor = 1) cannot recover a lost disk by
# itself, so redundancy comes from md RAID1 below it, formatted XFS as Garage
# recommends. Garage's metadata (SQLite) stays on the SSD with the system.
#
# The array was created by hand, once (whole disks, no partition table):
#   mdadm --create /dev/md/data --level=1 --raid-devices=2 --bitmap=internal \
#     --homehost=lbv --name=data /dev/sdb /dev/sdd
#   mkfs.xfs -L garage-data /dev/md/data
# Replacing a failed disk: see the README.
{ pkgs, ... }:
let
  # Outside Garage's StateDirectory: systemd sets that one up with an id-mapped
  # mount, which fails ("Device or resource busy") with a filesystem mounted
  # inside it.
  garageDataDir = "/srv/garage-data";

  # Who gets the alerts, and the account that sends them: lbv@ is an alias of
  # the labelleverte@ mailbox on vps (machines/vps/configuration.nix), so it is
  # an allowed sender for that login.
  # admin@ is an alias of the mickours@ mailbox (machines/vps/configuration.nix).
  alertsTo = "admin@libr.fr";
  alertsFrom = "lbv@libr.fr";
  smtpUser = "labelleverte@libr.fr";
  # Plain-text SMTP password, set by hand (root, 0400): see the README.
  smtpPasswordFile = "/var/lib/secrets/smtp-password";
in
{
  boot.swraid = {
    enable = true;
    # MAILADDR is what enables mdmonitor: it mails on Fail, DegradedArray,
    # SparesMissing... through the sendmail that msmtp provides below.
    mdadmConf = ''
      MAILADDR ${alertsTo}
      MAILFROM ${alertsFrom}
      ARRAY /dev/md/data metadata=1.2 UUID=9d0972a1:d169f33f:cb816ff1:a0e4d2f2
    '';
  };

  fileSystems.${garageDataDir} = {
    device = "/dev/disk/by-uuid/1053f52f-d923-4f52-b848-929f3b04eb80";
    fsType = "xfs";
    # A missing array must not stop the machine from booting (and RDP/SSH
    # from coming up): Garage is the one that refuses to start, below.
    options = [ "nofail" ];
  };
  # The module then adds it to the unit's ReadWritePaths.
  services.garage.settings.data_dir = garageDataDir;
  # Without the mount Garage would happily write into the empty directory on
  # the SSD and look healthy. Bound to the mount: it stops if the mount goes.
  systemd.services.garage.unitConfig.RequiresMountsFor = [ garageDataDir ];
  # A data directory outside the StateDirectory needs an owner that does not
  # change between boots, which a DynamicUser does not guarantee. Turning
  # DynamicUser off made systemd move /var/lib/private/garage (the metadata)
  # back to /var/lib/garage.
  systemd.services.garage.serviceConfig = {
    DynamicUser = false;
    User = "garage";
    Group = "garage";
  };
  users.users.garage = {
    isSystemUser = true;
    group = "garage";
  };
  users.groups.garage = { };
  systemd.tmpfiles.settings."10-garage-data".${garageDataDir}.d = {
    user = "garage";
    group = "garage";
    mode = "0700";
  };

  # Read every sector of both disks once a month, so a bad sector is found
  # (and rewritten from the other copy) before the day the mirror needs it.
  # Mismatches show up in /sys/block/mdX/md/mismatch_cnt.
  systemd.services.raid-check = {
    description = "Check md RAID arrays for read errors";
    serviceConfig.Type = "oneshot";
    script = ''
      for action in /sys/block/md*/md/sync_action; do
        [ -e "$action" ] || continue
        if [ "$(cat "$action")" = idle ]; then echo check > "$action"; fi
      done
    '';
  };
  systemd.timers.raid-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-01..07 02:00";
      Persistent = true;
    };
  };

  # SMART: mails on failing health, new pending/uncorrectable sectors... and
  # runs a short self-test every night and a long one every Saturday.
  services.smartd = {
    enable = true;
    defaults.autodetected = "-a -o on -S on -n standby,q -s (S/../.././03|L/../../6/04) -W 4,45,55";
    notifications = {
      mail = {
        enable = true;
        sender = alertsFrom;
        recipient = alertsTo;
      };
      # One mail at startup per disk: proves the whole mail chain works.
      test = false;
    };
  };

  # Outgoing mail only, through the libr.fr mail server on vps.
  programs.msmtp = {
    enable = true;
    setSendmail = true;
    accounts.default = {
      host = "mail.libr.fr";
      # TLS from the first byte: 587 (STARTTLS) is not reachable from here,
      # and Nextcloud on vps uses 465 too.
      port = 465;
      tls = true;
      tls_starttls = false;
      # Never leave mdadm or smartd waiting on a mail that cannot go out.
      timeout = 30;
      auth = true;
      user = smtpUser;
      from = alertsFrom;
      # EHLO name, "localhost" otherwise.
      domain = "lbv.libr.fr";
      passwordeval = "${pkgs.coreutils}/bin/cat ${smtpPasswordFile}";
    };
  };

  environment.systemPackages = [
    pkgs.mdadm
    pkgs.smartmontools
    pkgs.xfsprogs
  ];
}
