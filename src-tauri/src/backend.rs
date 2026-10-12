use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use tauri::{AppHandle, Manager, path::BaseDirectory};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(45);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Clone, Copy)]
enum ServiceStatus {
    Starting,
    Ready,
    Unavailable,
    Stopped,
}

struct BackendProcess {
    child: Child,
    port: u16,
    token: String,
    launcher_log: PathBuf,
}

struct ManagerState {
    status: ServiceStatus,
    process: Option<BackendProcess>,
    stopping: bool,
}

pub struct BackendManager {
    state: Mutex<ManagerState>,
}

impl BackendManager {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(ManagerState {
                status: ServiceStatus::Starting,
                process: None,
                stopping: false,
            }),
        }
    }

    pub fn public_status(&self) -> String {
        let Ok(state) = self.state.lock() else {
            return "unavailable".to_string();
        };

        match state.status {
            ServiceStatus::Starting => "starting",
            ServiceStatus::Ready => "ready",
            ServiceStatus::Unavailable | ServiceStatus::Stopped => "unavailable",
        }
        .to_string()
    }

    pub fn shutdown(&self) {
        let (port, token, log_path) = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.stopping = true;
            state.status = ServiceStatus::Stopped;
            let Some(process) = state.process.as_ref() else {
                return;
            };
            (
                process.port,
                process.token.clone(),
                process.launcher_log.clone(),
            )
        };

        append_log(&log_path, "Solicitando encerramento gracioso do backend.");
        if let Err(error) = local_request(port, "POST", "/api/desktop/shutdown", &token) {
            append_log(
                &log_path,
                &format!("O encerramento gracioso não respondeu: {error}"),
            );
        }

        let deadline = Instant::now() + SHUTDOWN_TIMEOUT;
        while Instant::now() < deadline {
            let exited = {
                let Ok(mut state) = self.state.lock() else {
                    return;
                };
                match state.process.as_mut() {
                    Some(process) => process.child.try_wait().ok().flatten().is_some(),
                    None => true,
                }
            };

            if exited {
                if let Ok(mut state) = self.state.lock() {
                    state.process.take();
                }
                append_log(&log_path, "Backend encerrado graciosamente.");
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }

        let process = self
            .state
            .lock()
            .ok()
            .and_then(|mut state| state.process.take());
        if let Some(mut process) = process {
            append_log(
                &log_path,
                "Tempo limite excedido; encerrando apenas o processo Java iniciado pelo aplicativo.",
            );
            let _ = process.child.kill();
            let _ = process.child.wait();
        }
    }
}

pub fn start(app: AppHandle) {
    thread::spawn(move || {
        if let Err(error) = start_and_monitor(&app) {
            mark_unavailable(&app, &error);
        }
    });
}

fn start_and_monitor(app: &AppHandle) -> Result<(), String> {
    let runtime = app
        .path()
        .resolve("java-runtime/bin/javaw.exe", BaseDirectory::Resource)
        .map_err(|error| format!("Não foi possível resolver o runtime Java: {error}"))?;
    let backend_jar = app
        .path()
        .resolve(
            "backend/finance-control-backend.jar",
            BaseDirectory::Resource,
        )
        .map_err(|error| format!("Não foi possível resolver o backend: {error}"))?;

    if !runtime.is_file() {
        return Err(format!(
            "Runtime Java não encontrado em {}",
            runtime.display()
        ));
    }
    if !backend_jar.is_file() {
        return Err(format!(
            "Backend não encontrado em {}",
            backend_jar.display()
        ));
    }

    let app_data = app
        .path()
        .app_local_data_dir()
        .map_err(|error| format!("Não foi possível resolver AppLocalData: {error}"))?;
    let data_dir = app_data.join("data");
    let logs_dir = app_data.join("logs");
    fs::create_dir_all(&data_dir)
        .map_err(|error| format!("Não foi possível criar o diretório de dados: {error}"))?;
    fs::create_dir_all(&logs_dir)
        .map_err(|error| format!("Não foi possível criar o diretório de logs: {error}"))?;
    verify_writable(&data_dir)?;

    let launcher_log = logs_dir.join("desktop.log");
    let backend_log = logs_dir.join("backend.log");
    let console_log = logs_dir.join("backend-console.log");
    rotate_log(&launcher_log)?;
    rotate_log(&backend_log)?;
    rotate_log(&console_log)?;
    append_log(&launcher_log, "Inicializando os serviços locais.");

    let manager = app.state::<BackendManager>();
    if manager.state.lock().map_err(lock_error)?.stopping {
        return Ok(());
    }

    let port = select_loopback_port()?;
    let token = random_session_token()?;
    let database = data_dir.join("finance-control.db");
    let stdout = open_log(&console_log)?;
    let stderr = stdout
        .try_clone()
        .map_err(|error| format!("Não foi possível duplicar o log do backend: {error}"))?;

    let mut command = Command::new(&runtime);
    command
        .arg("--enable-native-access=ALL-UNNAMED")
        .arg("-jar")
        .arg(&backend_jar)
        .arg("--spring.profiles.active=desktop")
        .arg("--server.address=127.0.0.1")
        .arg(format!("--server.port={port}"))
        .env("APP_FINANCE_DB_PATH", &database)
        .env("APP_FINANCE_SESSION_TOKEN", &token)
        .env("APP_FINANCE_LOG_PATH", &backend_log)
        .env_remove("DEBUG")
        .current_dir(&app_data)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));

    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);

    let mut child = command
        .spawn()
        .map_err(|error| format!("Não foi possível iniciar o backend: {error}"))?;

    {
        let mut state = manager.state.lock().map_err(lock_error)?;
        if state.stopping {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(());
        }
        state.process = Some(BackendProcess {
            child,
            port,
            token: token.clone(),
            launcher_log: launcher_log.clone(),
        });
    }

    let deadline = Instant::now() + STARTUP_TIMEOUT;
    loop {
        {
            let mut state = manager.state.lock().map_err(lock_error)?;
            if state.stopping {
                return Ok(());
            }
            if let Some(exit_status) = state
                .process
                .as_mut()
                .and_then(|process| process.child.try_wait().ok().flatten())
            {
                state.process.take();
                return Err(format!(
                    "O backend encerrou durante a inicialização ({exit_status})."
                ));
            }
        }

        if let Ok(response) = local_request(port, "GET", "/api/desktop/status", &token) {
            if response.status == 200 && response.body.trim() == r#"{"status":"ready"}"# {
                let mut state = manager.state.lock().map_err(lock_error)?;
                state.status = ServiceStatus::Ready;
                append_log(&launcher_log, "Backend autenticado e pronto.");
                break;
            }
        }

        if Instant::now() >= deadline {
            stop_failed_process(app);
            return Err("Tempo limite de 45 segundos excedido ao iniciar o backend.".to_string());
        }
        thread::sleep(Duration::from_millis(250));
    }

    loop {
        thread::sleep(Duration::from_secs(1));
        let exit_status = {
            let mut state = manager.state.lock().map_err(lock_error)?;
            if state.stopping {
                return Ok(());
            }
            state
                .process
                .as_mut()
                .and_then(|process| process.child.try_wait().ok().flatten())
        };
        if let Some(exit_status) = exit_status {
            if let Ok(mut state) = manager.state.lock() {
                state.process.take();
            }
            return Err(format!(
                "O backend encerrou inesperadamente ({exit_status})."
            ));
        }
    }
}

