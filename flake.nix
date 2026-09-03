{
  description = "forum — the FastTrackStudio community forum (Discourse)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # CI passes the tag/rev through the environment rather than as flake
        # args, so the workflow stays a plain `nix build --impure .#image`.
        # A bare `nix build .#image` gets the defaults. Same shape as
        # fts-auth.
        env =
          name: default:
          let
            v = builtins.getEnv name;
          in
          if v == "" then default else v;

        # Stock nixpkgs Discourse — no plugin override.
        #
        # Everything this deployment needs now ships IN CORE:
        # discourse-oauth2-basic (the fts-auth sign-in path), plus solved,
        # math, chat, reactions, calendar and ~40 more under `plugins/` in
        # the Discourse source. They arrive disabled and are turned on with
        # a site setting, not a rebuild. This is why nixpkgs' own
        # `discourse.plugins` set shrank to seven odds and ends — do not
        # reach for it expecting to find oauth2-basic there.
        #
        # If a THIRD-PARTY plugin is ever needed, it becomes an override
        # here with `mkDiscoursePlugin`, and it is part of the image rather
        # than runtime config: Discourse precompiles assets per plugin set,
        # so adding one is a rebuild.
        discourse = pkgs.discourse;
      in
      {
        packages = {
          inherit discourse;
          default = discourse;
          image = import ./nix/image.nix {
            inherit pkgs discourse;
            tag = env "FTS_TAG" "latest";
            rev = env "FTS_REV" "dev";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.skopeo
            pkgs.kubernetes-helm
            pkgs.postgresql
          ];
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
