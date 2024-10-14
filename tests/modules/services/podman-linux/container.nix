{ ... }:

{
  config = {
    services.podman.containers."my-container" = {
      description = "home-manager test";
      autoStart = true;
      autoUpdate = "registry";
      devices = [ "/dev/null:/dev/null" ];
      entrypoint = "/sleep.sh";
      environment = {
        "VAL_A" = "A";
        "VAL_B" = 2;
        "VAL_C" = false;
      };
      extraPodmanArgs = [ "--security-opt=no-new-privileges" ];
      extraConfig = {
        Container = {
          ReadOnlyTmpfs = true;
        };
        Service.Restart = "on-failure";
        Unit.Before = "fake.target";
      };
      image = "docker.io/alpine:latest";
      networks = [ "mynet" ];
      networkAliases = [ "test-alias" ];
      ports = [ "8080:80" ];
      volumes = [ "/tmp:/tmp" ];
    };

    nmt.script = ''
      configPath=home-files/.config/systemd/user
      containerFile=$configPath/podman-my-container.service
      assertFileExists $containerFile

      assertFileContains $containerFile \
        "my-container.container"
      assertFileContains $containerFile \
        "Description=home-manager test"
      assertFileContains $containerFile \
        "AutoUpdate=registry"
      assertFileContains $containerFile \
        "Image=docker.io/alpine:latest"
      assertFileContains $containerFile \
        "PodmanArgs=--security-opt=no-new-privileges"
      assertFileContains $containerFile \
        "PodmanArgs=--network-alias test-alias"
      assertFileContains $containerFile \
        "PodmanArgs=--entrypoint /sleep.sh"
      assertFileContains $containerFile \
        "Environment=VAL_A=A"
      assertFileContains $containerFile \
        "Environment=VAL_B=2"
      assertFileContains $containerFile \
        "Environment=VAL_C=false"
      assertFileContains $containerFile \
        "PublishPort=8080:80"
      assertFileContains $containerFile \
        "Volume=/tmp:/tmp"
      assertFileContains $containerFile \
        "AddDevice=/dev/null:/dev/null"
      assertFileContains $containerFile \
        "Network=mynet"
      assertFileContains $containerFile \
        "Requires=podman-mynet-network.service"
      assertFileContains $containerFile \
        "After=network.target"
      assertFileContains $containerFile \
        "After=podman-mynet-network.service"
      assertFileContains $containerFile \
        "ReadOnlyTmpfs=true"
      assertFileContains $containerFile \
        "Restart=on-failure"
      assertFileContains $containerFile \
        "Before=fake.target"
      assertFileContains $containerFile \
        "WantedBy=multi-user.target"
      assertFileContains $containerFile \
        "WantedBy=default.target"
      assertFileContains $containerFile \
        "Label=nix.home-manager.managed=true"
    '';
  };
}
