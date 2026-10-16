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

Après avoir ajouté quelqu'un, lui envoyer un lien de création d'identifiants :

```sh
kanidm person credential create-reset-token <identifiant> --name idm_admin
```

[kp]: https://github.com/oddlama/kanidm-provision#json-schema
