{ config, lib, pkgs, ... }:

with lib;

let
  podman-lib = import ./podman-lib.nix { inherit lib; };

  createQuadletSource = name: networkDef: ''
    # Automatically generated by home-manager for podman network configuration
    # DO NOT EDIT THIS FILE DIRECTLY
    #
    # ${name}.network
    [Network]
    Label=nix.home-manager.managed=true
    NetworkName=${name}
    ${podman-lib.formatExtraConfig networkDef}

    [Install]
    WantedBy=multi-user.target default.target

    [Service]
    Environment="PATH=${pkgs.su}:${pkgs.shadow}:${pkgs.coreutils}"
    RemainAfterExit=yes
  '';

  networkConfigAssertions = name: networkDef: {
    NetworkName = with types; enum [ "" name ];
  };

  toQuadletInternal = name: networkDef: {
    serviceName =
      "podman-${name}"; # becomes podman-<netname>-network.service because of quadlet
    source = createQuadletSource name networkDef;
    resourceType = "network";
    assertions = podman-lib.buildConfigAsserts name networkDef
      (networkConfigAssertions name networkDef);
  };

in {
  options = {
    services.podman.networks = mkOption {
      type = types.attrsOf (podman-lib.primitiveAttrs);
      default = { };
      example = literalMD ''
        ```
        {
          mynetwork = {
            Subnet = "192.168.1.0/24";
            Gateway = "192.168.1.1";
          };
        }
        ```
      '';
      description = "Defines Podman network quadlet configurations.";
    };
  };

  config = let
    networkQuadlets =
      mapAttrsToList toQuadletInternal config.services.podman.networks;
  in {
    internal.podman-quadlet-definitions = networkQuadlets;
    assertions = flatten (map (network: network.assertions) networkQuadlets);

    # manifest file
    home.file."${config.xdg.configHome}/podman/networks.manifest".text =
      podman-lib.generateManifestText networkQuadlets;
  };
}
