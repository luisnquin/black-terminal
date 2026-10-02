mod registry;

use registry::{Entry, Process, Status};
use std::{
    env,
    io::{Read, Write},
    process::{Command, ExitCode, Stdio},
    sync::mpsc,
    thread,
    time::Duration,
};

const GREEN: &str = "#a6e22e";
const GREY: &str = "#4b5263";
const RED: &str = "#f7768e";
const TEAL: &str = "#73daca";
const BG: &str = "#16181f";
const FG: &str = "#c0caf5";
const SELECTED: &str = "#232838";

const GPG_CONNECT_AGENT: &str = match option_env!("GPG_CONNECT_AGENT") {
    Some(p) => p,
    None => "gpg-connect-agent",
};
const SSH_ADD: &str = match option_env!("SSH_ADD") {
    Some(p) => p,
    None => "ssh-add",
};
const STTY: &str = match option_env!("STTY") {
    Some(p) => p,
    None => "stty",
};

#[derive(PartialEq)]
enum Daemon {
    Gpg,
    Ssh,
    Lsyncd,
}

enum Gpg {
    Unlocked,
    Locked,
    Down,
}

enum Ssh {
    Keys(usize),
    Empty,
    Down,
}

fn daemons(args: &[String]) -> Vec<Daemon> {
    let hide_lsyncd = env::var("TMUX_HIDE_LSYNCD").is_ok_and(|v| v == "1");
    args.iter()
        .filter_map(|a| match a.as_str() {
            "gpg" => Some(Daemon::Gpg),
            "ssh" => Some(Daemon::Ssh),
            "lsyncd" if !hide_lsyncd => Some(Daemon::Lsyncd),
            _ => None,
        })
        .collect()
}

fn gpg() -> Gpg {
    let Ok(out) = Command::new(GPG_CONNECT_AGENT)
        .args(["--no-autostart", "keyinfo --list", "/bye"])
        .stderr(Stdio::null())
        .output()
    else {
        return Gpg::Down;
    };

    let text = String::from_utf8_lossy(&out.stdout);
    if !text.lines().any(|l| l == "OK") {
        return Gpg::Down;
    }

    let cached = text
        .lines()
        .filter(|l| l.starts_with("S KEYINFO "))
        .any(|l| l.split_whitespace().nth(6) == Some("1"));

    if cached {
        Gpg::Unlocked
    } else {
        Gpg::Locked
    }
}

fn ssh() -> Ssh {
    if env::var_os("SSH_AUTH_SOCK").is_none() {
        return Ssh::Down;
    }

    let Ok(out) = Command::new(SSH_ADD)
        .arg("-l")
        .stderr(Stdio::null())
        .output()
    else {
        return Ssh::Down;
    };

    match out.status.code() {
        Some(0) => Ssh::Keys(String::from_utf8_lossy(&out.stdout).lines().count()),
        Some(1) => Ssh::Empty,
        _ => Ssh::Down,
    }
}

fn lsyncd_color(entries: &[Entry], unmanaged: &[Process]) -> &'static str {
    let statuses: Vec<Status> = entries.iter().map(Entry::status).collect();
    if statuses.contains(&Status::Crashed) {
        RED
    } else if statuses.contains(&Status::Running) || !unmanaged.is_empty() {
        GREEN
    } else {
        GREY
    }
}

fn gpg_view() -> (&'static str, &'static str) {
    match gpg() {
        Gpg::Unlocked => (GREEN, "unlocked"),
        Gpg::Locked => (GREY, "locked"),
        Gpg::Down => (GREY, "no agent"),
    }
}

fn ssh_view() -> (&'static str, String) {
    match ssh() {
        Ssh::Keys(1) => (GREEN, "1 key".into()),
        Ssh::Keys(n) => (GREEN, format!("{n} keys")),
        Ssh::Empty => (GREY, "no keys".into()),
        Ssh::Down => (GREY, "no agent".into()),
    }
}

