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

  outputs =
    {
      self,
      nixpkgs,
      simple-nixos-mailserver,
      deploy-rs,
      my_dotfiles,
      leProjetDeVieInput,
      bgremove,
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
            ./vps.nix
            simple-nixos-mailserver.nixosModules.mailserver
            leProjetDeVieInput.nixosModules.default
            bgremove.nixosModules.default
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

      # This is highly advised, and will prevent many possible mistakes
      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
      # Enable autoformat
      formatter.x86_64-linux = (import nixpkgs { system = "x86_64-linux"; }).pkgs.nixfmt-tree;
    };
}
