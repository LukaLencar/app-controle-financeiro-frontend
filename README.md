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
