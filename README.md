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
chown kanidm:kanidm /data/keys/kanidm-persons.json
chmod 400 /data/keys/kanidm-persons.json
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

[kp]: https://github.com/oddlama/kanidm-provision#json-schema
