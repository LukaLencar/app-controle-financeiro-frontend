# Carbon Control — frontend

Frontend técnico do App Controle Financeiro com React, TypeScript, Vite, React Router e CSS Modules. Requer Node.js 24 e npm 11 para desenvolvimento web.

## Desenvolvimento web

No PowerShell, dentro de `frontend`:

```powershell
npm ci
npm run dev
```

O Vite informa o endereço local, normalmente `http://localhost:5173`. A rota `/` mostra a fundação técnica; rotas inexistentes mostram a página 404. No navegador, a tela informa que os serviços locais não foram iniciados e não tenta executar o backend.

Para validar o build web:

```powershell
npm run build
```

## Desenvolvimento desktop integrado

Além de Node.js e npm, o build desktop requer Rust stable MSVC, Microsoft C++ Build Tools, Windows SDK, WebView2 Runtime e JDK 25 com `jlink`. O backend deve permanecer no repositório irmão `../backend`, ou seu caminho deve ser informado ao script.

Prepare o JAR e o runtime Java, teste-os de forma isolada e depois inicie o Tauri:

```powershell
npm run desktop:prepare
npm run desktop:dev
```

O atalho abaixo executa os dois passos na sequência:

```powershell
npm run desktop:dev:integrated
```

`desktop:prepare` executa `mvnw.cmd clean verify`, gera uma imagem Java 25 com `jlink`, copia os recursos gerados para a área ignorada pelo Git e inicia o backend duas vezes contra um SQLite descartável. O teste usa diretamente o Java embarcado, com `JAVA_HOME` vazio e sem Java no `PATH` do processo filho.

## Distribuição Windows

Gere o aplicativo e o instalador NSIS por usuário com:

```powershell
npm run desktop:package
```

Para indicar outro backend sem gravar caminhos pessoais no repositório:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-desktop.ps1 `
  -BackendPath D:\caminho\para\backend
```

O instalador é criado em `src-tauri/target/release/bundle/nsis`. O JAR, a imagem Java, executáveis, instaladores e bancos gerados permanecem fora do controle de versão.

## Execução local

O código Rust resolve o JAR e o runtime pelos recursos oficiais do Tauri, cria `data` e `logs` no `AppLocalData` da aplicação e inicia `javaw.exe` sem console adicional. O SQLite definitivo é `data/finance-control.db`; ele fica fora da pasta de instalação e nunca é removido ou substituído pelo launcher.

O backend escuta em uma porta dinâmica de `127.0.0.1`. Um segredo criptográfico novo é entregue somente pela variável de ambiente do processo filho e valida os endpoints internos de status e shutdown. A interface recebe apenas `starting`, `ready` ou `unavailable` por um comando Tauri restrito. Ao sair, o Tauri solicita encerramento gracioso e, após o limite de cinco segundos, pode terminar somente o processo Java que ele próprio criou. O plugin oficial de instância única impede um segundo backend e traz a janela existente para frente.

Os logs técnicos ficam em `AppLocalData/logs` e têm rotação simples ao atingir 5 MiB. O segredo da sessão não é gravado. Loopback e segredo de sessão restringem a API local, mas não criptografam o arquivo SQLite nem protegem contra todo software malicioso executado pela mesma conta do Windows.

O uso normal depois da instalação não depende de internet, Java, Maven, Node.js, Rust, Docker, PostgreSQL ou SQLite instalados separadamente. O instalador usa o mecanismo oficial do Tauri para obter o WebView2 quando ele ainda não existe; por isso, a instalação em uma máquina sem WebView2 pode precisar de internet.