fn segment(args: &[String]) -> String {
    let dots: String = daemons(args)
        .iter()
        .map(|a| match a {
            Daemon::Gpg => gpg_view().0,
            Daemon::Ssh => ssh_view().0,
            Daemon::Lsyncd => {
                let entries = registry::all();
                lsyncd_color(&entries, &registry::unmanaged(&entries))
            }
        })
        .map(|c| format!("#[fg={c}]•"))
        .collect();

    if dots.is_empty() {
        return dots;
    }
    format!("#[range=user|daemons]{dots}#[norange]")
}

fn home() -> String {
    env::var("HOME")
        .unwrap_or_default()
        .trim_end_matches('/')
        .to_string()
}

fn client_size(client: &str, what: &str, fallback: usize) -> usize {
    Command::new("tmux")
        .args([
            "display-message",
            "-p",
            "-c",
            client,
            &format!("#{{client_{what}}}"),
        ])
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
        .unwrap_or(fallback)
}

fn client_width(client: &str) -> usize {
    client_size(client, "width", 80)
}

fn fit(s: &str, budget: usize) -> String {
    if s.len() <= budget {
        return s.into();
    }
    let mut used = '…'.len_utf8();
    let mut tail: Vec<char> = Vec::new();
    for c in s.chars().rev() {
        if used + c.len_utf8() > budget {
            break;
        }
        used += c.len_utf8();
        tail.push(c);
    }
    std::iter::once('…').chain(tail.into_iter().rev()).collect()
}

fn short_path(path: &str, home: &str) -> String {
    let p = path.trim_end_matches('/');
    match p.strip_prefix(home) {
        Some(rest) if !home.is_empty() && (rest.is_empty() || rest.starts_with('/')) => {
            format!("~{rest}")
        }
        _ => p.to_string(),
    }
}

fn short_target(target: &str, home: &str) -> String {
    match target.split_once(':') {
        Some((host, dir)) if !host.contains('/') => format!("{host}:{}", short_path(dir, home)),
        _ => short_path(target, home),
    }
}

fn escape(s: &str) -> String {
    s.replace('#', "##")
}

fn status_color(s: Status) -> &'static str {
    match s {
        Status::Running => GREEN,
        Status::Stopped => GREY,
        Status::Crashed => RED,
    }
}

fn dot(color: &str, glyph: &str) -> String {
    format!("#[fg={color}]{glyph}#[default]  ")
}

fn row(color: &str, label: &str, detail: &str, budget: usize) -> String {
    let head = format!("{}{label:<8}#[dim]", dot(color, "●"));
    let detail = escape(detail);
    if head.len() + detail.len() > budget {
        return head;
    }
    format!("{head}{detail}")
}

fn pair(src: &str, dst: &str, budget: usize) -> String {
    let budget = budget.saturating_sub(" → ".len());
    let src_budget = if src.len() + dst.len() <= budget {
        src.len()
    } else {
        (budget / 2).max(budget.saturating_sub(dst.len()))
    };
    let src = fit(src, src_budget);
    let dst = fit(dst, budget.saturating_sub(src.len()));
    format!("{} → {}", escape(&src), escape(&dst))
}

struct Menu {
    width: usize,
    title: String,
    items: Vec<[String; 3]>,
}

// tmux trims menu items by the byte length of the expanded name, style
// directives included, so every budget below counts bytes, not cells.
impl Menu {
    fn new(client: &str, title: &str) -> Self {
        let width = client_width(client);
        Menu {
            title: format!(
                "#[fg={TEAL}] {} ",
                escape(&fit(title, width.saturating_sub(8)))
            ),
            width,
            items: Vec::new(),
        }
    }

    fn budget(&self, keyed: bool) -> usize {
        let max = self.width.saturating_sub(4);
        if keyed {
            max.saturating_sub(4)
        } else {
            max
        }
    }

    fn item(&mut self, name: String, key: &str, cmd: String) {
        self.items.push([name, key.into(), cmd]);
    }

    fn info(&mut self, name: String) {
        self.items
            .push([format!("-{name}"), String::new(), String::new()]);
    }