fn stop_failed_process(app: &AppHandle) {
    let process = app
        .state::<BackendManager>()
        .state
        .lock()
        .ok()
        .and_then(|mut state| state.process.take());
    if let Some(mut process) = process {
        let _ = process.child.kill();
        let _ = process.child.wait();
    }
}

fn mark_unavailable(app: &AppHandle, error: &str) {
    let manager = app.state::<BackendManager>();
    let log_path = manager
        .state
        .lock()
        .ok()
        .and_then(|mut state| {
            if state.stopping {
                return None;
            }
            state.status = ServiceStatus::Unavailable;
            state
                .process
                .as_ref()
                .map(|process| process.launcher_log.clone())
        })
        .or_else(|| {
            app.path()
                .app_local_data_dir()
                .ok()
                .map(|path| path.join("logs").join("desktop.log"))
        });

    if let Some(path) = log_path {
        append_log(&path, &format!("Falha na inicialização: {error}"));
    }
}

fn select_loopback_port() -> Result<u16, String> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .map_err(|error| format!("Não foi possível selecionar uma porta local: {error}"))?;
    let port = listener
        .local_addr()
        .map_err(|error| format!("Não foi possível identificar a porta local: {error}"))?
        .port();
    drop(listener);
    Ok(port)
}

fn random_session_token() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|error| format!("Não foi possível gerar o segredo da sessão: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

struct HttpResponse {
    status: u16,
    body: String,
}

fn local_request(port: u16, method: &str, path: &str, token: &str) -> Result<HttpResponse, String> {
    let mut stream = TcpStream::connect_timeout(
        &("127.0.0.1", port)
            .to_socket_addrs()
            .map_err(|error| format!("Endereço local inválido: {error}"))?
            .next()
            .ok_or_else(|| "Endereço local indisponível".to_string())?,
        Duration::from_secs(1),
    )
    .map_err(|error| format!("Serviço local indisponível: {error}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| format!("Não foi possível configurar a leitura local: {error}"))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| format!("Não foi possível configurar a escrita local: {error}"))?;

    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX-App-Session: {token}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|error| format!("Não foi possível enviar a requisição local: {error}"))?;

    let mut bytes = Vec::new();
    stream
        .take(64 * 1024)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("Não foi possível ler a resposta local: {error}"))?;
    let response = String::from_utf8_lossy(&bytes);
    let (head, body) = response
        .split_once("\r\n\r\n")
        .ok_or_else(|| "Resposta HTTP local inválida".to_string())?;
    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| "Status HTTP local inválido".to_string())?;
    Ok(HttpResponse {
        status,
        body: body.to_string(),
    })
}

fn verify_writable(directory: &Path) -> Result<(), String> {
    let name = format!(
        ".write-check-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let path = directory.join(name);
    File::create(&path)
        .map_err(|error| format!("O diretório de dados não permite escrita: {error}"))?;
    fs::remove_file(&path).map_err(|error| {
        format!("Não foi possível concluir o teste do diretório de dados: {error}")
    })
}

fn rotate_log(path: &Path) -> Result<(), String> {
    let Ok(metadata) = fs::metadata(path) else {
        return Ok(());
    };
    if metadata.len() <= MAX_LOG_BYTES {
        return Ok(());
    }

    let rotated = path.with_extension(format!(
        "{}.1",
        path.extension()
            .and_then(|value| value.to_str())
            .unwrap_or("log")
    ));
    if rotated.exists() {
        fs::remove_file(&rotated)
            .map_err(|error| format!("Não foi possível remover o log antigo: {error}"))?;
    }
    fs::rename(path, rotated).map_err(|error| format!("Não foi possível rotacionar o log: {error}"))
}

fn open_log(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("Não foi possível abrir o log local: {error}"))
}

fn append_log(path: &Path, message: &str) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut file) = open_log(path) {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let _ = writeln!(file, "[{timestamp}] {message}");
    }
}

fn lock_error<T>(error: std::sync::PoisonError<T>) -> String {
    format!("Estado interno indisponível: {error}")
}

use std::net::ToSocketAddrs;
