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
      selected="''${2:-}"

      idle="#2f3340"
      if [ "$selected" = "current" ]; then
        idle="#a6e22e"
      fi

      if [ -z "$tty_path" ] || [ "$tty_path" = "not a tty" ]; then
        printf '#[fg=%s]●' "$idle"
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
        printf '#[fg=%s]●' "$idle"
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

      printf '#[fg=%s]●' "$color"
    '';
  };

  gitStatus = pkgs.writeShellApplication {
    name = "tmux-git-status";
    runtimeInputs = with pkgs; [
      git
      gawk
    ];
    text = ''
      set -euo pipefail

      cd "''${1:-.}" 2>/dev/null || exit 0
      out="$(git status --porcelain=v2 --branch 2>/dev/null)" || exit 0

      printf '%s\n' "$out" | awk '
        /^# branch.oid / { oid = substr($3, 1, 7) }
        /^# branch.head / { head = $3 }
        /^# branch.ab / { ahead = $3 != "+0"; behind = $4 != "-0" }
        /^u / { conflict = 1 }
        /^\? / { dirty = 1 }
        /^[12] / {
          if (substr($2, 1, 1) != ".") staged = 1
          if (substr($2, 2, 1) != ".") dirty = 1
        }
        END {
          if (head == "(detached)") head = oid
          if (length(head) > 20) head = substr(head, 1, 19) "…"

          color = "#a6e22e"
          if (staged) color = "#7dcfff"
          if (dirty) color = "#e0af68"
          if (conflict) color = "#f7768e"

          printf "#[fg=%s]%s", color, head
          if (ahead) printf "#[fg=#7aa2f7]↑"
          if (behind) printf "#[fg=#bb9af7]↓"
        }
      '
    '';
  };
}