    fn rows(&mut self, rows: Vec<Row>) {
        let mut n = 0;
        for (name, cmd) in rows {
            let Some(cmd) = cmd else {
                self.info(name);
                continue;
            };
            n += 1;
            let key = if n <= 9 { n.to_string() } else { String::new() };
            self.item(name, &key, cmd);
        }
    }

    fn separator(&mut self) {
        self.items
            .push([String::new(), String::new(), String::new()]);
    }

    fn show(self, client: &str) -> Result<(), String> {
        let mut cmd = Command::new("tmux");
        cmd.args([
            "display-menu",
            "-M",
            "-c",
            client,
            "-x",
            "R",
            "-y",
            "S",
            "-b",
            "rounded",
        ])
        .args(["-s", &format!("bg={BG},fg={FG},bold")])
        .args(["-S", &format!("fg={TEAL}")])
        .args(["-H", &format!("bg={SELECTED},fg={FG},bold")])
        .args(["-T", &self.title])
        .arg("--");

        for [name, key, command] in &self.items {
            if name.is_empty() {
                cmd.arg("");
            } else {
                cmd.args([name, key, command]);
            }
        }

        run(&mut cmd)
    }
}

fn run(cmd: &mut Command) -> Result<(), String> {
    let out = cmd
        .stdin(Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if err.is_empty() {
            out.status.to_string()
        } else {
            err
        })
    }
}

fn exe() -> String {
    env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "tmux-daemons".into())
}

fn again(args: &str) -> String {
    format!("run -b \"{} {args}\"", exe())
}

fn menu(client: &str, args: &[String]) -> Result<(), String> {
    let mut m = Menu::new(client, "daemons");

    for daemon in daemons(args) {
        match daemon {
            Daemon::Gpg => {
                let (color, detail) = gpg_view();
                m.item(
                    row(color, "gnupg", detail, m.budget(true)),
                    "g",
                    String::new(),
                );
            }
            Daemon::Ssh => {
                let (color, detail) = ssh_view();
                m.item(
                    row(color, "ssh", &detail, m.budget(true)),
                    "s",
                    String::new(),
                );
            }
            Daemon::Lsyncd => {
                let entries = registry::all();
                let unmanaged = registry::unmanaged(&entries);
                let running = entries
                    .iter()
                    .filter(|e| e.status() == Status::Running)
                    .count()
                    + unmanaged.len();
                let detail = match entries.len() + unmanaged.len() {
                    0 => "none".into(),
                    n => format!("{running}/{n} on"),
                };
                m.item(
                    row(
                        lsyncd_color(&entries, &unmanaged),
                        "lsyncd",
                        &detail,
                        m.budget(true),
                    ),
                    "l",
                    again(&format!("lsyncd-menu {client} {}", args.join(" "))),
                );
            }
        }
    }

    m.show(client)
}

fn sync_text(syncs: &[(String, String)], fallback: &str, budget: usize, home: &str) -> String {
    let more = match syncs.len() {
        0 | 1 => String::new(),
        n => format!(" +{}", n - 1),
    };
    let budget = budget.saturating_sub(more.len());
    let text = match syncs.first() {
        Some((src, dst)) => pair(&short_path(src, home), &short_target(dst, home), budget),
        None => escape(&fit(&short_path(fallback, home), budget)),
    };
    format!("{text}{more}")
}

type Row = (String, Option<String>);

fn lsyncd_rows(m: &Menu, client: &str, args: &[String], patched: bool) -> Vec<Row> {
    let home = home();
    let entries = registry::all();
    let unmanaged = registry::unmanaged(&entries);

    let (active, stopped): (Vec<&Entry>, Vec<&Entry>) =
        entries.iter().partition(|e| e.status() != Status::Stopped);
    let mut rows: Vec<Row> = Vec::new();
    let managed = |e: &Entry, rows: &mut Vec<Row>| {
        let prefix = dot(status_color(e.status()), "●");
        let text = sync_text(
            &e.syncs,
            &e.key,
            m.budget(patched).saturating_sub(prefix.len() + 1),
            &home,
        );
        let cmd =
            patched.then(|| again(&format!("entry-menu {client} {} {}", e.key, args.join(" "))));
        rows.push((format!("{prefix}{text}"), cmd));
    };
    for e in active {
        managed(e, &mut rows);
    }
    for p in &unmanaged {
        let prefix = dot(GREEN, "●");
        let config = p.config.as_deref().unwrap_or("lsyncd");
        let text = sync_text(
            &p.syncs,
            config,
            m.budget(false).saturating_sub(prefix.len() + 1),
            &home,
        );
        rows.push((format!("{prefix}{text}"), None));
    }
    for e in stopped {
        managed(e, &mut rows);
    }
    rows
}

