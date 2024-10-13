{ config, lib, pkgs, ... }:

with lib;

let
  podman-lib = import ./podman-lib.nix { inherit lib; };

  quadletActivationCleanupScript = ''
    PATH=$PATH:${podman-lib.newuidmapPaths}

    DRYRUN_ENABLED() {
      return $([ -n "''${DRY_RUN:-}" ] && echo 0 || echo 1)
    }

    VERBOSE_ENABLED() {
      return $([ -n "''${VERBOSE:-}" ] && echo 0 || echo 1)
    }

    cleanup() {
      local resourceType=''${1}
      local manifestFile="${config.xdg.configHome}/podman/''${2}"
      local extraListCommands="''${3:-}"
      [[ ''${resourceType} = "container" ]] && extraListCommands+=" -a"

      [ ! -f "''${manifestFile}" ] && VERBOSE_ENABLED && echo "Manifest does not exist: ''${manifestFile}" && return 0

      VERBOSE_ENABLED && echo "Cleaning up ''${resourceType}s not in manifest..." || true

      loadManifest "''${manifestFile}"

      formatString="{{.Name}}"
      [[ ''${resourceType} = "container" ]] && formatString="{{.Names}}"

      # Capture the output of the podman command to a variable
      local listOutput=$(${config.services.podman.package}/bin/podman ''${resourceType} ls ''${extraListCommands} --filter 'label=nix.home-manager.managed=true' --format "''${formatString}")

      IFS=$'\n' read -r -d "" -a podmanResources <<< "''${listOutput}" || true

      # Check if the array is populated and iterate over it
      if [ ''${#podmanResources[@]} -eq 0 ]; then
        VERBOSE_ENABLED && echo "No ''${resourceType}s available to process." || true
      else
        for resource in "''${podmanResources[@]}"; do
            if ! isResourceInManifest "''${resource}"; then
              removeResource "''${resourceType}" "''${resource}"
            else
              VERBOSE_ENABLED && echo "Keeping managed ''${resourceType}: ''${resource}" || true
            fi
          done
      fi
    }

    isResourceInManifest() {
      local resource="''${1}"
      for manifestEntry in "''${resourceManifest[@]}"; do
        if [ "''${resource}" = "''${manifestEntry}" ]; then
          return 0  # Resource found in manifest
        fi
      done
      return 1  # Resource not found in manifest
    }

    # Function to fill resourceManifest from the manifest file
    loadManifest() {
      local manifestFile="''${1}"
      VERBOSE_ENABLED && echo "Loading manifest from ''${manifestFile}..." || true
      IFS=$'\n' read -r -d "" -a resourceManifest <<< "$(cat "''${manifestFile}")" || true
    }

    removeResource() {
      local resourceType="''${1}"
      local resource="''${2}"
      echo "Removing orphaned ''${resourceType}: ''${resource}"
      commands=()
      case "''${resourceType}" in
        "container")
          commands+="${config.services.podman.package}/bin/podman ''${resourceType} stop ''${resource}"
          commands+="${config.services.podman.package}/bin/podman ''${resourceType} rm -f ''${resource}"
          ;;
        "network")
          commands+="${config.services.podman.package}/bin/podman ''${resourceType} rm ''${resource}"
          ;;
      esac
      for command in "''${commands[@]}"; do
        command=$(echo ''${command} | tr -d ';&|`')
        DRYRUN_ENABLED && echo "Would run: ''${command}" && continue || true
        VERBOSE_ENABLED && echo "Running: ''${command}" || true
        if [[ "$(eval "''${command}")" != "''${resource}" ]]; then
          echo -e "\tCommand failed: ''${command}"
          usedByContainers=$(/nix/store/3xcbk8rnhi1710l8xnayz3y54z5323a2-podman-5.2.3/bin/podman container ls -a --filter "''${resourceType}=''${resource}" --format "{{.Names}}")
          echo -e "\t''${resource} in use by containers: ''${usedByContainers}"
        fi
      done
    }

    resourceManifest=()
    [[ "$@" == *"--verbose"* ]] && VERBOSE="true"
    [[ "$@" == *"--dry-run"* ]] && DRY_RUN="true"

    for type in "container" "network"; do
      cleanup "''${type}" "''${type}s.manifest"
    done
  '';

  # derivation to build a single Podman quadlet, outputting its systemd unit files
  buildPodmanQuadlet = quadlet:
    pkgs.stdenv.mkDerivation {
      name = "home-${quadlet.resourceType}-${quadlet.serviceName}";

      buildInputs = [ config.services.podman.package ];

      dontUnpack = true;

      buildPhase = ''
        mkdir $out
        # Directory for the quadlet file
        mkdir -p $out/quadlets
        # Directory for systemd unit files
        mkdir -p $out/units

        # Write the quadlet file
        echo -n "${quadlet.source}" > $out/quadlets/${quadlet.serviceName}.${quadlet.resourceType}

        # Generate systemd unit file/s from the quadlet file
        export QUADLET_UNIT_DIRS=$out/quadlets
        ${config.services.podman.package}/lib/systemd/user-generators/podman-user-generator $out/units
      '';

      passthru = {
        outPath = self.out;
        quadletData = quadlet;
      };
    };

  # Create a derivation for each quadlet spec
  builtQuadlets =
    map buildPodmanQuadlet config.internal.podman-quadlet-definitions;

  accumulateUnitFiles = prefix: path: quadlet:
    let
      entries = builtins.readDir path;
      processEntry = name: type:
        let
          newPath = "${path}/${name}";
          newPrefix = prefix + (if prefix == "" then "" else "/") + name;
        in if type == "directory" then
          accumulateUnitFiles newPrefix newPath quadlet
        else [{
          key = newPrefix;
          value = {
            path = newPath;
            parentQuadlet = quadlet;
          };
        }];
    in flatten
    (map (name: processEntry name (getAttr name entries)) (attrNames entries));

  allUnitFiles = concatMap (builtQuadlet:
    accumulateUnitFiles "" "${builtQuadlet.outPath}/units"
    builtQuadlet.quadletData) builtQuadlets;

  # we're doing this because the home-manager recursive file linking implementation can't
  # merge from multiple sources. so we link each file explicitly, which is fine for all unique files
  generateSystemdFileLinks = files:
    listToAttrs (map (unitFile: {
      name = "${config.xdg.configHome}/systemd/user/${unitFile.key}";
      value = { source = unitFile.value.path; };
    }) files);

in {
  imports = [ ./options.nix ];

  config = mkIf pkgs.stdenv.isLinux {
    home.file = generateSystemdFileLinks allUnitFiles;

    # if the length of builtQuadlets is 0, then we don't need register the activation script
    home.activation.podmanQuadletCleanup =
      lib.mkIf (lib.length builtQuadlets >= 1)
      (lib.hm.dag.entryAfter [ "reloadSystemd" ]
        quadletActivationCleanupScript);
  };
}
