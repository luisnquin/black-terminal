use std::{
    env, fs,
    os::unix::process::CommandExt,
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const KILL: &str = match option_env!("KILL") {
    Some(p) => p,
    None => "kill",
};

#[derive(Clone, Copy, PartialEq)]
pub enum Status {
    Running,
    Stopped,
    Crashed,
}

pub struct Entry {
    pub key: String,
    path: PathBuf,
    state: String,
    pub pid: i32,
    updated: u64,
    cwd: String,
    args: Vec<String>,
    pub syncs: Vec<(String, String)>,
}

fn dir() -> Option<PathBuf> {
    let base = match env::var("XDG_STATE_HOME") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from(env::var("HOME").ok().filter(|h| !h.is_empty())?).join(".local/state"),
    };
    Some(base.join("lsyncd"))
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn alive(pid: i32) -> bool {
    pid > 0 && cmdline(pid).is_some_and(|a| is_lsyncd(&a))
}

fn is_lsyncd(args: &[String]) -> bool {
    args.first()
        .is_some_and(|a| a.rsplit('/').next() == Some("lsyncd"))
}

#[cfg(target_os = "linux")]
fn cmdline(pid: i32) -> Option<Vec<String>> {
    let raw = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    Some(
        raw.split(|b| *b == 0)
            .filter(|a| !a.is_empty())
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect(),
    )
}

#[cfg(not(target_os = "linux"))]
fn cmdline(pid: i32) -> Option<Vec<String>> {
    let out = Command::new("ps")
        .args(["-o", "args=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    Some(
        String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .map(String::from)
            .collect(),
    )
}

#[cfg(target_os = "linux")]
fn processes() -> Vec<(i32, Vec<String>)> {
    let Ok(dir) = fs::read_dir("/proc") else {
        return Vec::new();
    };
    dir.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok())
        .filter(|pid| {
            fs::read_to_string(format!("/proc/{pid}/comm")).is_ok_and(|c| c.trim() == "lsyncd")
        })
        .filter_map(|pid| Some((pid, cmdline(pid)?)))
        .collect()
}

#[cfg(not(target_os = "linux"))]
fn processes() -> Vec<(i32, Vec<String>)> {
    let Ok(out) = Command::new("ps").args(["-axo", "pid=,args="]).output() else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut words = l.split_whitespace();
            let pid = words.next()?.parse().ok()?;
            Some((pid, words.map(String::from).collect()))
        })
        .collect()
}

pub fn patched() -> bool {
    Command::new("lsyncd")
        .arg("-version")
        .stdin(Stdio::null())
        .output()
        .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains("Registry: "))
}

pub struct Process {
    pub syncs: Vec<(String, String)>,
    pub config: Option<String>,
}

fn invocation(args: &[String]) -> Process {
    let mut p = Process {
        syncs: Vec::new(),
        config: None,
    };
    let mut it = args.iter().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "-rsync" | "-direct" => {
                if let (Some(s), Some(t)) = (it.next(), it.next()) {
                    p.syncs.push((s.clone(), t.clone()));
                }
            }
            "-rsyncssh" => {
                if let (Some(s), Some(h), Some(d)) = (it.next(), it.next(), it.next()) {
                    p.syncs.push((s.clone(), format!("{h}:{d}")));
                }
            }
            "-delay" | "-log" | "-logfile" | "-pidfile" => {
                it.next();
            }
            _ if a.starts_with('-') => {}
            _ => p.config = Some(a.clone()),
        }
    }
    p
}

pub fn unmanaged(entries: &[Entry]) -> Vec<Process> {
    let known: Vec<i32> = entries
        .iter()
        .filter(|e| e.status() == Status::Running)
        .map(|e| e.pid)
        .collect();
    processes()
        .into_iter()
        .filter(|(pid, args)| !known.contains(pid) && is_lsyncd(args))
        .map(|(_, args)| invocation(&args))
        .collect()
}

fn parse(key: String, path: PathBuf) -> Option<Entry> {
    let text = fs::read_to_string(&path).ok()?;
    let mut entry = Entry {
        key,
        path,
        state: String::new(),
        pid: 0,
        updated: 0,
        cwd: "/".into(),
        args: Vec::new(),
        syncs: Vec::new(),
    };

    for line in text.lines() {
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        match k {
            "state" => entry.state = v.into(),
            "pid" => entry.pid = v.parse().unwrap_or(0),
            "updated" => entry.updated = v.parse().unwrap_or(0),
            "cwd" => entry.cwd = v.into(),
            "arg" => entry.args.push(v.into()),
            "sync" => {
                let (src, dst) = v.split_once('\t').unwrap_or((v, "?"));
                entry.syncs.push((src.into(), dst.into()));
            }
            _ => {}
        }
    }

    Some(entry)
}

fn valid(key: &str) -> bool {
    !key.is_empty()
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

pub fn load(key: &str) -> Option<Entry> {
    if !valid(key) {
        return None;
    }
    parse(key.into(), dir()?.join(format!("{key}.reg")))
}

pub fn all() -> Vec<Entry> {
    let Some(read) = dir().and_then(|d| fs::read_dir(d).ok()) else {
        return Vec::new();
    };

    let mut entries: Vec<Entry> = read
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            let key = name.strip_suffix(".reg").filter(|k| valid(k))?.to_string();
            parse(key, e.path())
        })
        .collect();

    entries.sort_by_key(Entry::label);
    entries
}

impl Entry {
    pub fn status(&self) -> Status {
        match (self.state.as_str(), alive(self.pid)) {
            (_, true) => Status::Running,
            ("running", false) => Status::Crashed,
            _ => Status::Stopped,
        }
    }

    pub fn label(&self) -> String {
        self.syncs
            .first()
            .map_or_else(|| self.key.clone(), |(src, _)| src.clone())
    }

    pub fn start(&self) -> Result<(), String> {
        if !patched() {
            return Err("lsyncd is unpatched".into());
        }
        if self.status() == Status::Running {
            return Err("already running".into());
        }

        let since = now();
        let mut child = Command::new("lsyncd")
            .args(&self.args)
            .current_dir(&self.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map_err(|e| e.to_string())?;

        for _ in 0..40 {
            thread::sleep(Duration::from_millis(100));

            if let Ok(Some(code)) = child.try_wait() {
                if !code.success() {
                    return Err(code.code().map_or("killed".into(), |c| format!("exit {c}")));
                }
            }

            if let Some(e) = load(&self.key) {
                if e.updated >= since && e.status() == Status::Running {
                    return Ok(());
                }
            }
        }

        Err("no response".into())
    }

    pub fn stop(&self) -> Result<(), String> {
        if self.status() != Status::Running {
            return Ok(());
        }

        crate::run(Command::new(KILL).args(["-TERM", &self.pid.to_string()]))?;

        for _ in 0..300 {
            thread::sleep(Duration::from_millis(100));
            if !alive(self.pid) {
                return Ok(());
            }
        }

        Err("still alive".into())
    }

    pub fn forget(&self) -> Result<(), String> {
        if self.status() == Status::Running {
            return Err("still running".into());
        }
        fs::remove_file(&self.path).map_err(|e| e.to_string())
    }
}
