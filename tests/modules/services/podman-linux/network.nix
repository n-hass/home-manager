{ ... }:

{
  config = {
    services.podman.networks."my-net" = {
      subnet = "192.168.1.0/24";
      gateway = "192.168.1.1";
      extraConfig = {
        Network = {
          Options = {
            isolate = "true";
          };
          PodmanArgs = [ "--dns=192.168.55.1" "--log-level=debug" ];
        };
      };
    };

    nmt.script = ''
      configPath=home-files/.config/systemd/user
      networkFile=$configPath/podman-my-net-network.service
      assertFileExists $networkFile

      assertFileContains $networkFile \
        "my-net.network"
      assertFileContains $networkFile \
        "Subnet=192.168.1.0/24"
      assertFileContains $networkFile \
        "Gateway=192.168.1.1"
      assertFileContains $networkFile \
        "PodmanArgs=--dns=192.168.55.1"
      assertFileContains $networkFile \
        "PodmanArgs=--log-level=debug"
      assertFileContains $networkFile \
        "Options=isolate=true"
      assertFileContains $networkFile \
        "NetworkName=my-net"
      assertFileContains $networkFile \
        "WantedBy=multi-user.target"
      assertFileContains $networkFile \
        "WantedBy=default.target"
      assertFileContains $networkFile \
        "RemainAfterExit=yes"
      assertFileContains $networkFile \
        "Label=nix.home-manager.managed=true"
    '';
  };
}
