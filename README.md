# nixos-config

To update run:
```sh
nix run github:serokell/deploy-rs .#vps
```

## Comptes utilisateurs (SSO)

Les noms et adresses sont des données personnelles : ils ne sont **pas** dans ce
dépôt. Kanidm les lit au démarrage dans `/data/keys/kanidm-persons.json` sur le
serveur (`services.kanidm.provision.extraJsonFile`).

Le format est celui de [kanidm-provision][kp], dont
[`persons.example.json`](persons.example.json) est un exemple complet.
Attention : l'appartenance aux groupes se déclare sous `groups.<nom>.members`,
et *pas* dans chaque personne.

**Uniquement des personnes.** L'identifiant est `prenom.nom` — le même pour
Kanidm, pour le compte Nextcloud et pour l'adresse principale
`prenom.nom@libr.fr`. Les boîtes de service ou de rôle (`nextcloud@`,
`bitwarden@`, `labelleverte@`) ne sont *pas* ici : elles sont déclarées dans
`serviceAccounts` (`machines/vps/configuration.nix`), restent en authentification
par mot de passe, et n'ont donc ni SSO, ni réinitialisation d'identifiants, ni
mot de passe POSIX.

```sh
# éditer sur le serveur
ssh root@vps
$EDITOR /data/keys/kanidm-persons.json
systemd-tmpfiles --create --prefix=/data/keys   # réapplique propriétaire et mode déclarés
systemctl restart kanidm   # la reprovision a lieu au démarrage
```

Le fichier fait autorité : `autoRemove` étant actif, une personne retirée du
fichier est supprimée de Kanidm au redémarrage suivant. Un fichier absent fait
échouer le service plutôt que de vider l'annuaire.

### Renommer une personne : deux passes obligatoires

`kanidm-provision` **crée avant de supprimer**, et l'attribut `mail` doit être
unique dans tout l'annuaire. Renommer `marine` en `marine.mercier` en une seule
passe échoue donc : la nouvelle personne réclame une adresse que l'ancienne
détient encore, et kanidm refuse —

```
AttributeUniqueness([Mail, Mail])
409 Conflict  /v1/person/marine.mercier/_attr/mail
conflicting_with: marine@idm.libr.fr
```

ce qui fait échouer `kanidm.service` au démarrage (l'erreur survient dans
`ExecStartPost`). Procéder en deux passes :

1. téléverser le fichier avec les **nouveaux noms mais sans `mailAddresses`**,
   puis `systemctl restart kanidm`. Les anciennes personnes sont supprimées, ce
   qui libère les adresses ;
2. téléverser le fichier complet, avec les adresses, et redémarrer à nouveau.

Faire une sauvegarde avant (`cp -a kanidm-persons.json kanidm-persons.json.bak-$(date +%F)`).

À faire **avant** tout déplacement de boîte aux lettres : renommer une personne
la supprime et la recrée, donc son `entryuuid` change — or c'est lui qui donne
le chemin `/data/vmail/ldap/<entryuuid>`.

Après avoir ajouté quelqu'un, lui envoyer un lien de création d'identifiants :

```sh
kanidm person credential create-reset-token <identifiant> --name idm_admin
```

## Bureau à distance (RDP) sur lbv

Le service et le port 3389 sont déclarés dans `machines/lbv/configuration.nix`,
mais le certificat TLS et les identifiants RDP sont des secrets : ils se
configurent une seule fois, à la main, et sont stockés dans
`/var/lib/gnome-remote-desktop`.

```sh
ssh root@lbv.libr.fr
cd /var/lib/gnome-remote-desktop
sudo -u gnome-remote-desktop openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=lbv.libr.fr" -keyout rdp-tls.key -out rdp-tls.crt
grdctl --system rdp set-tls-key  /var/lib/gnome-remote-desktop/rdp-tls.key
grdctl --system rdp set-tls-cert /var/lib/gnome-remote-desktop/rdp-tls.crt
grdctl --system rdp set-credentials   # demande l'utilisateur et le mot de passe RDP
grdctl --system rdp enable
systemctl restart gnome-remote-desktop
grdctl --system status
```

Ces identifiants ne servent qu'à ouvrir la connexion RDP ; on arrive ensuite
sur l'écran de connexion GDM, où l'on se connecte avec son compte Linux
dans une nouvelle session, sans avoir à se déconnecter localement.

Client : Remmina ou GNOME Connexions sous Linux, « Connexion Bureau à
distance » sous Windows, adresse locale de lbv : `192.168.1.22:3389`.
Ne pas utiliser `lbv.libr.fr` : il pointe vers une adresse IPv6 publique, que
le pare-feu refuse même depuis le réseau local. L'adresse locale est
attribuée par DHCP ; si elle change, la retrouver avec `ip -4 -br addr` sur lbv.

Le port 3389 n'est ouvert qu'au réseau local (plages privées IPv4, IPv6
link-local et ULA). Depuis l'extérieur, passer par un tunnel SSH —
`ssh -L 3389:localhost:3389 root@lbv.libr.fr` — puis se connecter à
`localhost:3389`.

[kp]: https://github.com/oddlama/kanidm-provision#json-schema
