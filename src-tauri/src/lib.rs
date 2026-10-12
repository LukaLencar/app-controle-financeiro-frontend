mod backend;

use tauri::{Manager, RunEvent};

#[tauri::command]
fn desktop_status(manager: tauri::State<'_, backend::BackendManager>) -> String {
    manager.public_status()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .manage(backend::BackendManager::new())
        .invoke_handler(tauri::generate_handler![desktop_status])
        .setup(|app| {
            backend::start(app.handle().clone());
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        if let RunEvent::ExitRequested { .. } = event {
            app_handle.state::<backend::BackendManager>().shutdown();
        }
    });
}
