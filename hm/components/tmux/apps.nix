{pkgs, ...}: {
  paneBreathStatus = pkgs.writeShellApplication {
    name = "tmux-pane-breath-status";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      procps
    ];
    text = ''
      set -euo pipefail

      tty_path="''${1:-}"
      label="''${2:-}"
      selected="''${3:-0}"

      if [ -z "$tty_path" ] || [ "$tty_path" = "not a tty" ]; then
        printf '%s' "$label"
        exit 0
      fi

      tty="''${tty_path#/dev/}"

      elapsed="$(
        ps -t "$tty" -o pid=,ppid=,stat=,etimes=,comm= 2>/dev/null |
          awk '
            BEGIN { max = 0 }
            {
              comm = $5
              etime = $4

              if (comm ~ /^(zsh|bash|fish|sh|nu)$/) next
              if (comm ~ /^(tmux|ps|awk|cat|sed|grep)$/) next
              if (comm ~ /^tmux-pane-breath-status$/) next

              if (etime > max) max = etime
            }
            END { print max }
          '
      )"

      if [ -z "$elapsed" ] || [ "$elapsed" -lt 1 ]; then
        if [ "$selected" = "current" ]; then
          printf '#[fg=#c0caf5,bold]%s#[default]' "$label"
        else
          printf '#[fg=#a9b1d6]%s#[default]' "$label"
        fi
        exit 0
      fi

      phase="$(( $(date +%s) % 2 ))"

      if [ "$elapsed" -lt 60 ]; then
        color_a="#e0af68"
        color_b="#f6c177"
      elif [ "$elapsed" -lt 300 ]; then
        color_a="#ff9e64"
        color_b="#e0af68"
      else
        color_a="#f7768e"
        color_b="#ff5c8a"
      fi

      color="$color_a"
      if [ "$phase" -eq 1 ]; then
        color="$color_b"
      fi

      minutes="$(( elapsed / 60 ))"
      seconds="$(( elapsed % 60 ))"

      if [ "$minutes" -gt 0 ]; then
        runtime="''${minutes}m"
      else
        runtime="''${seconds}s"
      fi

      printf '#[fg=%s,bold]%s %s#[default]' "$color" "$label" "$runtime"
    '';
  };

  lsyncdStatus = pkgs.writeShellApplication {
    name = "tmux-lsyncd-status";
    runtimeInputs = with pkgs; [
      tmux
      gnugrep
    ];
    text = ''
      set -euo pipefail

      if [ "''${TMUX_HIDE_LSYNCD:-0}" = 1 ]; then
        exit 0
      fi

      status_file="$(tmux show-option -gqv @lsyncd_status_file)"
      status_file="''${status_file:-/tmp/lsyncd.status}"

      if ! pgrep -x lsyncd >/dev/null 2>&1; then
        printf 'LSYNCD=0'
        exit 0
      fi

      if [ ! -f "$status_file" ]; then
        printf 'LSYNCD=0'
        exit 0
      fi

      content="$(cat "$status_file" 2>/dev/null || true)"

      if printf '%s\n' "$content" | grep -qi 'error'; then
        printf 'LSYNCD=E'
      else
        printf 'LSYNCD=1'
      fi
    '';
  };

  gpgAgentStatus = pkgs.writeShellApplication {
    name = "tmux-gpg-agent-status";
    runtimeInputs = with pkgs; [
      gnupg
      gawk
    ];
    text = ''
      set -euo pipefail

      if [ "''${TMUX_HIDE_GPG_AGENT:-0}" = 1 ]; then
        exit 0
      fi

      keyinfo_out="$(
        gpg-connect-agent 'keyinfo --list' /bye 2>/dev/null || true
      )"

      if printf '%s\n' "$keyinfo_out" |
        awk '/^S KEYINFO / && $7 == "1" { found = 1 } END { exit(found ? 0 : 1) }'; then
        printf 'GPG=1'
      else
        printf 'GPG=0'
      fi
    '';
  };

  sshAgentStatus = pkgs.writeShellApplication {
    name = "tmux-ssh-agent-status";
    runtimeInputs = with pkgs; [
      openssh
    ];
    text = ''
      set -euo pipefail

      if [ "''${TMUX_HIDE_SSH_AGENT:-0}" = 1 ]; then
        exit 0
      fi

      sock="''${SSH_AUTH_SOCK:-}"
      if [ -z "$sock" ] || [ ! -S "$sock" ]; then
        printf 'SSH=0'
        exit 0
      fi

      if ssh-add -l >/dev/null 2>&1; then
        printf 'SSH=1'
      else
        printf 'SSH=0'
      fi
    '';
  };
}