fn lsyncd_menu(client: &str, args: &[String]) -> Result<(), String> {
    let patched = registry::patched();
    let mut m = Menu::new(client, "lsyncd");
    let mut rows = lsyncd_rows(&m, client, args, patched);

    if rows.is_empty() {
        m.info(format!(
            "#[dim]{}",
            if patched {
                "nothing recorded yet"
            } else {
                "nothing running"
            }
        ));
    }

    let fit_rows = client_size(client, "height", 24).saturating_sub(if patched { 6 } else { 7 });
    let hidden = rows.len().saturating_sub(fit_rows);
    if hidden > 0 {
        rows.truncate(fit_rows.saturating_sub(1));
    }

    m.rows(rows);

    if hidden > 0 {
        m.info(format!("#[dim]+{} more", hidden + 1));
    }
    if !patched {
        m.info("#[dim]read-only · lsyncd unpatched".into());
    }

    m.separator();
    m.item(
        "#[dim]‹  back".into(),
        "b",
        again(&format!("menu {client} {}", args.join(" "))),
    );
    m.show(client)
}

fn entry_menu(client: &str, key: &str, args: &[String]) -> Result<(), String> {
    let home = home();
    let e = registry::load(key).ok_or("unknown entry")?;
    let status = e.status();
    let mut m = Menu::new(client, &short_path(&e.label(), &home));

    let budget = m.budget(false).saturating_sub("-#[dim]".len());
    for (src, dst) in &e.syncs {
        let text = pair(&short_path(src, &home), &short_target(dst, &home), budget);
        m.info(format!("#[dim]{text}"));
    }

    let state = match status {
        Status::Running => "running",
        Status::Stopped => "stopped",
        Status::Crashed => "died",
    };
    let head = format!("{}#[dim]", dot(status_color(status), "●"));
    let pid = format!("{state} · pid {}", e.pid);
    let state = if status != Status::Stopped && head.len() + pid.len() < m.budget(false) {
        pid
    } else {
        state.into()
    };
    m.info(format!("{head}{state}"));
    m.separator();

    let action = |verb: &str| again(&format!("lsyncd {client} {verb} {key}"));
    if status == Status::Running {
        m.item(format!("{}stop", dot(GREY, "■")), "s", action("stop"));
        m.item(format!("{}restart", dot(TEAL, "↻")), "r", action("restart"));
    } else {
        m.item(format!("{}start", dot(GREEN, "▶")), "s", action("start"));
        m.item(format!("{}forget", dot(RED, "×")), "f", action("forget"));
    }

    m.separator();
    m.item(
        "#[dim]‹  back".into(),
        "b",
        again(&format!("lsyncd-menu {client} {}", args.join(" "))),
    );
    m.show(client)
}

fn lsyncd_action(client: &str, verb: &str, key: &str) -> Result<(), String> {
    let e = registry::load(key).ok_or("unknown entry")?;
    let name = short_path(&e.label(), &home());

    let (done, result) = match verb {
        "start" => ("started", e.start()),
        "stop" => ("stopped", e.stop()),
        "restart" => ("restarted", e.stop().and_then(|()| e.start())),
        "forget" => ("forgot", e.forget()),
        _ => return Err(format!("unknown action {verb}")),
    };

    match result {
        Ok(()) => {
            let room = client_width(client).saturating_sub(9 + done.len());
            toast(client, TEAL, &format!("{done} {}", fit(&name, room)))
        }
        Err(err) => toast(client, RED, &format!("{verb} failed: {err}")),
    }
}

