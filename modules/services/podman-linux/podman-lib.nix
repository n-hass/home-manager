{ lib, ... }:

with lib;

let
  primitive = with types; nullOr (oneOf [ bool int str path ]);
  primitiveAttrs = with types; attrsOf (either primitive (listOf primitive));

  formatPrimitiveValue = value:
    if isBool value then
      (if value then "true" else "false")
    else if isList value then
      concatStringsSep " " (map toString value)
    else
      toString value;
in {
  inherit primitive;
  inherit primitiveAttrs;
  inherit formatPrimitiveValue;

  buildConfigAsserts = quadletName: config: configTypeRules:
    flatten (mapAttrsToList (name: value:
      if hasAttr name configTypeRules then [{
        assertion = configTypeRules.${name}.check value;
        message = "in '${quadletName}' config. ${name}: '${
            toString value
          }' does not match expected type: ${
            configTypeRules.${name}.description
          }";
      }] else
        [ ]) config);

  formatAutoUpdate = autoupdate:
    if (builtins.elem autoupdate [ "registry" "local" ]) then
      "AutoUpdate=${autoupdate}"
    else
      "";

  formatExtraConfig = extraConfig: type:
    let
      handledNames = if type == "Container" then [
        "AddCapability"
        "AutoUpdate"
        "ContainerName"
        "Device"
        "DropCapability"
        "EntryPoint"
        "Environment"
        "EnvironmentFile"
        "Exec"
        "Image"
        "Label"
        "Network"
        "NetworkAlias"
        "PublishPort"
        "Volume"
      ] else if type == "Unit" then
        [ "Description" ]
      else
        [ ];
      nonNullConfig = filterAttrs
        (name: value: value != null && (!builtins.elem name handledNames))
        extraConfig;
    in concatStringsSep "\n"
    (mapAttrsToList (name: value: "${name}=${formatPrimitiveValue value}")
      nonNullConfig);

  formatExtraContainerConfig = extraConfig:
    let nonNullConfig = filterAttrs (name: value: value != null) extraConfig;
    in concatStringsSep "\n"
    (mapAttrsToList (name: value: "${name}=${formatPrimitiveValue value}")
      nonNullConfig);

  formatLabels = labels:
    let allLabels = { "nix.home-manager.managed" = true; } // labels;
    in formatSetSpaces allLabels "Label";

  formatListSpaces = list: header:
    if list != [ ] then "${header}=" + (concatStringsSep " " list) else "";

  formatListNewlines = list: header:
    if list != [ ] then
      concatStringsSep "\n" (map (item: "${header}=${item}") list)
    else
      "";

  formatNetworks = containerDef:
    let
      nets = containerDef.networks
        ++ (if (builtins.hasAttr "Network" containerDef.extraContainerConfig
          && builtins.isList containerDef.extraContainerConfig.Network) then
          containerDef.extraContainerConfig.Network
        else
          [ ]);
    in if (builtins.elem containerDef.networkMode [ "host" ]) then
      "Network=${containerDef.networkMode}"
    else if nets != [ ] then
      "Network=" + (concatStringsSep " " nets)
    else
      "";

  formatSetSpaces = set: header:
    if set != { } then
      "${header}=" + (concatStringsSep " "
        (mapAttrsToList (k: v: "${k}=${formatPrimitiveValue v}") set))
    else
      "";

  formatNetworkDependencies = networks:
    let formatElement = network: "podman-${network}-network.service";
    in concatStringsSep " " (map formatElement networks);

  formatPodmanArgs = containerDef:
    let
      podmanArgs =
        (concatStringsSep "--network-alias" containerDef.networkAliases)
        + (if (containerDef.entrypoint != null) then
          "--entrypoint ${containerDef.entrypoint}"
        else
          "") + (concatStringsSep " " containerDef.extraPodmanArgs);
    in if builtins.stringLength podmanArgs > 0 then
      "PodmanArgs=" + podmanArgs
    else
      "";

  # input expects a list of quadletInternalType with all the same resourceType
  generateManifestText = quadlets:
    let
      # create a list of all unique quadlet.resourceType in quadlets
      quadletTypes = unique (map (quadlet: quadlet.resourceType) quadlets);
      # if quadletTypes is > 1, then all quadlets are not the same type
      allQuadletsSameType = length quadletTypes <= 1;

      # ensures the service name is formatted correctly to be easily read
      #   by the activation script and matches `podman <resource> ls` output
      formatServiceName = quadlet:
        let
          # remove the podman- prefix from the service name string
          strippedName =
            builtins.replaceStrings [ "podman-" ] [ "" ] quadlet.serviceName;
          # specific logic for writing the unit name goes here. It should be
          #   identical to what `podman <resource> ls` shows
        in {
          "container" = strippedName;
          "network" = strippedName;
        }."${quadlet.resourceType}";
    in if allQuadletsSameType then ''
      ${concatStringsSep "\n"
      (map (quadlet: formatServiceName quadlet) quadlets)}
    '' else
      abort ''
        All quadlets must be of the same type.
        Quadlet types in this manifest: ${concatStringsSep ", " quadletTypes}'';

  installConfigDefaults = { WantedBy = null; };
  installConfigType = with types; attrsOf (either primitive (listOf primitive));
  installConfigTypeRules = { WantedBy = with types; nullOr (listOf str); };

  # podman requires setuid on newuidmad, so it cannot be provided by pkgs.shadow
  # Including all possible locations in PATH for newuidmap is a workaround.
  # NixOS provides a 'wrapped' variant at /run/wrappers/bin/newuidmap.
  # Other distros use the 'uidmap' package, ie for ubuntu: apt install uidmap.
  # Extra paths are added to handle distro package manager binary locations
  #
  # Tracking for a potential solution:
  #   https://github.com/NixOS/nixpkgs/issues/138423
  newuidmapPaths = "/run/wrappers/bin:/usr/bin:/bin:/usr/sbin:/sbin";

  removeBlankLines = text:
    let
      lines = splitString "\n" text;
      nonEmptyLines = filter (line: line != "") lines;
    in concatStringsSep "\n" nonEmptyLines;

  serviceConfigDefaults = {
    Restart = "always";
    TimeoutStopSec = 30;
    ExecStartPre = null;
  };
  serviceConfigType = with types; attrsOf (either primitive (listOf primitive));
  serviceConfigTypeRules = {
    Restart = types.enum [ "no" "always" "on-failure" "unless-stopped" ];
    TimeoutStopSec = types.int;
  };

  sourceHelpers = {
    ifAttrList = set: attr:
      if (builtins.hasAttr attr set && builtins.isList set.${attr}) then
        set.${attr}
      else
        [ ];
    ifAttrSet = set: attr:
      if (builtins.hasAttr attr set && builtins.isAttrs set.${attr}) then
        set.${attr}
      else
        { };
    ifAttrString = set: attr:
      if (builtins.hasAttr attr set && builtins.isString set.${attr}) then
        set.${attr}
      else
        "";
    ifNotEmptyList = list: text: if list != [ ] then text else "";
    ifNotEmptySet = set: text: if set != { } then text else "";
    ifNotNull = condition: text: if condition != null then text else "";
  };

  unitConfigDefaults = { After = null; };
  unitConfigType = with types; attrsOf (either primitive (listOf primitive));
  unitConfigTypeRules = { After = with types; nullOr (listOf str); };
}
