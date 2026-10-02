{
  lib,
  rustPlatform,
  coreutils,
  gnupg,
  openssh,
}:
rustPlatform.buildRustPackage {
  pname = "tmux-daemons";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  env = {
    GPG_CONNECT_AGENT = lib.getExe' gnupg "gpg-connect-agent";
    SSH_ADD = lib.getExe' openssh "ssh-add";
    STTY = lib.getExe' coreutils "stty";
    KILL = lib.getExe' coreutils "kill";
  };

  meta.mainProgram = "tmux-daemons";
}
