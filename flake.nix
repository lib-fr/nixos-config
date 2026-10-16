{
  description = "NixOS machines configuration for libr.fr";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  inputs.deploy-rs = {
    url = "github:serokell/deploy-rs";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.simple-nixos-mailserver = {
    url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-26.05";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.my_dotfiles = {
    url = "github:mickours/dotfiles";
    flake = false;
  };

  # For dev
  # inputs.leProjetDeVieInput.url = "git+file:///home/mickours/Projects/le-projet-de-vie-libr";
  inputs.leProjetDeVieInput.url = "github:mickours/le-projet-de-vie-web-site";

  inputs.bgremove.url = "github:RustyShare/bgremove/main";

  # Répartition des élèves en classes (dépôt local, pas encore poussé)
  inputs.repartition-classes = {
    url = "github:lib-fr/repartition_classes";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      simple-nixos-mailserver,
      deploy-rs,
      my_dotfiles,
      leProjetDeVieInput,
      bgremove,
      repartition-classes,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      leProjetDeVie = leProjetDeVieInput.packages."${system}";
    in
    {
      nixosConfigurations = {
        vps = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs leProjetDeVie; };

          modules = [
            ./machines/vps/configuration.nix
            simple-nixos-mailserver.nixosModules.mailserver
            leProjetDeVieInput.nixosModules.default
            bgremove.nixosModules.default
            repartition-classes.nixosModules.default
          ];
        };
        lbv = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./machines/lbv/configuration.nix
          ];
        };
      };

      deploy.nodes.vps.hostname = "vps";
      deploy.nodes.vps.profiles.system = {
        user = "root";
        sshUser = "root";
        path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.vps;
        # autoRollback = false;
      };
      deploy.nodes.lbv.hostname = "lbv";
      deploy.nodes.lbv.profiles.system = {
        user = "root";
        sshUser = "root";
        path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.lbv;
        # autoRollback = false;
      };

      # Exposed so the app can be built and its hashes refreshed on its own,
      # without going through a full nixos-rebuild:
      #   nix build .#nextcloud-app-facerecognition -L
      packages.x86_64-linux.nextcloud-app-facerecognition =
        (import nixpkgs { inherit system; }).callPackage ./pkgs/nextcloud-app-facerecognition
          { };

      # This is highly advised, and will prevent many possible mistakes
      checks =
        builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib
        // {
          x86_64-linux = (deploy-rs.lib.x86_64-linux.deployChecks self.deploy) // {
            # Asserts lib/kanidm-ldap.nix against a real Kanidm over LDAPS: the
            # DN format and attribute names there cannot be checked by building
            # the configuration, and getting them wrong breaks mail.
            #   nix build .#checks.x86_64-linux.kanidm-ldap -L
            kanidm-ldap = (import nixpkgs { inherit system; }).testers.runNixOSTest ./tests/kanidm-ldap.nix;
          };
        };
      # Enable autoformat
      formatter.x86_64-linux = (import nixpkgs { system = "x86_64-linux"; }).pkgs.nixfmt-tree;
    };
}