fn toast(client: &str, color: &str, text: &str) -> Result<(), String> {
    let room = client_width(client).saturating_sub(8);
    let text: String = text.chars().take(room).collect();
    let width = text.chars().count() + 8;
    run(Command::new("tmux")
        .args([
            "display-popup",
            "-c",
            client,
            "-x",
            "R",
            "-y",
            "S",
            "-h",
            "3",
        ])
        .args(["-w", &width.to_string(), "-b", "rounded"])
        .args(["-S", &format!("fg={TEAL}"), "-s", &format!("bg={BG}")])
        .args(["-e", &format!("DAEMONS_TOAST={text}")])
        .args(["-e", &format!("DAEMONS_TOAST_COLOR={color}")])
        .args(["-e", &format!("DAEMONS_TOAST_CLIENT={client}")])
        .args(["-E", &format!("{} toast", exe())]))
}

fn rgb(hex: &str) -> String {
    let n = u32::from_str_radix(hex.trim_start_matches('#'), 16).unwrap_or(0xffffff);
    format!("{};{};{}", n >> 16, (n >> 8) & 0xff, n & 0xff)
}

fn paint_toast() {
    let text = env::var("DAEMONS_TOAST").unwrap_or_default();
    let color = env::var("DAEMONS_TOAST_COLOR").unwrap_or_else(|_| TEAL.into());
    print!(
        "\x1b[?25l  \x1b[38;2;{}m●\x1b[0m  \x1b[1;38;2;{}m{text}\x1b[0m",
        rgb(&color),
        rgb(FG)
    );
    let _ = std::io::stdout().flush();

    let raw = Command::new(STTY).args(["raw", "-echo"]).status();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buf = [0u8; 64];
        if let Ok(n @ 1..) = std::io::stdin().read(&mut buf) {
            let _ = tx.send(buf[..n].to_vec());
        }
    });

    let Ok(bytes) = rx.recv_timeout(Duration::from_millis(1600)) else {
        return;
    };
    let Ok(client) = env::var("DAEMONS_TOAST_CLIENT") else {
        return;
    };
    if raw.is_ok_and(|s| s.success()) {
        let hex: Vec<String> = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let _ = Command::new("tmux")
            .args(["run-shell", "-b", "-d", "0.05", "-C"])
            .arg(format!("send-keys -K -c {client} -H {}", hex.join(" ")))
            .status();
    }
}

fn usage() -> Result<(), String> {
    Err("usage: tmux-daemons segment [gpg] [ssh] [lsyncd]
       tmux-daemons menu <client> [gpg] [ssh] [lsyncd]
       tmux-daemons lsyncd-menu <client> [daemons]
       tmux-daemons entry-menu <client> <key> [daemons]
       tmux-daemons lsyncd <client> start|stop|restart|forget <key>"
        .into())
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let arg = |i: usize| args.get(i).map(String::as_str);

    let result = match (arg(0), arg(1)) {
        (Some("segment"), _) => {
            print!("{}", segment(&args[1..]));
            Ok(())
        }
        (Some("toast"), _) => {
            paint_toast();
            Ok(())
        }
        (Some("menu"), Some(client)) => menu(client, &args[2..]),
        (Some("lsyncd-menu"), Some(client)) => lsyncd_menu(client, &args[2..]),
        (Some("entry-menu"), Some(client)) => match arg(2) {
            Some(key) => entry_menu(client, key, &args[3..]),
            None => usage(),
        },
        (Some("lsyncd"), Some(client)) => match (arg(2), arg(3)) {
            (Some(verb), Some(key)) => lsyncd_action(client, verb, key),
            _ => usage(),
        },
        _ => usage(),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            if let (Some(cmd), Some(client)) = (arg(0), arg(1)) {
                if cmd.ends_with("menu") && toast(client, RED, &e).is_ok() {
                    return ExitCode::SUCCESS;
                }
            }
            eprintln!("tmux-daemons: {e}");
            ExitCode::FAILURE
        }
    }
}
