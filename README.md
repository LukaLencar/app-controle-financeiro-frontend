# Carbon Control — frontend

Bootstrap técnico da Fase 0 com React, TypeScript, Vite, React Router e CSS Modules. Requer Node.js 24 e npm (ambiente validado com npm 11).

No PowerShell, dentro de `frontend`:

```powershell
npm install
npm run dev
```

Abra o endereço informado pelo Vite, normalmente `http://localhost:5173`. `/` mostra o ambiente local; qualquer rota inexistente mostra a página 404 com link de retorno. Use Ctrl+C para parar.

Build:

```powershell
npm run build
```

Saída em `dist`. CI utiliza `npm ci` e `npm run build`. O lockfile mantém as versões instaladas. A tela confirma apenas a inicialização do frontend; não consulta o backend e não contém funcionalidades financeiras ou autenticação.

## Desktop / Tauri — desenvolvimento

Requer Node.js 24, npm 11, Rust stable MSVC (`stable-x86_64-pc-windows-msvc`), Microsoft C++ Build Tools com ferramentas C++ x86/x64 e Windows SDK, além do WebView2 Runtime. Após instalar Rust, reabra o terminal para atualizar o PATH.

```powershell
npm install
npm run dev
npm run build
npm run desktop:dev
npm run desktop:build:no-bundle
```

Execute os servidores web e desktop separadamente: ambos usam `http://localhost:5173`, com porta fixa e `strictPort`. `desktop:dev` inicia o Vite automaticamente; encerre com Ctrl+C. O build desktop chama o build web e produz `src-tauri/target/release/finance-control-desktop.exe`, sem MSI ou NSIS.

Nesta Fase 0.5B1, Tauri é somente o shell desktop. Spring Boot não é iniciado automaticamente; SQLite continua pertencendo ao backend. Não há plugins Tauri, acesso ao banco ou integração com API. Os ícones são provisórios do template. O instalador final e a CI Windows serão definidos posteriormente; a CI atual continua validando somente o frontend web em Linux.
